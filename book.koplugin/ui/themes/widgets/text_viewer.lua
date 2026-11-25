--[[--
主题文本查看（替代 TextViewer）：标题栏 + 分页正文 + 翻页条，不滚动。
两种风格：缺省全屏；``fullscreen = false`` 为居中弹窗卡片（宽度同其它弹窗，高度随内容、最高 90% 屏高，
超出分页），带遮罩，点卡片外关闭。

  +-------------------------------+
  |           标题          [×]   |
  |-------------------------------|
  | 正文正文正文正文正文正文……    |
  | ……                            |
  | [<]        2 / 5         [>]  |
  +-------------------------------+

  TextViewer:new{ title = "日志", text = long_text }:show()
  TextViewer:new{ title = "李善德", text = detail, fullscreen = false }:show()
  TextViewer:new{ title = "日志", text = long_text, buttons = {
      { text = "稍后", callback = function() end },
      { text = "安装", variant = "primary", callback = function() end },
  } }:show()
  TextViewer:new{ title = "说明", html = "<h1>Hi</h1>", on_link = function(link) end, buttons = {
      { text = "取消", callback = function() end },
      { text = "安装", variant = "primary", callback = function() end },
  } }:show()

@module koplugin.book.ui.themes.widgets.text_viewer
--]]

local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Theme = require("ui.themes")
local Box = require("ui.themes.widgets.box")
local Modal = require("ui.themes.widgets.modal")
local Pager = require("ui.themes.widgets.pager")
local Input = require("ui.input")
local Text = require("ui.themes.widgets.text")
local TitleBar = require("ui.themes.widgets.titlebar")

---@class BookThemeTextViewer : BookThemeModal
---@field title string|nil
---@field text string
---@field html string|nil 有值时优先用 HtmlBox 排版（Markdown / 富文本），失败回退纯文字
---@field css string|nil 追加到 Html 基础样式（如表格）；仅 html 模式使用
---@field on_link fun(link: table)|nil HtmlBox 点到链接时回调；调用方决定是否打开
---@field on_close fun()|nil 关闭时回调一次
---@field inline_images table<string, { url: string, headers?: table<string, string> }>|nil
---@field emoji boolean|nil 正文中的 Unicode emoji 使用行内图片
---@field fullscreen boolean 全屏页（缺省）；false 为居中弹窗卡片
---@field page integer
---@field pages integer
---@field content_w integer 内容区宽（物理像素，已扣卡片边框）
---@field content_h integer 内容区高
---@field frame integer 卡片边框宽；全屏为 0
---@field body_h integer 正文区高度（物理像素）
---@field pager_h integer 翻页条高度（物理像素）
---@field fill integer 正文下方补的空白（全屏把内容撑满屏高；卡片为 0）
---@field buttons table[]|nil 底栏按钮 { text, variant, callback }；缺省只有标题栏关闭
local TextViewer = Modal:extend{
    fullscreen = true,
    title = nil,
    text = nil,
    html = nil,
    css = nil,
    on_link = nil,
    on_close = nil,
    buttons = nil,
}

--- 丢掉上一份正文（HtmlBox / TextBox 都可能占位图或 MuPDF 文档）。
local function releaseBody(self)
    local old = self.body
    self.body = nil
    if type(old) == "table" and type(old.free) == "function" then
        old:free()
    end
end

--- 卡片最高占屏高的比例。
local CARD_MAX_HEIGHT = 0.9

function TextViewer:init()
    self.covers_fullscreen = self.fullscreen
    Modal.init(self)
    local t = self.theme
    self.frame = self.fullscreen and 0 or Theme.px(t.dialog.border or 0)
    local outer_w = self.fullscreen and self.dimen.w or Modal.dialogWidth()
    local outer_h = self.fullscreen and self.dimen.h or math.floor(self.dimen.h * CARD_MAX_HEIGHT)
    self.content_w = outer_w - self.frame * 2
    self.content_h = outer_h - self.frame * 2
    local w, h = self.content_w, self.content_h
    local pad = Theme.px(t.space.lg)
    self.bar = TitleBar.widget({
        width = w, title = self.title,
        right_icon = "close", right_callback = function() self:dismiss() end,
    })
    local button_h = 0
    if self.buttons and #self.buttons > 0 then
        button_h = pad * 2 + Theme.px(t.control.height)
    end
    self.pager_h = Theme.px(t.control.height)
    self.body_h = math.max(1, h - self.bar:getSize().h - self.pager_h - pad * 2 - button_h)
    self._layout_locked = false
    self:applyBody()
    self:rebuild()
end

