--[[--
Book 书库插件 — 三栏桌面（图书馆 / 主页 / 设置）
  - 展示数据全部来自 API
  - 本地目录仅作下载缓存与封面缓存
  - 点书先进详情，再决定阅读

@module koplugin.book
--]]

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local Dispatcher = require("dispatcher")
local DataStorage = require("datastorage")
local NetworkMgr = require("ui/network/manager")
local Event = require("ui/event")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template
local lfs = require("libs/libkoreader-lfs")

local Api = require("api")
local Desktop = require("desktop")
local ReaderFloatMenu = require("readermenu")
local Device = require("device")
local StatsSync = require("stats_sync")
local StatsDb = require("stats_db")

local SETTINGS_KEY = "book_plugin_v2"
local FILEMAP_KEY = "book_plugin_filemap_v2"
local METAMAP_KEY = "book_plugin_meta_v2"
local START_WITH_ID = "bookshelf_book"
-- 本地缓存超过该天数未打开则清理（首次进首页触发）
local LOCAL_BOOK_TTL = 90 * 24 * 60 * 60
-- 阅读页关书后由 FM 侧插件实例打开桌面（模块级，跨实例）
local pending_open_desktop = false

local BookPlugin = WidgetContainer:extend{
    name = "book",
    is_doc_only = false,
}

local function defaultSettings()
    return {
        base_url = "",
        token = "",
        auto_sync = true,
        auto_stats = true,
        open_on_start = true,
        home_header = "clock",
        ui_scale = 130,
        reader_float_menu = true, -- 注入阅读页中键悬浮菜单，默认开
        library_dir = DataStorage:getDataDir() .. "/books",
    }
end

local function settings()
    local s = G_reader_settings:readSetting(SETTINGS_KEY)
    local old = G_reader_settings:readSetting("book_plugin")
    if type(s) ~= "table" then
        s = defaultSettings()
        if type(old) == "table" then
            if old.base_url and old.base_url ~= "" then s.base_url = old.base_url end
            if old.token and old.token ~= "" then s.token = old.token end
            if old.library_dir and old.library_dir ~= "" then s.library_dir = old.library_dir end
            if old.ui_scale then s.ui_scale = old.ui_scale end
            if old.auto_sync ~= nil then s.auto_sync = old.auto_sync end
            if old.open_on_start ~= nil then s.open_on_start = old.open_on_start end
        end
        G_reader_settings:saveSetting(SETTINGS_KEY, s)
    elseif type(old) == "table" then
        -- v2 已存在但空：补一次旧配置
        local dirty = false
        if (not s.base_url or s.base_url == "") and old.base_url and old.base_url ~= "" then
            s.base_url = old.base_url
            dirty = true
        end
        if (not s.token or s.token == "") and old.token and old.token ~= "" then
            s.token = old.token
            dirty = true
        end
        if (not s.library_dir or s.library_dir == "") and old.library_dir and old.library_dir ~= "" then
            s.library_dir = old.library_dir
            dirty = true
        end
        if dirty then
            G_reader_settings:saveSetting(SETTINGS_KEY, s)
        end
    end
    if not s.library_dir or s.library_dir == "" then
        s.library_dir = DataStorage:getDataDir() .. "/books"
    end
    if s.home_header ~= "hitokoto" then
        s.home_header = s.home_header or "clock"
    end
    return s
end

local function saveSettings(s)
    G_reader_settings:saveSetting(SETTINGS_KEY, s)
end

local function readerFloatMenuEnabled()
    local s = settings()
    return s.reader_float_menu ~= false
end

local function ensureDir(path)
    if lfs.attributes(path, "mode") ~= "directory" then
        lfs.mkdir(path)
    end
end

local function readFileMap()
    local map = G_reader_settings:readSetting(FILEMAP_KEY)
    if type(map) ~= "table" then
        return {}
    end
    return map
end

local function writeFileMap(map)
    G_reader_settings:saveSetting(FILEMAP_KEY, map)
end

-- filemap 兼容：旧值是 filename 字符串；新值是 { filename, last_open }
local function fileMapGet(map, path)
    local v = map[path]
    if type(v) == "table" then
        return v.filename, tonumber(v.last_open)
    end
    if type(v) == "string" then
        return v, nil
    end
    return nil, nil
