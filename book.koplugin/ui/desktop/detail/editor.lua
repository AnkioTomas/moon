--[[-- 书籍详情元信息编辑。 @module ui.desktop.detail.editor --]]

local BookInfo = require("ui.components.bookinfo")
local Text = require("utils.text")
local Common = require("ui.desktop.detail.common")
local bookSupportsEdit = Common.bookSupportsEdit
local _ = require("gettext")

return function(Detail)
--- 编辑元信息对话框（书名/作者/分类/系列）。
function Detail:openEditor()
    local book = self.book or {}
    if type(book.source_id) ~= "string" or type(book.stable_id) ~= "string" then
        return
    end
    if not bookSupportsEdit(book, self.source) then
        require("ui/uimanager"):show(require("ui/widget/infomessage"):new{
            text = _("当前数据源不支持编辑"),
            timeout = 2,
        })
        return
    end
    local UIManager = require("ui/uimanager")
    local MultiInputDialog = require("ui/widget/multiinputdialog")
    local dialog
    dialog = MultiInputDialog:new{
        title = _("编辑元信息"),
        fields = {
            { text = book.title or "", hint = _("书名") },
            { text = BookInfo.author(book), hint = _("作者") },
            { text = book.category or "", hint = _("分类") },
            { text = book.series or "", hint = _("系列") },
        },
        buttons = { {
            {
                text = _("取消"),
                id = "close",
                callback = function()
                    UIManager:close(dialog)
                end,
            },
            {
                text = _("保存"),
                is_enter_default = true,
                callback = function()
                    local fields = dialog:getFields()
                    UIManager:close(dialog)
                    self:saveMeta(fields)
                end,
            },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--- 保存编辑结果到 books 表（进度/简介/md5 保留），完成后 reload 重绘。
--- 本地源：分类/系列即目录层级，改动会移动文件、stable_id 跟着变
---（opens/reading_stats/pending_progress 由 moveBook 里的 renameStableId 迁移）。
---@param fields table 对话框字段值：书名/作者/分类/系列
function Detail:saveMeta(fields)
    local book = self.book
    if type(book) ~= "table" or type(fields) ~= "table" then
        return
    end
    if not bookSupportsEdit(book, self.source) then
        return
    end
    --- 空串归一为 nil：空标题才能回退 stable_id 显示
    ---@param s any 待格式化的文本或状态值
    ---@return string|nil
    local function nonempty(s)
        s = Text.trim(type(s) == "string" and s or "")
        return s ~= "" and s or nil
    end
    local title = nonempty(fields[1])
    local authors = nonempty(fields[2])
    local category = nonempty(fields[3])
    local series = nonempty(fields[4])
    local can_move = book.source_id == "local"
        and self.source ~= nil and self.source.id == "local"
        and type(self.source.moveBook) == "function"
    if can_move and not category then
        series = nil -- 本地源系列必须挂在分类下，与扫盘派生语义一致
    end
    local move_err, new_stable_id
    if can_move then
        local moved, err = self.source:moveBook(book.stable_id, category, series)
        if not moved then
            move_err = err
        else
            new_stable_id = moved
        end
    end
    if not move_err then
        local sid = new_stable_id or book.stable_id
        local BookDB = require("db.book")
        local existing = BookDB.get(book.source_id, sid)
        BookDB.upsertLocal({
            source_id = book.source_id,
            stable_id = sid,
            title = title,
            authors = authors,
            category = category,
            series = series,
            intro = existing and existing.intro or nil,
            md5 = existing and existing.md5 or nil,
        })
    end
    if not self.lifecycle:uiReady() then
        return
    end
    local UIManager = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")
    if move_err then
        UIManager:show(InfoMessage:new{ text = move_err, timeout = 2 })
        return
    end
    if new_stable_id and new_stable_id ~= book.stable_id and self.book then
        self.book.stable_id = new_stable_id
    end
    self:reload()
    UIManager:show(InfoMessage:new{
        text = _("元数据已更新"),
        timeout = 1.5,
    })
end
end

