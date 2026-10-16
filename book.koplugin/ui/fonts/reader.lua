--[[--
把月读字体应用到当前阅读文档：切 CRE 字体、写 sidecar。

@module koplugin.book.ui.fonts.reader
--]]

local Fonts = require("ui.fonts")
local logger = require("utils.log")
local _ = require("gettext")

local FontReader = {}

---@param ui table|nil
---@return boolean
function FontReader.supports(ui)
    return ui and ui.font ~= nil and type(ui.document) == "table"
        and type(ui.document.setFontFace) == "function" or false
end

---@param ui table ReaderUI
---@return string
function FontReader.currentId(ui)
    return ui.doc_settings:readSetting("book_reader_font_id") or ""
end

--- 把字体应用到当前文档并写入 sidecar；全书排版偏好由调用方落库（ui 层不反向依赖 reader）。
---@param ui table|nil
---@param id string
---@param name string|nil
---@return boolean|nil, string|nil
function FontReader.apply(ui, id, name)
    if not FontReader.supports(ui) then
        return nil, _("当前文档不支持字体与排版调整")
    end
    ---@cast ui table
    local face, err = Fonts.faceForId(id)
    if not face then
        logger.warn("book font apply resolve failed", "id=" .. tostring(id), "error=" .. tostring(err))
        return nil, err
    end
    -- ReaderFont:onSetFont 在 FontList 没有该字体名时静默不动；以 font_face 是否已切换判成败。
    ui.font:onSetFont(face)
    if ui.font.font_face ~= face then
        logger.warn("book font apply failed", "id=" .. tostring(id), "face=" .. face)
        return nil, _("应用字体失败")
    end
    ui.font:onSaveSettings()
    ui.doc_settings:saveSetting("book_reader_font_id", id)
    ui.doc_settings:saveSetting("book_reader_font_name", name or id)
    ui.doc_settings:flush()
    logger.dbg("book font applied", ui.document.file or "", "id=" .. tostring(id), "face=" .. face)
    require("ui/uimanager"):setDirty(ui.dialog, "ui")
    return true
end

return FontReader
