--[[--
一言和背景必须独立获取，完成顺序不影响最终合成。

@module tests.lockscreen.styles.quote_async_spec
--]]

local Assert = require("support.assert")
local background_cb
local quote_cb
local rendered

package.preload["lockscreen.background"] = function()
    return {
        ensure = function(cb)
            background_cb = cb
            return { cancel = function() end }
        end,
    }
end
package.preload["lockscreen.context"] = function()
    return { highlight = function() end }
end
package.preload["lockscreen.render"] = function()
    return {
        size = function() return 480, 800 end,
        measureText = function(_, _, size) return size end,
        write = function(_, bg, blocks)
            rendered = { bg = bg, text = blocks[3].text }
            return true
        end,
    }
end
package.preload["http.request"] = function()
    return {
        get = function(_, _, cb)
            quote_cb = cb
            return { cancel = function() end }
        end,
    }
end
package.preload["json"] = function()
    return { decode = function() return { data = { hitokoto = "异步一言" } } end }
end
package.preload["utils.paths"] = function()
    return { lockScreenDir = function() return "/lock" end }
end
package.preload["utils.settings"] = function()
    local settings = { lock_screen_quote_mode = "hitokoto" }
    return { get = function() return settings end, save = function() end }
end
package.preload["ui/network/manager"] = function()
    return { isOnline = function() return true end }
end
package.preload["ffi/util"] = function()
    return { template = function(s) return s end }
end

local Quote = require("lockscreen.styles.quote")
local done
Quote.fetch(function(ok) done = ok end)

-- 背景未完成时，一言请求已经发出。
Assert.is_true(type(background_cb) == "function")
Assert.is_true(type(quote_cb) == "function")
quote_cb([[{"data":{"hitokoto":"异步一言"}}]])
Assert.is_nil(rendered)
background_cb("/bg.jpg")
Assert.is_true(done)
Assert.eq(rendered.bg, "/bg.jpg")
Assert.eq(rendered.text, "异步一言")
