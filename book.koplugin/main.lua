--[[--
Book 书库 — 参考 simpleui.koplugin 的生命周期：
  - init 全程 pcall
  - 启动打开桌面（首页时钟+最近阅读，底栏：首页/书库/分类/设置）
  - patch FileManager + 注入 start_with = "bookshelf_book"

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

local SETTINGS_KEY = "book_plugin"
local START_WITH_ID = "bookshelf_book"

local BookPlugin = WidgetContainer:extend{
    name = "book",
    is_doc_only = false,
}

-- ---------------------------------------------------------------------------
-- settings
-- ---------------------------------------------------------------------------

local function settings()
    local s = G_reader_settings:readSetting(SETTINGS_KEY)
    if type(s) ~= "table" then
        s = {
            base_url = "",
            token = "",
            auto_sync = true,
            open_on_start = true,
            library_dir = DataStorage:getDataDir() .. "/books",
            _ui_v = 4,
        }
        G_reader_settings:saveSetting(SETTINGS_KEY, s)
    elseif (s._ui_v or 0) < 4 then
        s.open_on_start = true
        s._ui_v = 4
        G_reader_settings:saveSetting(SETTINGS_KEY, s)
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

-- 启动直进插件：open_on_start 默认开，且强制写 start_with（对齐 SimpleUI first-run）
local function forceStartWithBook()
    local s = settings()
    if s.open_on_start == false then
        return false
    end
    G_reader_settings:saveSetting("start_with", START_WITH_ID)
    s.open_on_start = true
    saveSettings(s)
    return true
end

local function isStartWithBook()
    if settings().open_on_start == false then
        return false
    end
    return G_reader_settings:readSetting("start_with", "filemanager") == START_WITH_ID
        or settings().open_on_start
end

-- ---------------------------------------------------------------------------
-- FileManager patch（对齐 simpleui：setupLayout 打标，onShow 再打开）
-- ---------------------------------------------------------------------------

local function patchFileManager(plugin)
    local ok, FileManager = pcall(require, "apps/filemanager/filemanager")
    if not ok or not FileManager then
        return
    end
    if FileManager._book_plugin_patched then
        return
    end
    FileManager._book_plugin_patched = true

    local orig_setup = FileManager.setupLayout
    FileManager.setupLayout = function(fm_self)
        orig_setup(fm_self)
        if not FileManager._book_boot_done then
            FileManager._book_boot_done = true
            if isStartWithBook() then
                fm_self._book_autoopen_pending = true
            end
        end

        local orig_onShow = fm_self.onShow
        if not fm_self._book_onshow_wrapped then
            fm_self._book_onshow_wrapped = true
            fm_self.onShow = function(this)
                if orig_onShow then
                    orig_onShow(this)
                end
                if this._book_autoopen_pending then
                    this._book_autoopen_pending = nil
                    UIManager:scheduleIn(0.15, function()
                        local inst = plugin
                        if inst and inst.openDesktop then
                            inst:openDesktop()
                        end
                    end)
                end
            end
        end
    end

    -- 「+」菜单首项
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

local function patchStartWithMenu()
    -- 往「启动时打开」里塞一项（simpleui 同思路）
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
            -- 选其它启动项时关掉我们的 open_on_start
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

-- ---------------------------------------------------------------------------
-- lifecycle
-- ---------------------------------------------------------------------------

function BookPlugin:init()
    local ok, err = pcall(function()
        -- 必须在 patch 之前写入 start_with，否则 setupLayout 读到旧值，桌面永远不自动开
        forceStartWithBook()

        self:onDispatcherRegisterActions()
        if self.ui.menu and self.ui.menu.registerToMainMenu then
            self.ui.menu:registerToMainMenu(self)
        end

        if self.ui.file_chooser then
            patchFileManager(self)
            patchStartWithMenu()
            -- 双保险：若 onShow 已过，延迟再开一次
            if isStartWithBook() then
                UIManager:scheduleIn(0.4, function()
                    if not self.desktop and self.ui and self.ui.file_chooser then
                        self:openDesktop()
                    end
                end)
            end
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
    self:openBookshelf()
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
    menu_items.book_library_settings = {
        text = _("Book 书库设置"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("服务器与令牌"),
                callback = function()
                    self:showConfigDialog()
                end,
            },
            {
                text = _("测试连接"),
                callback = function()
                    self:testConnection()
                end,
            },
            {
                text = _("启动时打开桌面"),
                checked_func = function()
                    return settings().open_on_start
                        or G_reader_settings:readSetting("start_with") == START_WITH_ID
                end,
                callback = function()
                    local s = settings()
                    s.open_on_start = not s.open_on_start
                    saveSettings(s)
                    if s.open_on_start then
                        G_reader_settings:saveSetting("start_with", START_WITH_ID)
                    elseif G_reader_settings:readSetting("start_with") == START_WITH_ID then
                        G_reader_settings:saveSetting("start_with", "filemanager")
                    end
                end,
            },
            {
                text = _("自动同步进度"),
                checked_func = function()
                    return settings().auto_sync
                end,
                callback = function()
                    local s = settings()
                    s.auto_sync = not s.auto_sync
                    saveSettings(s)
                end,
            },
        },
    }
end

function BookPlugin:showConfigDialog()
    local s = settings()
    local dialog
    dialog = MultiInputDialog:new{
        title = _("Book 服务器配置"),
        fields = {
            { text = s.base_url, hint = _("https://book.example.com") },
            { text = s.token, hint = _("bk_… 长期令牌"), text_type = "password" },
            { text = s.library_dir, hint = _("本地书库目录") },
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
                    self:openBookshelf()
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
    -- 未配置也可以进桌面（设置页可配）；书库页会提示
    if self.desktop then
        UIManager:close(self.desktop)
        self.desktop = nil
    end
    if self.bookshelf then
        UIManager:close(self.bookshelf)
        self.bookshelf = nil
    end

    local ok, desk = pcall(function()
        return Desktop:new{
            plugin = self,
            api = api,
            filter = filter or {},
            tab = "home",
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
        local map = G_reader_settings:readSetting("book_plugin_filemap") or {}
        map[path] = filename
        G_reader_settings:saveSetting("book_plugin_filemap", map)
        if self.desktop then
            UIManager:close(self.desktop)
            self.desktop = nil
        end
        if self.bookshelf then
            UIManager:close(self.bookshelf)
            self.bookshelf = nil
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
    local map = G_reader_settings:readSetting("book_plugin_filemap") or {}
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
