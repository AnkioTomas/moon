--[[--
翻译弹窗：主题组件 + Kindle 式语言选择，居中 popout；译文分页不滚动。

@module koplugin.book.features.translate.popup
--]]

require("l10n").apply()

local Device = require("device")
local Edge = require("features.translate.edge")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Languages = require("features.translate.languages")
local Theme = require("ui.themes")
local Box = require("ui.themes.widgets.box")
local Modal = require("ui.themes.widgets.modal")
local Pager = require("ui.themes.widgets.pager")
local Text = require("ui.themes.widgets.text")
local TitleBar = require("ui.themes.widgets.titlebar")
local _ = require("gettext")
local T = require("ffi/util").template

local Screen = Device.screen

---@class BookTranslatePopup : BookThemeModal
---@field translator table|nil KOReader Translator 单例
---@field text string 待译原文
---@field translated string|nil 译文；未就绪时 nil
---@field status string|nil 无译文时显示的状态（翻译中 / 失败原因）
---@field source_lang string|nil
---@field target_lang string|nil
---@field detected_lang string|nil
---@field note_index number|nil 改写既有笔记时的下标
---@field from_highlight boolean|nil 是否从划词入口打开
---@field full_page boolean|nil 是否用整页高度
---@field job CancelHandle|nil
---@field text_box table|nil 当前页译文 TextBoxWidget
---@field page integer 译文当前页
---@field pages integer 译文总页数
---@field text_h number 译文区高度
---@field popup_w number 弹窗宽度（Modal.width 是布局宽度，缺省整屏）
local TranslatePopup = Modal:extend{
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

--- 译文或语言变了：回到第一页重建面板。
function TranslatePopup:refreshView()
    self.page = 1
    self:rebuild()
    UIManager:setDirty(self, "ui")
end

--- 译文前后翻一页。
---@param dir integer 1 或 -1
function TranslatePopup:turn(dir)
    self.page = math.max(1, math.min(self.pages, self.page + dir))
    self:rebuild()
    UIManager:setDirty(self, "ui")
end

--- 发起 Edge 翻译；重复调用会取消在途请求。
---@param self BookTranslatePopup
function TranslatePopup:requestTranslate()
    if self.job then
        self.job.cancel()
    end
    self.translated, self.status = nil, _("正在翻译…")
    self:refreshView()
    self.job = Edge.translateAsync(self.text, self.target_lang, self.source_lang, function(translated, detected_lang, err)
        self.job = nil
        self.translated = translated
        self.status = not translated and T(_("翻译失败：%1"), tostring(err)) or nil
        self.detected_lang = detected_lang or self.detected_lang
        self:refreshView()
    end)
end

--- 划词场景：复制 / 存笔记。
---
--- 按钮结构不依赖译文：init 时译文还是空串，按结果决定要不要建按钮的话，
--- 译文回来后没人重建这棵树，按钮就永远不出现。译文只在点按那一刻取。
---@param self BookTranslatePopup
---@return table[] 按钮行，每行是 buttonRow 的 specs
function TranslatePopup:actionRows()
    local rows = {}

    --- 存笔记：index 有值则改写既有笔记，否则新建。
    ---@param full boolean 是否连原文一起存
    local function saveNote(full)
        local translated = self.translated
        if not translated then return end
        local ui = require("apps/reader/readerui").instance
        local text = full and ("▣ " .. self.text .. "\n● " .. translated) or translated
        self:close()
        if not (ui and ui.highlight) then return end
        UIManager:close(ui.highlight.highlight_dialog)
        ui.highlight.highlight_dialog = nil
        if self.note_index then
            ui.highlight:editNote(self.note_index, false, text)
        else
            ui.highlight:addNote(text)
        end
    end

    if self.from_highlight then
        rows[#rows + 1] = {
            {
                text = _("保存主要翻译到笔记"),
                callback = function() saveNote(false) end,
            },
            {
                text = _("保存全部内容到笔记"),
                callback = function() saveNote(true) end,
            },
        }
    end

    if Device:hasClipboard() then
        rows[#rows + 1] = {
            {
                text = _("复制主要翻译"),
                callback = function()
                    local translated = self.translated
                    if translated then
                        Device.input.setClipboardText(translated)
                    end
                end,
            },
        }
        if self.from_highlight then
            rows[#rows][2] = {
                text = _("复制全部内容"),
                callback = function()
                    local translated = self.translated
                    if translated then
                        Device.input.setClipboardText("▣ " .. self.text .. "\n● " .. translated)
                    end
                end,
            }
        end
    end

    return rows
end

---@param self BookTranslatePopup
function TranslatePopup:init()
    Modal.init(self)
    self.popup_w = math.floor(math.min(Screen:getWidth(), Screen:getHeight()) * 0.88)
    self.text_h = math.floor(Screen:getHeight() * (self.full_page and 0.62 or 0.26))
    self.page = 1
    self:rebuild()
end

--- 标题栏 + 语言按钮 + 分页译文 + 操作行。
function TranslatePopup:rebuild()
    local t = self.theme
    local pad = Theme.px(t.space.md)
    local gap = Theme.px(t.space.sm)
    local inner = self.popup_w - pad * 2
    local body = Text.box("body", self.translated or self.status or "", inner, { height = self.text_h, bg = t.dialog.bg })
    self.pages = math.max(1, math.ceil(body:getAllLineCount() / body:getVisLineCount()))
    self.page = math.min(self.page, self.pages)
    for _i = 2, self.page do body:scrollDown() end
    self.text_box = body

    local group = VerticalGroup:new{
        align = "left",
        TitleBar.widget({
            width = inner, title = _("翻译"),
            right_icon = "close", right_callback = function() self:close() end,
        }),
        VerticalSpan:new{ width = gap },
        self:buttonRow({
            {
                text = langButtonText(self, _("源语言"), self.source_lang, true),
                callback = function()
                    Languages.pick(self.translator, _("源语言"), true, self.source_lang, function(code)
                        self.source_lang = code
                        Languages.applySource(code)
                        self:requestTranslate()
                    end)
                end,
            },
            {
                text = langButtonText(self, _("目标语言"), self.target_lang, false),
                callback = function()
                    Languages.pick(self.translator, _("目标语言"), false, self.target_lang, function(code)
                        self.target_lang = code
                        Languages.applyTarget(code)
                        self:requestTranslate()
                    end)
                end,
            },
        }, inner),
        VerticalSpan:new{ width = gap },
        body,
        Pager.widget({
            width = inner, page = self.page, pages = self.pages,
            on_prev = function() self:turn(-1) end,
            on_next = function() self:turn(1) end,
        }),
    }
    for _i, row in ipairs(self:actionRows()) do
        group[#group + 1] = VerticalSpan:new{ width = gap }
        group[#group + 1] = self:buttonRow(row, inner)
    end
    self:setPanel(Box:new{ style = t.dialog, padding = pad, group })
end

--- 关窗时取消在途翻译：不取消的话回调仍会往已关闭的 widget 上 setDirty，
--- 并把整个弹窗（含原文与译文）挂在请求闭包里活到响应返回。
function TranslatePopup:onCloseWidget()
    if self.job then
        self.job.cancel()
    end
    self.job = nil
    Modal.onCloseWidget(self)
end

--- 打开翻译弹窗并立即请求译文。
---@param opts table
---@return BookTranslatePopup
local function open(opts)
    local popup = TranslatePopup:new{
        translator = opts.translator,
        text = opts.text,
        source_lang = opts.source_lang,
        target_lang = opts.target_lang,
        full_page = opts.full_page == true,
        from_highlight = opts.from_highlight,
        note_index = opts.index,
    }
    popup:show()
    popup:requestTranslate()
    return popup
end

return {
    open = open,
    TranslatePopup = TranslatePopup,
}
