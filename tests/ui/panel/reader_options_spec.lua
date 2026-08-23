--[[-- 阅读页快捷面板设置项可用性离线用例。 --]]

local Assert = require("support.assert")

package.preload["l10n"] = function() return { apply = function() end } end
package.preload["gettext"] = function() return function(value) return value end end

local saved = {
    quick_panel_reader_actions = { "toc" },
    quick_panel_reader_action_layout_renamed = true,
}
package.preload["utils.settings"] = function()
    return {
        get = function() return saved end,
        save = function(values) saved = values end,
    }
end

local ACTIONS = {
    toc = { id = "toc", title = "目录", icon = "menu_book", scope = "reader", run = function() end },
    preset = {
        id = "preset", title = "预设", icon = "article", scope = "reader",
        available = function(ctx) return ctx.ui == nil or ctx.ui.rolling ~= nil end,
        run = function() end,
    },
    layout = {
        id = "layout", title = "布局", icon = "format_size", scope = "reader",
        available = function(ctx)
            local ui = ctx and ctx.ui
            if not ui then return true end
            return ui.config ~= nil
        end,
        run = function() end,
    },
}
local ORDER = { "toc", "preset", "layout" }

package.preload["ui.panel.actions.registry"] = function()
    local Registry = {}
    function Registry.get(id) return ACTIONS[id] end
    function Registry.readerOrder() return ORDER end
    function Registry.available(action, ctx)
        if not action or not action.available then return true end
        return action.available(ctx) == true
    end
    function Registry.active() return false end
    return Registry
end

package.loaded["ui.panel.reader"] = nil
local ReaderPanel = require("ui.panel.reader")

local function findOption(id)
    for _, option in ipairs(ReaderPanel.options()) do
        if option.id == id then return option end
    end
end

Assert.is_true(findOption("layout").available)
Assert.is_true(findOption("preset").available)

ReaderPanel.setEnabled("layout", true)
Assert.is_true(findOption("layout").enabled)
