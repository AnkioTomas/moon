--[[--
主体：一言。

@module koplugin.book.features.lockscreen.components.hitokoto
--]]

local Hitokoto = require("online.hitokoto")
local QuotePanel = require("features.lockscreen.components.quote_panel")
local _ = require("gettext")

local M = {
    id = "hitokoto",
    label = _("一言"),
    needs_network = true,
    layout = "quote",
}

--- 由公共语句面板负责排版，本组件只转发文本和出处。
---@param position string
---@param wide boolean
---@param text string
---@param source string
---@return table[]
function M.blocks(position, wide, text, source)
    return QuotePanel.blocks(text, source, position, wide)
end

--- 未过期缓存优先；没有就用当天回退句，避免墨水屏空白。
---@param cb fun(text: string, source: string)
function M.ensureText(cb)
    local data = Hitokoto:current() or Hitokoto.fallback()
    cb(data.text, data.source or "")
end

return M
