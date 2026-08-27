--[[-- 阅读页快捷面板设置项可用性离线用例。 --]]

local Assert = require("support.assert")

package.preload["l10n"] = function() return { apply = function() end } end
package.preload["gettext"] = function() return function(value) return value end end

local saved = {
    quick_panel_reader_actions = { "toc" },
}
package.preload["utils.settings"] = function()
    return {
        get = function() return saved end,
        save = function(values) saved = values end,
    }
end

local ACTIONS = {
    toc = { id = "toc", title = "目录", icon = "menu_book", scope = "reader", run = function() end },
    dictionary = {
        id = "dictionary", title = "词典", icon = "book", scope = "reader",
        run = function() end,
    },
}
local ORDER = { "toc", "dictionary" }

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

Assert.is_true(findOption("dictionary").available)

ReaderPanel.setEnabled("dictionary", true)
Assert.is_true(findOption("dictionary").enabled)
