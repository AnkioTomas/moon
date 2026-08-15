--[[--
阅读面板：阅读页点按中间弹出的全屏窗口 — 详情 / 目录 / 视觉 三个 Tab。

  详情 — 本地缓存 meta 先行渲染，同时发 book_info_request 交 Source 更新
  目录 — 章会话列章节（跳转 gotoChapter）；整本书列 ui.toc（GotoXPointer/GotoPage）
  视觉 — 阅读外观入口（桥接 KOReader 排版设置 / 阅读器菜单）

布局参照 ui.desktop.detail：TitleBar + Tab 行 + 内容区，禁止滚动容器。

@module koplugin.book.ui.reader.panel
--]]

local Blitbuffer = require("ffi/blitbuffer")
local ButtonTable = require("ui/widget/buttontable")
local Device = require("device")
local Event = require("ui/event")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local Menu = require("ui/widget/menu")
local TextWidget = require("ui/widget/textwidget")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local BookInfo = require("ui.components.bookinfo")
local UI = require("ui.components.bookui")
local Session = require("ui.reader.session")
local Store = require("book.store")
local _ = require("gettext")
local Screen = Device.screen

local Panel = InputContainer:extend{
    name = "book_reader_panel",
    covers_fullscreen = true,
    plugin = nil,
    tab = "detail",
    book = nil,
}

--- Tab 定义（顺序即展示顺序）。
local TABS = {
    { id = "detail", text = _("详情") },
    { id = "toc", text = _("目录") },
    { id = "visual", text = _("视觉") },
}

--- 初始化全屏尺寸、返回键，拉书籍信息并 rebuild。
function Panel:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    if Device:hasKeys() then
        self.key_events = {
            Close = { { Device.input.group.Back } },
        }
    end
    self:loadBook()
    self:rebuild()
end

---@return table
function Panel:getSize()
    return self.dimen
end

--- 关面板并强制重绘下层阅读页（全屏盖住，否则残影）。
---@return boolean
function Panel:onClose()
    self._closed = true
    UIManager:close(self)
    local ui = self.plugin and self.plugin.ui
    UIManager:nextTick(function()
        UIManager:setDirty(ui and ui.dialog or "all", "full")
    end)
    return true
end

--- Widget 关闭时触发 close_callback。
function Panel:onCloseWidget()
    self._closed = true
    local cb = self.close_callback
    self.close_callback = nil
    if cb then
        cb()
    end
end

--- 重读缓存 meta 并重绘（Source 更新缓存后的 refresh 也走这里）。
function Panel:reload()
    local cur = Session.current()
    if not cur or not cur.ref then
        return
    end
    Store.getMetaAsync(cur.ref, function(meta)
        if self._closed then
            return
        end
        if meta then
            meta.ref = cur.ref
            self.book = meta
        end
        self:rebuild()
        UIManager:setDirty(self, "full")
    end)
end

--- 详情数据：先用会话 book / 本地缓存，再发事件交 Source 更新。
function Panel:loadBook()
    local cur = Session.current()
    if not cur then
        return
    end
    self.book = cur.book
    if cur.ref then
        self:reload()
    end
    if self.plugin then
        self.plugin:emitToSource("book_info_request", {
            ref = cur.ref,
            book = cur.book,
            refresh = function()
                if not self._closed then
                    self:reload()
                end
            end,
        })
    end
end

--- 详情 Tab：紧凑英雄卡（封面 / 书名 / 作者 / 简介 / 进度）。
---@param w number
---@return table
function Panel:buildDetail(w)
    local cur = Session.current()
    local book = self.book or (cur and cur.book) or {}
    if cur and cur.ref and type(book) == "table" and not book.ref then
        book.ref = cur.ref
    end
    local source = (cur and cur.source) or (self.plugin and self.plugin:getSource())
    return BookInfo.hero(self.plugin, source, book, {
        width = w,
        show_progress = true,
        show_parent = self,
    })
end

--- 目录 Tab：章会话列章节；整本书列 ui.toc。点击跳转并关窗。
---@param w number
---@param h number
---@return table
function Panel:buildToc(w, h)
    local items = {}
    local ui = self.plugin and self.plugin.ui
    local Chapter = require("chapters.init")
    if Chapter.isActive() and type(Chapter.toc()) == "table" then
        local cur_idx = Chapter.currentIdx()
        for _, ch in ipairs(Chapter.toc()) do
            local i = tonumber(ch.idx) or 0
            items[#items + 1] = {
                text = (i == cur_idx and "• " or "") .. (ch.title or ("#" .. i)),
                callback = function()
                    self:onClose()
                    Chapter.gotoChapter(i)
                end,
            }
        end
    elseif ui and ui.toc and type(ui.toc.toc) == "table" then
        for _, entry in ipairs(ui.toc.toc) do
            local depth = tonumber(entry.depth) or 1
            items[#items + 1] = {
                text = string.rep("  ", math.max(0, depth - 1)) .. (entry.title or "?"),
                callback = function()
                    self:onClose()
                    if ui.link then
                        ui.link:addCurrentLocationToStack()
                    end
                    if entry.xpointer then
                        ui:handleEvent(Event:new("GotoXPointer", entry.xpointer, entry.xpointer))
                    elseif entry.page then
                        ui:handleEvent(Event:new("GotoPage", entry.page))
                    end
                end,
            }
        end
    end
    if #items == 0 then
        return LeftContainer:new{
            dimen = Geom:new{ w = w, h = h },
            TextWidget:new{
                text = _("暂无目录"),
                face = UI.face("cfont", 15),
                fgcolor = UI.muted(),
            },
        }
    end
    return Menu:new{
        item_table = items,
        no_title = true,
        is_borderless = true,
        is_popout = false,
        covers_fullscreen = false,
        width = w,
        height = h,
        items_font_size = UI.fontSize(16),
        show_parent = self,
    }
