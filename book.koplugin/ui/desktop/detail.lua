--[[--
书籍详情：顶栏 + 封面/元信息/简介 + 底部按钮
  单页；简介超出可视高度截断。禁止 ScrollableContainer，也不分页。

布局：
  +-----------------------------------------------+
  | ← 书名……                                  ✕  | TitleBar
  |-----------------------------------------------|
  | +----+  作者  xxx                             |
  | |封面|  分类  xxx                             |
  | |    |  系列  xxx                             |
  | +----+  NN%  ========····                     |
  | 简介                                          |
  | ………………………………………………………          |
  |-----------------------------------------------|
  | [返回]  [刮削?]  [开始阅读]                   |
  +-----------------------------------------------+

@module koplugin.book.ui.detail
--]]

local Blitbuffer = require("ffi/blitbuffer")
local ButtonTable = require("ui/widget/buttontable")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TitleBar = require("ui/widget/titlebar")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local TextWidget = require("ui/widget/textwidget")
local BookInfo = require("ui.components.bookinfo")
local UI = require("ui.components.bookui")
local _ = require("gettext")
local Screen = Device.screen

local Detail = InputContainer:extend{
    name = "book_detail",
    covers_fullscreen = true,
    book = nil,
    plugin = nil,
    source = nil,
    desktop = nil,
}

--- 元信息一行：左侧标签 + 右侧值；值为空则返回 nil。
---@param label string
---@param value string|nil
---@param width number
---@return table|nil
local function metaRow(label, value, width)
    if not value or value == "" then
        return nil
    end
    local label_w = UI.sz(72)
    local value_w = math.max(UI.sz(40), width - label_w - UI.sz(8))
    return HorizontalGroup:new{
        LeftContainer:new{
            dimen = Geom:new{ w = label_w, h = UI.sz(28) },
            TextWidget:new{
                text = label,
                face = UI.face("xx_smallinfofont", 14),
                fgcolor = UI.muted(),
            },
        },
        TextWidget:new{
            text = tostring(value),
            face = UI.face("cfont", 15),
            max_width = value_w,
            fgcolor = Blitbuffer.COLOR_BLACK,
        },
    }
end

--- 初始化全屏尺寸、返回键，并 rebuild。
function Detail:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    if Device:hasKeys() then
        self.key_events = {
            Close = { { Device.input.group.Back } },
        }
    end
    self:rebuild()
    if self.book and self.book.ref and self.book.ref.source_id == "zlib" then
        self._store_detail_job = require("zlib.init").getDetailAsync(self.book, function(detail)
            self._store_detail_job = nil
            if self._closed or not detail then return end
            self.book = detail
            self:rebuild()
            require("ui/uimanager"):setDirty(self, "full")
        end)
    end
end

--- 返回详情页尺寸。
---@return table
function Detail:getSize()
    return self.dimen
end

--- 关闭详情并强制重绘下层桌面。
---@return boolean
function Detail:onClose()
    self._closed = true
    if self._store_detail_job and self._store_detail_job.cancel then self._store_detail_job.cancel() end
    if self._install_job and self._install_job.cancel then self._install_job.cancel() end
    self._store_detail_job, self._install_job = nil, nil
    local UIManager = require("ui/uimanager")
    local desk = self.desktop
    UIManager:close(self)
    -- 全屏详情盖住桌面，关掉后必须强制重绘下层，否则残影/白板
    UIManager:nextTick(function()
        if desk and not desk._closed then
            UIManager:setDirty(desk, "full")
        else
            UIManager:setDirty("all", "full")
        end
    end)
    return true
end

--- 刮削结束后重读 books 行并重绘：元数据与封面都只在 rebuild 时取，
--- 光 setDirty 只会把旧数据再画一遍。
function Detail:reload()
    local ref = self.book.ref
    local row
    require("utils.db.queue").run(function()
        row = require("utils.db.book").get(ref.source_id, ref.stable_id)
    end, {
        on_done = function()
            if self._closed then
                return
            end
            if row then
                row.ref = self.book.ref
                self.book = row
            end
            self:rebuild()
            require("ui/uimanager"):setDirty(self, "full")
        end,
    })
end

--- Widget 关闭时触发 close_callback。
function Detail:onCloseWidget()
    self._closed = true
    local cb = self.close_callback
    self.close_callback = nil
    if cb then
        cb()
    end
end

