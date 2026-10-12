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
    cache_key = function()
        return (Hitokoto:current() or Hitokoto.fallback()).text
    end,
}

--- 未过期缓存优先；没有就用当天回退句，避免墨水屏空白。
---@param position string
---@param wide boolean
---@return table[]
function M.blocks(position, wide)
    local data = Hitokoto:current() or Hitokoto.fallback()
    return QuotePanel.blocks(data.text, data.source or "", position, wide)
end

return M
