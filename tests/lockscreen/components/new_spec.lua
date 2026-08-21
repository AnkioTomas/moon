--[[--
lockscreen 新主体：message 块结构。

@module tests.lockscreen.components.new_spec
--]]

local Assert = require("support.assert")

package.preload["utils.settings"] = function()
    return {
        get = function()
            return { lock_screen_custom_message = "自定义测试留言" }
        end,
        save = function() end,
    }
end
package.preload["lockscreen.components.quote_panel"] = function()
    return {
        blocks = function(text, source, position, wide)
            return { { text = text, source = source, position = position, wide = wide } }
        end,
    }
end
package.loaded["lockscreen.components.message"] = nil

local Message = require("lockscreen.components.message")

local msg = Message.blocks("center-center", true)
Assert.eq(msg[1].text, "自定义测试留言")
Assert.eq(msg[1].source, "留言")
