--[[--
翻译弹窗：KOReader 原生控件 + Kindle 式语言选择，居中 popout。

@module koplugin.book.translate.popup
--]]

require("l10n").apply()

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local ButtonTable = require("ui/widget/buttontable")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Edge = require("translate.edge")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Languages = require("translate.languages")
local Popup = require("ui.components.popup")
local _ = require("gettext")
local T = require("ffi/util").template

local Screen = Device.screen

---@class BookTranslatePopup : InputContainer
local TranslatePopup = InputContainer:extend{
    name = "book_translate_popup",
}

--- 语言按钮文案：源语言：英语 ▼
---@param self BookTranslatePopup
---@param label string
---@param code string|nil
---@param use_detected boolean|nil
---@return string
local function langButtonText(self, label, code, use_detected)
    local name = Languages.displayName(self.translator, code, use_detected and self.detected_lang or nil)
    return T(_("%1：%2 ▼"), label, name)
end

--- 居中显示 popout。
---@param widget table
---@return nil
local function showCentered(widget)
    local size = widget.dimen or widget:getSize()
    UIManager:show(widget, nil, nil,
        math.floor((Screen:getWidth() - size.w) / 2),
        math.floor((Screen:getHeight() - size.h) / 2))
end

--- 刷新语言按钮与译文。
---@param self BookTranslatePopup
---@return nil
function TranslatePopup:refreshView()
    if self.source_btn then
        self.source_btn:setText(langButtonText(self, _("源语言"), self.source_lang, true))
    end
    if self.target_btn then
        self.target_btn:setText(langButtonText(self, _("目标语言"), self.target_lang, false))
    end
    if self.text_box then
        self.text_box:setText(self.translated or "")
    end
    UIManager:setDirty(self, "ui")
end

--- 弹出语言单选（常用语言 + 全部语言）。
---@param self BookTranslatePopup
---@param title string
---@param include_auto boolean
---@param current string|nil
---@param on_pick fun(code: string)
---@return nil
function TranslatePopup:pickLanguage(title, include_auto, current, on_pick)
    local function openPicker(all_languages)
        Popup.single{
            title = title,
            current = current,
            choice_icons = true,
            centered = not all_languages,
            items = all_languages
                and Languages.allItems(self.translator, include_auto)
                or Languages.pickerItems(self.translator, include_auto, current),
            on_select = function(code)
                if code == Languages.ALL_LANGUAGES then
                    openPicker(true)
                    return
                end
                on_pick(code)
            end,
        }
    end
    openPicker(false)
end

--- 发起 Edge 翻译；重复调用会取消在途请求。
---@param self BookTranslatePopup
---@return nil
function TranslatePopup:requestTranslate()
    if self.job and self.job.cancel then
        self.job.cancel()
    end
    self.translated = _("正在翻译…")
    self:refreshView()
    self.job = Edge.translateAsync(self.text, self.target_lang, self.source_lang, function(translated, detected_lang, err)
        self.job = nil
        if not translated then
            self.translated = _("翻译失败")
            self:refreshView()
            return
        end
        self.translated = translated
        if detected_lang then
            self.detected_lang = detected_lang
        end
        self:refreshView()
    end)
end

--- 划词场景：复制 / 存笔记。
---@param self BookTranslatePopup
---@return table|nil
function TranslatePopup:actionButtons()
    local rows = {}
    local translated = self.translated
    if translated == "" or translated == _("正在翻译…") or translated == _("翻译失败") then
        return nil
    end

    if self.from_highlight then
        local ui = require("apps/reader/readerui").instance
        local text_all = "▣ " .. self.text .. "\n● " .. translated
        local index = self.note_index
        rows[#rows + 1] = {
            {
                text = _("保存主要翻译到笔记"),
                callback = function()
                    UIManager:close(self)
                    if ui and ui.highlight then
                        UIManager:close(ui.highlight.highlight_dialog)
                        ui.highlight.highlight_dialog = nil
                        if index then
                            ui.highlight:editNote(index, false, translated)
                        else
                            ui.highlight:addNote(translated)
                        end
                    end
                end,
            },
            {
                text = _("保存全部内容到笔记"),
                callback = function()
                    UIManager:close(self)
                    if ui and ui.highlight then
                        UIManager:close(ui.highlight.highlight_dialog)
                        ui.highlight.highlight_dialog = nil
                        if index then
                            ui.highlight:editNote(index, false, text_all)
                        else
                            ui.highlight:addNote(text_all)
                        end
                    end
                end,
            },
        }
    end

    if Device:hasClipboard() then
        rows[#rows + 1] = {
            {
                text = _("复制主要翻译"),
                callback = function()
                    Device.input.setClipboardText(translated)
                end,
            },
        }
        if self.from_highlight then
            local text_all = "▣ " .. self.text .. "\n● " .. translated
            rows[#rows][2] = {
                text = _("复制全部内容"),
                callback = function()
                    Device.input.setClipboardText(text_all)
                end,
            }
        end
    end

    if #rows == 0 then
        return nil
    end
    return ButtonTable:new{
        width = self.width - Size.padding.default * 2,
        buttons = rows,
        zero_sep = true,
        show_parent = self,
    }
