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

local SETTINGS_KEY = "book_plugin_v2"
local FILEMAP_KEY = "book_plugin_filemap_v2"
local START_WITH_ID = "bookshelf_book"

local BookPlugin = WidgetContainer:extend{
    name = "book",
    is_doc_only = false,
}

local function defaultSettings()
    return {
        base_url = "",
        token = "",
        auto_sync = true,
        open_on_start = true,
        home_header = "clock",
        ui_scale = 130,
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

local function ensureDir(path)
    if lfs.attributes(path, "mode") ~= "directory" then
        lfs.mkdir(path)
    end
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
            table.insert(item.sub_item_table, 1, {
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
                if row.text ~= _("Book 书库") and row.callback then
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
        return item
    end
end

function BookPlugin:init()
    local ok, err = pcall(function()
        applyStartWithOnce()
        self:onDispatcherRegisterActions()
        if self.ui.menu and self.ui.menu.registerToMainMenu then
            self.ui.menu:registerToMainMenu(self)
        end
        patchFileManager(self)
        patchStartWithMenu()
        if self.ui.file_chooser then
            requestDesktopOpen(self, self.ui)
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
        sorting_hint = "tools",
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

function BookPlugin:openBook(book)
    local filename = book.filename
    if not filename or filename == "" then
        UIManager:show(InfoMessage:new{ text = _("无效文件名") })
        return
    end
    local path = self:localPathFor(filename)
    local function doOpen()
        local map = G_reader_settings:readSetting(FILEMAP_KEY) or {}
        map[path] = filename
        G_reader_settings:saveSetting(FILEMAP_KEY, map)
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
        UIManager:show(InfoMessage:new{ text = _("正在下载…"), timeout = 1 })
        local ok, err = self:getApi():downloadBook(filename, path)
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
    local map = G_reader_settings:readSetting(FILEMAP_KEY) or {}
    return map[path] or path:match("([^/\\]+)$")
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
                text = T(_("已跳转到约 %1%%"), string.format("%.1f", pct * 100)),
                timeout = 2,
            })
        end
    end)
end

function BookPlugin:onReaderReady()
    if settings().auto_sync then
        self:pullCurrentProgress(false)
    end
end

function BookPlugin:onCloseDocument()
    if settings().auto_sync then
        self:pushCurrentProgress(false)
    end
end

function BookPlugin:onSuspend()
    if settings().auto_sync and self.ui.document then
        self:pushCurrentProgress(false)
    end
end

return BookPlugin