end

local function fileMapSet(map, path, filename, last_open)
    map[path] = {
        filename = filename,
        last_open = last_open or os.time(),
    }
end

local function readMetaMap()
    local map = G_reader_settings:readSetting(METAMAP_KEY)
    if type(map) ~= "table" then
        return {}
    end
    return map
end

local function writeMetaMap(map)
    G_reader_settings:saveSetting(METAMAP_KEY, map)
end

local function bookFilenameOf(book)
    if type(book) ~= "table" then
        return nil
    end
    local f = book.filename or book.fileName or book.file or book.path
    if type(f) ~= "string" or f == "" then
        return nil
    end
    return f:match("([^/\\]+)$") or f
end

--- 从 API 书籍对象抽出悬浮层/详情要用的字段（不存 KOReader 文档解析结果）
local function metaFromBook(book)
    if type(book) ~= "table" then
        return nil
    end
    local filename = bookFilenameOf(book)
    if not filename then
        return nil
    end
    local desc = book.description or book.intro or book.summary
    return {
        filename = filename,
        bookName = book.bookName or book.title,
        author = book.author,
        favorite = book.favorite,
        category = book.category,
        series = book.series,
        description = desc,
        progressPercent = book.progressPercent,
    }
end

-- 仅在用户开启时写入 start_with；关掉就尊重，不再每次强制改写
local function applyStartWithOnce()
    local s = settings()
    if s.open_on_start == false then
        return false
    end
    if G_reader_settings:readSetting("start_with") ~= START_WITH_ID then
        G_reader_settings:saveSetting("start_with", START_WITH_ID)
    end
    return true
end

local function isStartWithBook()
    local s = settings()
    if s.open_on_start == false then
        return false
    end
    return G_reader_settings:readSetting("start_with", "filemanager") == START_WITH_ID
end

local function openDesktopFromFileManager(fallback_plugin)
    -- Reader 关闭后 PluginLoader 会重建实例；优先拿当前存活的 book
    local ok_pl, PluginLoader = pcall(require, "pluginloader")
    if ok_pl and PluginLoader and PluginLoader.getPluginInstance then
        local book = PluginLoader:getPluginInstance("book")
        if book and book.openDesktop then
            book:openDesktop()
            return true
        end
    end
    local ok, FileManager = pcall(require, "apps/filemanager/filemanager")
    local fm = ok and FileManager and FileManager.instance
    local book = fm and fm.book
    if book and book.openDesktop then
        book:openDesktop()
        return true
    end
    if fm then
        for _, child in ipairs(fm) do
            if type(child) == "table" and child.name == "book" and child.openDesktop then
                child:openDesktop()
                return true
            end
        end
    end
    if fallback_plugin and fallback_plugin.openDesktop and fallback_plugin.ui
        and fallback_plugin.ui.file_chooser then
        fallback_plugin:openDesktop()
        return true
    end
    return false
end

local function wrapFmOnShow(plugin, fm)
    if not fm or fm._book_onshow_wrapped then
        return
    end
    fm._book_onshow_wrapped = true
    local orig_onShow = fm.onShow
    fm.onShow = function(this)
        if orig_onShow then
            orig_onShow(this)
        end
        if this._book_autoopen_pending then
            this._book_autoopen_pending = nil
            UIManager:scheduleIn(0, function()
                if plugin and plugin.openDesktop and not plugin.desktop then
                    plugin:openDesktop()
                end
            end)
        end
        if pending_open_desktop then
            pending_open_desktop = false
            UIManager:scheduleIn(0, function()
                if not openDesktopFromFileManager(plugin) then
                    logger.warn("book pending desktop open failed")
                end
            end)
        end
    end
end

local function requestDesktopOpen(plugin, fm)
    if not isStartWithBook() then
        return
    end
    if fm then
        fm._book_autoopen_pending = true
        wrapFmOnShow(plugin, fm)
    end
    UIManager:scheduleIn(0.25, function()
        if plugin and plugin.openDesktop and not plugin.desktop then
            local ok, FileManager = pcall(require, "apps/filemanager/filemanager")
            local live = ok and FileManager and FileManager.instance
            if (plugin.ui and plugin.ui.file_chooser) or live then
                plugin:openDesktop()
            end
        end
    end)
