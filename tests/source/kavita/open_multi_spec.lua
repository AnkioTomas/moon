local Assert = require("support.assert")

package.preload["gettext"] = function()
    return function(text) return text end
end

local JsonStub = require("support.json_stub")
package.preload["json"] = function()
    return { encode = JsonStub.encode, decode = JsonStub.decode }
end

package.preload["ui/uimanager"] = function()
    return {
        nextTick = function(_, fn) fn() end,
        scheduleIn = function() end,
        unschedule = function() end,
        close = function() end,
    }
end

local cfg = { base_url = "https://host:port/kavita", api_key = "test-key", libraries = { ["8"] = true } }
package.preload["utils.settings"] = function()
    return { getSource = function() return cfg end }
end

local toc = {
    { idx = 1, chapterId = 11, volumeId = 5, libraryId = 8, seriesId = 42, pages = 100, format = "epub", title = "卷一", toc_version = 3 },
    { idx = 2, chapterId = 12, volumeId = 6, libraryId = 8, seriesId = 42, pages = 200, format = "epub", title = "卷二" },
}
local toc_puts = {}
package.preload["source.toc"] = function()
    return {
        read = function() return toc end,
        index = function() return nil end,
        put = function(_, stable_id, list) toc_puts[#toc_puts + 1] = { stable_id = stable_id, list = list }; return true end,
        drop = function() end,
    }
end

local upserts, touch_paths = {}, {}
package.preload["db.book"] = function()
    return {
        upsertLocal = function(row) upserts[#upserts + 1] = row; return true end,
        touchPath = function(...) touch_paths[#touch_paths + 1] = { ... }; return true end,
        get = function() return nil end,
    }
end

package.preload["ui/network/manager"] = function()
    return {
        isOnline = function() return true end,
        isConnected = function() return true end,
        runWhenOnline = function(_, fn) fn() end,
    }
end

package.preload["ui/widget/progressbardialog"] = function()
    return {
        new = function(_, opts)
            return {
                show = function() end,
                close = function() end,
                reportProgress = function() end,
            }
        end,
    }
end

local picker
package.preload["ui.views.popup"] = function()
    return {
        single = function(opts)
            picker = opts
            opts.on_select(2)
            return { close = function() end }
        end,
    }
end

local download_calls = {}
package.preload["http.request"] = function()
    return {
        download = function(opts, dest, cb)
            download_calls[#download_calls + 1] = { opts = opts, dest = dest }
            local file = io.open(dest, "wb")
            if file then
                file:write("PK\003\004fake epub content")
                file:close()
            end
            cb(true, nil)
            return { cancel = function() end }
        end,
    }
end

local touch_calls, clear_cache_calls = {}, {}
package.preload["book.store"] = function()
    return {
        touch = function(path, identity, opts)
            touch_calls[#touch_calls + 1] = { path = path, identity = identity, opts = opts }
            return true
        end,
        toc = function()
            return { { idx = 1, chapterId = 12, volumeId = 6, libraryId = 8, seriesId = 42, pages = 200, format = "epub", title = "卷二" } }
        end,
        clearCache = function(_, stable_id)
            clear_cache_calls[#clear_cache_calls + 1] = stable_id
            return true
        end,
        markDeleted = function() return true end,
        reconcile = function() return { pulled = 0, pushed = 0, hidden = 0, conflicts = 0, skipped = false } end,
    }
end

local Kavita = require("source.kavita")
local Paths = require("utils.paths")
local vol_dir = Paths.bookWorkDir("42:12", "kavita")
os.remove(vol_dir .. "/1.epub")

local source = Kavita.new()
local result, err
source:openBookAsync(
    { source_id = "kavita", stable_id = "42", book = { title = "Harry Potter", format = "epub", path = "/old/1.epub" } },
    {},
    function(path, e) result, err = path, e end
)

-- 弹选册，选中第 2 册后物化成独立册行
Assert.not_nil(picker)
Assert.eq(picker.title, "选择要阅读的卷册")
Assert.eq(#picker.items, 2)

Assert.len(upserts, 1)
Assert.eq(upserts[1].stable_id, "42:12")
Assert.eq(upserts[1].title, "卷二")
Assert.eq(upserts[1].cover, "42")
-- 旧模型给容器下过整本 → 物化册行时清掉容器缓存
Assert.len(clear_cache_calls, 1)
Assert.eq(clear_cache_calls[1], "42")

Assert.len(toc_puts, 1)
Assert.eq(toc_puts[1].stable_id, "42:12")
Assert.len(toc_puts[1].list, 1)
Assert.eq(toc_puts[1].list[1].chapterId, 12)
Assert.eq(toc_puts[1].list[1].seriesId, 42)
Assert.eq(toc_puts[1].list[1].idx, 1)
Assert.eq(toc_puts[1].list[1].toc_version, 3)

Assert.not_nil(result)
Assert.is_nil(err)
Assert.matches(result, "/1%.epub$")
Assert.len(download_calls, 1)
Assert.eq(download_calls[1].opts.url, "https://host:port/kavita/api/Download/chapter?chapterId=12")

-- 册行以整书模式登记：identity 是 42:12，且不带 chapter_idx
Assert.len(touch_calls, 1)
Assert.eq(touch_calls[1].identity.stable_id, "42:12")
Assert.is_nil(touch_calls[1].opts)
Assert.eq(touch_calls[1].path, result)

-- 直接打开册行：读单条 toc，命中已下载文件直接复用，不再弹选册、不重复下载。
local result_path = result
picker, result, err = nil, nil, nil
source:openBookAsync(
    { source_id = "kavita", stable_id = "42:12", book = { title = "卷二", format = "epub", path = result_path } },
    {},
    function(path, e) result, err = path, e end
)

Assert.is_nil(picker)
Assert.eq(result, result_path)
Assert.is_nil(err)
Assert.len(download_calls, 1)
Assert.len(touch_calls, 2)
Assert.eq(touch_calls[2].identity.stable_id, "42:12")
Assert.is_nil(touch_calls[2].opts)
