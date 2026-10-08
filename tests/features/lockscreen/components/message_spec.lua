--[[--
features.lockscreen.components.message：自定义留言块结构。

@module tests.features.lockscreen.components.message_spec
--]]

local Assert = require("support.assert")

package.preload["utils.settings"] = function()
    return {
        get = function(name)
            assert(name == "features.lockscreen")
            return { lock_screen_custom_message = "自定义测试留言" }
        end,
    }
end
package.preload["features.lockscreen.components.quote_panel"] = function()
    return {
        blocks = function(text, source, position, wide)
            return { { text = text, source = source, position = position, wide = wide } }
        end,
    }
end
package.loaded["features.lockscreen.components.message"] = nil

local Message = require("features.lockscreen.components.message")

local msg = Message.blocks("center-center", true)
Assert.eq(msg[1].text, "自定义测试留言")
Assert.eq(msg[1].source, "留言")
