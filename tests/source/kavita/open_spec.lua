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
    }
end

local cfg = { base_url = "https://host:port/kavita", api_key = "test-key", libraries = { ["8"] = true } }
package.preload["utils.settings"] = function()
    return { getSource = function() return cfg end }
end

package.preload["source.toc"] = function()
    return {
        read = function() return { { idx = 1, chapterId = 7, volumeId = 3, libraryId = 8, pages = 100, format = "epub", toc_version = 3 } } end,
        put = function() return true end,
        drop = function() end,
    }
end

local network = { online = true }
package.preload["ui/network/manager"] = function()
    return {
        isOnline = function() return network.online end,
        isConnected = function() return network.online end,
        runWhenOnline = function(_, fn) if network.online then fn() end end,
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

local touch_calls = {}
package.preload["book.store"] = function()
    return {
        touch = function(path, identity, opts)
            touch_calls[#touch_calls + 1] = { path = path, identity = identity, opts = opts }
            return true
        end,
        markDeleted = function() return true end,
        reconcile = function() return { pulled = 0, pushed = 0, hidden = 0, conflicts = 0, skipped = false } end,
    }
end

local Kavita = require("source.kavita")
local source = Kavita.new()

-- 沙箱 test/ 跨次运行会残留上一轮下载的册文件；文件复用逻辑会把它们当成已缓存。
-- 清掉本轮用到的册文件，保证下载路径被真正走到。
local Paths = require("utils.paths")
os.remove(Paths.bookWorkDir("42", "kavita") .. "/1.epub")
os.remove(Paths.bookWorkDir("43", "kavita") .. "/1.epub")

local open_result
local open_err
source:openBookAsync({ source_id = "kavita", stable_id = "42", book = { title = "Test Book", format = "epub" } }, {}, function(path, err)
    open_result = path
    open_err = err
end)

Assert.not_nil(open_result)
Assert.is_nil(open_err)
Assert.len(download_calls, 1)
Assert.eq(download_calls[1].opts.url, "https://host:port/kavita/api/Download/chapter?chapterId=7")
Assert.len(touch_calls, 1)
Assert.eq(touch_calls[1].path, open_result)
Assert.eq(touch_calls[1].identity.stable_id, "42")
Assert.is_nil(touch_calls[1].opts)

local offline_cfg = { base_url = "https://host:port/kavita", api_key = "test-key", libraries = { ["8"] = true } }
cfg = offline_cfg
network.online = false
source = Kavita.new()

local offline_result
local offline_err
source:openBookAsync({ source_id = "kavita", stable_id = "43", book = { title = "Test Book", format = "epub" } }, {}, function(path, err)
    offline_result = path
    offline_err = err
end)

Assert.is_nil(offline_result)
Assert.not_nil(offline_err)
Assert.eq(offline_err, "网络不可用，请先连接 Wi-Fi")

-- 已下载书籍离线：直接复用本地文件，不发网络请求、不报错。
network.online = false
source = Kavita.new()
local downloaded = Paths.bookWorkDir("42", "kavita") .. "/1.epub"
local fh = io.open(downloaded, "wb")
fh:write("PK\003\004fake epub content")
fh:close()
local downloads_before = #download_calls
local reuse_result, reuse_err
source:openBookAsync(
    { source_id = "kavita", stable_id = "42", book = { title = "Test Book", format = "epub", path = downloaded } },
    {},
    function(path, err) reuse_result, reuse_err = path, err end
)
Assert.eq(reuse_result, downloaded)
Assert.is_nil(reuse_err)
Assert.eq(#download_calls, downloads_before)
