--[[--
Book 书库插件：对接 PHP Book 管理端。

入口原则（别再藏了）：
1. FileManager 启动默认直接打开全屏书架
2. 标题栏「+」菜单第一项
3. 顶栏菜单 → 工具 →「Book 书库」（与云存储同级）
4. 长按 Home 也可打开

@module koplugin.book
--]]

local BD = require("ui/bidi")
local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local NetworkMgr = require("ui/network/manager")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template
local lfs = require("libs/libkoreader-lfs")

-- 用 dofile 相对路径，避免 package.path 时机问题导致整插件加载失败
local function loadSibling(name)
    local info = debug.getinfo(1, "S")
    local src = info and info.source or ""
    if src:sub(1, 1) == "@" then
        src = src:sub(2)
    end
    local dir = src:match("(.*/)")
    if not dir then
        return require(name)
    end
    local path = dir .. name .. ".lua"
    local ok, mod = pcall(dofile, path)
    if ok then
        return mod
    end
    -- 回退 require（PluginLoader 已把插件目录塞进 path）
    return require(name)
end

local Api = loadSibling("api")
local Bookshelf = loadSibling("bookshelf")

local BookPlugin = WidgetContainer:extend{
    name = "book",
    is_doc_only = false,
}

local SETTINGS_KEY = "book_plugin"

local function settings()
    local s = G_reader_settings:readSetting(SETTINGS_KEY)
    if type(s) ~= "table" then
        s = {
            base_url = "",
            token = "",
            auto_sync = true,
            open_on_start = true, -- 默认启动就进书架
            library_dir = DataStorage:getDataDir() .. "/books",
        }
        G_reader_settings:saveSetting(SETTINGS_KEY, s)
    end
    if s.open_on_start == nil then
        s.open_on_start = true
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

function BookPlugin:init()
    self:onDispatcherRegisterActions()
    if self.ui.menu and self.ui.menu.registerToMainMenu then
        self.ui.menu:registerToMainMenu(self)
    end

    -- 只在文件管理器里挂入口 / 自动打开
    if self.ui.file_chooser then
        self:_patchFileManager()
        UIManager:nextTick(function()
            if not self.ui or not self.ui.file_chooser then
                return
            end
            self:_patchTitleBar()
            if settings().open_on_start then
                self:openBookshelf()
            end
        end)
    end
end

function BookPlugin:_patchFileManager()
    if self._plus_patched or not self.ui.getPlusDialogButtons then
        return
    end
    self._plus_patched = true
    local plugin = self
    local orig = self.ui.getPlusDialogButtons
    self.ui.getPlusDialogButtons = function(fm)
        local title, buttons = orig(fm)
        table.insert(buttons, 1, {
            {
                text = _("Book 书库"),
                callback = function()
                    UIManager:close(fm.plus_dialog)
                    plugin:openBookshelf()
                end,
            },
        })
        return title, buttons
    end
end

function BookPlugin:_patchTitleBar()
    local tb = self.ui.title_bar
    if not tb or self._title_patched then
        return
    end
    self._title_patched = true
    local plugin = self
    -- 长按 Home → 书库（短按仍回家目录）
    local prev_hold = tb.left_icon_hold_callback
    tb.left_icon_hold_callback = function()
        plugin:openBookshelf()
    end
    if tb.left_button then
        tb.left_button.hold_callback = tb.left_icon_hold_callback
    end
    -- 保留原 hold 引用以免以后要还原
    self._prev_home_hold = prev_hold
end

function BookPlugin:onDispatcherRegisterActions()
    Dispatcher:registerAction("book_open_shelf", {
        category = "none",
        event = "BookOpenShelf",
        title = _("打开 Book 书架"),
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
    -- 与 cloudstorage 同级：工具页，一眼能看见
    menu_items.book_library = {
        text = _("Book 书库"),
        sorting_hint = "tools",
        callback = function()
            self:openBookshelf()
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
                text = _("自动同步进度"),
                checked_func = function()
                    return settings().auto_sync
                end,
                callback = function()
                    local cur = settings()
                    cur.auto_sync = not cur.auto_sync
                    saveSettings(cur)
                end,
            },
            {
                text = _("启动时打开书架"),
                checked_func = function()
                    return settings().open_on_start
                end,
                callback = function()
                    local cur = settings()
                    cur.open_on_start = not cur.open_on_start
                    saveSettings(cur)
                end,
            },
            {
                text = _("同步当前书进度"),
                enabled = self.ui.document ~= nil,
                callback = function()
                    self:pushCurrentProgress(true)
                end,
            },
            {
                text = _("拉取当前书进度"),
                enabled = self.ui.document ~= nil,
                callback = function()
                    self:pullCurrentProgress(true)
                end,
            },
            {
                text_func = function()
                    local s = settings()
                    local u = s.base_url ~= "" and s.base_url or _("未配置")
                    return T(_("当前: %1"), BD.wrap(u))
                end,
                enabled = false,
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
            {
                text = s.base_url,
                hint = _("https://book.example.com"),
            },
            {
                text = s.token,
                hint = _("bk_… 长期令牌"),
                text_type = "password",
            },
            {
                text = s.library_dir,
                hint = _("本地书库目录"),
            },
        },
        buttons = {
            {
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
                        -- 保存后直接进书架
                        self:openBookshelf()
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function BookPlugin:withNetwork(callback)
    NetworkMgr:runWhenOnline(function()
        callback()
    end)
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

--- 立刻弹出全屏书架（不先卡在 NetworkMgr）
function BookPlugin:openBookshelf(filter)
    local api = self:getApi()
    if not api:configured() then
        UIManager:show(InfoMessage:new{
            text = _("请先配置 Book 服务器地址和令牌"),
            timeout = 2,
        })
        self:showConfigDialog()
        return
    end

    if self.bookshelf then
        UIManager:close(self.bookshelf)
        self.bookshelf = nil
    end

    local ok, shelf_or_err = pcall(function()
        return Bookshelf:new{
            plugin = self,
            api = api,
            filter = filter or {},
            close_callback = function()
                self.bookshelf = nil
            end,
        }
    end)
    if not ok then
        logger.err("book bookshelf create failed", shelf_or_err)
        UIManager:show(InfoMessage:new{
            text = _("书架打开失败: ") .. tostring(shelf_or_err),
        })
        return
    end

    self.bookshelf = shelf_or_err
    UIManager:show(self.bookshelf)
end

function BookPlugin:localPathFor(filename)
    local s = settings()
    ensureDir(s.library_dir)
    local base = filename:match("([^/\\]+)$") or filename
    return s.library_dir .. "/" .. base
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
    if map[path] then
        return map[path]
    end
    return path:match("([^/\\]+)$")
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
