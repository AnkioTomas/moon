--[[--
Book 桌面 — 对齐 SimpleUI 的壳，不做它的主题/模块系统：
  首页：时间 + 最近阅读
  底栏：首页 | 书库 | 分类 | 设置

@module koplugin.book.desktop
--]]

local BD = require("ui/bidi")
local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputDialog = require("ui/widget/inputdialog")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local Menu = require("ui/widget/menu")
local NetworkMgr = require("ui/network/manager")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template
local Screen = Device.screen

local BAR_H = Screen:scaleBySize(52)

local TABS = {
    { id = "home", text = _("首页") },
    { id = "library", text = _("书库") },
    { id = "category", text = _("分类") },
    { id = "settings", text = _("设置") },
}

local Desktop = InputContainer:extend{
    name = "book_desktop",
    covers_fullscreen = true,
    plugin = nil,
    api = nil,
    tab = "home",
    filter = nil,
}

function Desktop:init()
    self.filter = self.filter or {}
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.page = 1
    self.page_size = 20
    self.total = 0
    self._closed = false
    self.ges_events = {
        TapBar = {
            GestureRange:new{
                ges = "tap",
                range = Geom:new{
                    x = 0,
                    y = self.dimen.h - BAR_H,
                    w = self.dimen.w,
                    h = BAR_H,
                },
            },
        },
        Swipe = {
            GestureRange:new{
                ges = "swipe",
                range = self.dimen,
            },
        },
    }
    self:rebuild()
    UIManager:nextTick(function()
        if not self._closed and self.tab == "home" then
            self:refreshClock()
        end
    end)
end

function Desktop:contentHeight()
    return self.dimen.h - BAR_H
end

