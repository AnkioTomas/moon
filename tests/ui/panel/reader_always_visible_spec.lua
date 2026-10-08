--[[-- 阅读快捷面板：always_visible 动作即便不在面板勾选列表里也要显示（可用性仍按 available）。 --]]

local Assert = require("support.assert")

package.preload["gettext"] = function() return function(value) return value end end
package.preload["l10n"] = function() return { apply = function() end } end

local SYNC = {
    id = "pull_progress", title = "拉取进度", icon = "download", scope = "reader",
    always_visible = true,
    available = function(ctx) return ctx and ctx.ui ~= nil end,
}
local XRAY = {
    id = "xray", title = "X-Ray", icon = "xray", scope = "reader",
    available = function() return true end,
}

package.preload["ui.panel.action_list"] = function()
    return {
        create = function()
            return {
                ids = function() return { "xray" } end,
                setEnabled = function() end,
                move = function() end,
                options = function() return {} end,
            }
        end,
    }
end

package.preload["ui.panel.actions.registry"] = function()
    local Registry = {}
    function Registry.get(id)
        if id == "pull_progress" then return SYNC end
        if id == "xray" then return XRAY end
    end
    function Registry.readerOrder() return { "xray", "pull_progress" } end
    function Registry.available(action, ctx)
        if not action or not action.available then return true end
        return action.available(ctx) == true
    end
    function Registry.active() return false end
    return Registry
end

local ReaderPanel = require("ui.panel.reader")

-- 列表里只有 xray；pull_progress 不在列表但 always_visible 且可用 → 追加在末尾
local actions = ReaderPanel.actions({})
Assert.eq(#actions, 2)
Assert.eq(actions[1].id, "xray")
Assert.eq(actions[2].id, "pull_progress")

-- 不可用（非 Kavita）时不追加，也不进列表
SYNC.available = function() return false end
actions = ReaderPanel.actions({})
Assert.eq(#actions, 1)
Assert.eq(actions[1].id, "xray")

return true