end

local function patchFileManager(plugin)
    local ok, FileManager = pcall(require, "apps/filemanager/filemanager")
    if not ok or not FileManager then
        return
    end

    if not FileManager._book_plugin_patched then
        FileManager._book_plugin_patched = true

        local orig_setup = FileManager.setupLayout
        FileManager.setupLayout = function(fm_self)
            orig_setup(fm_self)
            wrapFmOnShow(plugin, fm_self)
            if not FileManager._book_boot_done then
                FileManager._book_boot_done = true
                if isStartWithBook() then
                    fm_self._book_autoopen_pending = true
                end
            end
        end

        if FileManager.getPlusDialogButtons and not FileManager._book_plus_patched then
            FileManager._book_plus_patched = true
            local orig_plus = FileManager.getPlusDialogButtons
            FileManager.getPlusDialogButtons = function(fm)
                local title, buttons = orig_plus(fm)
                table.insert(buttons, 1, {{
                    text = _("Book 桌面"),
                    callback = function()
                        UIManager:close(fm.plus_dialog)
                        plugin:openDesktop()
                    end,
                }})
                return title, buttons
            end
        end
    end

    if FileManager.instance then
        wrapFmOnShow(plugin, FileManager.instance)
        requestDesktopOpen(plugin, FileManager.instance)
    end
end

local function patchStartWithMenu()
    local ok, FMMenu = pcall(require, "apps/filemanager/filemanagermenu")
    if not ok or not FMMenu or not FMMenu.getStartWithMenuTable then
        return
    end
    if FMMenu._book_startwith_patched then
        return
    end
    FMMenu._book_startwith_patched = true
    local orig = FMMenu.getStartWithMenuTable
    FMMenu.getStartWithMenuTable = function(self)
        local item = orig(self)
        if item and item.sub_item_table then
            -- 避免重复插入
            local already = false
            for _, row in ipairs(item.sub_item_table) do
                if row._book_startwith_item then
                    already = true
                    break
                end
            end
            if not already then
                table.insert(item.sub_item_table, 1, {
                    _book_startwith_item = true,
                    text = _("Book 书库"),
                    checked_func = function()
                        return G_reader_settings:readSetting("start_with") == START_WITH_ID
                    end,
                    callback = function()
                        G_reader_settings:saveSetting("start_with", START_WITH_ID)
                        local s = settings()
                        s.open_on_start = true
                        saveSettings(s)
                    end,
                    radio = true,
                })
                for _, row in ipairs(item.sub_item_table) do
                    if not row._book_startwith_item and row.callback and not row._book_startwith_wrapped then
                        row._book_startwith_wrapped = true
                        local prev = row.callback
                        row.callback = function(...)
                            local s = settings()
                            s.open_on_start = false
                            saveSettings(s)
                            return prev(...)
                        end
                    end
                end
            end
        end
        return item
    end
end

-- 把 Book 菜单项钉在「设置」顶部；只改 order 表，不碰 MenuSorter 本体
local MENU_ITEM_ID = "book_library"
local function pinBookInSettingsMenu()
    for _, modname in ipairs({
        "ui/elements/filemanager_menu_order",
        "ui/elements/reader_menu_order",
    }) do
        local ok, order = pcall(require, modname)
        if ok and type(order) == "table" and type(order.setting) == "table" then
            for i = #order.setting, 1, -1 do
                if order.setting[i] == MENU_ITEM_ID then
                    table.remove(order.setting, i)
                end
            end
            table.insert(order.setting, 1, MENU_ITEM_ID)
        end
    end
end

function BookPlugin:init()
    local ok, err = pcall(function()
        applyStartWithOnce()
        self:onDispatcherRegisterActions()
        pinBookInSettingsMenu()
        if self.ui.menu and self.ui.menu.registerToMainMenu then
            self.ui.menu:registerToMainMenu(self)
        end
        patchFileManager(self)
        patchStartWithMenu()
        if self.ui.file_chooser then
            requestDesktopOpen(self, self.ui)
        end
        if pending_open_desktop and self.ui.file_chooser then
            pending_open_desktop = false
            UIManager:scheduleIn(0.2, function()
                if self and self.openDesktop and not self.desktop then
                    self:openDesktop()
                end
            end)
        end
    end)
    if not ok then
        logger.err("book plugin init failed:", err)
    end
