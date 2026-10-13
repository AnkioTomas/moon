--[[--
阅读页 AI 功能：划词「AI 解释」、问书手势、读完章节自动摘要（summary.lua）、开书前情提要（recap.lua）。

AI 请求本身走通用客户端 `require("ai")`（翻译、X-Ray 也用它）；这里只管阅读页入口与展示。
未配置 AI 时划词菜单不出现这个按钮。

@module koplugin.book.features.ai
--]]

require("l10n").apply()
local _ = require("gettext")

local Ai = {}

---@param plugin BookPlugin
local function onPage(plugin)
    require("features.ai.summary").onPage(plugin.ui)
end

--- 登记「问书」手势，事件由下面的 events 接住。
function Ai.onCreate()
    require("dispatcher"):registerAction("book_ai_ask", {
        category = "none",
        event = "BookAiAsk",
        title = _("问书"),
        reader = true,
    })
end

--- 翻页不拦截（返回 nil），其它模块照常收到。
Ai.events = {
    PageUpdate = onPage,
    PosUpdate = onPage,
    ---@param plugin BookPlugin
    BookAiAsk = function(plugin)
        if not plugin.ui.document then return false end
        if not require("ai").isConfigured() then
            require("ui.themes.widgets.toast"):new{ text = _("请先在月读设置中配置 AI 服务"), timeout = 3 }:show()
            return true
        end
        require("features.ai.explain").askBook(plugin.ui)
        return true
    end,
}

--- 往划词菜单加「AI 解释」；按钮键沿用 `12_ai_explain`，已保存的长按菜单顺序与开关照旧生效。
---@param plugin BookPlugin
function Ai.onReaderReady(plugin)
    require("features.ai.recap").onReaderReady()
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
