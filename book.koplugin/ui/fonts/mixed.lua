--[[--
中西文分用字体：西文作主字体，当前中文阅读字体作第一候补。
只改变当前 CRE 文档的字体选择，不改正文、DOM、字体文件或全局字体设置。

@module koplugin.book.ui.fonts.mixed
--]]

local Settings = require("utils.settings")
local _ = require("gettext")

local Mixed = {}

--- 空 id 恢复自动选择；仅限制含中文字形的字体，把汉字留给中文候补。
---@param id string
---@param name string
---@return boolean|nil, string|nil, boolean|nil changed
function Mixed.setWestern(id, name)
    local settings = Settings.get("reader")
    if id == settings.western_font_id then return true, nil, false end
    if id ~= "" then
        local face, err = require("ui.fonts").faceForId(id)
        if not face then return nil, err end
        local cre = require("document/credocument"):engineInit()
        local path, index = cre.getFontFaceFilenameAndFaceIndex(face)
        local font = require("ffi/freetype").newFaceSize(path, 20, index) --[[@as FreeTypeSize]]
        local has_chinese = font:hasGlyph(0x4E2D)
        font:done()
        if has_chinese then return nil, _("请选择不含中文字形的字体，以保留所选中文字体") end
    end
    settings.western_font_id = id
    settings.western_font_name = name
    Settings.save("reader")
    return true, nil, true
end

---@param document table CRE 文档；其它文档不安装
function Mixed.install(document)
    local settings = Settings.get("reader")
    if type(document.setupFallbackFontFaces) ~= "function" or document._book_mixed_fonts
        or not settings.mixed_fonts then return end

    local cre = document:engineInit()
    local installed = {}
    for _, face in ipairs(cre.getFontFaces()) do installed[face] = true end
    local western = settings.western_font_id ~= "" and require("ui.fonts").faceForId(settings.western_font_id)
        or installed.Bookerly and "Bookerly" or installed["Noto Serif"] and "Noto Serif"
    if not western then return end

    local setFontFace = document.setFontFace
    local setupFallbackFontFaces = document.setupFallbackFontFaces
    local setAdjustedFallbackFontSizes = document.setAdjustedFallbackFontSizes
    local setWordSpacing = document.setWordSpacing
    local cjk_faces = {}
    local selected, split
    local word_spacing
    document._book_mixed_fonts = true

    document.setupFallbackFontFaces = function(doc)
        if not split then return setupFallbackFontFaces(doc) end
        -- 沿用原生候补配置，直接拼最终列表；先恢复原列表会多清一次字形缓存。
        local faces = { selected }
        local seen = { [selected] = true, [western] = true }
        local user_fallback = G_reader_settings:readSetting("fallback_font")
        if user_fallback and not seen[user_fallback] then
            faces[#faces + 1] = user_fallback
            seen[user_fallback] = true
        end
        local additional = not G_reader_settings:isFalse("additional_fallback_fonts")
        if additional or not user_fallback then
            for _, face in pairs(doc.fallback_fonts) do
                if not seen[face] then
                    faces[#faces + 1] = face
                    seen[face] = true
                end
                if not additional then break end
            end
        end
        local value = table.concat(faces, "|")
        if doc._document:getStringProperty("crengine.font.fallback.faces") ~= value then
            doc._document:setStringProperty("crengine.font.fallback.faces", value)
        end
    end

    document.setAdjustedFallbackFontSizes = function(doc, enabled)
        -- 按西文字体 x-height 缩放候补会把汉字缩小；中文仍使用当前阅读字号。
        if split then enabled = false end
        return setAdjustedFallbackFontSizes(doc, enabled)
    end

    document.setWordSpacing = function(doc, values)
        word_spacing = values
        -- 中文字体下保存的小词距换到西文字体后会挤掉词间空隙；
        -- 组合模式至少保留字体的自然空格宽度，两端对齐也不再压缩空格。
        return setWordSpacing(doc, split and { math.max(100, values[1]), 100 } or values)
    end

    document.setFontFace = function(doc, face)
        selected = face
        if face and cjk_faces[face] == nil then
            local path, index = cre.getFontFaceFilenameAndFaceIndex(face)
            cjk_faces[face] = false
            if path then
                local font = require("ffi/freetype").newFaceSize(path, 20, index) --[[@as FreeTypeSize]]
                cjk_faces[face] = font:hasGlyph(0x4E2D)
                font:done()
            end
        end
        split = face and cjk_faces[face] or false
        setFontFace(doc, split and western or face)
        doc:setupFallbackFontFaces()
        doc:setAdjustedFallbackFontSizes(G_reader_settings:nilOrTrue("cre_adjusted_fallback_font_sizes"))
        if word_spacing then doc:setWordSpacing(word_spacing) end
    end
end

return Mixed
