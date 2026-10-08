--[[--
kamare 已安装但打开失败（抛异常）时的回落：不崩溃、不返回第三态，改下载 cbz 交内置阅读器。

覆盖两处新增 pcall：
  1. kamare.lua 的 Client:streamChapter（外部非公开方法）抛错；
  2. kavita.lua 的 Kamare.open 整体 pcall，Viewer.new 抛错。

@module tests.source.kavita.kamare_open_fail_spec
--]]

local Assert = require("support.assert")

package.preload["gettext"] = function()
    return function(text) return text end
end

local JsonStub = require("support.json_stub")
package.preload["json"] = function()
    return { encode = JsonStub.encode, decode = JsonStub.decode }
end

local warnings = {}
package.preload["utils.log"] = function()
    return {
        warn = function(...) warnings[#warnings + 1] = { ... } end,
        dbg = function() end,
        info = function() end,
        err = function(...) warnings[#warnings + 1] = { ... } end,
    }
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

local comic_toc = {
    { idx = 1, chapterId = 77, volumeId = 5, libraryId = 10, seriesId = 42, pages = 30, format = "cbz", title = "第 1 话", toc_version = 3 },
}
package.preload["source.toc"] = function()
    return {
        read = function() return comic_toc end,
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
        request = function(opts, cb)
            cb({ code = 404, body = "" })
            return { cancel = function() end }
        end,
    }
end

local touch_calls = {}
package.preload["book.store"] = function()
    return {
        touch = function(path, identity) touch_calls[#touch_calls + 1] = { path = path, identity = identity }; return true end,
        toc = function() return nil end,
        clearCache = function() return true end,
        markDeleted = function() return true end,
        reconcile = function() return { pulled = 0, pushed = 0, hidden = 0, conflicts = 0, skipped = false } end,
    }
end

package.preload["db.book"] = function()
    return { upsertLocal = function() return true end, touchPath = function() return true end, get = function() return nil end }
end

-- 可控的 kamare 桩：streamChapter / Viewer.new 都能按开关抛错。
local stream_should_throw = false
local viewer_should_throw = false
package.preload["kavitaclient"] = function()
    return {
        device_id = "dev-1",
        streamChapter = function()
            if stream_should_throw then error("streamChapter boom") end
            return { image_disposable = true }
        end,
        getFileDimensions = function() return {}, 200 end,
    }
end
package.preload["kamareimageviewer"] = function()
    return {
        new = function()
            if viewer_should_throw then error("viewer boom") end
            return nil -- 构造失败：Kamare.open 返回 nil,err
        end,
    }
end

local Kavita = require("source.kavita")
local source = Kavita.new()

local Paths = require("utils.paths")

local function openOnce()
    os.remove(Paths.bookWorkDir("42", "kavita") .. "/1.cbz")
    local result, err, opts
    source:openBookAsync(
        { source_id = "kavita", stable_id = "42", book = { title = "Comic Series", format = "cbz" } },
        {},
        function(p, e, o) result, err, opts = p, e, o end
    )
    return result, err, opts
end

-- 场景 1：streamChapter 抛错 → 回落下载，不返回第三态。
stream_should_throw = true
local result, err, opts = openOnce()
Assert.not_nil(result, "streamChapter 失败必须回落下载")
Assert.is_nil(err)
Assert.is_nil(opts)
Assert.matches(result, "/1%.cbz$")
Assert.len(download_calls, 1)

-- 场景 2：Viewer.new 抛错 → 同样回落下载。
stream_should_throw = false
viewer_should_throw = true
result, err, opts = openOnce()
Assert.not_nil(result, "viewer 构造失败必须回落下载")
Assert.is_nil(err)
Assert.is_nil(opts)
Assert.matches(result, "/1%.cbz$")
Assert.len(download_calls, 2)
Assert.len(touch_calls, 2)

Assert.is_true(#warnings >= 2, "回落必须写 warn 日志")
