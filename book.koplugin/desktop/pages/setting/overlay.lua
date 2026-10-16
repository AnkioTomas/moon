--[[--
设置功能叠层：标题栏（返回 + 标题）+ 固定预览行 + 下方分组分页设置项。全屏主题页。

  +-------------------------------+
  | [<]       阅读页顶栏          |
  |-------------------------------|
  | [ 预览（可选） ]              |
  |-------------------------------|
  | 分组标题                      |
  | 设置行 …                      |
  | [<]        1 / 2         [>]  |
  +-------------------------------+

@module koplugin.book.desktop.pages.setting.overlay
--]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Geom = require("ui/geometry")
local LineWidget = require("ui/widget/linewidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local Theme = require("ui.themes")
local Box = require("ui.themes.widgets.box")
local Modal = require("ui.themes.widgets.modal")
local Sections = require("ui.themes.widgets.sections")
local Text = require("ui.themes.widgets.text")
local TitleBar = require("ui.themes.widgets.titlebar")

---@class BookSettingsOverlaySpec
---@field id string
---@field title string
---@field preview (fun(width: number): table)|nil
---@field sections fun(): BookThemeSection[]

---@class BookSettingsOverlay : BookThemeModal
---@field spec BookSettingsOverlaySpec
---@field page integer
local Overlay = Modal:extend{
    name = "book_settings_overlay",
    covers_fullscreen = true,
    spec = nil,
    page = 1,
}

--- 示意框：卡片表面，子件居中。叠层已经占了预览行，不再套「预览」标题。
---@param width number
---@param child table
---@param child_h number
---@return table
function Overlay.previewBox(width, child, child_h)
    return Box:new{ style = Theme.current().card, width = width, height = child_h, child }
end

--- 空预览：同一个框，框内淡字。
---@param width number
---@param child_h number
---@param text string
---@return table
function Overlay.previewPlaceholder(width, child_h, text)
    local t = Theme.current()
    return Overlay.previewBox(width, Text.line("caption", text, { color = t.color.faint }), child_h)
end

--- 打开功能叠层；已有叠层先关。
---@param desktop BookDesktop
---@param spec BookSettingsOverlaySpec
function Overlay.open(desktop, spec)
    if desktop.settings_overlay then desktop.settings_overlay:close() end
    desktop.settings_overlay = Overlay:new{
        spec = spec,
        close_callback = function()
            desktop.settings_overlay = nil
            if not desktop.closed then UIManager:setDirty(desktop, "ui") end
        end,
    }
    desktop.settings_overlay:show()
end

function Overlay:init()
    Modal.init(self)
    self:rebuild()
end

function Overlay:rebuild()
    local t = self.theme
    local w, h = self.dimen.w, self.dimen.h
    local rule = Theme.px(t.row.divider)
    -- VerticalGroup 第一次 getSize 就缓存每个子件的偏移。对还没放进正文的 page
    -- 调 getSize，再追加 body，绘制时 _offsets[body] 是 nil。
    local bar = TitleBar.widget({
        width = w, title = self.spec.title,
        left_icon = "arrow_back", left_callback = function() self:close() end,
    })
    local page = VerticalGroup:new{ align = "left", bar }
    local head_h = bar:getSize().h
    if self.spec.preview then
        local pad = Theme.px(t.space.md)
        local preview = self.spec.preview(w - pad * 2)
        local block_h = preview:getSize().h + pad * 2
        page[#page + 1] = CenterContainer:new{
            dimen = Geom:new{ w = w, h = block_h },
            preview,
        }
        page[#page + 1] = LineWidget:new{
            background = Blitbuffer.Color8(t.color.rule),
            dimen = Geom:new{ w = w, h = rule },
        }
        head_h = head_h + block_h + rule
    end
    local body
    body, self.page = Sections.widget({
        width = w,
        height = h - head_h,
        sections = self.spec.sections(),
        page = self.page,
        on_page = function(p) self.page = p; self:updateView() end,
    })
    page[#page + 1] = body
    self:setPanel(Box:new{ style = { bg = t.color.page }, width = w, height = h, page })
end

--- 重算设置项并重画（设置改了之后调用方调）。
function Overlay:updateView()
    self:rebuild()
    UIManager:setDirty(self, "ui")
end

return Overlay