end

---@param self BookTranslatePopup
---@return nil
function TranslatePopup:init()
    self.width = math.floor(math.min(Screen:getWidth(), Screen:getHeight()) * 0.88)
    local pad = Size.padding.default
    local lang_w = math.floor((self.width - pad * 3) / 2)
    local text_h = math.floor(Screen:getHeight() * 0.26)
    local inner_w = self.width - pad * 2

    self.source_btn = Button:new{
        text = langButtonText(self, _("源语言"), self.source_lang, true),
        width = lang_w,
        bordersize = 0,
        padding = Size.padding.small,
        radius = 0,
        callback = function()
            self:pickLanguage(_("源语言"), true, self.source_lang, function(code)
                self.source_lang = code
                Languages.applySource(code)
                self:requestTranslate()
            end)
        end,
    }
    self.target_btn = Button:new{
        text = langButtonText(self, _("目标语言"), self.target_lang, false),
        width = lang_w,
        bordersize = 0,
        padding = Size.padding.small,
        radius = 0,
        callback = function()
            self:pickLanguage(_("目标语言"), false, self.target_lang, function(code)
                self.target_lang = code
                Languages.applyTarget(code)
                self:requestTranslate()
            end)
        end,
    }

    self.text_box = TextBoxWidget:new{
        text = self.translated or "",
        face = require("ui/font"):getFace("x_smallinfofont"),
        width = inner_w - pad * 2,
        height = text_h,
        alignment = "left",
    }

    local title_bar = TitleBar:new{
        width = self.width,
        align = "left",
        title = _("翻译"),
        with_bottom_line = false,
        close_callback = function()
            UIManager:close(self)
        end,
        show_parent = self,
    }

    local divider = LineWidget:new{
        background = Blitbuffer.COLOR_BLACK,
        dimen = Geom:new{ w = self.width, h = Size.line.medium },
    }

    local body = FrameContainer:new{
        padding = pad,
        VerticalGroup:new{
            align = "left",
            HorizontalGroup:new{
                align = "center",
                self.source_btn,
                HorizontalSpan:new{ width = pad },
                self.target_btn,
            },
            VerticalSpan:new{ width = Size.padding.small },
            FrameContainer:new{
                bordersize = Size.border.thin,
                bordercolor = Blitbuffer.COLOR_BLACK,
                background = Blitbuffer.COLOR_WHITE,
                padding = pad,
                self.text_box,
            },
        },
    }

    local button_table = self:actionButtons()
    local content = VerticalGroup:new{ align = "left", title_bar, divider, body }
    if button_table then
        content[#content + 1] = CenterContainer:new{
            dimen = Geom:new{
                w = self.width,
                h = button_table:getSize().h,
            },
            button_table,
        }
    end

    self[1] = FrameContainer:new{
        radius = Size.radius.window,
        bordersize = Size.border.window,
        padding = 0,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        content,
    }
    self.dimen = self[1]:getSize()
end

--- 打开翻译弹窗并立即请求译文。
---@param opts table
---@return BookTranslatePopup
local function open(opts)
    opts = opts or {}
    local popup = TranslatePopup:new{
        translator = opts.translator,
        text = opts.text,
        source_lang = opts.source_lang,
        target_lang = opts.target_lang,
        from_highlight = opts.from_highlight,
        note_index = opts.index,
        translated = "",
    }
    showCentered(popup)
    popup:requestTranslate()
    return popup
end

return {
    open = open,
    TranslatePopup = TranslatePopup,
}
