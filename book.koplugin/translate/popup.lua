--[[--
Kindle 式翻译弹窗：源/目标语言下拉与译文区。

@module koplugin.book.translate.popup
--]]

require("l10n").apply()

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
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

--- 语言选择按钮文案。
---@param self BookTranslatePopup
---@param label string
---@param code string|nil
---@return string
local function langButtonText(self, label, code)
    local name = Languages.displayName(self.translator, code, self.detected_lang)
    return T(_("%1 %2 ▼"), label, name)
end

--- 刷新语言按钮与译文。
---@param self BookTranslatePopup
---@return nil
function TranslatePopup:refreshView()
    if self.source_btn then
        self.source_btn:setText(langButtonText(self, _("源语言："), self.source_lang))
    end
    if self.target_btn then
        self.target_btn:setText(langButtonText(self, _("目标语言："), self.target_lang))
    end
    if self.text_box then
        self.text_box:setText(self.translated or "")
    end
    UIManager:setDirty(self, "ui")
end

--- 弹出语言单选列表。
---@param self BookTranslatePopup
---@param title string
---@param include_auto boolean
---@param current string|nil
---@param on_pick fun(code: string)
---@return nil
function TranslatePopup:pickLanguage(title, include_auto, current, on_pick)
    Popup.single{
        title = title,
        current = current,
        choice_icons = true,
        items = Languages.options(self.translator, include_auto),
        on_select = function(code)
            on_pick(code)
        end,
    }
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

--- 打开详细译文（TextViewer）。
---@param self BookTranslatePopup
---@return nil
function TranslatePopup:openDetail()
    if not self.show_detail or self.translated == "" or self.translated == _("正在翻译…") then
        return
    end
    local source = self.source_lang == "auto" and (self.detected_lang or "auto") or self.source_lang
    UIManager:close(self)
    self.show_detail(self.translated, source)
end

---@param self BookTranslatePopup
---@return nil
function TranslatePopup:init()
    local width = math.floor(math.min(Screen:getWidth(), Screen:getHeight()) * 0.88)
    local pad = Size.padding.default
    local lang_w = math.floor((width - pad * 3) / 2)
    local text_h = math.floor(Screen:getHeight() * 0.28)

    self.source_btn = Button:new{
        text = langButtonText(self, _("源语言："), self.source_lang),
        width = lang_w,
        callback = function()
            self:pickLanguage(_("源语言"), true, self.source_lang, function(code)
                self.source_lang = code
                Languages.applySource(code)
                self:requestTranslate()
            end)
        end,
    }
    self.target_btn = Button:new{
        text = langButtonText(self, _("目标语言："), self.target_lang),
        width = lang_w,
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
        width = width - pad * 2,
        height = text_h,
        alignment = "left",
    }

    local detail_btn = Button:new{
        text = _("翻译简介"),
        callback = function()
            self:openDetail()
        end,
    }

    local title_bar = TitleBar:new{
        width = width,
        align = "left",
        title = _("翻译"),
        with_bottom_line = true,
        close_callback = function()
            UIManager:close(self)
        end,
        show_parent = self,
    }

    local body = VerticalGroup:new{
        align = "left",
        HorizontalGroup:new{
            align = "center",
            self.source_btn,
            HorizontalSpan:new{ width = pad },
            self.target_btn,
        },
        VerticalSpan:new{ width = Size.span.vertical_default },
        FrameContainer:new{
            bordersize = Size.border.thin,
            bordercolor = Blitbuffer.COLOR_BLACK,
            background = Blitbuffer.COLOR_WHITE,
            padding = pad,
            CenterContainer:new{
                dimen = Geom:new{
                    w = width - pad * 2,
                    h = text_h,
                },
                self.text_box,
            },
        },
        VerticalSpan:new{ width = Size.padding.small },
        detail_btn,
    }

    local frame = FrameContainer:new{
        radius = Size.radius.window,
        bordersize = Size.border.window,
        padding = 0,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{
            title_bar,
            LineWidget:new{
                background = Blitbuffer.COLOR_BLACK,
                dimen = Geom:new{ w = width, h = Size.line.medium },
            },
            FrameContainer:new{
                padding = pad,
                padding_top = 0,
                body,
            },
        },
    }
    self.frame = frame
    self.dimen = Geom:new{
        w = Screen:getWidth(),
        h = Screen:getHeight(),
    }
    self.align = "center"
    self[1] = frame
end

--- 打开翻译弹窗并立即请求译文。
---@param opts table translator, text, source_lang, target_lang, show_detail
---@return BookTranslatePopup
local function open(opts)
    opts = opts or {}
    local popup = TranslatePopup:new{
        translator = opts.translator,
        text = opts.text,
        source_lang = opts.source_lang,
        target_lang = opts.target_lang,
        show_detail = opts.show_detail,
        translated = "",
    }
    UIManager:show(popup)
    popup:requestTranslate()
    return popup
end

return {
    open = open,
    TranslatePopup = TranslatePopup,
}
