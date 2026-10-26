--[[--
全书阅读排版偏好：字体 + CRE 边距/字号，按 source_id + stable_id 存 books.reader_prefs。

连续章节每章是独立物理文件；本模块在关书/休眠/切章前捕获当前排版，开章时按书身份写回 sidecar。
「保存为默认」写 G_reader_settings，并同步覆盖所有已有 reader_prefs；无 per-book 快照的章节书
开书时从全局默认注入，避免旧章 sidecar 挡住默认。

@module koplugin.book.reader.prefs
--]]

local JSON = require("json")
local lfs = require("libs/libkoreader-lfs")
local BookDB = require("book.books_db")
local Fonts = require("ui.fonts")
local FontReader = require("ui.fonts.reader")
local Store = require("book.store")
local logger = require("utils.log")

local M = {}

-- 超过此大小的书按「重」处理：默认不用内嵌字体和样式（固定阈值，不跟瞬时可用内存晃）。
-- 开书确认阈值见 utils.mem.warnThresholdBytes（随可用内存在 8–40MB 间伸缩）。
M.BIG_BOOK_BYTES = 20 * 1024 * 1024

-- 不在 configurable 里、由 KOReader 的样式微调模块直接存进 sidecar 的排版键（行距 / 段距等微调与自定义 CSS 在这里）。
local DOC_KEYS = {
    "style_tweaks", "style_tweaks_enabled", "book_style_tweak", "book_style_tweak_enabled",
    "inverse_reading_order", "invert_ui_layout",
    "highlight_drawer", "highlight_color",
    "text_lang", "hyphenation", "floating_punctuation", "font_family_fonts", "css",
    "preferred_dictionaries", "disabled_dicts", "wikipedia_language", "toc_ticks_ignored_levels",
}

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
    local doc_keys = {}
    for _idx, key in ipairs(DOC_KEYS) do
        doc_keys[key] = doc and doc:readSetting(key)
    end
    -- 高亮样式的活状态在 view.highlight，sidecar 是上次 SaveSettings 的旧值；
    -- 刚在菜单里改完就捕获（保存为默认 / 关书）读 sidecar 会拿到旧格式。
    local highlight = ui.view and ui.view.highlight
    if type(highlight) == "table" then
        if type(highlight.saved_drawer) == "string" and highlight.saved_drawer ~= "" then
            doc_keys.highlight_drawer = highlight.saved_drawer
        end
        if type(highlight.saved_color) == "string" and highlight.saved_color ~= "" then
            doc_keys.highlight_color = highlight.saved_color
        end
    end
    return {
        font_id = font_id,
        font_name = font_id and doc:readSetting("book_reader_font_name") or nil,
        font_face = font_face,
        copt = copt,
        doc = doc_keys,
    }
end

--- 只有章节书需要跨文件同步：整本书只有一个物理文件，KOReader sidecar 已是唯一真相。
---@param identity BookIdentity
---@return table|nil
function M.load(identity)
    return decode(BookDB.getReaderPrefs(identity.source_id, identity.stable_id))
end

--- 从 G_reader_settings 组装与 capture 同形的 prefs（章节书无 per-book 快照时用）。
---@return table|nil
function M.fromDefaults()
    if not G_reader_settings or type(G_reader_settings.data) ~= "table" then
        return nil
    end
    local copt = {}
    local has_copt = false
    for key, value in pairs(G_reader_settings.data) do
        local name = type(key) == "string" and key:match("^copt_(.+)$")
        if name and name ~= SKIP_COPT_KEY then
            local value_type = type(value)
            if value_type == "number" or value_type == "string" or value_type == "table" then
                copt[name] = copyValue(value)
                has_copt = true
            end
        end
    end
    local font_face = G_reader_settings:readSetting("cre_font")
    local font_id = G_reader_settings:readSetting("book_reader_default_font_id")
    if type(font_id) ~= "string" or font_id == "" then
        font_id = nil
    end
    if not idMatchesFace(font_id, font_face) then
        font_id = nil
    end
    if not has_copt and type(font_face) ~= "string" and not font_id then
        return nil
    end
    return {
        font_id = font_id,
        font_name = font_id,
        font_face = font_face,
        copt = copt,
    }
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
    -- 大 EPUB 内嵌中文字体会让 CRE 按字号/字重各缓存一份，512MB 设备易 OOM：默认关闭内嵌字体；
    -- 本书已设置或用户「设为默认」过（G_reader_settings）则尊重原值。
    -- 大文件（插图合集等）连全局默认也不认，内嵌字体与内嵌样式都关；本书自己设过的照旧。
    local big = (lfs.attributes(document.file, "size") or 0) >= M.BIG_BOOK_BYTES
    if doc_settings:readSetting("copt_embedded_fonts") == nil
        and (big or not (G_reader_settings and G_reader_settings:has("copt_embedded_fonts"))) then
        doc_settings:saveSetting("copt_embedded_fonts", 0)
    end
    if big and doc_settings:readSetting("copt_embedded_css") == nil then
        doc_settings:saveSetting("copt_embedded_css", 0)
    end
    local identity = Store.identityFor(document.file)
    if not (identity and identity.chapter_idx) then
        return false
    end
    local prefs = M.load(identity) or M.fromDefaults()
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
    -- 旧版本存的偏好没有 doc 字段：不动这章自己的微调。有 doc 时缺席即「全书没设」，要清掉。
    if prefs.doc then
        for _idx, key in ipairs(DOC_KEYS) do
            local value = prefs.doc[key]
            if value == nil then
                doc_settings:delSetting(key)
            else
                doc_settings:saveSetting(key, copyValue(value))
            end
        end
    end
    local font_id = type(prefs.font_id) == "string" and prefs.font_id or ""
    local face = (font_id ~= "" and Fonts.faceForId(font_id)) or prefs.font_face
    if type(face) == "string" and face ~= "" then
        doc_settings:saveSetting("font_face", face)
        doc_settings:saveSetting("book_reader_font_id", font_id)
        doc_settings:saveSetting("book_reader_font_name", prefs.font_name or font_id)
    end
end

--- 当前排版存为全局默认：同 KOReader ConfigDialog「设为默认」，逐项写 G_reader_settings 的
--- `<prefix>_<name>`（CRE 为 copt，PDF/DjVu 为 kopt）；字体同 ReaderFont 写 cre_font。
--- 同时覆盖所有已有 books.reader_prefs，让章节源下次打开也吃到这套。
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
    -- 高亮不在 configurable 里，不会跟着 copt_* 进全局默认；且全局键名与 sidecar 不同
    -- （drawer 是 highlight_drawing_style，见 ReaderHighlight:onReadSettings 的回退读取）。
    -- 不写这两个，新书只能吃 KOReader 默认划线，与字体/间距的表现不一致。
    if prefs and prefs.doc then
        if type(prefs.doc.highlight_drawer) == "string" and prefs.doc.highlight_drawer ~= "" then
            G_reader_settings:saveSetting("highlight_drawing_style", prefs.doc.highlight_drawer)
        end
        if type(prefs.doc.highlight_color) == "string" and prefs.doc.highlight_color ~= "" then
            G_reader_settings:saveSetting("highlight_color", prefs.doc.highlight_color)
        end
    end
    G_reader_settings:flush()
    if prefs then
        if not BookDB.replaceAllReaderPrefs(JSON.encode(prefs)) then
            logger.warn("book.reader_prefs replaceAll failed")
        end
    end
    return true
end

return M