--- 重建封面、元信息、简介与底部按钮。
function Detail:rebuild()
    local book = self.book or {}
    local w = Screen:getWidth()
    local h = Screen:getHeight()
    local pad = UI.pagePad()
    local content_w = w - pad * 2
    local title = BookInfo.title(book)
    if title == "?" then title = _("书籍详情") end

    local cw, ch = UI.sz(120), UI.sz(170)
    local cover_w = select(1, BookInfo.cover(self.plugin, self.source, book, cw, ch, {
        badge = false,
        show_parent = self,
    }))

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

    local caps = self.source and self.source:capabilities() or {}
    local btn_font = UI.buttonFontSize()
    local button_row = {
        {
            text = _("返回"),
            font_size = btn_font,
            callback = function()
                self:onClose()
            end,
        },
    }
    if caps.scrape == true and type(book.ref) == "table"
        and type(book.ref.source_id) == "string" and type(book.ref.stable_id) == "string" then
        table.insert(button_row, {
            text = _("刮削"),
            font_size = btn_font,
            callback = function()
                require("scrape.ui").start(self.book.ref, self.book.title, function()
                    self:reload()
                end)
            end,
        })
    end
    local store_book = book.ref and book.ref.source_id == "zlib"
    table.insert(button_row, {
        text = store_book and _("加入书库") or _("开始阅读"),
        font_size = btn_font,
        enabled = store_book and type(self.source and self.source.importBookAsync) == "function"
            or (not store_book and (caps.whole_book == true or caps.chapters == true)),
        callback = function()
            if store_book then
                if self._install_job then return end
                if not require("zlib.init").hasCredentials() then
                    require("zlib.setting").open(self.plugin)
                    return
                end
                local ProgressbarDialog = require("ui/widget/progressbardialog")
                local UIManager = require("ui/uimanager")
                local InfoMessage = require("ui/widget/infomessage")
                local dialog = ProgressbarDialog:new{
                    title = _("正在加入书库…"),
                    subtitle = book.title,
                    progress_max = tonumber(book.filesize),
                    dismissable = false,
                }
                dialog:show()
                require("ui/network/manager"):runWhenOnline(function()
                    if self._closed then dialog:close(); return end
                    self._install_job = require("zlib.init").installAsync(self.source, book, function(bytes)
                        dialog:reportProgress(bytes)
                    end, function(ok, err, filename)
                        self._install_job = nil
                        dialog:close()
                        if self._closed then return end
                        if not ok then
                            UIManager:show(InfoMessage:new{ text = err or _("下载失败") })
                            return
                        end
                        local desk = self.desktop
                        self:onClose()
                        UIManager:show(InfoMessage:new{
                            text = _("已加入书库：") .. tostring(filename or book.title),
                            timeout = 3,
                        })
                        if desk and not desk._closed then
                            desk._library_state = nil
                            desk.page = 1
                            desk:switchTab("library")
                        end
                    end)
                end)
                return
            end
            local plugin = self.plugin
            local b = self.book
            self:onClose()
            if plugin and plugin.openBook then plugin:openBook(b) end
        end,
    })
    local buttons = ButtonTable:new{
        width = content_w,
        buttons = { button_row },
        zero_sep = true,
        show_parent = self,
    }

    local footer_pad_v = UI.sz(12)
    local footer_h = buttons:getSize().h + footer_pad_v * 2
    local title_h = title_bar:getHeight()
    local body_h = math.max(UI.sz(80), h - title_h - footer_h)
    local body_inner_h = math.max(UI.sz(60), body_h - pad - UI.sz(12))

    local meta_w = math.max(UI.sz(80), content_w - cw - UI.sz(14))
    local category = book.category
    if type(category) == "string" and category ~= "" then
        category = category:gsub("[,\n]+", " · ")
    end
    local author = BookInfo.author(book)
    local meta_kids = { align = "left" }
    for _, row in ipairs({
        metaRow(_("作者"), author ~= "" and author or _("未知作者"), meta_w),
        metaRow(_("分类"), category, meta_w),
        metaRow(_("系列"), book.series, meta_w),
    }) do
        if row then
            if #meta_kids > 0 then
                table.insert(meta_kids, VerticalSpan:new{ width = UI.sz(6) })
            end
            table.insert(meta_kids, row)
        end
    end
    local metadata = VerticalGroup:new(meta_kids)
    local progress = BookInfo.progressRow(meta_w, BookInfo.pct(book))
    local filler = math.max(UI.sz(8), ch - metadata:getSize().h - progress:getSize().h)

    local header = HorizontalGroup:new{
        align = "top",
        cover_w,
        HorizontalSpan:new{ width = UI.sz(14) },
        LeftContainer:new{
            dimen = Geom:new{ w = meta_w, h = ch },
            VerticalGroup:new{
                align = "left",
                metadata,
                VerticalSpan:new{ width = filler },
                progress,
            },
        },
    }

    local body_kids = { align = "left", header }
    local desc = BookInfo.desc(book)
    if desc ~= "" then
        local gap = UI.sz(12)
        local title_h_block = UI.sz(30) + UI.sz(6)
        local avail_desc_h = math.max(UI.sz(40), body_inner_h - header:getSize().h - gap - title_h_block)
        table.insert(body_kids, VerticalSpan:new{ width = gap })
        table.insert(body_kids, LeftContainer:new{
            dimen = Geom:new{ w = content_w, h = UI.sz(30) },
            TextWidget:new{
                text = _("简介"),
                face = UI.face("cfont", 15),
                fgcolor = Blitbuffer.COLOR_BLACK,
            },
        })
        table.insert(body_kids, VerticalSpan:new{ width = UI.sz(6) })
        table.insert(body_kids, TextBoxWidget:new{
            text = desc,
            face = UI.face("xx_smallinfofont", 14),
            width = content_w,
            height = avail_desc_h,
            alignment = "left",
            fgcolor = UI.muted(),
        })
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
                padding_top = UI.sz(12),
                background = Blitbuffer.COLOR_WHITE,
                dimen = Geom:new{ w = w, h = body_h },
                LeftContainer:new{
                    dimen = Geom:new{ w = content_w, h = body_inner_h },
                    VerticalGroup:new(body_kids),
                },
            },
            FrameContainer:new{
                bordersize = 0,
                padding = pad,
                padding_top = footer_pad_v,
                padding_bottom = footer_pad_v,
                background = Blitbuffer.COLOR_WHITE,
                dimen = Geom:new{ w = w, h = footer_h },
                buttons,
            },
        },
    }
    self.dimen = Geom:new{ x = 0, y = 0, w = w, h = h }
end

return Detail
