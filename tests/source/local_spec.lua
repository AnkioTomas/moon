--[[-- source.local：手动扫盘未配置目录时引导用户直接设置。 --]]

local Assert = require("support.assert")

package.preload["gettext"] = function()
    return function(text) return text end
end

local delegated = {}
package.preload["source.base"] = function()
    return {
        onEvent = function(_, event, payload)
            delegated[#delegated + 1] = { event = event, payload = payload }
        end,
    }
end

local cfg = {}
package.preload["utils.settings"] = function()
    return { getSource = function() return cfg end }
end
package.preload["source.local.client"] = function()
    return {
        new = function(client_cfg)
            return {
                configured = function()
                    return type(client_cfg.path) == "string" and client_cfg.path ~= ""
                end,
            }
        end,
    }
end

local shown
package.preload["ui/uimanager"] = function()
    return { show = function(_, widget) shown = widget end }
end
package.preload["ui/widget/confirmbox"] = function()
    return { new = function(_, opts) return opts end }
end

local opened_with
package.preload["source.local.setting"] = function()
    return { open = function(plugin) opened_with = plugin end }
end

local source = require("source.local").new()
local plugin = {}
local desktop = { plugin = plugin }

-- 后台生命周期不弹窗，继续交给基类按既有规则静默跳过。
source:onEvent("desktop_open", desktop)
Assert.len(delegated, 1)
Assert.eq(delegated[1].event, "desktop_open")
Assert.is_nil(shown)

-- 用户明确点刷新时必须说明原因，并提供直达目录选择器的按钮。
source:onEvent("library_refresh_request", desktop)
Assert.len(delegated, 1)
Assert.eq(shown.text, "请先设置本地书库目录，再扫描书籍。")
Assert.eq(shown.ok_text, "立即设置")
shown.ok_callback()
Assert.eq(opened_with, plugin)

-- 已配置目录时不改变原有扫盘事件流。
cfg.path = "/books"
source:onEvent("library_refresh_request", desktop)
Assert.len(delegated, 2)
Assert.eq(delegated[2].event, "library_refresh_request")

return true
