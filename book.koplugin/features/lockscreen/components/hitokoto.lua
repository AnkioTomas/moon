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
    -- 有缓存用正文；还在等网络时绑锁屏次数，不然回退句会挂很多天。
    cache_key = function()
        Hitokoto:ensure()
        local cur = Hitokoto:current()
        if cur then return cur.text end
        return Hitokoto.fallback().text
            .. require("features.lockscreen.cycle").pending(true)
    end,
}

--- 未过期缓存优先；没有就用当天回退句，避免墨水屏空白。
---@param position string
---@param wide boolean
---@return table[]
function M.blocks(position, wide)
    Hitokoto:ensure()
    local data = Hitokoto:current() or Hitokoto.fallback()
    return QuotePanel.blocks(data.text, data.source or "", position, wide)
end

return M
