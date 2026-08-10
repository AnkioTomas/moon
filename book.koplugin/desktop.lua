--[[--
Book 桌面壳 — SimpleUI 同级能力（精简实现，不抄主题系统）：
  - 底栏图标+文字：首页 / 书库 / 分类 / 设置
  - 首页模块：时钟 + 最近阅读封面行
  - 书库：封面网格
  - 分类 / 设置

@module koplugin.book.desktop
--]]

local BD = require("ui/bidi")
local Blitbuffer = require("ffi/blitbuffer")
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
local LineWidget = require("ui/widget/linewidget")
local Menu = require("ui/widget/menu")
local NetworkMgr = require("ui/network/manager")
local OverlapGroup = require("ui/widget/overlapgroup")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template
local Screen = Device.screen

local Registry = require("modules/registry")
local CoverGrid = require("modules/covergrid")

local BAR_H = Screen:scaleBySize(56)
local ICON_SZ = Screen:scaleBySize(22)

-- 插件目录下 icons/（PluginLoader 把插件目录塞进 package.path，但不保证 cwd）
local function pluginIconDir()
    local info = debug.getinfo(1, "S")
    local src = info and info.source
    if src and src:sub(1, 1) == "@" then
        local dir = src:sub(2):match("(.*/)")
        if dir then return dir .. "icons/" end
    end
    return "icons/"
end