end

--- 视觉 Tab：阅读外观入口（桥接 KOReader 自带设置，不自造排版 UI）。
---@param w number
---@return table
function Panel:buildVisual(w)
    local ui = self.plugin and self.plugin.ui
    --- 整行可点动作。
    ---@param text string
    ---@param fn fun()
    ---@return table
    local function action(text, fn)
        local row_h = UI.sz(48)
        local tap = BookInfo.tappable(w, row_h, fn)
        tap[1] = LeftContainer:new{
            dimen = Geom:new{ w = w, h = row_h },
            TextWidget:new{
                text = text,
                face = UI.face("cfont", 16),
                fgcolor = Blitbuffer.COLOR_BLACK,
            },
        }
        return tap
    end
    return VerticalGroup:new{
        align = "left",
        action(_("排版与字体"), function()
            self:onClose()
            if ui then
                ui:handleEvent(Event:new("ShowConfigMenu"))
            end
        end),
        action(_("阅读器菜单"), function()
            self:onClose()
            if ui then
                ui:handleEvent(Event:new("ShowMenu"))
            end
        end),
    }
end

--- 切换 Tab 并重建内容区。
---@param id string
function Panel:switchTab(id)
    if self.tab == id then
        return
    end
    self.tab = id
    self:rebuild()
    UIManager:setDirty(self, "ui")
end

--- 重建 TitleBar、Tab 行与内容区。
function Panel:rebuild()
    local w = Screen:getWidth()
    local h = Screen:getHeight()
    local pad = UI.pagePad()
    local content_w = w - pad * 2
    local title = BookInfo.title(self.book)
    if title == "?" then
        title = _("阅读")
    end

    local title_bar = TitleBar:new{
        fullscreen = true,
        width = w,
        align = "center",
        with_bottom_line = true,
        title = title,
        title_face = UI.face("cfont", 18),
        button_padding = UI.sz(11),
        right_icon_size_ratio = UI.titleIconRatio(0.6),
        close_callback = function()
            self:onClose()
        end,
        show_parent = self,
    }

    local tab_row = {}
    for _, t in ipairs(TABS) do
        tab_row[#tab_row + 1] = {
            text = (self.tab == t.id and "• " or "") .. t.text,
            font_size = UI.buttonFontSize(),
            callback = function()
                self:switchTab(t.id)
            end,
        }
    end
    local tabs = ButtonTable:new{
        width = content_w,
        buttons = { tab_row },
        zero_sep = true,
        show_parent = self,
    }

    local title_h = title_bar:getHeight()
    local tabs_h = tabs:getSize().h + UI.sz(8)
    local body_h = math.max(UI.sz(80), h - title_h - tabs_h)

    local content
    if self.tab == "toc" then
        content = self:buildToc(content_w, body_h - pad)
    elseif self.tab == "visual" then
        content = self:buildVisual(content_w)
    else
        content = self:buildDetail(content_w)
    end

    self[1] = FrameContainer:new{
        bordersize = 0,
        padding = 0,
        background = Blitbuffer.COLOR_WHITE,
        dimen = Geom:new{ w = w, h = h },
        VerticalGroup:new{
            align = "left",
            title_bar,
            FrameContainer:new{
                bordersize = 0,
                padding = pad,
                padding_top = UI.sz(8),
                padding_bottom = 0,
                background = Blitbuffer.COLOR_WHITE,
                dimen = Geom:new{ w = w, h = tabs_h },
                tabs,
            },
            FrameContainer:new{
                bordersize = 0,
                padding = pad,
                padding_top = 0,
                background = Blitbuffer.COLOR_WHITE,
                dimen = Geom:new{ w = w, h = body_h },
                LeftContainer:new{
                    dimen = Geom:new{ w = content_w, h = body_h - pad },
                    VerticalGroup:new{ align = "left", content, VerticalSpan:new{ width = 0 } },
                },
            },
        },
    }
    self.dimen = Geom:new{ x = 0, y = 0, w = w, h = h }
end

return Panel
