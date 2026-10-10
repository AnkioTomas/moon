--[[-- 书籍详情元信息编辑。 @module desktop.detail.editor --]]

local Book = require("ui.widgets.book")
local Input = require("ui.themes.widgets.input")
local Toast = require("ui.themes.widgets.toast")
local Text = require("utils.text")
local Common = require("desktop.detail.common")
local bookSupportsEdit = Common.bookSupportsEdit
local _ = require("gettext")

return function(Detail)
--- 编辑元信息对话框（书名/作者/分类/系列）。
function Detail:openEditor()
    local book = self.book
    if not bookSupportsEdit(book, self.source) then
        Toast:new{ text = _("当前数据源不支持编辑"), timeout = 2 }:show()
        return
    end
    Input:new{
        title = _("编辑元信息"),
        fields = {
            { label = _("书名"), text = book.title or "" },
            { label = _("作者"), text = Book.author(book) },
            { label = _("分类"), text = book.category or "" },
            { label = _("系列"), text = book.series or "" },
        },
        ok_text = _("保存"),
        callback = function(...) self:saveMeta({ ... }) end,
    }:show()
end

--- 保存编辑结果到 books 表（进度/简介/md5 保留），完成后 reload 重绘。
--- 本地源：分类/系列即目录层级，改动会移动文件、stable_id 跟着变
---（opens/reading_stats/pending_progress 由 moveBook 里的 renameStableId 迁移）。
---@param fields table 对话框字段值：书名/作者/分类/系列
function Detail:saveMeta(fields)
    local book = self.book
    if not bookSupportsEdit(book, self.source) then
        return
    end
    --- 空串归一为 nil：空标题才能回退 stable_id 显示
    ---@param s string 输入框文本
    ---@return string|nil
    local function nonempty(s)
        s = Text.trim(s)
        return s ~= "" and s or nil
    end
    local title = nonempty(fields[1])
    local authors = nonempty(fields[2])
    local category = nonempty(fields[3])
    local series = nonempty(fields[4])
    local owner = Common.bookOwnerSource(book, self.source)
    local sid = book.stable_id
    if type(owner.moveBook) == "function" then
        if not category then
            series = nil -- 本地源系列必须挂在分类下，与扫盘派生语义一致
        end
        local moved, err = owner:moveBook(book.stable_id, category, series)
        if not moved then
            if not self.closed then Toast:new{ text = err, timeout = 2 }:show() end
            return
        end
        sid = moved
    end
    local BookDB = require("book.books_db")
    local existing = BookDB.get(book.source_id, sid)
    local saved = BookDB.upsertLocal({
        source_id = book.source_id,
        stable_id = sid,
        title = title,
        authors = authors,
        category = category,
        series = series,
        intro = existing and existing.intro or nil,
        md5 = existing and existing.md5 or nil,
    })
    if saved then
        owner:onEvent("book_meta_changed", {
            identity = { source_id = book.source_id, stable_id = sid },
            cover = false,
        })
    end
    if self.closed then return end
    book.stable_id = sid
    if not saved then
        Toast:new{ text = _("保存元信息失败"), timeout = 2 }:show()
        return
    end
    self:reload()
    Toast:new{ text = _("元数据已更新"), timeout = 1.5 }:show()
end
end