--- 构造正文：优先 HtmlBox，不可用或没有 HTML 时回退 Text.box。
function TextViewer:applyBody()
    releaseBody(self)
    local pad = Theme.px(self.theme.space.lg)
    local width = self.content_w - pad * 2
    local height = self.body_h
    self._html_mode = false
    if type(self.html) == "string" and self.html ~= "" then
        local css = type(self.css) == "string" and self.css or nil
        -- 仅当底板被壁纸挖空或非纯白底时才逐像素扣白；普通纯白页直接走底层 blitFrom。
        local is_transparent = function()
            ---@type BookThemeBox|nil
            local panel = self[1]
            return not (panel and panel.style and panel.style.bg == 0xFF)
        end
        local ok, box = pcall(function()
            return require("ui.themes.widgets.html").widget({
                width = width,
                height = height,
                html = self.html,
                css = css,
                on_link = self.on_link,
                transparent = is_transparent,
            })
        end)
        if ok and box then
            self._html_mode = true
            self.body = box
            self.pages = math.max(1, tonumber(box.page_count) or 1)
            self.page = math.min(math.max(1, self.page or 1), self.pages)
            if self.body.setPageNumber then
                self.body:setPageNumber(self.page)
            end
            self.fill = 0
            if self.pages == 1 then
                self.fill = self.pager_h
            end
            if not self.fullscreen then
                local used = self.body.getSize and self.body:getSize().h or height
                if not self._layout_locked then
                    self.content_h = self.content_h - math.max(0, self.body_h - used)
                    if self.pages == 1 then
                        self.content_h = self.content_h - self.pager_h
                    end
                    self._layout_locked = true
                end
                self.fill = 0
            end
            return
        end
    end
    self.body = Text.box("body", self.text or "", width,
        { height = height, transparent = true, emoji = self.emoji, inline_images = self.inline_images })
    self.pages = math.max(1, math.ceil(self.body:getAllLineCount() / self.body:getVisLineCount()))
    self.page = math.min(math.max(1, self.page or 1), self.pages)
    -- 不足一页时 TextBoxWidget 把高度压到实际行数，单页也不显示翻页条：空出的高度
    -- 全屏补成空白（Box 会把整组居中，不补正文就浮在屏幕中间），卡片直接收掉。
    self.fill = self.body_h - self.body:getSize().h
    if self.pages == 1 then self.fill = self.fill + self.pager_h end
    if not self.fullscreen then
        if not self._layout_locked then
            self.content_h = self.content_h - self.fill
            self._layout_locked = true
        end
        self.fill = 0
    end
end

--- 异步替换正文（加载完成 / 失败 / 撤权后更新 README）。
---@param opts { text?: string, html?: string|nil, css?: string|nil }
function TextViewer:setContent(opts)
    opts = opts or {}
    if opts.text ~= nil then self.text = opts.text end
    if opts.html ~= nil then self.html = opts.html end
    if opts.css ~= nil then self.css = opts.css end
    self.page = 1
    self:applyBody()
    self:rebuild()
    UIManager:setDirty(self, "ui")
end

function TextViewer:onCloseWidget()
    releaseBody(self)
    if Modal.onCloseWidget then
        Modal.onCloseWidget(self)
    end
    if self.on_close then
        local fn = self.on_close
        self.on_close = nil
        fn()
    end
end

function TextViewer:rebuild()
    local t = self.theme
    local w = self.content_w
    local pad = Theme.px(t.space.lg)
    local kids = {
        align = "center",
        self.bar,
        Box:new{ style = {}, padding = pad, self.body },
        VerticalSpan:new{ width = self.fill },
    }
    if self.pages > 1 then
        kids[#kids + 1] = Pager.widget({
            width = w,
            page = self.page,
            pages = self.pages,
            range = self.dimen,
            on_page = function(page) self:turn(page - self.page) end,
        })
    end
    if self.buttons and #self.buttons > 0 then
        kids[#kids + 1] = VerticalSpan:new{ width = pad }
        kids[#kids + 1] = self:buttonRow(self.buttons, w - pad * 2)
        kids[#kids + 1] = VerticalSpan:new{ width = pad }
    end
    self:setPanel(Box:new{
        style = self.fullscreen and { bg = t.color.page } or t.dialog,
        width = w + self.frame * 2,
        height = self.content_h + self.frame * 2,
        VerticalGroup:new(kids),
    })
end

--- 前后翻一页；HtmlBox 用页码，TextBoxWidget 按可见行数滚动。
---@param dir integer 1 或 -1
function TextViewer:turn(dir)
    local page = Input.page(self.page + dir, self.pages)
    if page == self.page then return end
    if self._html_mode and self.body and self.body.setPageNumber then
        self.page = page
        self.body:setPageNumber(page)
        -- HtmlBox:_render 会缓存 bb；只改页码或 setDirty 不会换掉已绘制的正文。
        require("ui.themes.widgets.html").invalidatePage(self.body)
    else
        if page == 1 then
            self.body:scrollToTop()
        elseif page == self.pages then
            self.body:scrollToBottom()
        elseif page > self.page then
            self.body:scrollDown()
        else
            self.body:scrollUp()
        end
        self.page = page
    end
    self:rebuild()
    UIManager:setDirty(self, "ui")
end

return TextViewer
