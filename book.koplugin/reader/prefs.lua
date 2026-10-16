--[[--
全书阅读排版偏好：字体 + CRE 边距/字号，按 source_id + stable_id 存 books.reader_prefs。

连续章节每章是独立物理文件；本模块在关书/休眠/切章前捕获当前排版，开章时按书身份写回 sidecar。

@module koplugin.book.reader.prefs
--]]

local JSON = require("json")
local BookDB = require("book.books_db")
local Fonts = require("ui.fonts")
local FontReader = require("ui.fonts.reader")
local Store = require("book.store")
local logger = require("utils.log")

local M = {}

--- native_font.lua 为渲染字体选项塞进 configurable 的临时键，不属于排版偏好。
local SKIP_COPT_KEY = "book_font_face"

local function copyValue(value)
    if type(value) ~= "table" then
        return value
    end
    local out = {}
    for k, v in pairs(value) do
        out[k] = v
    end
    return out
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

---@return boolean
local function idMatchesFace(id, face)
    if type(id) ~= "string" or id == "" or type(face) ~= "string" or face == "" then
        return false
    end
    return Fonts.faceNameForId(id) == face
end

--- 从当前 ReaderUI 采集字体与 copt 排版。
---@param ui table|nil
---@return table|nil
function M.capture(ui)
    if not FontReader.supports(ui) then
        return nil
    end
    local config = ui.document.configurable
    if not config then
        return nil
    end
    -- configurable 就是整套 copt_ 排版状态；逐键白名单会丢字重、字间距等设置。
    local copt = {}
    for key, value in pairs(config) do
        local value_type = type(value)
        if key ~= SKIP_COPT_KEY
            and (value_type == "number" or value_type == "string" or value_type == "table") then
            copt[key] = copyValue(value)
        end
    end
    local doc = ui.doc_settings
    local font_id = doc and doc:readSetting("book_reader_font_id")
    local font_face = ui.font.font_face
    if not font_face and doc then
        font_face = doc:readSetting("font_face")
    end
    -- book_reader_font_id 只负责让插件字体在下次启动时重新注册，不是第二份字体状态。
    -- 用户经 KOReader 原生菜单换字体后，旧 id 不得反过来覆盖当前 font_face。
    if not idMatchesFace(font_id, font_face) then
        font_id = nil
    end
    return {
        font_id = font_id,
        font_name = font_id and doc:readSetting("book_reader_font_name") or nil,
        font_face = font_face,
        copt = copt,
    }
end

--- 只有章节书需要跨文件同步：整本书只有一个物理文件，KOReader sidecar 已是唯一真相。
---@param identity BookIdentity
---@return table|nil
function M.load(identity)
    return decode(BookDB.getReaderPrefs(identity.source_id, identity.stable_id))
end

---@param ui table
---@param identity BookIdentity|nil 缺省按当前文档路径解析
---@return boolean 是否成功写入数据库
function M.captureAndSave(ui, identity)
    identity = identity or Store.ensureIdentity(ui.document.file)
    if not (identity and identity.chapter_idx) then
        return false
    end
    local prefs = M.capture(ui)
    if not prefs then
        return false
    end
    -- 连续章节每章独立 sidecar；关书时若当前章未写入 book_reader_font_id，
    -- 不得用空值覆盖全书已保存的字体偏好。
    local existing = M.load(identity)
    if existing then
        local id = prefs.font_id
        if (type(id) ~= "string" or id == "")
            and idMatchesFace(existing.font_id, prefs.font_face) then
            prefs.font_id = existing.font_id
            prefs.font_name = existing.font_name or prefs.font_name
        end
    end
    local ok = BookDB.setReaderPrefs(identity.source_id, identity.stable_id, JSON.encode(prefs))
    if not ok then
        logger.warn("book.reader_prefs save failed", identity.source_id, identity.stable_id)
    end
    return ok
end

--- DocSettingsLoad：把全书偏好写进 sidecar，交给 KOReader 原生 ReadSettings 加载。
---
--- 必须在 ReadSettings 之前写，文档加载完再逐键重放只能覆盖手工列举的那几项，
--- 未列举的键（字重、字间距等）已经按该章 sidecar 的默认值渲染完毕。
---@param doc_settings table
---@param document table|nil
---@return boolean
function M.inject(doc_settings, document)
    if type(document) ~= "table" or type(document.setFontFace) ~= "function" then
        return false
    end
    -- 整本书不需要跨文件偏好注入，但插件字体仍须在原生 ReadSettings 前重新注册。
    -- 否则 sidecar 虽保留 font_face，CRE 冷启动时找不到该字体，只会静默回退默认字体。
    -- 新书没有自己的字体 id 时，用「保存为默认配置」记下的默认插件字体。
    local persisted_font_id = doc_settings:readSetting("book_reader_font_id")
        or G_reader_settings:readSetting("book_reader_default_font_id")
    if type(persisted_font_id) == "string" and persisted_font_id ~= "" then
        Fonts.faceForId(persisted_font_id)
    end
    local identity = Store.identityFor(document.file)
    if not (identity and identity.chapter_idx) then
        return false
    end
    local prefs = M.load(identity)
    if not prefs then
        return false
    end
    M.write(doc_settings, prefs)
    return true
end

--- 把 capture 的排版写进 sidecar；同一本书换物理文件（章节、双语版）时在开书前调用。
---@param doc_settings table
---@param prefs table capture / load 的结果
function M.write(doc_settings, prefs)
    for key, value in pairs(prefs.copt or {}) do
        doc_settings:saveSetting("copt_" .. key, copyValue(value))
    end
    local font_id = type(prefs.font_id) == "string" and prefs.font_id or ""
    local face = (font_id ~= "" and Fonts.faceForId(font_id)) or prefs.font_face
    if type(face) == "string" and face ~= "" then
        doc_settings:saveSetting("font_face", face)
        doc_settings:saveSetting("book_reader_font_id", font_id)
        doc_settings:saveSetting("book_reader_font_name", prefs.font_name or font_id)
    end
end

--- 当前排版存为新书默认：同 KOReader ConfigDialog「设为默认」，逐项写 G_reader_settings 的
--- `<prefix>_<name>`（CRE 为 copt，PDF/DjVu 为 kopt）；字体同 ReaderFont 写 cre_font。
---@param ui table ReaderUI
---@return boolean
function M.saveDefaults(ui)
    local config = ui and ui.document and ui.document.configurable
    local prefix = ui and ui.config and ui.config.options and ui.config.options.prefix
    if not (config and prefix) then
        return false
    end
    for key, value in pairs(config) do
        local value_type = type(value)
        if key ~= SKIP_COPT_KEY
            and (value_type == "number" or value_type == "string" or value_type == "table") then
            G_reader_settings:saveSetting(prefix .. "_" .. key, copyValue(value))
        end
    end
    local prefs = M.capture(ui)
    if prefs and type(prefs.font_face) == "string" and prefs.font_face ~= "" then
        G_reader_settings:saveSetting("cre_font", prefs.font_face)
        if prefs.font_id then
            G_reader_settings:saveSetting("book_reader_default_font_id", prefs.font_id)
        else
            G_reader_settings:delSetting("book_reader_default_font_id")
        end
    end
    G_reader_settings:flush()
    return true
end

return M