function Desktop:buildBottomBar()
    local cells = {}
    local cell_w = math.floor(self.dimen.w / #TABS)
    for i, tab in ipairs(TABS) do
        local active = self.tab == tab.id
        local w = (i == #TABS) and (self.dimen.w - cell_w * (#TABS - 1)) or cell_w
        table.insert(cells, CenterContainer:new{
            dimen = Geom:new{ w = w, h = BAR_H },
            TextWidget:new{
                text = tab.text,
                face = Font:getFace("cfont", active and 18 or 16),
                bold = active,
                fgcolor = active and Blitbuffer.COLOR_BLACK or Blitbuffer.gray(0.45),
            },
        })
    end
    return FrameContainer:new{
        bordersize = 0,
        padding = 0,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{
            align = "left",
            LineWidget:new{
                background = Blitbuffer.gray(0.7),
                dimen = Geom:new{ w = self.dimen.w, h = Size.line.thin },
            },
            HorizontalGroup:new(cells),
        },
    }
end

function Desktop:onTapBar(_, ges)
    if not ges or not ges.pos then
        return false
    end
    if ges.pos.y < self.dimen.h - BAR_H then
        return false
    end
    local idx = math.floor(ges.pos.x * #TABS / self.dimen.w) + 1
    if idx < 1 then idx = 1 end
    if idx > #TABS then idx = #TABS end
    self:switchTab(TABS[idx].id)
    return true
end

function Desktop:onSwipe(_, ges_ev)
    if type(ges_ev) ~= "table" or not ges_ev.direction then
        return true
    end
    -- 底栏区域不翻页
    if ges_ev.pos and ges_ev.pos.y >= self.dimen.h - BAR_H then
        return true
    end
    local direction = BD.flipDirectionIfMirroredUILayout(ges_ev.direction)
    if direction == "south" then
        -- 下滑关闭桌面，回 FileManager（和 Menu 一致）
        self:onClose()
        return true
    end
    if self.tab == "library" then
        if direction == "west" then
            local pages = math.max(1, math.ceil((self.total or 0) / self.page_size))
            if self.page < pages then
                self.page = self.page + 1
                self:rebuild()
            end
            return true
        elseif direction == "east" then
            if self.page > 1 then
                self.page = self.page - 1
                self:rebuild()
            end
            return true
        end
    end
    return true
end

function Desktop:switchTab(id)
    if self.tab == id and id ~= "library" and id ~= "category" then
        return
    end
    self.tab = id
    if id == "library" then
        self.page = 1
    end
    self:rebuild()
end

function Desktop:rebuild()
    local ok, err = pcall(function()
        local content
        if self.tab == "home" then
            content = self:buildHome()
        elseif self.tab == "library" then
            content = self:buildLibrary()
        elseif self.tab == "category" then
            content = self:buildCategories()
        else
            content = self:buildSettings()
        end

        self[1] = FrameContainer:new{
            background = Blitbuffer.COLOR_WHITE,
            bordersize = 0,
            padding = 0,
            dimen = self.dimen,
            VerticalGroup:new{
                align = "left",
                content,
                self:buildBottomBar(),
            },
        }
        self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
        if self.ges_events and self.ges_events.TapBar and self.ges_events.TapBar[1] then
            self.ges_events.TapBar[1].range = Geom:new{
                x = 0,
                y = self.dimen.h - BAR_H,
                w = self.dimen.w,
                h = BAR_H,
            }
        end
    end)
    if not ok then
        logger.err("book desktop rebuild failed:", err)
        UIManager:show(InfoMessage:new{ text = _("桌面构建失败:\n") .. tostring(err) })
        return
    end
    UIManager:setDirty(self, "ui")
end

-- ---------------------------------------------------------------------------
-- 首页：时钟 + 最近阅读
-- ---------------------------------------------------------------------------

function Desktop:recentBooks(limit)
    limit = limit or 8
    local list = {}
    local ok, ReadHistory = pcall(require, "readhistory")
    if ok and ReadHistory then
        pcall(function()
            if ReadHistory.reload then
                ReadHistory:reload()
            elseif ReadHistory._read then
                ReadHistory:_read(true)
            end
        end)
        local lib = nil
        if self.plugin and self.plugin.localPathFor then
            -- library_dir 前缀过滤；没有就全要
            local s = G_reader_settings:readSetting("book_plugin") or {}
            lib = s.library_dir
        end
        local map = G_reader_settings:readSetting("book_plugin_filemap") or {}
        local function push(entry, path, mapped)
            table.insert(list, {
                title = entry.text or path:match("([^/\\]+)$") or path,
                path = path,
                filename = mapped or path:match("([^/\\]+)$"),
                mandatory = entry.mandatory or "",
                book = {
                    filename = mapped or path:match("([^/\\]+)$"),
                    bookName = entry.text,
                },
            })
        end
        for _, entry in ipairs(ReadHistory.hist or {}) do
            if #list >= limit then break end
            local path = entry.file
            if path then
                local mapped = map[path]
                local in_lib = (not lib) or (lib ~= "" and path:sub(1, #lib) == lib)
                if in_lib or mapped then
                    push(entry, path, mapped)
                end
            end
        end
        -- 过滤后为空：退回全局最近，避免首页空白
        if #list == 0 then
            for _, entry in ipairs(ReadHistory.hist or {}) do
                if #list >= limit then break end
                local path = entry.file
                if path then
                    push(entry, path, map[path])
                end
            end
        end
    end
    return list
end

function Desktop:buildHome()
    local h = self:contentHeight()
    local w = self.dimen.w
    local now = os.date("*t")
    local time_str = string.format("%02d:%02d", now.hour, now.min)
    local date_str = os.date("%Y-%m-%d %A")

    local rows = {
        VerticalSpan:new{ width = Screen:scaleBySize(36) },
        CenterContainer:new{
            dimen = Geom:new{ w = w, h = Screen:scaleBySize(72) },
            TextWidget:new{
                text = time_str,
                face = Font:getFace("cfont", 64),
                bold = true,
            },
        },
        CenterContainer:new{
            dimen = Geom:new{ w = w, h = Screen:scaleBySize(28) },
            TextWidget:new{
                text = date_str,
                face = Font:getFace("xx_smallinfofont", 16),
                fgcolor = Blitbuffer.gray(0.4),
            },
        },
        VerticalSpan:new{ width = Screen:scaleBySize(24) },
        LeftContainer:new{
            dimen = Geom:new{ w = w, h = Screen:scaleBySize(30) },
            TextWidget:new{
                text = "  " .. _("最近阅读"),
                face = Font:getFace("cfont", 18),
                bold = true,
            },
        },
        VerticalSpan:new{ width = Screen:scaleBySize(8) },
    }

    local recent = self:recentBooks(8)
    if #recent == 0 then
        table.insert(rows, LeftContainer:new{
            dimen = Geom:new{ w = w, h = Screen:scaleBySize(40) },
            TextWidget:new{
                text = "  " .. _("暂无记录 · 去书库打开一本书"),
                face = Font:getFace("xx_smallinfofont", 15),
                fgcolor = Blitbuffer.gray(0.5),
            },
        })
    else
        for _, item in ipairs(recent) do
            local book = item.book
            table.insert(rows, FrameContainer:new{
                bordersize = 0,
                padding = 0,
                margin = 0,
                background = Blitbuffer.COLOR_WHITE,
                Button:new{
                    text = item.title,
                    bordersize = 0,
                    radius = 0,
                    padding = Size.padding.large,
                    text_font_face = "cfont",
                    text_font_size = 17,
                    width = w,
                    align = "left",
                    callback = function()
                        if self.plugin and book then
                            self.plugin:openBook(book)
                        end
                    end,
                },
            })
        end
    end

    local vg = VerticalGroup:new{ align = "left" }
    for _, r in ipairs(rows) do
        table.insert(vg, r)
    end

    return FrameContainer:new{
        bordersize = 0,
        padding = 0,
        background = Blitbuffer.COLOR_WHITE,
        dimen = Geom:new{ w = w, h = h },
        vg,
    }
end

function Desktop:refreshClock()
    if self._closed or self.tab ~= "home" then
        return
    end
    self:rebuild()
    UIManager:scheduleIn(30, function()
        if self.refreshClock then
            self:refreshClock()
        end
    end)
end

-- ---------------------------------------------------------------------------
-- 书库
-- ---------------------------------------------------------------------------

function Desktop:filterLabel()
    local parts = {}
    if self.filter.favorite and self.filter.favorite ~= "" then
        table.insert(parts, self.filter.favorite)
    end
    if self.filter.search and self.filter.search ~= "" then
        table.insert(parts, T(_("搜:%1"), self.filter.search))
    end
    if self.filter.finished == "1" then
        table.insert(parts, _("已读"))
    elseif self.filter.finished == "0" then
        table.insert(parts, _("未读"))
    end
    if #parts == 0 then
        return _("全部")
    end
    return table.concat(parts, " · ")
end

function Desktop:embedMenu(menu)
    -- 嵌入桌面：关闭按钮 / 下滑 / 多指滑 都关掉整个桌面，避免只拆掉 Menu 留下空洞
    local desk = self
    menu.onClose = function()
        desk:onClose()
        return true
    end
    menu.onCloseAllMenus = function()
        desk:onClose()
        return true
    end
    menu.onMultiSwipe = function()
        desk:onClose()
        return true
    end
    return menu
end

function Desktop:buildLibrary()
    local h = self:contentHeight()
    local w = self.dimen.w
    local items = {
        { text = _("加载中…"), enabled = false },
    }
    local menu = self:embedMenu(Menu:new{
        title = T(_("书库 · %1"), self:filterLabel()),
        item_table = items,
        width = w,
        height = h,
        is_borderless = true,
        is_popout = false,
        covers_fullscreen = false,
        show_parent = self,
        title_bar_left_icon = "appbar.search",
        close_callback = function() end,
    })
    menu.onLeftButtonTap = function()
        self:showSearch()
    end
    UIManager:nextTick(function()
        if self._closed or self.tab ~= "library" then return end
        self:loadLibraryInto(menu)
    end)
    return menu
end

function Desktop:loadLibraryInto(menu)
    local function apply(items, title)
        if self._closed or self.tab ~= "library" then return end
        menu:switchItemTable(title or menu.title, items)
        UIManager:setDirty(self, "ui")
    end

    local function fetch()
        if not self.api or not self.api:configured() then
            apply({
                {
                    text = _("请先配置服务器与令牌"),
                    callback = function()
                        if self.plugin then self.plugin:showConfigDialog() end
                    end,
                },
            }, _("书库"))
            return
        end

        local res, err
        local ok, thrown = pcall(function()
            res, err = self.api:listBooks{
                page = self.page,
                pageSize = self.page_size,
                favorite = self.filter.favorite or "",
                search = self.filter.search or "",
                category = self.filter.category or "",
                series = self.filter.series or "",
                finished = self.filter.finished or "",
            }
        end)
        if not ok then
            apply({{ text = _("异常: ") .. tostring(thrown), enabled = false }}, _("书库"))
            return
        end
        if not res then
            apply({
                {
                    text = err or _("加载失败 · 点此重试"),
                    callback = function() self:rebuild() end,
                },
            }, _("书库"))
            return
        end

        local books = res.data or {}
        self.total = tonumber(res.count) or #books
        local pages = math.max(1, math.ceil(self.total / self.page_size))
        local label = self:filterLabel()
        local items = {
            {
                text = T(_("▾ %1 · %2/%3 页 · 共 %4 本"), label, self.page, pages, self.total),
                callback = function()
                    self:showLibraryActions()
                end,
            },
        }
        if #books == 0 then
            table.insert(items, { text = _("（没有书籍）"), enabled = false })
        end
        for _, book in ipairs(books) do
            local title = book.bookName or book.filename or "?"
            local author = book.author or ""
            local pct = tonumber(book.progressPercent) or 0
            if pct > 0 and pct <= 1 then pct = pct * 100 end
            local b = book
            table.insert(items, {
                text = title,
                mandatory = pct > 0 and string.format("%.0f%%", pct) or author,
                callback = function()
                    if self.plugin then self.plugin:openBook(b) end
                end,
            })
        end
        if self.page > 1 then
            table.insert(items, {
                text = _("上一页"),
                callback = function()
                    self.page = self.page - 1
                    self:rebuild()
                end,
            })
        end
        if self.page < pages then
            table.insert(items, {
                text = _("下一页"),
                callback = function()
                    self.page = self.page + 1
                    self:rebuild()
                end,
            })
        end
        apply(items, T(_("书库 · %1"), label))
    end

    if NetworkMgr.isOnline and NetworkMgr:isOnline() then
        fetch()
    else
        NetworkMgr:runWhenOnline(fetch)
    end
end

function Desktop:showSearch()
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
                    self.page = 1
                    self.tab = "library"
                    self:rebuild()
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
                    self.page = 1
                    self.tab = "library"
                    self:rebuild()
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Desktop:showLibraryActions()
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    dialog = ButtonDialog:new{
        title = _("书库"),
        buttons = {
            {{ text = _("搜索"), callback = function()
                UIManager:close(dialog); self:showSearch()
            end }},
            {{ text = _("未读"), callback = function()
                UIManager:close(dialog); self.filter.finished = "0"; self.page = 1; self:rebuild()
            end }},
            {{ text = _("已读"), callback = function()
                UIManager:close(dialog); self.filter.finished = "1"; self.page = 1; self:rebuild()
            end }},
            {{ text = _("清除筛选"), callback = function()
                UIManager:close(dialog); self.filter = {}; self.page = 1; self:rebuild()
            end }},
            {{ text = _("刷新"), callback = function()
                UIManager:close(dialog); self:rebuild()
            end }},
        },
    }
    UIManager:show(dialog)
end

-- ---------------------------------------------------------------------------
-- 分类
-- ---------------------------------------------------------------------------

function Desktop:buildCategories()
    local h = self:contentHeight()
    local w = self.dimen.w
    local items = { { text = _("加载中…"), enabled = false } }
    local menu = self:embedMenu(Menu:new{
        title = _("分类"),
        item_table = items,
        width = w,
        height = h,
        is_borderless = true,
        is_popout = false,
        covers_fullscreen = false,
        show_parent = self,
        close_callback = function() end,
    })
    UIManager:nextTick(function()
        if self._closed or self.tab ~= "category" then return end
        self:loadCategoriesInto(menu)
    end)
    return menu
end

function Desktop:loadCategoriesInto(menu)
    local function apply(items)
        if self._closed or self.tab ~= "category" then return end
        menu:switchItemTable(_("分类"), items)
        UIManager:setDirty(self, "ui")
    end

    local function fetch()
        if not self.api or not self.api:configured() then
            apply({{
                text = _("请先配置服务器"),
                callback = function()
                    if self.plugin then self.plugin:showConfigDialog() end
                end,
            }})
            return
        end
        local res, err = self.api:filters()
        if not res then
            apply({{
                text = err or _("加载失败 · 点此重试"),
                callback = function() self:rebuild() end,
            }})
            return
        end
        local favorites = (res.data and res.data.favorites) or {}
        local items = {{
            text = _("全部分类"),
            callback = function()
                self.filter.favorite = ""
                self.page = 1
                self:switchTab("library")
            end,
        }}
        if #favorites == 0 then
            table.insert(items, { text = _("（暂无分类）"), enabled = false })
        end
        for _, name in ipairs(favorites) do
            local cat = name
            table.insert(items, {
                text = cat,
                callback = function()
                    self.filter.favorite = cat
                    self.page = 1
                    self:switchTab("library")
                end,
            })
        end
        apply(items)
    end

    if NetworkMgr.isOnline and NetworkMgr:isOnline() then
        fetch()
    else
        NetworkMgr:runWhenOnline(fetch)
    end
end

-- ---------------------------------------------------------------------------
-- 设置
-- ---------------------------------------------------------------------------

function Desktop:buildSettings()
    local h = self:contentHeight()
    local w = self.dimen.w
    local plugin = self.plugin
    local s = G_reader_settings:readSetting("book_plugin") or {}
    local open_on = s.open_on_start
        or G_reader_settings:readSetting("start_with") == "bookshelf_book"
    local auto_sync = s.auto_sync ~= false
    local items = {
        {
            text = _("服务器与令牌"),
            callback = function()
                if plugin then plugin:showConfigDialog() end
            end,
        },
        {
            text = _("测试连接"),
            callback = function()
                if plugin then plugin:testConnection() end
            end,
        },
        {
            text = _("启动时打开桌面"),
            mandatory = open_on and _("开") or _("关"),
            callback = function()
                local st = G_reader_settings:readSetting("book_plugin") or {}
                st.open_on_start = not open_on
                G_reader_settings:saveSetting("book_plugin", st)
                if st.open_on_start then
                    G_reader_settings:saveSetting("start_with", "bookshelf_book")
                elseif G_reader_settings:readSetting("start_with") == "bookshelf_book" then
                    G_reader_settings:saveSetting("start_with", "filemanager")
                end
                self:rebuild()
            end,
        },
        {
            text = _("自动同步进度"),
            mandatory = auto_sync and _("开") or _("关"),
            callback = function()
                local st = G_reader_settings:readSetting("book_plugin") or {}
                st.auto_sync = not auto_sync
                G_reader_settings:saveSetting("book_plugin", st)
                self:rebuild()
            end,
        },
        {
            text = _("关闭桌面"),
            callback = function()
                self:onClose()
            end,
        },
    }
    return self:embedMenu(Menu:new{
        title = _("设置"),
        item_table = items,
        width = w,
        height = h,
        is_borderless = true,
        is_popout = false,
        covers_fullscreen = false,
        show_parent = self,
        close_callback = function() end,
    })
end

function Desktop:onClose()
    self._closed = true
    UIManager:close(self)
    if self.close_callback then
        self.close_callback()
    end
    return true
end

function Desktop:onCloseWidget()
    self._closed = true
end

return Desktop
