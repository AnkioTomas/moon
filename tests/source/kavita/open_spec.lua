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
        read = function() return { { idx = 1, chapterId = 7, volumeId = 3, libraryId = 8, pages = 100 } } end,
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
source:openBookAsync({ source_id = "kavita", stable_id = "42", book = { title = "Test Book", format = "epub" } }, {}, function(path, err)
    offline_result = path
    offline_err = err
end)

Assert.is_nil(offline_result)
Assert.not_nil(offline_err)
Assert.eq(offline_err, "网络不可用，请先连接 Wi-Fi")
