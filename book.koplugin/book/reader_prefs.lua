--[[--
全书阅读排版偏好：字体 + CRE 边距/字号，按 source_id + stable_id 存 books.reader_prefs。

连续章节每章是独立物理文件；本模块在关书/休眠/切章前捕获当前排版，开章后按书身份覆盖应用。

@module koplugin.book.book.reader_prefs
--]]

local JSON = require("json")
local BookDB = require("utils.db.book")
local MoonFont = require("utils.font")
local Store = require("book.store")

local M = {}

--- CRE configurable 中跟全书排版相关的键（copt_ 前缀落 doc_settings）。
local COPT_KEYS = {
    "h_page_margins",
    "t_page_margin",
    "b_page_margin",
    "sync_t_b_page_margins",
    "font_size",
    "line_spacing",
}

---@param value any
---@return any
local function copyValue(value)
    if type(value) ~= "table" then
        return value
    end
    local out = {}
    for i, v in ipairs(value) do
        out[i] = v
    end
    for k, v in pairs(value) do
        if out[k] == nil then
            out[k] = v
        end
    end
    return out
end

---@param value table
---@return string|nil
local function encode(value)
    local ok, payload = pcall(JSON.encode, value)
    return ok and payload or nil
end

---@param raw string|nil
---@return table|nil
local function decode(raw)
    if type(raw) ~= "string" or raw == "" then
        return nil
    end
    local ok, value = pcall(JSON.decode, raw)
    return ok and type(value) == "table" and value or nil
end

---@param ui table|nil
---@return BookIdentity|nil
function M.identityForUi(ui)
    if not ui or not ui.document or not ui.document.file then
        return nil
    end
    return Store.ensureIdentity(ui.document.file)
end

--- 从当前 ReaderUI 采集字体与 copt 排版。
---@param ui table|nil
---@return table|nil
function M.capture(ui)
    if not MoonFont.supportsReader(ui) then
        return nil
    end
    local config = ui.document.configurable
    if not config then
        return nil
    end
    local copt = {}
    for i = 1, #COPT_KEYS do
        local key = COPT_KEYS[i]
        local value = config[key]
        if value ~= nil then
            copt[key] = copyValue(value)
        end
    end
    local doc = ui.doc_settings
    return {
        font_id = doc and doc:readSetting("book_reader_font_id") or nil,
        font_name = doc and doc:readSetting("book_reader_font_name") or nil,
        font_face = doc and doc:readSetting("font_face") or nil,
        copt = copt,
    }
end

---@param identity BookIdentity|nil
---@param prefs table|nil
---@return boolean
function M.save(identity, prefs)
    if not identity or not prefs then
        return false
    end
    local source_id = identity.source_id
    local stable_id = identity.stable_id
    if type(source_id) ~= "string" or type(stable_id) ~= "string" or stable_id == "" then
        return false
    end
    local payload = encode(prefs)
    if not payload then
        return false
    end
    return BookDB.setReaderPrefs(source_id, stable_id, payload)
end

---@param identity BookIdentity|nil
---@return table|nil
function M.load(identity)
    if not identity then
        return nil
    end
    return decode(BookDB.getReaderPrefs(identity.source_id, identity.stable_id))
end

---@param ui table|nil
---@param identity BookIdentity|nil
---@return boolean
function M.captureAndSave(ui, identity)
    identity = identity or M.identityForUi(ui)
    if not identity then
        return false
    end
    local prefs = M.capture(ui)
    if not prefs then
        return false
    end
    return M.save(identity, prefs)
end

--- 把全书偏好应用到当前文档（覆盖该章 sidecar 已加载的排版）。
---@param ui table|nil
---@param identity BookIdentity|nil
---@return boolean
function M.apply(ui, identity)
    if not MoonFont.supportsReader(ui) then
        return false
    end
    identity = identity or M.identityForUi(ui)
    if not identity then
        return false
    end
    local prefs = M.load(identity)
    if not prefs then
        return false
    end

    local config = ui.document.configurable
    local typeset = ui.typeset
    local copt = prefs.copt or {}
    if config then
        for i = 1, #COPT_KEYS do
            local key = COPT_KEYS[i]
            local value = copt[key]
            if value ~= nil then
                config[key] = copyValue(value)
            end
        end
        if ui.doc_settings and config.saveSettings then
            config:saveSettings(ui.doc_settings, "copt_")
            ui.doc_settings:flush()
        end
    end

    local font_id = type(prefs.font_id) == "string" and prefs.font_id or ""
    if font_id ~= "" then
        MoonFont.applyToReader(ui, font_id, prefs.font_name)
    elseif type(prefs.font_face) == "string" and prefs.font_face ~= "" and ui.font then
        ui.font:onSetFont(prefs.font_face)
        ui.font:onSaveSettings()
        if ui.doc_settings then
            ui.doc_settings:saveSetting("book_reader_font_id", "")
            ui.doc_settings:saveSetting("book_reader_font_name", "")
            ui.doc_settings:flush()
        end
    end

    if typeset then
        if copt.h_page_margins then
            typeset:onSetPageHorizMargins(copyValue(copt.h_page_margins))
        end
        if copt.t_page_margin ~= nil and copt.b_page_margin ~= nil then
            typeset:onSetPageTopAndBottomMargin({ copt.t_page_margin, copt.b_page_margin })
        end
    end
    if ui.font then
        if copt.font_size then
            ui.font:onSetFontSize(copt.font_size)
        end
        if copt.line_spacing then
            ui.font:onSetLineSpace(copt.line_spacing)
        end
    end

    require("ui/uimanager"):setDirty(ui.dialog, "ui")
    if ui.handleEvent then
        ui:handleEvent(require("ui/event"):new("UpdatePos"))
    end
    return true
end

return M
