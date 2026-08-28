--[[--
ReaderConfig 字体选项 patch。

@module koplugin.book.ui.panel.native_font
--]]

require("l10n").apply()

local _ = require("gettext")

---@class BookQuickPanelNativeFont
---@field install fun(ui: table|nil): void

local NativeFont = {}

---@param ui table|nil
---@return string[], string|nil
local function fontFaces(ui)
    local font = ui and ui.font
    if not font or type(font.onSetFont) ~= "function" then return {}, nil end
    local ok, cre = pcall(function()
        return require("document/credocument"):engineInit()
    end)
    if not ok or not cre or type(cre.getFontFaces) ~= "function" then
        return {}, font.font_face
    end
    return cre.getFontFaces() or {}, font.font_face
end

---@param options table[]
local function addFontOption(options)
    for _i, group in ipairs(options) do
        if group.icon == "appbar.textsize" then
            for _j, option in ipairs(group.options or {}) do
                if option._book_font_option then return end
            end
            group.options[#group.options + 1] = {
                _book_font_option = true,
                name = "book_font_face",
                name_text = _("字体"),
                toggle = { _("选择") },
                values = { 1 },
                args = { 1 },
                default_value = 1,
                event = "BookSetFont",
                more_options = true,
                more_options_param = {
                    value_table = { "" },
                    value_min = 1,
                    value_max = 1,
                    event = "BookSetFont",
                },
            }
            return
        end
    end
end

---@param config table
local function prepareFontOption(config)
    local option
    for _i, group in ipairs(config.options or {}) do
        if group.icon == "appbar.textsize" then
            for _j, item in ipairs(group.options or {}) do
                if item._book_font_option then option = item break end
            end
        end
    end
    if not option then return end
    local faces, current = fontFaces(config.ui)
    if #faces == 0 then option.show = false return end
    local index = 1
    for i, face in ipairs(faces) do
        if face == current then index = i break end
    end
    config._book_font_faces = faces
    config.configurable.book_font_face = index
    option.show = true
    option.toggle = { faces[index] }
    option.values = { index }
    option.args = { index }
    option.default_value = index
    option.more_options_param.value_table = faces
    option.more_options_param.value_min = 1
    option.more_options_param.value_max = #faces
    option.more_options_param.show_true_value_func = function(value)
        return faces[value] or ""
    end
end

---@param ui table|nil
function NativeFont.install(ui)
    local ok, ReaderConfig = pcall(require, "apps/reader/modules/readerconfig")
    if not ok or type(ReaderConfig) ~= "table" then return end
    addFontOption(require("ui/data/koptoptions"))
    addFontOption(require("ui/data/creoptions"))
    if not ReaderConfig._book_reader_font_patched then
        ReaderConfig._book_reader_font_patched = true
        local original_init = ReaderConfig.init
        ReaderConfig.init = function(self, ...)
            original_init(self, ...)
            prepareFontOption(self)
        end
        local original_show = ReaderConfig.onShowConfigMenu
        ReaderConfig.onShowConfigMenu = function(self, ...)
            prepareFontOption(self)
            return original_show(self, ...)
        end
        function ReaderConfig:onBookSetFont(index)
            local face = self._book_font_faces and self._book_font_faces[tonumber(index)]
            if face and self.ui and self.ui.font then self.ui.font:onSetFont(face) end
            return true
        end
        local original_save = ReaderConfig.onSaveSettings
        if type(original_save) == "function" then
            ReaderConfig.onSaveSettings = function(self, ...)
                self.configurable.book_font_face = nil
                return original_save(self, ...)
            end
        end
    end
    if ui and ui.config then prepareFontOption(ui.config) end
end

---@type BookQuickPanelNativeFont
return NativeFont
