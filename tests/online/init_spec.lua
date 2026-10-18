--[[--
各端点 ensure：过期才拉天气 / 一言 / 摸鱼日报 / 必应。
@module tests.online.init_spec
--]]

local Assert = require("support.assert")

package.preload["l10n"] = function() return { apply = function() end } end
package.preload["gettext"] = function() return function(s) return s end end
package.preload["json"] = function()
    return require("support.json_stub")
end
package.preload["device"] = function()
    return {
        screen = {
            getWidth = function() return 480 end,
            getHeight = function() return 800 end,
            isColorEnabled = function() return false end,
        },
    }
end

local cache_dir = (os.getenv("TMPDIR") or "/tmp") .. "/moon-online-init-spec"
os.execute("mkdir -p '" .. cache_dir .. "'")
os.execute("rm -f '" .. cache_dir .. "'/*.json")
package.preload["utils.paths"] = function()
    return {
        onlineCacheDir = function() return cache_dir end,
        ensureOnlineCache = function() end,
    }
end

local PNG = "\137PNG\r\n\26\nxxxx"
local requests = {}
package.preload["http.request"] = function()
    return {
        get = function(url, opts, cb)
            requests[#requests + 1] = { kind = "get", url = url, opts = opts, cb = cb }
            return { cancel = function() end }
        end,
        download = function(opts, dest, cb)
            requests[#requests + 1] = { kind = "download", url = opts.url, dest = dest }
            local file = io.open(dest, "wb")
            if file then
                file:write(PNG)
                file:close()
            end
            cb(true)
            return { cancel = function() end }
        end,
    }
end

package.preload["ui/network/manager"] = function()
    return { isConnected = function() return true end }
end

local by_key = {}
package.preload["workers.tasks"] = function()
    return {
        get = function(key) return by_key[key] end,
        enqueue = function(spec)
            by_key[spec.key] = spec
            spec.state = "running"
            spec.cancel = function()
                if spec.handle then spec.handle.cancel() end
                by_key[spec.key] = nil
            end
            spec.handle = spec.run(function() end, function()
                by_key[spec.key] = nil
            end)
            return spec
        end,
    }
end

package.preload["ui.guard"] = function()
    return {
        call = function(_label, fn, ...)
            return fn(...)
        end,
    }
end

local function ensureAll()
    for _idx, name in ipairs({ "weather", "hitokoto", "myrl", "bing" }) do
        require("online." .. name):ensure()
    end
end
ensureAll()
Assert.eq(#requests, 4)
Assert.eq(requests[1].url, "https://api.ankio.net/weather?city=")
Assert.eq(requests[2].url, "https://api.ankio.net/hitokoto")
Assert.eq(requests[3].url, "https://api.ankio.net/myrl?type=json")
Assert.eq(requests[4].url, "https://api.ankio.net/bing?type=json")

requests[1].cb('{"current_condition":[{"temp_C":"1","weatherCode":"113","weatherDesc":[{"value":"Sunny"}]}]}')
requests[2].cb('{"hitokoto":"月"}')
requests[3].cb('{"date":{"lunar":"初一"},"holiday":{},"history":[],"news":[],"quote":{}}')
requests[4].cb('{"link":"https://www.bing.com/th?id=OHR.x.jpg"}')
Assert.is_true(require("online.weather"):fresh())
Assert.is_true(require("online.bing"):fresh())
Assert.is_true(require("online.bing"):imageReady())
Assert.is_true(require("online.myrl"):imageReady())
Assert.eq(require("online.weather"):current().temp, "1")
Assert.eq(requests[5].kind, "download")
Assert.is_true(tostring(requests[5].url):find("myrl", 1, true) ~= nil)
Assert.eq(requests[6].kind, "download")
Assert.eq(requests[6].url, "https://www.bing.com/th?id=OHR.x.jpg")

requests = {}
ensureAll()
Assert.eq(#requests, 0, "未过期不拉网")

os.execute("rm -rf '" .. cache_dir .. "'")
return true
