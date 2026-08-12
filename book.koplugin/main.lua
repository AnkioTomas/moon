--[[--
Book 书库插件入口。

职责：
  - 打开 / 关闭 Book 桌面
  - 下载并打开书（点书先进详情，再决定阅读）
  - 阅读页中部热区与悬浮菜单
  - 关书 / 休眠时同步进度、上报统计

不放这里：
  - 本地缓存、filemap/metamap → moon.cache
  - FileManager / start_with / 菜单置顶 → moon.host
  - 进度推拉 → moon.progress

KOReader 会为 FileManager 和 Reader 各建一个插件实例；关书后 FM 侧实例才是开桌面的宿主。

@module koplugin.book
--]]

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local Dispatcher = require("dispatcher")
local NetworkMgr = require("ui/network/manager")
local logger = require("logger")
require("l10n")
local _ = require("gettext")
local lfs = require("libs/libkoreader-lfs")

local SourceRegistry = require("source.registry")
local Desktop = require("ui.desktop")
local ReaderFloatMenu = require("ui.readermenu")
local Device = require("device")
local StatsSync = require("stats_sync")
local MoonSettings = require("moon.settings")
local Cache = require("moon.cache")
local Host = require("moon.host")
local Progress = require("moon.progress")

local BookPlugin = WidgetContainer:extend{
    name = "book",
    is_doc_only = false, -- FileManager 与 Reader 都要加载
}

-- 默认开；设置里关掉才是 false
local function readerFloatMenuEnabled()
    return MoonSettings.get().reader_float_menu ~= false
end

--- FileManager / Reader 各会调一次。宿主钩子见 moon.host。
function BookPlugin:init()
    -- pcall：宿主补丁失败不能把整个插件弄死
    local ok, err = pcall(function()
        Host.applyStartWith()
        self:onDispatcherRegisterActions()
        if self.ui.menu and self.ui.menu.registerToMainMenu then
            self.ui.menu:registerToMainMenu(self)
        end
        Host.install(self)
    end)
    if not ok then
        logger.err("book plugin init failed:", err)
    end
end

--- 手势/快捷动作：打开 Book 桌面
function BookPlugin:onDispatcherRegisterActions()
    Dispatcher:registerAction("book_open_shelf", {
        category = "none",
        event = "BookOpenShelf",
        title = _("打开 Book 桌面"),
        general = true,
        filemanager = true,
    })
end

--- Dispatcher 回调：打开桌面
function BookPlugin:onBookOpenShelf()
    self:openDesktop()
    return true
end

--- 当前活跃数据源（同时只激活一个）
function BookPlugin:getSource()
    return SourceRegistry.getActive()
end

--- 切换数据源后丢掉桌面缓存；书城不可用则退回首页
function BookPlugin:onSourceChanged()
    SourceRegistry.invalidate()
    local source = self:getSource()
    if source and source.clearCaches then
        source:clearCaches()
    end
    if self.desktop then
        self.desktop.source = source
        self.desktop.api = source -- 过渡期：部分 UI 仍读 api
        self.desktop._home_state = nil
        self.desktop._home_loaded = false
        self.desktop._library_state = nil
        self.desktop._store_state = nil
        self.desktop._insight_state = nil
        self.desktop._insight_loaded = false
        local caps = source:capabilities() or {}
        if self.desktop.tab == "store" and not caps.store then
            self.desktop.tab = "home"
        end
        self.desktop:rebuild()
    end
end

--- KOReader 主菜单项（设置里）
function BookPlugin:addToMainMenu(menu_items)
    menu_items.book_library = {
        text = _("Book 桌面"),
        -- moon.host 已把该项钉在设置菜单顶部；sorting_hint 仅作 order 未命中时的兜底
        sorting_hint = "setting",
        callback = function()
            self:openDesktop()
        end,
    }
end

