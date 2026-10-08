--[[--
未安装 kamare 时的漫画回落：不报错，按原路径下载后交内置阅读器。

@module tests.source.kavita.kamare_fallback_spec
--]]

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
        show = function() end,
    }
end

local cfg = { base_url = "https://host:port/kavita", api_key = "test-key", libraries = { ["10"] = true } }
package.preload["utils.settings"] = function()
    return { getSource = function() return cfg end, saveSource = function() end }
end

-- 漫画目录（cbz，单册）。
package.preload["source.toc"] = function()
    return {
        read = function()
            return { { idx = 1, chapterId = 77, volumeId = 5, libraryId = 10, seriesId = 42, pages = 30, format = "cbz", title = "第 1 话", toc_version = 3 } }
        end,
        index = function() return nil end,
        put = function() return true end,
        drop = function() end,
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
    return { new = function() return { show = function() end, close = function() end, reportProgress = function() end } end }
end

local download_calls = {}
package.preload["http.request"] = function()
    return {
        download = function(opts, dest, cb)
            download_calls[#download_calls + 1] = { opts = opts, dest = dest }
            local file = io.open(dest, "wb")
            if file then file:write("PK\003\004fake cbz"); file:close() end
            cb(true, nil)
            return { cancel = function() end }
        end,
    }
end

local touch_calls = {}
package.preload["book.store"] = function()
    return {
        touch = function(path, identity, opts) touch_calls[#touch_calls + 1] = { path = path, identity = identity, opts = opts }; return true end,
        toc = function() return nil end,
        clearCache = function() return true end,
        markDeleted = function() return true end,
        reconcile = function() return { pulled = 0, pushed = 0, hidden = 0, conflicts = 0, skipped = false } end,
    }
end

package.preload["db.book"] = function()
    return { upsertLocal = function() return true end, touchPath = function() return true end, get = function() return nil end }
end

-- 注意：不 preload kamareimageviewer → Kamare.available() 为 false（模拟未安装）。

local Kavita = require("source.kavita")
local source = Kavita.new()

-- 清掉沙箱残留册文件，确保走到下载。
local Paths = require("utils.paths")
os.remove(Paths.bookWorkDir("42", "kavita") .. "/1.cbz")

local result, err, opts
source:openBookAsync(
    { source_id = "kavita", stable_id = "42", book = { title = "Comic Series", format = "cbz" } },
    {},
    function(p, e, o) result, err, opts = p, e, o end
)

-- 无 kamare：正常下载回落，不报错，无第三态。
Assert.not_nil(result)
Assert.is_nil(err)
Assert.is_nil(opts)
Assert.matches(result, "/1%.cbz$")
Assert.len(download_calls, 1)
Assert.eq(download_calls[1].opts.url, "https://host:port/kavita/api/Download/chapter?chapterId=77")
Assert.len(touch_calls, 1)
Assert.eq(touch_calls[1].identity.stable_id, "42")
