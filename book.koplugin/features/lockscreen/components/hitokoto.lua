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
    needs_network = function()
        return Hitokoto.configuredTtl() ~= 0
    end,
    layout = "quote",
    -- 有缓存（含过期）用固定那句；还在等网络且从未缓存时绑锁屏次数，不然回退句会挂很多天。
    -- ttl==0 时不联网：有缓存用缓存，没有再用内置句子。
    cache_key = function()
        Hitokoto:ensureConfigured()
        if #Hitokoto:quotes() > 0 then
            return Hitokoto.stable().text
        end
        return Hitokoto.fallback().text
            .. require("features.lockscreen.cycle").pending(true)
    end,
}

--- 已缓存句子按年积日固定取一句；没有就用当天回退句，避免墨水屏空白或闪来闪去。
---@param position string
---@param wide boolean
---@return table[]
function M.blocks(position, wide)
    Hitokoto:ensureConfigured()
    local data = Hitokoto.stable()
    return QuotePanel.blocks(data.text, data.source or "", position, wide)
end

return M
