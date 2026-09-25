--[[--
utils.font 微信字体列表：进程内缓存也受 LIST_TTL 约束。

@module tests.utils.font_list_spec
--]]

local Assert = require("support.assert")
local Config = require("support.config")

package.preload["ffi/archiver"] = function() return {} end
package.preload["datastorage"] = function()
    return { getDataDir = function() return Config.dir() end }
end
package.preload["ui/font"] = function() return { fontmap = {}, faces = {} } end
package.preload["fontlist"] = function()
    return { fontinfo = {}, getFontList = function() return {} end }
end
package.preload["json"] = function()
    local Json = require("support.json_stub")
    return { decode = Json.decode, encode = Json.encode }
end
package.preload["util"] = function() return { findFiles = function() end } end
package.preload["libs/libkoreader-lfs"] = function()
    return { attributes = function() return nil end }
end
package.preload["utils.paths"] = function()
    -- 不存在的目录：磁盘缓存读不到也写不进，只剩内存与 http.Cache 两层。
    return {
        fontsDir = function() return Config.dir() .. "/font_list_spec_absent" end,
        ensureFonts = function() end,
    }
end
package.preload["utils.settings"] = function()
    return { get = function() return {} end }
end
package.preload["http.cache"] = function()
    return {
        key = function() return "font-list" end,
        set = function() end,
        getAsync = function(_, cb) cb(nil); return { cancel = function() end } end,
    }
end
local fetches = 0
package.preload["http.request"] = function()
    return {
        ok = function(code) return code == 200 end,
        request = function(_, cb)
            fetches = fetches + 1
            cb({ code = 200, body = '{"items":[{"id":"f1","name":"F1","url":"https://x/f1.zip"}]}' })
            return { cancel = function() end }
        end,
    }
end
package.preload["workers.job"] = function()
    return {
        run = function(worker, opts)
            opts.on_done(worker())
            return { cancel = function() end }
        end,
    }
end

package.loaded["utils.font"] = nil
local MoonFont = require("utils.font")

local items
local function list()
    MoonFont.listAsync(false, function(result) items = result end)
end

list()
Assert.eq(fetches, 1)
Assert.eq(items[1].id, "f1")

-- TTL 内：命中内存，不联网。
list()
Assert.eq(fetches, 1)

-- 过了 7 天：内存缓存失效，必须重新拉。
local real_time = os.time
os.time = function() return real_time() + 8 * 24 * 3600 end
list()
os.time = real_time
Assert.eq(fetches, 2, "内存缓存不能绕过 TTL")

return true
