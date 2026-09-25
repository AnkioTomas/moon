--[[--
主体：热点新闻。序号是列，标题是正文。布局与取数继承历史上的今天（history.lua）。

@module koplugin.book.ui.desktop.home.views.news
--]]

local UI = require("ui.components.bookui")
local _ = require("gettext")

---@class BookHomeNews : BookHomeHistory
---@field data string[]|nil 日报新闻标题数组
local M = setmetatable({
    id = "news",
    label = _("热点新闻"),
    icon = "newspaper",
    lines = 4,
    mark_w = 20,
    field = "news",
    markColor = UI.dim,
}, require("ui.desktop.home.views.history"))
M.__index = M

---@param i integer
---@return string mark
---@return string title
function M:row(i)
    local data = type(self.data) == "table" and self.data or {}
    return string.format("%02d", i), data[i] or (i == 1 and #data == 0 and "--" or "")
end

return M