--- 打开全屏桌面。已有实例先关再开，避免叠两层。
function BookPlugin:openDesktop(filter)
    local source = self:getSource()
    if self.desktop then
        UIManager:close(self.desktop)
        self.desktop = nil
    end

    local ok, desk = pcall(function()
        return Desktop:new{
            plugin = self,
            source = source,
            api = source, -- 与 desktop.api 同义，旧 UI 读这个
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

--- 打开书：已缓存直接读；否则联网下载。打开前关掉桌面，避免阅读栈下面压着全屏页。
function BookPlugin:openBook(book)
    local filename = book.filename
    if not filename or filename == "" then
        UIManager:show(InfoMessage:new{ text = _("无效文件名") })
        return
    end
    Cache.remember(book)
    local path = Cache.bookPath(filename)
    local function doOpen()
        Cache.touch(path, filename)
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
    NetworkMgr:runWhenOnline(function()
        local source = self:getSource()
        local title = book.bookName or book.title
            or (filename:match("([^/\\]+)$") or filename)
        local size = tonumber(book.fileSize or book.filesize or book.size or book.file_size)
        if not size or size <= 0 then
            -- 列表没带大小时 HEAD 探一下，进度条才有上限
            size = source:probeFileSize(filename)
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

        local ok, err = source:downloadBook(filename, path, dialog and function(bytes)
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

--- 上报 KOReader 阅读统计到当前数据源。
--- 自动/手动都走后台分步；手动才弹进度条。
--- @param show_msg boolean 是否提示用户
--- @param force boolean 忽略节流与「自动上报」开关
function BookPlugin:pushReadingStats(show_msg, force)
    if MoonSettings.get().auto_stats == false and not force then
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

    NetworkMgr:runWhenOnline(function()
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

        StatsSync.pushAsync(self:getSource(), {
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

--- 关掉阅读页悬浮菜单；关书 / 回桌面前必须先清掉
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

--- 中部热区 handler。返回 true 表示已消费，KOReader 不再翻页。
function BookPlugin:onTapBookReaderFloatMenu()
    if not readerFloatMenuEnabled() then
        return false
    end
    if self._reader_float_menu and not self._reader_float_menu._closed then
        return true -- 已打开：吞掉点击，别再翻页
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
        return true -- 失败也吞掉，避免变成翻页
    end
    self._reader_float_menu = menu
    UIManager:show(menu)
    -- 下层是阅读页；优先刷面板区域，再补一刀全屏 ui
    if menu._panel_dimen then
        UIManager:setDirty("all", "ui", menu._panel_dimen)
        UIManager:setDirty("all", "ui")
    else
        UIManager:setDirty("all", "ui")
    end
    return true
end

--- 退出阅读并打开 Book 桌面（悬浮菜单「首页」）。
--- 路径对齐 KOReader：onClose → showFileManager → 再 openDesktop。
--- 只 onClose 会留下空栈（打开书时 FM/桌面已被关掉），看起来像直接退出。
function BookPlugin:exitReadingToDesktop()
    self:closeReaderFloatMenu()
    local ui = self.ui
    if not (ui and ui.document) then
        if not Host.openFromFileManager(self) then
            logger.warn("book exitReadingToDesktop: not in reader and no desktop host")
        end
        return
    end
    local file = ui.document.file
    Host.setPending(true)
    Host.watchFileManager(self)
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
            if not Host.takePending() then
                -- FM onShow 已经消费过 pending，避免开两次
                return
            end
            if not Host.openFromFileManager(nil) then
                logger.warn("book exitReadingToDesktop: desktop not opened")
            end
        end)
    end)
end

--- 阅读页就绪：挂热区、拉远端进度、注册统计设备
function BookPlugin:onReaderReady()
    self:registerReaderFloatMenuZones()
    local s = MoonSettings.get()
    if s.auto_sync then
        Progress.pull(self.ui, self:getSource(), false)
    end
    if s.auto_stats ~= false then
        NetworkMgr:runWhenOnline(function()
            StatsSync.registerDevice(self:getSource())
        end)
    end
end

--- 旋转 / 改分辨率后重挂中部热区
function BookPlugin:onSetDimensions()
    self:registerReaderFloatMenuZones()
end

--- 关书：推进度 + 上报统计
function BookPlugin:onCloseDocument()
    self:closeReaderFloatMenu()
    local s = MoonSettings.get()
    if s.auto_sync then
        Progress.push(self.ui, self:getSource(), false)
    end
    if s.auto_stats ~= false then
        self:pushReadingStats(false, false)
    end
end

--- 休眠：有打开的书才推，网络可能马上断
function BookPlugin:onSuspend()
    -- 没在读书就不用推；休眠时网络可能马上断，能推多少算多少
    if not self.ui.document then
        return
    end
    local s = MoonSettings.get()
    if s.auto_sync then
        Progress.push(self.ui, self:getSource(), false)
    end
    if s.auto_stats ~= false then
        self:pushReadingStats(false, false)
    end
end

return BookPlugin
