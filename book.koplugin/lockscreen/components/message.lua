--[[--
主体：自定义留言。

@module koplugin.book.lockscreen.components.message
--]]

local MoonSettings = require("utils.settings")
local QuotePanel = require("lockscreen.components.quote_panel")
local U = require("lockscreen.components.util")
local _ = require("gettext")

local M = {
    id = "message",
    label = _("自定义留言"),
    layout = "quote",
    cache_key = function()
        return MoonSettings.get().lock_screen_custom_message or ""
    end,
}

-- 自定义留言沿用 quote 布局，空文本回退到公共默认句子。
--- 留言不需要网络请求，生成时直接读取当前配置。
---@param position string
---@param wide boolean
---@return table[]
function M.blocks(position, wide)
    local text = MoonSettings.get().lock_screen_custom_message
    if type(text) ~= "string" or text:match("^%s*$") then
        text = U.FALLBACK_MESSAGE
    end
    return QuotePanel.blocks(text, _("留言"), position, wide)
end

return M
