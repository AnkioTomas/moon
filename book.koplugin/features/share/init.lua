--[[--
书摘分享：划词菜单与书摘列表可生成分享图片，不强制先划线。

经 `highlight.buttons` / `note.item_actions` 登记，下层不点名本 feature。

@module koplugin.book.features.share
--]]

require("l10n").apply()

local Ext = require("utils.extension")
local Paths = require("utils.paths")
local _ = require("gettext")

local Share = {}

local lfs = require("libs/libkoreader-lfs")

---@param stable_id string|nil
---@param source_id string|nil
---@return string|nil
local function coverOf(stable_id, source_id)
    if type(stable_id) ~= "string" or stable_id == "" then return nil end
    if type(source_id) ~= "string" or source_id == "" then return nil end
    local path = Paths.coverPath(stable_id, source_id)
    return lfs.attributes(path, "mode") == "file" and path or nil
end

--- 从当前阅读会话和文档属性收集书名、作者、章节、封面。
---@param highlight table|nil
---@param ctx { ui?: table, snapshot?: table }|nil
---@return table
local function bookContext(highlight, ctx)
    local Session = require("reader.session")
    local snapshot = ctx and ctx.snapshot
    if not snapshot then
        snapshot = Session.current()
    end
    local ui = (ctx and ctx.ui) or (highlight and highlight.ui) or (snapshot and snapshot.ui)
    local title, authors, chapter, source_id, stable_id
    if snapshot and snapshot.identity then
        local identity = snapshot.identity
        local book = identity.book or {}
        source_id, stable_id = identity.source_id, identity.stable_id
        title = book.title
        authors = book.authors
        chapter = Session.chapterTitle(snapshot)
    end
    local props = ui and (ui.doc_props or (ui.document and ui.document.file and ui.document.doc_props)) or {}
    title = title or props.display_title or props.title
    authors = authors or props.authors
    return {
        title = title or "",
        authors = authors or "",
        chapter = chapter or "",
        cover = coverOf(stable_id, source_id),
        source_id = source_id,
        stable_id = stable_id,
    }
end

---@param text any
---@return string
local function cleanText(text)
    if type(text) ~= "string" then return "" end
    text = require("util").cleanupSelectedText(text)
    return require("utils.text").trim(text)
end

--- 从划词菜单（新选区或已有高亮）收集分享内容。不保存划线。
---@param highlight table
---@param index number|nil 已有标注的序号
---@return table
function Share.payloadFromHighlight(highlight, index)
    local ctx = bookContext(highlight)
    local text, chapter
    if index and highlight and highlight.ui and highlight.ui.annotation then
        local item = highlight.ui.annotation.annotations and highlight.ui.annotation.annotations[index]
        if type(item) == "table" then
            text = item.text
            if type(item.chapter) == "string" and item.chapter ~= "" then chapter = item.chapter end
        end
    end
    if not text and highlight and highlight.selected_text then
        text = highlight.selected_text.text
    end
    ctx.text = cleanText(text)
    if chapter then ctx.chapter = chapter end
    return ctx
end

--- 从全书书摘列表条目收集分享内容。
---@param entry table
---@param ctx { ui?: table, snapshot?: table }|nil
---@return table
function Share.payloadFromNote(entry, ctx)
    local payload = bookContext(nil, ctx)
    payload.text = cleanText(entry and entry.text)
    if entry and type(entry.chapter) == "string" and entry.chapter ~= "" then
        payload.chapter = entry.chapter
    end
    return payload
end

--- 打开样式选择并生成分享图。
---@param payload table
function Share.open(payload)
    require("features.share.dialog").open(payload)
end

Ext.add("highlight.buttons", {
    key = "share",
    factory = function(highlight, index)
        return {
            text = _("书摘"),
            callback = function()
                local payload = Share.payloadFromHighlight(highlight, index)
                -- 只关菜单、清选区，不把这次划词存成高亮。
                if highlight and highlight.onClose then
                    highlight:onClose()
                end
                Share.open(payload)
            end,
        }
    end,
})

Ext.add("note.item_actions", {
    text = _("书摘"),
    icon = "share",
    run = function(entry, ctx)
        Share.open(Share.payloadFromNote(entry, ctx))
    end,
})

return Share
