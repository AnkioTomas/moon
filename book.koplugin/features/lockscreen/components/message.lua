--[[--
主体：自定义留言。

@module koplugin.book.features.lockscreen.components.message
--]]

local Settings = require("features.lockscreen.settings")
local QuotePanel = require("features.lockscreen.components.quote_panel")
local _ = require("gettext")

local M = {
    id = "message",
    label = _("自定义留言"),
    layout = "quote",
    cache_key = Settings.customMessage,
}

--- 留言不需要网络请求，生成时直接读取当前配置；空留言回退到公共默认句子。
---@param position string
---@param wide boolean
---@return table[]
function M.blocks(position, wide)
    return QuotePanel.blocks(Settings.customMessage(), _("留言"), position, wide)
end

return M
