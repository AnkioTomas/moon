--[[--
全书阅读排版偏好：字体 + CRE 边距/字号，按 source_id + stable_id 存 books.reader_prefs。

连续章节每章是独立物理文件；本模块在关书/休眠/切章前捕获当前排版，开章时按书身份写回 sidecar。

@module koplugin.book.book.reader_prefs
--]]

local JSON = require("json")
local BookDB = require("utils.db.book")
local MoonFont = require("utils.font")
local Store = require("book.store")
local logger = require("logger")

local M = {}

--- native_font.lua 为渲染字体选项塞进 configurable 的临时键，不属于排版偏好。
local SKIP_COPT_KEY = "book_font_face"

---@param identity BookIdentity|nil
---@return boolean
local function isChapter(identity)
    -- 整本书只有一个物理文件，KOReader sidecar 已是唯一真相；只有章节书需要跨文件同步。
    return identity ~= nil and identity.chapter_idx ~= nil
end

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
    return {
        font_id = doc and doc:readSetting("book_reader_font_id") or nil,
        font_name = doc and doc:readSetting("book_reader_font_name") or nil,
        font_face = doc and doc:readSetting("font_face") or nil,
        copt = copt,
    }
end

---@param identity BookIdentity|nil
---@param prefs table|nil
---@return boolean 是否已排入数据库队列
function M.save(identity, prefs)
    if not isChapter(identity) or not prefs then
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
    -- 走队列：直写会和在飞的队列任务抢同一条 sqlite 连接（关书时进度也在写）
    require("utils.db.queue").run(function()
        assert(BookDB.setReaderPrefs(source_id, stable_id, payload), "failed to save reader preferences")
    end, {
        on_failed = function(err)
            logger.warn("book.reader_prefs save failed", source_id, stable_id, err)
        end,
    })
    return true
end

---@param identity BookIdentity|nil
---@return table|nil
function M.load(identity)
    if not isChapter(identity) then
        return nil
    end
    return decode(BookDB.getReaderPrefs(identity.source_id, identity.stable_id))
end

---@param ui table|nil
---@param identity BookIdentity|nil
---@return boolean
function M.captureAndSave(ui, identity)
    identity = identity or M.identityForUi(ui)
    if not isChapter(identity) then
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
            and type(existing.font_id) == "string" and existing.font_id ~= "" then
            prefs.font_id = existing.font_id
            prefs.font_name = existing.font_name or prefs.font_name
        end
    end
    return M.save(identity, prefs)
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
    local identity = Store.identityFor(document.file)
    if not isChapter(identity) then
        return false
    end
    local prefs = M.load(identity)
    if not prefs then
        return false
    end
    for key, value in pairs(prefs.copt or {}) do
        doc_settings:saveSetting("copt_" .. key, copyValue(value))
    end
    local font_id = type(prefs.font_id) == "string" and prefs.font_id or ""
    local face = (font_id ~= "" and MoonFont.faceForId(font_id)) or prefs.font_face
    if type(face) == "string" and face ~= "" then
        doc_settings:saveSetting("font_face", face)
        doc_settings:saveSetting("book_reader_font_id", font_id)
        doc_settings:saveSetting("book_reader_font_name", prefs.font_name or font_id)
    end
    return true
end

return M
