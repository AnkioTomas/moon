local Assert = require("support.assert")
local JsonStub = require("support.json_stub")

package.preload["gettext"] = function()
    return function(text) return text end
end
package.preload["json"] = function()
    return { encode = JsonStub.encode, decode = JsonStub.decode }
end
package.preload["ui/uimanager"] = function()
    return {
        nextTick = function(_, fn) fn() end,
        scheduleIn = function() end,
        unschedule = function() end,
    }
end

local cfg = { base_url = "https://host:port/kavita", api_key = "test-key", heartbeat_interval = 30 }
package.preload["utils.settings"] = function()
    return { getSource = function() return cfg end }
end

local book_format = "epub"
package.preload["db.book"] = function()
    return { get = function() return { format = book_format } end }
end

local heartbeat_rows, sync_calls = {}, {}
package.preload["book.progress"] = function()
    return {
        clampFraction = function(v)
            v = tonumber(v) or 0
            if v < 0 then return 0 elseif v > 1 then return 1 end
            return v
        end,
        recordHeartbeat = function(identity, pos)
            heartbeat_rows[#heartbeat_rows + 1] = { identity = identity, pos = pos }
            return true
        end,
        syncAsync = function(_, opts, cb)
            sync_calls[#sync_calls + 1] = opts
            if cb then cb({ pulled = 0, pushed = 0, hidden = 0, conflicts = 0, skipped = false }) end
        end,
    }
end

local toc_cache
package.preload["source.toc"] = function()
    return {
        read = function() return toc_cache end,
        put = function(_, _, list) toc_cache = list; return true end,
        drop = function() toc_cache = nil end,
    }
end

local volumes = {
    { id = 5, name = "Vol 1", seriesId = 42, chapters = {
        { id = 11, title = "Chapter 1", format = 3, pages = 120 },
    } },
}
local progress_body
local get_progress_calls = 0
local save_payloads, mark_payloads = {}, {}
package.preload["http.request"] = function()
    return {
        request = function(opts, cb)
            local url = opts.url or ""
            if url:match("/api/Series/volumes") then
                cb({ code = 200, body = JsonStub.encode(volumes) })
            elseif url:match("/api/Series/%d+") then
                cb({ code = 200, body = JsonStub.encode({ id = 42, libraryId = 8 }) })
            elseif url:match("/api/Reader/get%-progress") then
                get_progress_calls = get_progress_calls + 1
                if progress_body then
                    cb({ code = 200, body = JsonStub.encode(progress_body) })
                else
                    cb({ code = 404, body = "" })
                end
            elseif url:match("/api/Reader/mark%-chapter%-read") then
                mark_payloads[#mark_payloads + 1] = JsonStub.decode(opts.body)
                cb({ code = 200, body = "" })
            elseif url:match("/api/Reader/progress") then
                save_payloads[#save_payloads + 1] = JsonStub.decode(opts.body)
                cb({ code = 200, body = "" })
            else
                cb({ code = 404, body = "" })
            end
            return { cancel = function() end }
        end,
    }
end

local Kavita = require("source.kavita")

-- ── 章节目录解析（Series/volumes → toc）────────────────────────────

toc_cache = nil
local toc
Kavita.new():loadTocAsync({ source_id = "kavita", stable_id = "42" }, function(t) toc = t end)
Assert.not_nil(toc)
Assert.eq(#toc, 1)
Assert.eq(toc[1].chapterId, 11)
Assert.eq(toc[1].volumeId, 5)
Assert.eq(toc[1].libraryId, 8)
Assert.eq(toc[1].pages, 120)

-- ── getProgressAsync ──────────────────────────────────────────────

toc_cache = { { idx = 1, chapterId = 11, volumeId = 5, libraryId = 8, pages = 120 } }
progress_body = { chapterId = 11, pageNum = 30, seriesId = 42, volumeId = 5 }
local src = Kavita.new()
local id = { source_id = "kavita", stable_id = "42", book = { format = "epub" } }

local pos, perr
src:getProgressAsync(id, function(p, e) pos, perr = p, e end)
Assert.not_nil(pos)
Assert.is_nil(perr)
Assert.eq(pos.fraction, 0.25)
Assert.eq(pos.page, 30)
Assert.eq(pos.total_pages, 120)

progress_body = nil
local pos2, meta2
src:getProgressAsync(id, function(p, _, m) pos2, meta2 = p, m end)
Assert.is_nil(pos2)
Assert.is_true(meta2.empty)

book_format = "cbz"
get_progress_calls = 0
local pos3, meta3
src:getProgressAsync({ source_id = "kavita", stable_id = "42", book = { format = "cbz" } }, function(p, _, m)
    pos3, meta3 = p, m
end)
Assert.is_nil(pos3)
Assert.is_true(meta3.empty)
Assert.eq(get_progress_calls, 0)

-- ── putProgressAsync ──────────────────────────────────────────────

toc_cache = { { idx = 1, chapterId = 11, volumeId = 5, libraryId = 8, pages = 120 } }
save_payloads, mark_payloads = {}, {}
local ok
src:putProgressAsync(id, {
    fraction = 0.25,
    locator = "/body/DocFragment[8]/body/section/p[3]/text().0",
}, function(o) ok = o end)
Assert.is_true(ok)
Assert.len(save_payloads, 1)
Assert.eq(save_payloads[1].chapterId, 11)
Assert.eq(save_payloads[1].volumeId, 5)
Assert.eq(save_payloads[1].libraryId, 8)
Assert.eq(save_payloads[1].seriesId, 42)
Assert.eq(save_payloads[1].pageNum, 30)
Assert.eq(save_payloads[1].bookScrollId, "//body/p[3]")
Assert.len(mark_payloads, 0)

save_payloads, mark_payloads = {}, {}
src:putProgressAsync(id, { fraction = 1, locator = "/body/DocFragment[8]/body/section/p[3]/text().0" }, function() end)
Assert.eq(save_payloads[1].pageNum, 120)
Assert.len(mark_payloads, 1)
Assert.eq(mark_payloads[1].chapterId, 11)
Assert.eq(mark_payloads[1].seriesId, 42)
Assert.eq(mark_payloads[1].libraryId, 8)

-- 章元数据缺失：降级只发 pageNum/bookScrollId
toc_cache = { { idx = 1, pages = 100 } }
save_payloads, mark_payloads = {}, {}
local ok2
src:putProgressAsync(id, { fraction = 0.5 }, function(o) ok2 = o end)
Assert.is_true(ok2)
Assert.len(save_payloads, 1)
Assert.is_nil(save_payloads[1].chapterId)
Assert.eq(save_payloads[1].pageNum, 50)
Assert.is_nil(save_payloads[1].bookScrollId)

-- 漫画跳过
toc_cache = { { idx = 1, chapterId = 11, pages = 120 } }
save_payloads, mark_payloads = {}, {}
src:putProgressAsync({ source_id = "kavita", stable_id = "42", book = { format = "cbz" } }, { fraction = 0.5 }, function() end)
Assert.len(save_payloads, 0)

-- ── 翻页心跳 ──────────────────────────────────────────────────────

toc_cache = { { idx = 1, chapterId = 11, pages = 120 } }
do
    local hb = Kavita.new()
    heartbeat_rows, sync_calls = {}, {}
    local hb_id = { source_id = "kavita", stable_id = "42", book = { format = "epub" } }

    hb:onEvent("page_changed", { identity = hb_id, page = 3, total_pages = 100, percent = 10 })
    Assert.len(heartbeat_rows, 1)
    Assert.len(sync_calls, 1)

    hb:onEvent("page_changed", { identity = hb_id, page = 3, total_pages = 100, percent = 10 })
    Assert.len(heartbeat_rows, 1)

    hb:onEvent("page_changed", { identity = hb_id, page = 5, total_pages = 100, percent = 20 })
    Assert.len(heartbeat_rows, 1)

    hb._heartbeat.at = os.time() - 31
    hb:onEvent("page_changed", { identity = hb_id, page = 5, total_pages = 100, percent = 20 })
    Assert.len(heartbeat_rows, 2)
    Assert.len(sync_calls, 2)

    cfg.heartbeat_interval = 0
    heartbeat_rows = {}
    Kavita.new():onEvent("page_changed", { identity = hb_id, page = 1, total_pages = 100, percent = 1 })
    Assert.len(heartbeat_rows, 0)
    cfg.heartbeat_interval = 30

    heartbeat_rows = {}
    hb:onEvent("page_changed", {
        identity = { source_id = "kavita", stable_id = "42", book = { format = "cbz" } },
        page = 1, total_pages = 100, percent = 1,
    })
    Assert.len(heartbeat_rows, 0)
end
