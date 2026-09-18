--[[--
数据源设置：混合模式挂在当前活跃源分区顶部。
@module tests.ui.desktop.settings.source_spec
--]]

local Assert = require("support.assert")

local mixed = false
local saved
package.preload["utils.settings"] = function()
    return {
        libraryMixed = function() return mixed end,
        zlibEnabled = function() return false end,
        save = function(patch) saved = patch end,
        activeSourceId = function() return "wechat" end,
    }
end
package.preload["source.registry"] = function()
    return {
        listEnabled = function()
            return {
                { id = "local", name = "本地" },
                { id = "wechat", name = "微信读书" },
            }
        end,
        list = function()
            return {
                { id = "local", name = "本地" },
                { id = "wechat", name = "微信读书" },
            }
        end,
        isEnabled = function() return true end,
        setEnabled = function() end,
        setActive = function() end,
    }
end
package.preload["source.wechat.setting"] = function()
    return {
        rows = function()
            return {
                function() return { id = "wechat-login" } end,
            }
        end,
    }
end
package.preload["source.local.setting"] = function()
    return {
        rowStatus = function() return "ok", true end,
        rows = function()
            return {
                function() return { id = "local-dir" } end,
            }
        end,
    }
end
package.preload["ui/widget/infomessage"] = function() return { new = function(_, o) return o end } end
package.preload["ui/uimanager"] = function() return { show = function() end } end
package.preload["ui.views.popup"] = function() return { sheet = function() end, list = function() end } end
package.preload["ui.components.settingrow"] = function()
    return {
        build = function(_, opts) return opts end,
    }
end
package.preload["gettext"] = function() return function(s) return s end end
package.preload["ffi/util"] = function()
    return { template = function(fmt, a, b) return fmt:gsub("%%1", tostring(a)):gsub("%%2", tostring(b or "")) end }
end
package.preload["zlib.setting"] = function() return {} end

package.loaded["ui.desktop.settings.source"] = nil
local Source = require("ui.desktop.settings.source")
local src = Source.new()
local sections = src:sections{
    desktop = { updateView = function() end, onEvent = function() end },
    plugin = nil,
    active_id = "wechat",
    active_name = "微信读书",
}

Assert.eq(sections[1].title, "书籍来源")
Assert.eq(#sections[1].rows, 2, "公共区只留当前源+启用列表")
Assert.eq(sections[2].title, "微信读书", "活跃源分区紧挨公共区")
Assert.eq(sections[2].rows[1]().title, "混合模式", "混合开关在活跃源分区第一行")
Assert.eq(sections[2].rows[2]().id, "wechat-login")

-- 点开混合开关会写 settings
sections[2].rows[1]().callback()
Assert.eq(saved.library_mixed, true)

return true
