--[[--
设置功能叠层：顶栏（返回 + 标题）+ 固定预览行 + 下方分页设置项。
壳对齐书籍详情，数据不是书，不复用 Detail。

@module koplugin.book.ui.desktop.settings.overlay
--]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local RightContainer = require("ui/widget/container/rightcontainer")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local BookInfo = require("ui.components.bookinfo")
local Icon = require("ui.components.icon")
local Lifecycle = require("ui.lifecycle")
local Pager = require("ui.components.pager")
local UI = require("ui.components.bookui")
local _ = require("gettext")
local Screen = Device.screen

---@class BookSettingsOverlay : InputContainer, LifecycleOwner
---@field desktop BookDesktop
---@field spec BookSettingsOverlaySpec
---@field page number
---@field close_callback fun()|nil
---@field lifecycle Lifecycle
local Overlay = InputContainer:extend{
    name = "book_settings_overlay",
    covers_fullscreen = true,
}

---@class BookSettingsOverlaySpec
---@field id string
---@field title string
---@field preview (fun(width: number): table)|nil
---@field sections fun(): BookQuickPanelSettingSection[]

--- 示意框。叠层已经占了预览行，不再套「预览」标题。
---@param width number
---@param child table
---@param child_h number
---@return table
function Overlay.previewBox(width, child, child_h)
    return FrameContainer:new{
        bordersize = 1,
        padding = 0,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        dimen = Geom:new{ w = width, h = child_h },
        child,
    }
end

--- 空预览：同一条框，框内淡字。
---@param width number
---@param child_h number
---@param text string
---@return table
function Overlay.previewPlaceholder(width, child_h, text)
    local pad = UI.sz(12)
    local label = TextWidget:new{
        text = text or "",
        face = UI.face("cfont", 13),
        max_width = math.max(1, width - pad * 2),
        fgcolor = UI.dim(),
    }
    return Overlay.previewBox(width, CenterContainer:new{
        dimen = Geom:new{ w = math.max(1, width - 2), h = math.max(1, child_h - 2) },
        label,
    }, child_h)
end

--- 分组标题和行构建器展平进分页数据。
---@param out table
---@param width number
---@param title string
---@param row_builders table
---@return nil
function Overlay.appendSection(out, width, title, row_builders)
    if #out > 0 then table.insert(out, VerticalSpan:new{ width = UI.sectionGap() }) end
    table.insert(out, LeftContainer:new{
        dimen = Geom:new{ w = width, h = UI.sz(28) },
        TextWidget:new{ text = title, face = UI.face("cfont", 13), max_width = width, fgcolor = UI.muted() },
    })
    local gap = VerticalSpan:new{ width = UI.sz(6) }
    for i, build in ipairs(row_builders or {}) do
        if i > 1 then table.insert(out, gap) end
        table.insert(out, build(width))
    end
end

--- 打开功能叠层；已有叠层先关。
---@param desktop BookDesktop
---@param spec BookSettingsOverlaySpec
---@return nil
function Overlay.open(desktop, spec)
    Overlay.close(desktop)
    if type(spec) ~= "table" or type(spec.title) ~= "string" then return end
    local desk = desktop
    desktop.settings_overlay = Overlay:new{
        desktop = desktop,
        spec = spec,
        covers_fullscreen = true,
        close_callback = function()
            desk.settings_overlay = nil
            if desk.lifecycle and desk.lifecycle.state ~= "Destroy" then
                require("ui/uimanager"):setDirty(desk, "ui")
            end
        end,
    }
    local UIManager = require("ui/uimanager")
    UIManager:show(desktop.settings_overlay)
    UIManager:setDirty(desktop.settings_overlay, "ui")
end

--- 关掉当前设置叠层。
---@param desktop BookDesktop|nil
---@return nil
function Overlay.close(desktop)
    local page = desktop and desktop.settings_overlay
    if not page then return end
    page:onClose()
end

function Overlay:init()
    self.lifecycle = Lifecycle.attach(self)
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.page = self.page or 1
    if Device:hasKeys() then
        self.key_events = {
            Close = { { Device.input.group.Back } },
        }
    end
    self:onCreate()
    self:onResume()
    self:updateView()
end

---@return table
function Overlay:getSize()
    return self.dimen
end

---@param w number
---@return table
function Overlay:buildTopBar(w)
    local pad = UI.pagePad()
    local bar_h = UI.sz(48)
    local label = Icon.label{ name = "arrow_back", size = 24, text = _("返回") }
    local back_w = label:getSize().w + UI.sz(12)
    local back = BookInfo.tappable(back_w, bar_h, function()
        self:onClose()
    end)
    back[1] = LeftContainer:new{
        dimen = Geom:new{ w = back_w, h = bar_h },
        label,
    }
    local title = TextWidget:new{
        text = self.spec.title,
        face = UI.face("cfont", 16),
        max_width = math.max(1, w - back_w - pad * 3),
    }
    local line_h = UI.line()
    return FrameContainer:new{
        bordersize = 0,
        padding = 0,
        background = Blitbuffer.COLOR_WHITE,
        dimen = Geom:new{ w = w, h = bar_h + line_h },
        VerticalGroup:new{
            align = "left",
            OverlapGroup:new{
                dimen = Geom:new{ w = w, h = bar_h },
                LeftContainer:new{
                    dimen = Geom:new{ w = w, h = bar_h },
                    HorizontalGroup:new{
                        HorizontalSpan:new{ width = pad },
                        back,
                    },
                },
                RightContainer:new{
                    dimen = Geom:new{ w = w - pad, h = bar_h },
                    title,
                },
            },
            LineWidget:new{
                background = UI.rule(),
                dimen = Geom:new{ w = w, h = line_h },
            },
        },
    }
end

function Overlay:updateView()
    local w, h = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = w, h = h }
    local page_pad = UI.pagePad()
    local card_w = math.max(UI.sz(100), w - page_pad * 2)
    local top_bar = self:buildTopBar(w)
    local header = VerticalGroup:new{ align = "left", top_bar }
    local header_h = top_bar.dimen.h
    if self.spec.preview then
        local preview = self.spec.preview(card_w)
        local preview_h = preview.dimen and preview.dimen.h or (preview.getSize and preview:getSize().h) or 0
        local preview_box = FrameContainer:new{
            bordersize = 0,
            padding = page_pad,
            padding_top = UI.sz(8),
            padding_bottom = UI.sz(8),
            margin = 0,
            background = Blitbuffer.COLOR_WHITE,
            dimen = Geom:new{ w = w, h = preview_h + UI.sz(16) },
            preview,
        }
        table.insert(header, preview_box)
        header_h = header_h + preview_box.dimen.h
    end
    table.insert(header, LineWidget:new{
        background = UI.rule(),
        dimen = Geom:new{ w = w, h = UI.line() },
    })
    header_h = header_h + UI.line()
    header.dimen = Geom:new{ w = w, h = header_h }

    local packed = {}
    for _, section in ipairs(self.spec.sections()) do
        Overlay.appendSection(packed, card_w, section.title, section.rows)
    end
    local band_h = Pager.bandH()
    local body_h = math.max(1, h - header_h - band_h)
    local bottom_pad = UI.sz(4)
    local pack_h = math.max(1, body_h - page_pad - bottom_pad)
    local pages_kids = Pager.pack(packed, pack_h)
    local pages = #pages_kids
    local page = Pager.clamp(self.page, pages)
    self.page = page
    local page_body = FrameContainer:new{
        bordersize = 0, padding = page_pad, padding_bottom = bottom_pad, margin = 0,
        background = Blitbuffer.COLOR_WHITE, dimen = Geom:new{ w = w, h = body_h },
        VerticalGroup:new(pages_kids[page]),
    }
    self[1] = (select(1, Pager.frame(w, h, {
        top = header,
        body = page_body,
        page = page,
        pages = pages,
        handlers = {
            on_prev = function() self.page = page - 1; self:updateView() end,
            on_next = function() self.page = page + 1; self:updateView() end,
            on_first = function() self.page = 1; self:updateView() end,
            on_last = function() self.page = pages; self:updateView() end,
        },
    })))
    if self.lifecycle:uiReady() then
        require("ui/uimanager"):setDirty(self, "ui")
    end
    return self[1]
end

function Overlay:onClose()
    if self.lifecycle.state ~= "Destroy" then
        self:onDestroy()
    end
    local UIManager = require("ui/uimanager")
    local desk = self.desktop
    UIManager:close(self)
    UIManager:nextTick(function()
        if desk and desk.lifecycle and desk.lifecycle.state ~= "Destroy" then
            UIManager:setDirty(desk, "ui")
        else
            UIManager:setDirty("all", "ui")
        end
    end)
    return true
end

function Overlay:onCloseWidget()
    if self.lifecycle.state ~= "Destroy" then
        self:onDestroy()
    end
    if self[1] and self[1].free then
        self[1]:free()
    end
    local cb = self.close_callback
    self.close_callback = nil
    if cb then cb() end
end

return Overlay
