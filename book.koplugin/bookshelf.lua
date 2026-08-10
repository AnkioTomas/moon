--[[--
全屏书架桌面：顶栏 + 工具条 + 封面网格 + 底部分页。

@module koplugin.book.bookshelf
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local ButtonDialog = require("ui/widget/buttondialog")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputDialog = require("ui/widget/inputdialog")
local LineWidget = require("ui/widget/linewidget")
local ProgressWidget = require("ui/widget/progresswidget")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Screen = Device.screen
local lfs = require("libs/libkoreader-lfs")
local _ = require("gettext")
local T = require("ffi/util").template

local Bookshelf = InputContainer:extend{
    covers_fullscreen = true,
    is_always_active = true,
    name = "book_bookshelf",
    -- injected
    plugin = nil,
    api = nil,
    filter = nil, -- { favorite=, search=, category=, series= }
}

local COLS = 3
local PAGE_SIZE_HINT = 9 -- 3x3，实际按屏幕再算

local function coverCachePath(plugin, filename)
    local dir = plugin:coverCacheDir()
    local key = (filename or ""):gsub("[^%w%.%-]", "_")
    if #key > 120 then
        key = key:sub(1, 120)
    end
    return dir .. "/" .. key .. ".img"
end

local function ensureDir(path)
    if lfs.attributes(path, "mode") ~= "directory" then
        lfs.mkdir(path)
    end
end

function Bookshelf:init()
    self.filter = self.filter or {}
    self.page = 1
    self.total = 0
    self.books = {}
    self.page_size = PAGE_SIZE_HINT
    self.dimen = Geom:new{
        x = 0, y = 0,
        w = Screen:getWidth(),
        h = Screen:getHeight(),
    }
    self.item_widgets = {}
    self.cover_jobs = {}

    self.ges_events = {
        Tap = {
            GestureRange:new{ ges = "tap", range = self.dimen },
        },
        Swipe = {
            GestureRange:new{ ges = "swipe", range = self.dimen },
        },
    }

    if Device:hasKeys() then
        self.key_events = {
            Close = { { Device.input.group.Back } },
            NextPage = { { "RPgFwd" }, { "Right" } },
            PrevPage = { { "RPgBack" }, { "Left" } },
        }
    end

    self:recalcLayout()
    self:buildUI()
    self:loadPage(1)
end

function Bookshelf:recalcLayout()
    self.margin = Size.padding.small
    self.gap = Size.padding.small
    -- 预估顶栏+工具+底栏高度后算格子
    local chrome = Screen:scaleBySize(120)
    local grid_h = self.dimen.h - chrome
    local grid_w = self.dimen.w - 2 * self.margin
    self.cols = COLS
    self.item_w = math.floor((grid_w - (self.cols - 1) * self.gap) / self.cols)
    -- 封面约 4:5.5 + 标题 + 进度
    self.cover_h = math.floor(self.item_w * 1.35)
    self.title_h = Screen:scaleBySize(32)
    self.prog_h = Screen:scaleBySize(10)
    self.item_h = self.cover_h + self.title_h + self.prog_h + Size.padding.small * 2
    self.rows = math.max(1, math.floor((grid_h + self.gap) / (self.item_h + self.gap)))
    self.page_size = self.cols * self.rows
end

function Bookshelf:filterSubtitle()
    local parts = {}
    if self.filter.favorite and self.filter.favorite ~= "" then
        table.insert(parts, self.filter.favorite)
    end
    if self.filter.search and self.filter.search ~= "" then
        table.insert(parts, T(_("搜索: %1"), self.filter.search))
    end
    if self.filter.category and self.filter.category ~= "" then
        table.insert(parts, self.filter.category)
    end
    if #parts == 0 then
        return _("全部书籍")
    end
    return table.concat(parts, " · ")
end

function Bookshelf:buildUI()
    self.title_bar = TitleBar:new{
        fullscreen = true,
        align = "center",
        title = _("Book 书库"),
        subtitle = self:filterSubtitle(),
        with_bottom_line = true,
        left_icon = "home",
        left_icon_tap_callback = function()
            self:showActionMenu()
        end,
        close_callback = function()
            self:onClose()
        end,
        show_parent = self,
    }

    local btn_h = Screen:scaleBySize(36)
    local mkbtn = function(text, cb)
        return Button:new{
            text = text,
            bordersize = Size.border.thin,
            margin = 0,
            padding = Size.padding.small,
            radius = Screen:scaleBySize(6),
            height = btn_h,
            show_parent = self,
            callback = cb,
        }
    end

    self.toolbar = HorizontalGroup:new{
        mkbtn(_("搜索"), function() self:showSearch() end),
        HorizontalSpan:new{ width = self.gap },
        mkbtn(_("分类"), function() self:showCategories() end),
        HorizontalSpan:new{ width = self.gap },
        mkbtn(_("刷新"), function() self:loadPage(self.page, true) end),
        HorizontalSpan:new{ width = self.gap },
        mkbtn(_("设置"), function()
            if self.plugin and self.plugin.showConfigDialog then
                self.plugin:showConfigDialog()
            end
        end),
    }

    self.grid = VerticalGroup:new{ align = "left" }
    self.footer_text = TextWidget:new{
        text = "",
        face = Font:getFace("xx_smallinfofont"),
    }
    self.footer = HorizontalGroup:new{
        Button:new{
            text = _("上一页"),
            bordersize = Size.border.thin,
            margin = 0,
            padding = Size.padding.small,
            show_parent = self,
            callback = function() self:prevPage() end,
        },
        HorizontalSpan:new{ width = Size.padding.large },
        self.footer_text,
        HorizontalSpan:new{ width = Size.padding.large },
        Button:new{
            text = _("下一页"),
            bordersize = Size.border.thin,
            margin = 0,
            padding = Size.padding.small,
            show_parent = self,
            callback = function() self:nextPage() end,
        },
    }

    self.main = VerticalGroup:new{
        align = "center",
        self.title_bar,
        VerticalSpan:new{ width = Size.padding.small },
        self.toolbar,
        VerticalSpan:new{ width = Size.padding.small },
        LineWidget:new{
            background = Blitbuffer.COLOR_GRAY,
            dimen = Geom:new{ w = self.dimen.w - 2 * self.margin, h = Size.line.thin },
        },
        VerticalSpan:new{ width = Size.padding.small },
        self.grid,
        VerticalSpan:new{ width = Size.padding.small },
        self.footer,
    }

    self[1] = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding = 0,
        margin = 0,
        width = self.dimen.w,
        height = self.dimen.h,
        CenterContainer:new{
            dimen = self.dimen,
            self.main,
        },
    }
end

function Bookshelf:makeBookItem(book, w, h)
    local cover_h = self.cover_h
    local cover_w = w - Size.padding.small * 2
    local cover_path = coverCachePath(self.plugin, book.filename or "")
    local has_cover = book.filename
        and lfs.attributes(cover_path, "mode") == "file"
        and (lfs.attributes(cover_path, "size") or 0) > 64

    local cover_widget
    if has_cover then
        cover_widget = ImageWidget:new{
            file = cover_path,
            width = cover_w,
            height = cover_h,
            scale_factor = 0,
            alpha = false,
        }
    else
        local label = book.bookName or book.filename or "?"
        cover_widget = FrameContainer:new{
            width = cover_w,
            height = cover_h,
            background = Blitbuffer.COLOR_LIGHT_GRAY,
            bordersize = 0,
            padding = Size.padding.small,
            CenterContainer:new{
                dimen = Geom:new{ w = cover_w, h = cover_h },
                TextBoxWidget:new{
                    text = label,
                    face = Font:getFace("xx_smallinfofont"),
                    width = cover_w - Size.padding.small * 2,
                    alignment = "center",
                    fgcolor = Blitbuffer.COLOR_DARK_GRAY,
                },
            },
        }
        if book.filename then
            table.insert(self.cover_jobs, book.filename)
        end
    end

    local title = TextWidget:new{
        text = book.bookName or book.filename or "",
        face = Font:getFace("xx_smallinfofont"),
        max_width = cover_w,
        truncate_left = false,
        padding = 0,
    }

    local pct = tonumber(book.progressPercent) or 0
    if pct > 1 then
        -- already 0-100
    else
        pct = pct * 100
    end
    pct = math.max(0, math.min(100, pct))

    local progress = ProgressWidget:new{
        width = cover_w,
        height = math.max(Size.line.medium, Screen:scaleBySize(4)),
        percentage = pct / 100,
        bordercolor = Blitbuffer.COLOR_DARK_GRAY,
        fillcolor = Blitbuffer.COLOR_BLACK,
        bgcolor = Blitbuffer.COLOR_WHITE,
    }

    local content = VerticalGroup:new{
        align = "center",
        cover_widget,
        VerticalSpan:new{ width = Screen:scaleBySize(2) },
        title,
        VerticalSpan:new{ width = Screen:scaleBySize(2) },
        progress,
    }

    local frame = FrameContainer:new{
        bordersize = Size.border.thin,
        padding = Size.padding.small,
        margin = 0,
        radius = Screen:scaleBySize(6),
        background = Blitbuffer.COLOR_WHITE,
        width = w,
        height = h,
        CenterContainer:new{
            dimen = Geom:new{ w = w, h = h },
            content,
        },
    }

    local item = InputContainer:new{
        dimen = Geom:new{ w = w, h = h },
        book = book,
        [1] = frame,
    }
    item.ges_events = {
        Tap = {
            GestureRange:new{
                ges = "tap",
                range = item.dimen,
            },
        },
    }
    item.onTap = function(_, ges)
        if ges.pos:intersectWith(item.dimen) then
            self:openBook(book)
            return true
        end
    end
    -- paintTo 时更新 dimen 坐标
    local orig_paint = item.paintTo
    item.paintTo = function(this, bb, x, y)
        this.dimen.x = x
        this.dimen.y = y
        return orig_paint(this, bb, x, y)
    end

    return item
end

function Bookshelf:rebuildGrid()
    for i = #self.grid, 1, -1 do
        local w = self.grid[i]
        if w.free then w:free() end
        table.remove(self.grid, i)
    end
    self.item_widgets = {}
    self.cover_jobs = {}

    local idx = 1
    for r = 1, self.rows do
        local row = HorizontalGroup:new{}
        for c = 1, self.cols do
            if idx <= #self.books then
                local item = self:makeBookItem(self.books[idx], self.item_w, self.item_h)
                table.insert(self.item_widgets, item)
                table.insert(row, item)
                if c < self.cols then
                    table.insert(row, HorizontalSpan:new{ width = self.gap })
                end
            else
                table.insert(row, HorizontalSpan:new{ width = self.item_w })
                if c < self.cols then
                    table.insert(row, HorizontalSpan:new{ width = self.gap })
                end
            end
            idx = idx + 1
        end
        table.insert(self.grid, row)
        if r < self.rows then
            table.insert(self.grid, VerticalSpan:new{ width = self.gap })
        end
    end

    local pages = math.max(1, math.ceil(self.total / self.page_size))
    self.footer_text:setText(T(_("第 %1 / %2 页 · 共 %3 本"), self.page, pages, self.total))
    if self.title_bar.setSubTitle then
        self.title_bar:setSubTitle(self:filterSubtitle(), true)
    end
end

function Bookshelf:loadPage(page, force)
    if not self.api or not self.api:configured() then
        UIManager:show(InfoMessage:new{ text = _("请先配置服务器与令牌") })
        if self.plugin and self.plugin.showConfigDialog then
            self.plugin:showConfigDialog()
        end
        return
    end

    self.page = math.max(1, page or 1)

    local function doLoad()
        UIManager:show(InfoMessage:new{ text = _("加载中…"), timeout = 1 })
        local res, err = self.api:listBooks{
            page = self.page,
            pageSize = self.page_size,
            favorite = self.filter.favorite or "",
            search = self.filter.search or "",
            category = self.filter.category or "",
            series = self.filter.series or "",
            finished = self.filter.finished or "",
        }
        if not res then
            UIManager:show(InfoMessage:new{ text = err or _("加载失败") })
            self.books = {}
            self.total = 0
            self:rebuildGrid()
            UIManager:setDirty(self, "ui")
            return
        end

        self.books = res.data or {}
        self.total = tonumber(res.count) or #self.books
        self:rebuildGrid()
        UIManager:setDirty(self, "ui")
        self:scheduleCoverFetch()
    end

    -- 书架 UI 已经显示；联网失败也只影响列表，不吞掉整页
    local NetworkMgr = require("ui/network/manager")
    if NetworkMgr.isOnline and NetworkMgr:isOnline() then
        doLoad()
    elseif NetworkMgr.runWhenOnline then
        NetworkMgr:runWhenOnline(doLoad)
    else
        doLoad()
    end
end

function Bookshelf:scheduleCoverFetch()
    if not self.cover_jobs or #self.cover_jobs == 0 then
        return
    end
    local jobs = self.cover_jobs
    self.cover_jobs = {}
    local i = 1
    local function step()
        if not self._shown then
            return
        end
        if i > #jobs then
            return
        end
        local filename = jobs[i]
        i = i + 1
        local path = coverCachePath(self.plugin, filename)
        ensureDir(self.plugin:coverCacheDir())
        if lfs.attributes(path, "mode") ~= "file" then
            local ok = self.api:downloadCover(filename, path)
            if ok then
                -- 轻量刷新：整页重画格子
                self:rebuildGrid()
                UIManager:setDirty(self, "ui")
            end
        end
        UIManager:scheduleIn(0.05, step)
    end
    UIManager:scheduleIn(0.1, step)
end

function Bookshelf:nextPage()
    local pages = math.max(1, math.ceil(self.total / self.page_size))
    if self.page < pages then
        self:loadPage(self.page + 1)
    end
end

function Bookshelf:prevPage()
    if self.page > 1 then
        self:loadPage(self.page - 1)
    end
end

function Bookshelf:openBook(book)
    if self.plugin and self.plugin.openBook then
        self.plugin:openBook(book)
    end
end

function Bookshelf:showSearch()
    local dialog
    dialog = InputDialog:new{
        title = _("搜索书籍"),
        input = self.filter.search or "",
        input_hint = _("书名或作者"),
        buttons = {{
            {
                text = _("清除"),
                callback = function()
                    UIManager:close(dialog)
                    self.filter.search = ""
                    self:loadPage(1)
                end,
            },
            {
                text = _("取消"),
                id = "close",
                callback = function()
                    UIManager:close(dialog)
                end,
            },
            {
                text = _("搜索"),
                is_enter_default = true,
                callback = function()
                    self.filter.search = dialog:getInputText() or ""
                    UIManager:close(dialog)
                    self:loadPage(1)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Bookshelf:showCategories()
    local res, err = self.api:filters()
    if not res then
        UIManager:show(InfoMessage:new{ text = err or _("加载分类失败") })
        return
    end
    local favorites = (res.data and res.data.favorites) or {}
    local buttons = {}
    table.insert(buttons, {{
        text = _("全部分类"),
        callback = function()
            UIManager:close(self.cat_dialog)
            self.filter.favorite = ""
            self:loadPage(1)
        end,
    }})
    for _, name in ipairs(favorites) do
        local cat = name
        table.insert(buttons, {{
            text = cat,
            callback = function()
                UIManager:close(self.cat_dialog)
                self.filter.favorite = cat
                self:loadPage(1)
            end,
        }})
    end
    self.cat_dialog = ButtonDialog:new{
        title = _("选择分类"),
        buttons = buttons,
    }
    UIManager:show(self.cat_dialog)
end

function Bookshelf:showActionMenu()
    local dialog
    dialog = ButtonDialog:new{
        title = _("Book 书库"),
        buttons = {
            {{
                text = _("未读"),
                callback = function()
                    UIManager:close(dialog)
                    self.filter.finished = "0"
                    self:loadPage(1)
                end,
            }},
            {{
                text = _("已读"),
                callback = function()
                    UIManager:close(dialog)
                    self.filter.finished = "1"
                    self:loadPage(1)
                end,
            }},
            {{
                text = _("清除筛选"),
                callback = function()
                    UIManager:close(dialog)
                    self.filter = {}
                    self:loadPage(1)
                end,
            }},
            {{
                text = _("测试连接"),
                callback = function()
                    UIManager:close(dialog)
                    if self.plugin and self.plugin.testConnection then
                        self.plugin:testConnection()
                    end
                end,
            }},
            {{
                text = _("关闭"),
                callback = function()
                    UIManager:close(dialog)
                end,
            }},
        },
    }
    UIManager:show(dialog)
end

function Bookshelf:onShow()
    self._shown = true
    return true
end

function Bookshelf:onCloseWidget()
    self._shown = false
end

function Bookshelf:onClose()
    UIManager:close(self)
    if self.close_callback then
        self.close_callback()
    end
    return true
end

function Bookshelf:onTap(ges)
    -- 子 item 自己处理；这里兜底
    for _, item in ipairs(self.item_widgets) do
        if item.dimen and ges.pos:intersectWith(item.dimen) then
            return item:onTap(ges)
        end
    end
end

function Bookshelf:onSwipe(ges)
    if ges.direction == "west" then
        self:nextPage()
        return true
    elseif ges.direction == "east" then
        self:prevPage()
        return true
    end
end

function Bookshelf:onNextPage()
    self:nextPage()
    return true
end

function Bookshelf:onPrevPage()
    self:prevPage()
    return true
end

return Bookshelf