local TABS = {
    { id = "home", text = _("首页"), icon = "home.svg" },
    { id = "library", text = _("书库"), icon = "library.svg" },
    { id = "category", text = _("分类"), icon = "tags.svg" },
    { id = "settings", text = _("设置"), icon = "settings.svg" },
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
    self.page_size = 12
    self.total = 0
    self._closed = false
    self.ges_events = {
        TapBar = {
            GestureRange:new{
                ges = "tap",
                range = function()
                    return Geom:new{
                        x = 0,
                        y = Screen:getHeight() - BAR_H,
                        w = Screen:getWidth(),
                        h = BAR_H,
                    }
                end,
            },
        },
        Swipe = {
            GestureRange:new{
                ges = "swipe",
                range = function()
                    return Geom:new{
                        x = 0, y = 0,
                        w = Screen:getWidth(),
                        h = Screen:getHeight(),
                    }
                end,
            },
        },
    }
    self:rebuild()
    UIManager:nextTick(function()
        if not self._closed and self.tab == "home" then
            self:scheduleClockTick()
        end
    end)
end

function Desktop:contentHeight()
    return self.dimen.h - BAR_H
end

function Desktop:safeIcon(name)
    local path = pluginIconDir() .. name
    local ok, img = pcall(function()
        local ImageWidget = require("ui/widget/imagewidget")
        local w = ImageWidget:new{
            file = path,
            width = ICON_SZ,
            height = ICON_SZ,
            is_icon = true,
            alpha = true,
        }
        if w._render then w:_render() end
        return w
    end)
    if ok and img then return img end
    -- 回退：KOReader 内置 icon
    local fallback = ({
        ["home.svg"] = "home",
        ["library.svg"] = "appbar.cabinet",
        ["tags.svg"] = "appbar.menu",
        ["settings.svg"] = "appbar.settings",
    })[name]
    if fallback then
        local ok2, iw = pcall(function()
            return require("ui/widget/iconwidget"):new{
                icon = fallback,
                width = ICON_SZ,
                height = ICON_SZ,
                alpha = true,
            }
        end)
        if ok2 and iw then return iw end
    end
    return TextWidget:new{
        text = "•",
        face = Font:getFace("cfont", 18),
    }
end

function Desktop:buildBottomBar()
    local cells = {}
    local cell_w = math.floor(self.dimen.w / #TABS)
    for i, tab in ipairs(TABS) do
        local active = self.tab == tab.id
        local w = (i == #TABS) and (self.dimen.w - cell_w * (#TABS - 1)) or cell_w
        local vg = VerticalGroup:new{ align = "center" }
        table.insert(vg, self:safeIcon(tab.icon))
        table.insert(vg, VerticalSpan:new{ width = Screen:scaleBySize(2) })
        table.insert(vg, TextWidget:new{
            text = tab.text,
            face = Font:getFace("xx_smallinfofont", 12),
            bold = active,
            fgcolor = active and Blitbuffer.COLOR_BLACK or Blitbuffer.gray(0.45),
        })
        local content = CenterContainer:new{
            dimen = Geom:new{ w = w, h = BAR_H },
            vg,
        }
        local og = OverlapGroup:new{
            allow_mirroring = false,
            dimen = Geom:new{ w = w, h = BAR_H },
            content,
        }
        if active then
            table.insert(og, LineWidget:new{
                dimen = Geom:new{ w = w, h = Size.line.medium },
                background = Blitbuffer.COLOR_BLACK,
                overlap_offset = { 0, 0 },
            })
        end
        table.insert(cells, og)
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
    if not ges or not ges.pos then return false end
    if ges.pos.y < self.dimen.h - BAR_H then return false end
    local idx = math.floor(ges.pos.x * #TABS / self.dimen.w) + 1
    if idx < 1 then idx = 1 end
    if idx > #TABS then idx = #TABS end
    self:switchTab(TABS[idx].id)
    return true
end

function Desktop:onSwipe(_, ges_ev)
    if type(ges_ev) ~= "table" or not ges_ev.direction then return true end
    if ges_ev.pos and ges_ev.pos.y >= self.dimen.h - BAR_H then return true end
    local direction = BD.flipDirectionIfMirroredUILayout(ges_ev.direction)
    if direction == "south" then
        self:onClose()
        return true
    end
    if self.tab == "library" then
        if direction == "west" then
            local pages = math.max(1, math.ceil((self.total or 0) / self.page_size))
            if self.page < pages then
                self.page = self.page + 1
                self._library_books = nil
                self:rebuild()
            end
        elseif direction == "east" then
            if self.page > 1 then
                self.page = self.page - 1
                self._library_books = nil
                self:rebuild()
            end
        end
    end
    return true
end

function Desktop:switchTab(id)
    if id == "library" and self.tab ~= "library" then
        self._library_books = nil
        self.page = self.page or 1
    end
    self.tab = id
    if id == "home" then
        self:scheduleClockTick()
    end
    self:rebuild()
end

function Desktop:ctx()
    return {
        width = self.dimen.w,
        height = self:contentHeight(),
        plugin = self.plugin,
        api = self.api,
        desktop = self,
        filter = self.filter,
    }
end

function Desktop:rebuild()
    local ok, err = pcall(function()
        self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
        local content
        if self.tab == "home" then
            content = self:buildHome()
        elseif self.tab == "library" then
            content = self:buildLibraryShell()
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
    end)
    if not ok then
        logger.err("book desktop rebuild failed:", err)
        UIManager:show(InfoMessage:new{ text = _("桌面构建失败:\n") .. tostring(err) })
        return
    end
    UIManager:setDirty(self, "ui")
end

function Desktop:buildHome()
    local h = self:contentHeight()
    local body = Registry.buildHome(self:ctx())
    return FrameContainer:new{
        bordersize = 0,
        padding = 0,
        background = Blitbuffer.COLOR_WHITE,
        dimen = Geom:new{ w = self.dimen.w, h = h },
        body,
    }
end

function Desktop:scheduleClockTick()
    if self._clock_scheduled then return end
    self._clock_scheduled = true
    UIManager:scheduleIn(30, function()
        self._clock_scheduled = false
        if self._closed or self.tab ~= "home" then return end
        self:rebuild()
        self:scheduleClockTick()
    end)
end

-- ---------------------------------------------------------------------------
-- 书库：封面网格（异步拉数）
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
    if #parts == 0 then return _("全部") end
    return table.concat(parts, " · ")
end

function Desktop:buildLibraryShell()
    local h = self:contentHeight()
    local w = self.dimen.w
    -- 先放占位，nextTick 拉完再 rebuild 成网格
    local placeholder = FrameContainer:new{
        bordersize = 0,
        padding = 0,
        background = Blitbuffer.COLOR_WHITE,
        dimen = Geom:new{ w = w, h = h },
        CenterContainer:new{
            dimen = Geom:new{ w = w, h = h },
            TextWidget:new{
                text = _("加载书库…"),
                face = Font:getFace("cfont", 18),
                fgcolor = Blitbuffer.gray(0.45),
            },
        },
    }
    if self._library_books then
        local pages = math.max(1, math.ceil((self.total or 0) / self.page_size))
        return CoverGrid.build(self:ctx(), self._library_books, {
            header = T(_("书库 · %1"), self:filterLabel()),
            page = self.page,
            pages = pages,
            empty_text = _("没有书籍"),
        })
    end
    UIManager:nextTick(function()
        if self._closed or self.tab ~= "library" then return end
        self:fetchLibrary()
    end)
    return placeholder
end

function Desktop:fetchLibrary()
    local function done(books, err)
        if self._closed or self.tab ~= "library" then return end
        if not books then
            self._library_books = {}
            self.total = 0
            UIManager:show(InfoMessage:new{ text = err or _("加载失败"), timeout = 3 })
        else
            self._library_books = books
        end
        self:rebuild()
    end

    local function fetch()
        if not self.api or not self.api:configured() then
            done(nil, _("请先在设置里配置服务器与令牌"))
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
            done(nil, tostring(thrown))
            return
        end
        if not res then
            done(nil, err or _("加载失败"))
            return
        end
        self.total = tonumber(res.count) or 0
        done(res.data or {})
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
                    self._library_books = nil
                    self.tab = "library"
                    self:rebuild()
                end,
            },
            {
                text = _("取消"),
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("搜索"),
                is_enter_default = true,
                callback = function()
                    self.filter.search = dialog:getInputText() or ""
                    UIManager:close(dialog)
                    self.page = 1
                    self._library_books = nil
                    self.tab = "library"
                    self:rebuild()
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- ---------------------------------------------------------------------------
-- 分类 / 设置（Menu 嵌入）
-- ---------------------------------------------------------------------------

function Desktop:embedMenu(menu)
    local desk = self
    menu.onClose = function() desk:onClose(); return true end
    menu.onCloseAllMenus = function() desk:onClose(); return true end
    menu.onMultiSwipe = function() desk:onClose(); return true end
    return menu
end

function Desktop:buildCategories()
    local h = self:contentHeight()
    local w = self.dimen.w
    local menu = self:embedMenu(Menu:new{
        title = _("分类"),
        item_table = { { text = _("加载中…"), enabled = false } },
        width = w, height = h,
        is_borderless = true, is_popout = false, covers_fullscreen = false,
        show_parent = self, close_callback = function() end,
    })
    UIManager:nextTick(function()
        if self._closed or self.tab ~= "category" then return end
        local function apply(items)
            menu:switchItemTable(_("分类"), items)
            UIManager:setDirty(self, "ui")
        end
        local function fetch()
            if not self.api or not self.api:configured() then
                apply({{ text = _("请先配置服务器"), callback = function()
                    self:switchTab("settings")
                end }})
                return
            end
            local res, err = self.api:filters()
            if not res then
                apply({{ text = err or _("加载失败"), callback = function() self:rebuild() end }})
                return
            end
            local favorites = (res.data and res.data.favorites) or {}
            local items = {{
                text = _("全部分类"),
                callback = function()
                    self.filter.favorite = ""
                    self.page = 1
                    self._library_books = nil
                    self:switchTab("library")
                end,
            }}
            for _, name in ipairs(favorites) do
                local cat = name
                table.insert(items, {
                    text = cat,
                    callback = function()
                        self.filter.favorite = cat
                        self.page = 1
                        self._library_books = nil
                        self:switchTab("library")
                    end,
                })
            end
            if #favorites == 0 then
                table.insert(items, { text = _("（暂无分类）"), enabled = false })
            end
            apply(items)
        end
        if NetworkMgr.isOnline and NetworkMgr:isOnline() then fetch()
        else NetworkMgr:runWhenOnline(fetch) end
    end)
    return menu
end

function Desktop:buildSettings()
    local h = self:contentHeight()
    local w = self.dimen.w
    local plugin = self.plugin
    local s = G_reader_settings:readSetting("book_plugin") or {}
    local open_on = s.open_on_start ~= false
    local auto_sync = s.auto_sync ~= false
    local items = {
        {
            text = _("服务器与令牌"),
            callback = function() if plugin then plugin:showConfigDialog() end end,
        },
        {
            text = _("测试连接"),
            callback = function() if plugin then plugin:testConnection() end end,
        },
        {
            text = _("搜索书库"),
            callback = function() self:showSearch() end,
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
                else
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
            callback = function() self:onClose() end,
        },
    }
    return self:embedMenu(Menu:new{
        title = _("设置"),
        item_table = items,
        width = w, height = h,
        is_borderless = true, is_popout = false, covers_fullscreen = false,
        show_parent = self, close_callback = function() end,
    })
end

function Desktop:onClose()
    self._closed = true
    UIManager:close(self)
    if self.close_callback then self.close_callback() end
    return true
end

function Desktop:onCloseWidget()
    self._closed = true
end

return Desktop
