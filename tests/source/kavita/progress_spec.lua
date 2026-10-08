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
    }
end

local cfg = { base_url = "https://host:port/kavita", api_key = "test-key" }
package.preload["utils.settings"] = function()
    return { getSource = function() return cfg end }
end

local book_format = "epub"
local book_path
package.preload["db.book"] = function()
    return { get = function() return { format = book_format, path = book_path } end }
end

-- 最小 epub：12 个 spine 都指向同一个文档（含 id 锚点），供 pageNum=11 → spine[11] 解析。
local epub_entries = {
    ["META-INF/container.xml"] =
        '<container><rootfiles><rootfile full-path="OEBPS/content.opf"/></rootfiles></container>',
    ["OEBPS/content.opf"] = (function()
        local items, refs = {}, {}
        for i = 0, 11 do
            items[#items + 1] = '<item id="x' .. i
                .. '" href="text00011.html" media-type="application/xhtml+xml"/>'
            refs[#refs + 1] = '<itemref idref="x' .. i .. '"/>'
        end
        return '<package><manifest>' .. table.concat(items) .. '</manifest><spine>'
            .. table.concat(refs) .. '</spine></package>'
    end)(),
    ["OEBPS/text00011.html"] =
        '<html><body><h2 id="b007">七</h2><p>正文</p></body></html>',
}
package.preload["ffi/archiver"] = function()
    return { Reader = { new = function()
        local scanned, i = {}, 0
        local keys = { "META-INF/container.xml", "OEBPS/content.opf", "OEBPS/text00011.html" }
        return {
            open = function() return true end,
            close = function() end,
            iterate = function()
                return function()
                    i = i + 1
                    local key = keys[i]
                    if not key then return nil end
                    scanned[key] = true
                    return { path = key, mode = "file" }
                end
            end,
            extractToMemory = function(_, key)
                if not scanned[key] then return nil end
                return epub_entries[key]
            end,
        }
    end } }
end

package.preload["book.progress"] = function()
    return {
        clampFraction = function(v)
            v = tonumber(v) or 0
            if v < 0 then return 0 elseif v > 1 then return 1 end
            return v
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

local pos, perr, pmeta
src:getProgressAsync(id, function(p, e, m) pos, perr, pmeta = p, e, m end)
Assert.not_nil(pos)
Assert.is_nil(perr)
Assert.eq(pos.fraction, 0.25)
-- Kavita pageNum 是 0-based spine：对外页码要 +1。
Assert.eq(pos.page, 31)
Assert.eq(pos.total_pages, 120)
Assert.eq(pos.locator, "/body/DocFragment[31]/body")
Assert.is_true(pmeta.page_level)

-- 已读完（pageNum == pages）：页码钳到末页，locator 落回最后一个 spine
progress_body = { chapterId = 11, pageNum = 120, seriesId = 42, volumeId = 5 }
local pdone
src:getProgressAsync(id, function(p) pdone = p end)
Assert.eq(pdone.fraction, 1)
Assert.eq(pdone.page, 120)
Assert.eq(pdone.locator, "/body/DocFragment[120]/body")

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
-- pageNum 取真实 spine（DocFragment[8] → 7），不是「内容比例 × 页数」。
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
Assert.eq(save_payloads[1].pageNum, 7)
-- 页内锚点 = //body + body 相对完整路径（无名段补 [1]）。
Assert.eq(save_payloads[1].bookScrollId, "//body/section[1]/p[3]")
Assert.len(mark_payloads, 0)

save_payloads, mark_payloads = {}, {}
src:putProgressAsync(id, { fraction = 1, locator = "/body/DocFragment[120]/body/p[3]/text().0" }, function() end)
-- 最后一屏读完：pageNum = pages（Kavita 的「已读完」约定）而非 pages-1
Assert.eq(save_payloads[1].pageNum, 120)
Assert.eq(save_payloads[1].bookScrollId, "//body/p[3]")
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

-- 无 locator 的比例估算：真正读完前不得凑到 pages（Kavita 视 pageNum==pages 为本章已读完）。
toc_cache = { { idx = 1, chapterId = 11, pages = 24 } }
save_payloads, mark_payloads = {}, {}
src:putProgressAsync(id, { fraction = 0.98 }, function() end)
Assert.eq(save_payloads[1].pageNum, 23)
save_payloads, mark_payloads = {}, {}
src:putProgressAsync(id, { fraction = 1 }, function() end)
Assert.eq(save_payloads[1].pageNum, 24)

-- 漫画跳过
toc_cache = { { idx = 1, chapterId = 11, pages = 120 } }
save_payloads, mark_payloads = {}, {}
src:putProgressAsync({ source_id = "kavita", stable_id = "42", book = { format = "cbz" } }, { fraction = 0.5 }, function() end)
Assert.len(save_payloads, 0)

-- ── 多卷：进度按单册折算全书比例，回写时折回单册 ──────────────────────

toc_cache = {
    { idx = 1, chapterId = 11, volumeId = 5, libraryId = 8, pages = 100 },
    { idx = 2, chapterId = 12, volumeId = 6, libraryId = 8, pages = 100 },
}
local id2 = { source_id = "kavita", stable_id = "42", chapter_idx = 2, book = { format = "epub" } }

-- 第 2 册 50% → 全书 75%，章内 50%
progress_body = { chapterId = 12, pageNum = 50, seriesId = 42, volumeId = 6 }
local p2
src:getProgressAsync(id2, function(p) p2 = p end)
Assert.not_nil(p2)
Assert.eq(p2.fraction, 0.75)
Assert.eq(p2.chapter_idx, 2)
Assert.eq(p2.chapter_fraction, 0.5)
Assert.eq(p2.page, 51)
Assert.eq(p2.locator, "/body/DocFragment[51]/body")

-- 带章内比例回写：pageNum = 0.5 × 100
save_payloads, mark_payloads = {}, {}
src:putProgressAsync(id2, { fraction = 0.75, chapter_idx = 2, chapter_fraction = 0.5 }, function() end)
Assert.eq(save_payloads[1].pageNum, 50)
Assert.eq(save_payloads[1].chapterId, 12)
Assert.eq(save_payloads[1].volumeId, 6)

-- 只有全书比例（心跳脏行）：折回第 2 册 → 仍是 50
save_payloads, mark_payloads = {}, {}
src:putProgressAsync(id2, { fraction = 0.75 }, function() end)
Assert.eq(save_payloads[1].pageNum, 50)

-- 第 2 册读完（全书 100%）→ 本册 pageNum=100 且发 mark-chapter-read
save_payloads, mark_payloads = {}, {}
src:putProgressAsync(id2, { fraction = 1, chapter_idx = 2 }, function() end)
Assert.eq(save_payloads[1].pageNum, 100)
Assert.len(mark_payloads, 1)
Assert.eq(mark_payloads[1].chapterId, 12)

-- ── 网页端 bookScrollId = id("X")：用本地 epub 解析成 spine 内路径 ──────
-- Kavita 网页端进度存的是元素 id（不是 //body 路径）；解析后 locator 才带页内锚点，
-- 才能与本地 xpointer 比 spine 内先后、跳转才精准。
toc_cache = { { idx = 1, chapterId = 11, volumeId = 5, libraryId = 8, pages = 52 } }
book_path = "/fake/7540.epub"
progress_body = { chapterId = 11, pageNum = 11, seriesId = 42, volumeId = 5, bookScrollId = 'id("b007")' }
local pscroll
src:getProgressAsync(id, function(p) pscroll = p end)
Assert.not_nil(pscroll)
Assert.eq(pscroll.locator, "/body/DocFragment[12]/body/h2")
-- 无本地文件时退回「只到 spine」，不崩
book_path = nil
local pnopath
src:getProgressAsync(id, function(p) pnopath = p end)
Assert.eq(pnopath.locator, "/body/DocFragment[12]/body")

