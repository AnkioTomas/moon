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
---@field id string|nil
---@field title string
---@field preview (fun(width: number): table)|nil
---@field sections fun(): BookThemeSection[]
---@field on_close (fun())|nil
---@field refresh_seconds number|nil 页面在最上层时每隔这么久重算一次（运行状态这类实时页）
---@field right_icon string|nil 标题栏右上角图标
---@field right_callback (fun())|nil

---@class BookSettingsOverlay : BookThemeModal
---@field spec BookSettingsOverlaySpec
---@field parent BookSettingsOverlay|nil 二级页面的上一层
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
    Overlay.closeAll(desktop)
    Overlay.push(desktop, spec)
end

--- 在当前叠层之上再开一层（二级页面）：返回时回到上一层并重算它的设置项。
---@param desktop BookDesktop
---@param spec BookSettingsOverlaySpec
function Overlay.push(desktop, spec)
    local parent = desktop.settings_overlay
    local overlay
    overlay = Overlay:new{
        spec = spec,
        parent = parent,
        close_callback = function()
            desktop.settings_overlay = overlay.parent
            if desktop.closed then
                if overlay.parent then overlay.parent:close() end
            elseif overlay.parent then
                overlay.parent:updateView()
            else
                UIManager:setDirty(desktop, "ui")
            end
            if spec.on_close then spec.on_close() end
        end,
    }
    desktop.settings_overlay = overlay
    overlay:show()
end

--- 关掉整条叠层链（根页导航切换、换源时用）。
---@param desktop BookDesktop
function Overlay.closeAll(desktop)
    local overlay = desktop.settings_overlay
    while overlay do
        local parent = overlay.parent
        overlay.parent = nil
        overlay:close()
        overlay = parent
    end
end

function Overlay:init()
    Modal.init(self)
    self:rebuild()
    if self.spec.refresh_seconds then self:startRefresh(self.spec.refresh_seconds) end
end

-- 第一次 2 秒后就刷：CPU 占用要两次采样才有数。被二级页面盖住时不画。
function Overlay:startRefresh(seconds)
    self._refresh = require("ui.guard").wrap("settings refresh", function()
        if self.refresh_stopped then return end
        local stack = UIManager._window_stack
        if stack[#stack].widget == self then self:updateView() end
        UIManager:scheduleIn(seconds, self._refresh)
    end)
    UIManager:scheduleIn(2, self._refresh)
end

function Overlay:onCloseWidget()
    self.refresh_stopped = true
    if self._refresh then UIManager:unschedule(self._refresh) end
    Modal.onCloseWidget(self)
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
        right_icon = self.spec.right_icon, right_callback = self.spec.right_callback,
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
