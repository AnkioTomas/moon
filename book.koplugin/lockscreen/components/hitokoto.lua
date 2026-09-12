--[[--
主体：一言。

@module koplugin.book.lockscreen.components.hitokoto
--]]

local Hitokoto = require("online.hitokoto")
local QuotePanel = require("lockscreen.components.quote_panel")
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

--- 异步拉取一言；失败回落本地缓存。句柄挂调用方。
---@param cb fun(text: string, source: string)
---@return table|nil
function M.ensureText(cb)
    return Hitokoto:fetch({}, function(data)
        cb(data.text, data.source)
    end)
end

return M