end

function BookPlugin:onDispatcherRegisterActions()
    Dispatcher:registerAction("book_open_shelf", {
        category = "none",
        event = "BookOpenShelf",
        title = _("打开 Book 桌面"),
        general = true,
        filemanager = true,
    })
end

function BookPlugin:onBookOpenShelf()
    self:openDesktop()
    return true
end

function BookPlugin:getApi()
    local s = settings()
    return Api:new{
        base_url = s.base_url,
        token = s.token,
    }
end

function BookPlugin:coverCacheDir()
    local dir = settings().library_dir .. "/.covers"
    ensureDir(settings().library_dir)
    ensureDir(dir)
    return dir
end

function BookPlugin:addToMainMenu(menu_items)
    menu_items.book_library = {
        text = _("Book 桌面"),
        -- order 表已置顶；sorting_hint 仅作 order 未命中时的兜底
        sorting_hint = "setting",
        callback = function()
            self:openDesktop()
        end,
    }
end

function BookPlugin:showConfigDialog()
    local s = settings()
    local dialog
    dialog = MultiInputDialog:new{
        title = _("Book 服务器配置"),
        fields = {
            { text = s.base_url or "", hint = _("https://book.example.com") },
            { text = s.token or "", hint = _("bk_… 长期令牌"), text_type = "password" },
            { text = s.library_dir or "", hint = _("本地下载缓存目录") },
        },
        buttons = {{
            {
                text = _("取消"),
                id = "close",
                callback = function()
                    UIManager:close(dialog)
                end,
            },
            {
                text = _("保存"),
                callback = function()
                    local fields = dialog:getFields()
                    s.base_url = (fields[1] or ""):gsub("%s+", "")
                    s.token = (fields[2] or ""):gsub("%s+", "")
                    s.library_dir = (fields[3] or ""):gsub("%s+$", "")
                    if s.library_dir == "" then
                        s.library_dir = DataStorage:getDataDir() .. "/books"
                    end
                    saveSettings(s)
                    UIManager:close(dialog)
                    UIManager:show(InfoMessage:new{ text = _("已保存"), timeout = 2 })
                    if self.desktop then
                        self.desktop.api = self:getApi()
                        self.desktop._home_state = nil
                        self.desktop._home_loaded = false
                        self.desktop._library_state = nil
                        self.desktop:rebuild()
                    end
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function BookPlugin:withNetwork(callback)
    NetworkMgr:runWhenOnline(callback)
end

function BookPlugin:testConnection()
    self:withNetwork(function()
        local res, err = self:getApi():ping()
        if not res then
            UIManager:show(InfoMessage:new{ text = err or _("连接失败") })
            return
        end
        local name = res.data and (res.data.display_name or res.data.username) or "?"
        UIManager:show(InfoMessage:new{
            text = T(_("连接成功：%1"), name),
            timeout = 3,
        })
    end)
end

function BookPlugin:openBookshelf(filter)
    self:openDesktop(filter)
end

function BookPlugin:openDesktop(filter)
    local api = self:getApi()
    if self.desktop then
        UIManager:close(self.desktop)
        self.desktop = nil
    end

    local ok, desk = pcall(function()
        return Desktop:new{
            plugin = self,
            api = api,
            filter = filter or {},
            tab = "home",
            covers_fullscreen = true,
            close_callback = function()
                self.desktop = nil
            end,
        }
    end)
    if not ok then
        logger.err("book desktop create failed:", desk)
        UIManager:show(InfoMessage:new{
            text = _("桌面打开失败:\n") .. tostring(desk),
        })
        return
    end
    self.desktop = desk
    UIManager:show(self.desktop)
    UIManager:setDirty(self.desktop, "full")
end

function BookPlugin:localPathFor(filename)
    local s = settings()
    ensureDir(s.library_dir)
    return s.library_dir .. "/" .. (filename:match("([^/\\]+)$") or filename)
end

--- 记录本地书最近打开时间（供过期清理）
function BookPlugin:touchLocalBook(path, filename)
    if not path or path == "" or not filename or filename == "" then
        return
    end
    local map = readFileMap()
    fileMapSet(map, path, filename, os.time())
    writeFileMap(map)
    -- 统计上报用：md5 -> 远端 filename
    StatsDb.rememberPathFilename(path, filename)
end

--- 清理长期未打开的本地下载缓存；返回删除文件数
function BookPlugin:cleanupStaleLocalBooks()
    local s = settings()
    local dir = s.library_dir
    if not dir or dir == "" then
        return 0
    end
    if lfs.attributes(dir, "mode") ~= "directory" then
        return 0
    end

    local now = os.time()
    local map = readFileMap()
    local removed = 0
    local dirty = false

    local function lastOpenOf(path, mapped_last)
        if mapped_last and mapped_last > 0 then
            return mapped_last
        end
        local attr = lfs.attributes(path)
        if not attr then
            return 0
        end
        return tonumber(attr.access) or tonumber(attr.modification) or 0
    end

    local function removeCover(filename)
        if not filename or filename == "" then
            return
        end
        local ok, Cover = pcall(require, "cover")
        if not ok or not Cover then
            return
        end
        local cached = Cover.cachedPath(self, filename)
        if cached then
            pcall(os.remove, cached)
        end
        local base = Cover.pathFor(self, filename)
        for _, ext in ipairs({ ".jpg", ".jpeg", ".png", ".webp", ".gif", "", ".part" }) do
            pcall(os.remove, base .. ext)
        end
    end

    for name in lfs.dir(dir) do
        if name ~= "." and name ~= ".." and name ~= ".covers" then
            local path = dir .. "/" .. name
            if lfs.attributes(path, "mode") == "file" then
                local filename, last_open = fileMapGet(map, path)
                filename = filename or name
                local t = lastOpenOf(path, last_open)
                if t > 0 and (now - t) >= LOCAL_BOOK_TTL then
                    local ok = pcall(os.remove, path)
                    if ok and lfs.attributes(path, "mode") ~= "file" then
                        removed = removed + 1
                        if map[path] ~= nil then
                            map[path] = nil
                            dirty = true
                        end
                        removeCover(filename)
                        logger.info("book cleaned stale local", path)
                    end
                end
            end
        end
    end

    for path, _ in pairs(map) do
        if lfs.attributes(path, "mode") ~= "file" then
            map[path] = nil
            dirty = true
        end
    end
    if dirty then
        writeFileMap(map)
    end
    return removed
end

--- 手动清空插件下载的书籍与封面缓存；返回 books, covers
function BookPlugin:clearLocalCache()
    local s = settings()
    local dir = s.library_dir
    local books, covers = 0, 0
    if not dir or dir == "" or dir == "/" then
        return books, covers
    end
    if lfs.attributes(dir, "mode") ~= "directory" then
        return books, covers
    end

    local ok_cover, Cover = pcall(require, "cover")
    if ok_cover and Cover and Cover.abortPending then
        Cover.abortPending()
    end

    for name in lfs.dir(dir) do
        if name ~= "." and name ~= ".." and name ~= ".covers" then
            local path = dir .. "/" .. name
            if lfs.attributes(path, "mode") == "file" then
                local ok = pcall(os.remove, path)
                if ok and lfs.attributes(path, "mode") ~= "file" then
                    books = books + 1
                end
            end
        end
    end

    local cover_dir = dir .. "/.covers"
    if lfs.attributes(cover_dir, "mode") == "directory" then
        for name in lfs.dir(cover_dir) do
            if name ~= "." and name ~= ".." then
                local path = cover_dir .. "/" .. name
                if lfs.attributes(path, "mode") == "file" then
                    local ok = pcall(os.remove, path)
                    if ok and lfs.attributes(path, "mode") ~= "file" then
                        covers = covers + 1
                    end
                end
            end
        end
    end

    writeFileMap({})
    writeMetaMap({})
    logger.info("book cache cleared", books, covers)
    return books, covers
end

--- 缓存 API 书籍元数据（按 filename）；打开书 / 列表刷新时写入
function BookPlugin:rememberBookMeta(book)
    local meta = metaFromBook(book)
    if not meta then
        return
    end
    local map = readMetaMap()
    map[meta.filename] = meta
    writeMetaMap(map)
end

function BookPlugin:rememberBooksMeta(books)
    if type(books) ~= "table" then
        return
    end
    local map = readMetaMap()
    local dirty = false
    for _, book in ipairs(books) do
        local meta = metaFromBook(book)
        if meta then
            map[meta.filename] = meta
            dirty = true
        end
    end
    if dirty then
        writeMetaMap(map)
    end
end

--- 当前阅读书 / 指定 filename 的 API 元数据缓存；没有就返回空表
function BookPlugin:getCachedBookMeta(filename)
    filename = filename or self:remoteFilenameForCurrent()
    if type(filename) ~= "string" or filename == "" then
        return {}
    end
    filename = filename:match("([^/\\]+)$") or filename
    local map = readMetaMap()
    local meta = map[filename]
    if type(meta) == "table" then
        return meta
    end
    return { filename = filename }
end

--- 按 filename（完整路径或 basename）查找已缓存元数据；未缓存返回 nil
function BookPlugin:findCachedBookMeta(filename)
    if type(filename) ~= "string" or filename == "" then
        return nil
    end
    local map = readMetaMap()
    local meta = map[filename]
    if type(meta) ~= "table" then
        local base = filename:match("([^/\\]+)$") or filename
        meta = map[base]
    end
    if type(meta) ~= "table" then
        return nil
    end
    -- 至少要有书名，才算能进详情的有效缓存（避免空壳 {filename}）
    if meta.bookName or meta.title then
        return meta
    end
    return nil
end

function BookPlugin:openBook(book)
    local filename = book.filename
    if not filename or filename == "" then
        UIManager:show(InfoMessage:new{ text = _("无效文件名") })
        return
    end
    self:rememberBookMeta(book)
    local path = self:localPathFor(filename)
    local function doOpen()
        self:touchLocalBook(path, filename)
        if self.desktop then
            if self.desktop.detail then
                UIManager:close(self.desktop.detail)
                self.desktop.detail = nil
            end
            UIManager:close(self.desktop)
            self.desktop = nil
        end
        local ReaderUI = require("apps/reader/readerui")
        UIManager:nextTick(function()
            ReaderUI:showReader(path)
        end)
    end
    if lfs.attributes(path, "mode") == "file" then
        doOpen()
        return
    end
    self:withNetwork(function()
        local api = self:getApi()
        local title = book.bookName or book.title
            or (filename:match("([^/\\]+)$") or filename)
        local size = tonumber(book.fileSize or book.filesize or book.size or book.file_size)
        if not size or size <= 0 then
            size = api:probeFileSize(filename)
        end

        local dialog
        local ok_dlg, ProgressbarDialog = pcall(require, "ui/widget/progressbardialog")
        if ok_dlg and ProgressbarDialog then
            dialog = ProgressbarDialog:new{
                title = _("正在下载…"),
                subtitle = title,
                progress_max = (size and size > 0) and size or nil,
                refresh_time_seconds = 1,
                dismissable = false,
            }
            dialog:show()
        else
            UIManager:show(InfoMessage:new{ text = _("正在下载…") })
        end

        local ok, err = api:downloadBook(filename, path, dialog and function(bytes)
            dialog:reportProgress(bytes)
        end or nil)

        if dialog then
            dialog:close()
        end
        if not ok then
            UIManager:show(InfoMessage:new{ text = err or _("下载失败") })
            return
        end
        doOpen()
    end)
end

function BookPlugin:remoteFilenameForCurrent()
    if not self.ui.document or not self.ui.document.file then
        return nil
    end
    local path = self.ui.document.file
    local map = readFileMap()
    local filename = fileMapGet(map, path)
    return filename or path:match("([^/\\]+)$")
end

function BookPlugin:currentFraction()
    if not self.ui.document then
        return 0
    end
    local doc = self.ui.document
    if doc.getXPointer and doc.getProportionFromXPointer then
        local ok, p = pcall(function()
            return doc:getProportionFromXPointer(doc:getXPointer())
        end)
        if ok and type(p) == "number" then
            return math.max(0, math.min(1, p))
        end
    end
    if self.ui.getCurrentPage and doc.getPageCount then
        local page = self.ui:getCurrentPage() or 1
        local total = doc:getPageCount() or 1
        if total > 0 then
            return math.max(0, math.min(1, page / total))
        end
    end
    return 0
end

function BookPlugin:pushCurrentProgress(show_msg)
    local filename = self:remoteFilenameForCurrent()
    if not filename then
        return
    end
    local frac = self:currentFraction()
    self:withNetwork(function()
        local res, err = self:getApi():updateProgress(filename, frac, 0, 0)
        if show_msg then
            UIManager:show(InfoMessage:new{
                text = res and _("进度已上传") or (err or _("上传失败")),
                timeout = 2,
            })
        elseif not res then
            logger.warn("book push progress failed", err)
        end
    end)
end

--- 上报 KOReader 阅读统计（page_stat）到 /index/stats/import
--- 自动/手动均后台分步执行；手动显示 ProgressbarDialog
function BookPlugin:pushReadingStats(show_msg, force)
    if settings().auto_stats == false and not force then
        return
    end
    if StatsSync.isBusy() then
        if show_msg then
            UIManager:show(InfoMessage:new{
                text = _("阅读统计正在上报…"),
                timeout = 2,
            })
        end
        return
    end

    self:withNetwork(function()
        -- 联网成功后再弹进度条，避免取消 Wi-Fi 后对话框挂死
        local dialog
        if show_msg then
            local ok_dlg, ProgressbarDialog = pcall(require, "ui/widget/progressbardialog")
            if ok_dlg and ProgressbarDialog then
                dialog = ProgressbarDialog:new{
                    title = _("正在上报阅读统计…"),
                    subtitle = _("读取本地统计并上传"),
                    progress_max = StatsSync.progressMax(),
                    refresh_time_seconds = 0.05,
                    dismissable = false,
                }
                dialog:show()
            else
                UIManager:show(InfoMessage:new{
                    text = _("正在上报阅读统计…"),
                    timeout = 1,
                })
            end
        end

        StatsSync.pushAsync(self:getApi(), {
            force = force,
            on_progress = function(step)
                if dialog then
                    dialog:reportProgress(step)
                end
            end,
            on_done = function(ok, err)
                if dialog then
                    if ok and err ~= "throttled" then
                        dialog:reportProgress(StatsSync.progressMax())
                    end
                    dialog:close()
                    dialog = nil
                end
                if show_msg then
                    local text
                    if ok and err == "throttled" then
                        text = _("统计上报已节流，稍后再试")
                    elseif ok then
                        text = _("阅读统计已上传")
                    elseif err == "busy" then
                        text = _("阅读统计正在上报…")
                    else
                        text = err or _("统计上传失败")
                    end
                    UIManager:show(InfoMessage:new{ text = text, timeout = 2 })
                elseif not ok and err ~= "throttled" and err ~= "busy" then
                    logger.warn("book push reading stats failed", err)
                end
            end,
        })
    end)
end

function BookPlugin:pullCurrentProgress(show_msg)
    local filename = self:remoteFilenameForCurrent()
    if not filename then
        return
    end
    self:withNetwork(function()
        local res, err = self:getApi():getProgress(filename)
        if not res then
            if show_msg then
                UIManager:show(InfoMessage:new{ text = err or _("拉取失败") })
            end
            return
        end
        local pct = res.data
        if type(pct) ~= "number" then
            if show_msg then
                UIManager:show(InfoMessage:new{ text = _("远端无进度"), timeout = 2 })
            end
            return
        end
        if pct > 1 then
            pct = pct / 100
        end
        if self.ui.document and self.ui.document.getXPointerFromProportion then
            local xptr = self.ui.document:getXPointerFromProportion(pct)
            if xptr and self.ui.rolling then
                self.ui.rolling:onGotoXPointer(xptr)
            elseif xptr and self.ui.link then
                self.ui.link:onGotoXPointer(xptr)
            end
        elseif self.ui.document and self.ui.document.getPageCount then
            local total = self.ui.document:getPageCount() or 1
            local page = math.max(1, math.min(total, math.floor(pct * total + 0.5)))
            self.ui:handleEvent(Event:new("GotoPage", page))
        end
        if show_msg then
            UIManager:show(InfoMessage:new{
                text = T(_("已跳转到约 %1%"), string.format("%.1f", pct * 100)),
                timeout = 2,
            })
        end
    end)
end

function BookPlugin:closeReaderFloatMenu()
    if self._reader_float_menu then
        pcall(function()
            self._reader_float_menu._closed = true
            UIManager:close(self._reader_float_menu)
        end)
        self._reader_float_menu = nil
    end
end

--- 阅读中部点击：打开 Book 悬浮菜单（覆盖左右翻页区中部）
function BookPlugin:registerReaderFloatMenuZones()
    if not self.ui or not self.ui.registerTouchZones then
        return
    end
    if not Device:isTouchDevice() then
        return
    end
    if not readerFloatMenuEnabled() then
        return
    end
    -- 中部：宽 50% × 高 50%，避开顶部系统菜单与底部字体条
    self.ui:registerTouchZones({
        {
            id = "book_reader_float_menu_tap",
            ges = "tap",
            screen_zone = {
                ratio_x = 1 / 4,
                ratio_y = 1 / 4,
                ratio_w = 1 / 2,
                ratio_h = 1 / 2,
            },
            overrides = {
                "tap_forward",
                "tap_backward",
            },
            handler = function()
                return self:onTapBookReaderFloatMenu()
            end,
        },
    })
end

function BookPlugin:onTapBookReaderFloatMenu()
    if not readerFloatMenuEnabled() then
        return false
    end
    if self._reader_float_menu and not self._reader_float_menu._closed then
        return true
    end
    local plugin = self
    local ok, menu = pcall(function()
        return ReaderFloatMenu:new{
            plugin = plugin,
            covers_fullscreen = false,
            close_callback = function()
                plugin._reader_float_menu = nil
            end,
        }
    end)
    if not ok then
        logger.err("book reader float menu failed:", menu)
        return true
    end
    self._reader_float_menu = menu
    UIManager:show(menu)
    -- 下层阅读页 + 面板；优先刷面板区域
    if menu._panel_dimen then
        UIManager:setDirty("all", "ui", menu._panel_dimen)
        UIManager:setDirty("all", "ui")
    else
        UIManager:setDirty("all", "ui")
    end
    return true
end

--- 退出阅读并打开 Book 桌面（主页按钮）
--- 路径对齐 KOReader：onClose → showFileManager → 再 openDesktop
--- 只 onClose 会留下空栈（打开书时 FM/桌面已被关掉），看起来像“直接退出”
function BookPlugin:exitReadingToDesktop()
    self:closeReaderFloatMenu()
    local ui = self.ui
    if not (ui and ui.document) then
        if not openDesktopFromFileManager(self) then
            logger.warn("book exitReadingToDesktop: not in reader and no desktop host")
        end
        return
    end
    local file = ui.document.file
    pending_open_desktop = true
    local ok_fm, FileManager = pcall(require, "apps/filemanager/filemanager")
    if ok_fm and FileManager and FileManager.instance then
        wrapFmOnShow(self, FileManager.instance)
    end
    UIManager:nextTick(function()
        if ui.onClose then
            -- false：避免关书时强制全刷，随后我们自己刷桌面
            ui:onClose(false)
        end
        if ui.showFileManager then
            pcall(function()
                ui:showFileManager(file)
            end)
        end
        -- showFileManager 会重建 FM + 插件；下一拍再开桌面
        UIManager:nextTick(function()
            if not pending_open_desktop then
                return
            end
            pending_open_desktop = false
            if not openDesktopFromFileManager(nil) then
                logger.warn("book exitReadingToDesktop: desktop not opened")
            end
        end)
    end)
end

function BookPlugin:onReaderReady()
    self:registerReaderFloatMenuZones()
    if settings().auto_sync then
        self:pullCurrentProgress(false)
    end
    if settings().auto_stats ~= false then
        self:withNetwork(function()
            StatsSync.registerDevice(self:getApi())
        end)
    end
end

function BookPlugin:onSetDimensions()
    -- 旋转/改分辨率后重挂中部热区
    self:registerReaderFloatMenuZones()
end

function BookPlugin:onCloseDocument()
    self:closeReaderFloatMenu()
    if settings().auto_sync then
        self:pushCurrentProgress(false)
    end
    if settings().auto_stats ~= false then
        self:pushReadingStats(false, false)
    end
end

function BookPlugin:onSuspend()
    if settings().auto_sync and self.ui.document then
        self:pushCurrentProgress(false)
    end
    if settings().auto_stats ~= false and self.ui.document then
        self:pushReadingStats(false, false)
    end
end

return BookPlugin
