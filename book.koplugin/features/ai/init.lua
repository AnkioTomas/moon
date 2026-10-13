--[[--
阅读页 AI 功能：划词「AI 解释」。

AI 请求本身走通用客户端 `require("ai")`（翻译、X-Ray 也用它）；这里只管阅读页入口与展示。
未配置 AI 时划词菜单不出现这个按钮。

@module koplugin.book.features.ai
--]]

require("l10n").apply()
local _ = require("gettext")

local Ai = {}

--- 往划词菜单加「AI 解释」；按钮键沿用 `12_ai_explain`，已保存的长按菜单顺序与开关照旧生效。
---@param plugin BookPlugin
function Ai.onReaderReady(plugin)
    local ui = plugin.ui
    ui.highlight:addToHighlightDialog("12_ai_explain", function(this)
        return {
            text = _("AI 解释"),
            show_in_highlight_dialog_func = function()
                return require("ai").isConfigured()
            end,
            callback = require("ui.guard").wrap("ai explain", function()
                local selected = {
                    text = require("util").cleanupSelectedText(this.selected_text.text),
                    pos0 = this.selected_text.pos0,
                }
                this:onClose(true)
                require("features.ai.explain").run(this.ui, selected)
            end),
        }
    end)
end

return Ai
