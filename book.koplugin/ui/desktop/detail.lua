--[[--
书籍详情：Material 返回顶栏 + 书籍信息（hero，点按开始阅读）+ 阅读情况 + 底部动作行
  单页，禁止 ScrollableContainer；「最近几天」用 PageStrip 分页，不做高度裁剪。
  书城书（zlib / 微信未上架）未入库：无编辑/统计，hero 不显示简介摘要与进度，完整简介直下，
  底部：zlib「加入书库」下载导入；微信「加入书架」。
  弹窗：自管 _closed。

布局：
  +-----------------------------------------------+
  | ← 返回                                        | 自绘顶栏 + 通栏底线
  |-----------------------------------------------|
  | +----+  书名                                  |
  | |封面|  作者          ← 点按开始阅读           | BookInfo.hero（正常展示：
  | +----+  分类 · 系列 / 简介摘要 / 进度条        |   详情都在这张卡里）
  |-----------------------------------------------|
  | +---------+ +---------+ +---------+           |
  | | 累计时长 | | 已读页数 | | 上次阅读 |           | KPI 卡片
  | +---------+ +---------+ +---------+           |
  | 最近几天（平铺，无卡片）                        |
  | 08-15  ========····  42分钟                    |
  | 08-14  ====········  25分钟                    |
  |           ‹  ● ● ○  ›                         | PageStrip（>1 页才出现）
  |-----------------------------------------------|
  | [编辑] [刮削] [下载] [标记已读] [删除]          | 工具行：等宽竖排 chip
  | [▶ 继续阅读 / 开始阅读]                        | 主按钮单独一行
  +-----------------------------------------------+

@module koplugin.book.ui.detail
--]]

local Blitbuffer = require("ffi/blitbuffer")
local ButtonTable = require("ui/widget/buttontable")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TopContainer = require("ui/widget/container/topcontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local TextWidget = require("ui/widget/textwidget")
local Catalog = require("book.catalog")
local BookInfo = require("ui.components.bookinfo")
local Icon = require("ui.components.icon")
local PageStrip = require("ui.components.pagestrip")
local UI = require("ui.components.bookui")
local Surface = require("ui.components.surface")
local Text = require("utils.text")
local Store = require("book.store")
local SourceCapabilities = require("types.book_source").SourceCapabilities
local _ = require("gettext")
local T = require("ffi/util").template
local Screen = Device.screen

---@class BookDetailPage : InputContainer
---@field book Book|BookDetail|table
---@field plugin BookPlugin|nil
---@field source BookSource|nil
---@field desktop BookDesktop|nil
---@field store_preview boolean
---@field close_callback fun()|nil
---@field _dirty boolean|nil
---@field _closed boolean|nil
local Detail = InputContainer:extend{
    name = "book_detail",
    covers_fullscreen = true,
    book = nil,
    plugin = nil,
    source = nil,
    desktop = nil,
    store_preview = false,
}

--- 打开详情浮层。详情页自己的入口，不要经 Desktop:onEvent 分流。
---@param desktop BookDesktop 所属桌面实例
---@param book table 当前操作或展示的书籍数据
---@return nil
function Detail.open(desktop, book)
    if type(book) ~= "table" then return end
    local UIManager = require("ui/uimanager")
    if desktop.detail then
        UIManager:close(desktop.detail)
        desktop.detail = nil
    end
    if book.source_id and book.source_id ~= "zlib" then
        Store.rememberMany({ book })
    end
    local desk = desktop
    desktop.detail = Detail:new{
        book = book,
        plugin = desktop.plugin,
        source = desktop.source,
        desktop = desktop,
        store_preview = desktop.tab == "store",
        covers_fullscreen = true,
        close_callback = function()
            local dirty = desk.detail and desk.detail._dirty
            desk.detail = nil
            if desk.lifecycle.state == "Destroy" then
                return
            end
            if dirty then
                desk:onEvent("detail_dirty")
                if desk.tab ~= "home" then
                    desk:updateView()
                end
            else
                UIManager:setDirty(desk, "ui")
            end
        end,
    }
    UIManager:show(desktop.detail)
    UIManager:setDirty(desktop.detail, "ui")
end

--- 书城预览书：zlib 待下载；源自带书城的书加入该源远端书架。
---@param book table|nil 当前操作或展示的书籍数据
---@param source table|nil 书籍所属数据源实例
---@param store_preview boolean|nil 是否按书城预览模式构建详情
---@return "zlib"|"source"|nil
local function storeKind(book, source, store_preview)
    if type(book) ~= "table" then
        return nil
    end
    if book.source_id == "zlib" then
        return "zlib"
    end
    if store_preview and source and book.source_id == source.id
        and type(source.addStoreBookAsync) == "function" then
        return "source"
    end
    return nil
end

--- 书籍属主源：身份匹配当前源则复用，否则按 source_id 解析。
---@param book table|nil 当前操作或展示的书籍数据
---@param fallback_source table|nil 书籍未提供源标识时使用的数据源
---@return table|nil
local function bookOwnerSource(book, fallback_source)
    if type(book) ~= "table" or type(book.source_id) ~= "string" then
        return fallback_source
    end
    return require("source.registry").resolve(book.source_id) or fallback_source
end

--- 按书籍属主源判断是否可刮削（不用当前活跃源冒充）。
---@param book table|nil 当前操作或展示的书籍数据
---@param fallback_source table|nil 书籍未提供源标识时使用的数据源
---@return boolean
local function bookSupportsScrape(book, fallback_source)
    if type(book) ~= "table" or type(book.source_id) ~= "string" or type(book.stable_id) ~= "string" then
        return false
    end
    return SourceCapabilities.supportsScrape(bookOwnerSource(book, fallback_source))
end

--- 按书籍属主源判断是否可编辑元信息。
---@param book table|nil 当前操作或展示的书籍数据
---@param fallback_source table|nil 书籍未提供源标识时使用的数据源
---@return boolean
local function bookSupportsEdit(book, fallback_source)
    if type(book) ~= "table" or type(book.source_id) ~= "string" or type(book.stable_id) ~= "string" then
        return false
    end
    return SourceCapabilities.supportsEdit(bookOwnerSource(book, fallback_source))
end

--- 小节标题（书城书的简介用）。
---@param text string 需要展示的文字
---@param width number 目标宽度，单位像素
---@return table
local function sectionTitle(text, width)
    return LeftContainer:new{
        dimen = Geom:new{ w = width, h = UI.sz(30) },
        TextWidget:new{
            text = text,
            face = UI.face("cfont", 15),
            fgcolor = Blitbuffer.COLOR_BLACK,
        },
    }
end

--- 动作 chip：等宽描边按钮，Material 图标 + 文案（不加粗），整颗可点。
---@param w number 可用宽度，单位像素
---@param h number 可用高度，单位像素
---@param icon string Material Icons 原名
---@param text string 需要展示的文字
---@param on_tap fun() 点击命中区域时执行的回调
---@param direction string|nil "row"（默认）或 "column"
---@return table
local function actionChip(w, h, icon, text, on_tap, direction)
    direction = direction or "row"
    local column = direction == "column"
    local tap = BookInfo.tappable(w, h, on_tap)
    tap[1] = Surface.build{ child = Icon.label{
                name = icon,
                text = text,
                direction = direction,
                size = column and 20 or 18,
                font_size = column and 11 or 14,
                gap = column and UI.sz(2) or UI.sz(6),
                max_width = w - UI.sz(8),
            }, options = {
        width = w,
        height = h,
        shadow = false,
    }, kind = "pill" }
    return tap
end

--- 等宽 chip 行。
---@param width number 行宽，单位像素
---@param height number 按钮高度，单位像素
---@param chips table[] { icon, text, fn }
---@param direction string|nil "row" 或 "column"
---@return table
local function chipRow(width, height, chips, direction)
    local gap = UI.sz(8)
    local n = #chips
    local cell_w = n > 0 and math.floor((width - gap * (n - 1)) / n) or width
    local row = HorizontalGroup:new{ align = "center" }
    for i, chip in ipairs(chips) do
        if i > 1 then
            table.insert(row, HorizontalSpan:new{ width = gap })
        end
        table.insert(row, actionChip(cell_w, height, chip.icon, chip.text, chip.fn, direction))
    end
    return row
end

--- KPI 卡片：描边白底，上值下标签。
---@param w number 可用宽度，单位像素
---@param value string 当前设置项的值
---@param label string 展示给用户的标签文字
---@return table, number 卡片 widget 与其高度
local function kpiCard(w, value, label)
    local pad = UI.sz(10)
    local inner_w = math.max(1, w - pad * 2)
    local value_w = TextWidget:new{
        text = value,
        face = UI.face("cfont", 16),
        max_width = inner_w,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    local label_w = TextWidget:new{
        text = label,
        face = UI.face("xx_smallinfofont", 11),
        max_width = inner_w,
        fgcolor = UI.muted(),
    }
    local h = pad * 2 + value_w:getSize().h + UI.sz(4) + label_w:getSize().h
    local card = Surface.build{ child = CenterContainer:new{
            dimen = Geom:new{ w = inner_w, h = h - pad * 2 },
            VerticalGroup:new{
                align = "center",
                value_w,
                VerticalSpan:new{ width = UI.sz(4) },
                label_w,
            },
        }, options = {
        width = w,
        height = h,
        padding = pad,
        shadow = true,
    }, kind = "card" }
    return card, h
end

--- 初始化全屏尺寸、返回键，rebuild 并拉本机阅读统计。
---@return nil
function Detail:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    if Device:hasKeys() then
        self.key_events = {
            Close = { { Device.input.group.Back } },
        }
    end
    self:updateView()
    self:fetchStats()
    local kind = storeKind(self.book, self.source, self.store_preview)
    if kind == "zlib" then
        self._store_detail_job = require("zlib.init").getDetailAsync(self.book, function(detail)
            self._store_detail_job = nil
            if self._closed or not detail then return end
            self.book = detail
            self:updateView()
            require("ui/uimanager"):setDirty(self, "ui")
        end)
    elseif kind == "source" and self.source and self.source.getDetailAsync then
        local book = self.book
        self._store_detail_job = self.source:getDetailAsync({
            source_id = book.source_id,
            stable_id = book.stable_id,
            book = book,
        }, function(detail, err)
            self._store_detail_job = nil
            if self._closed or not detail then return end
            self.book = detail
            self:updateView()
            require("ui/uimanager"):setDirty(self, "ui")
        end)
    end
end

--- 返回详情页尺寸。
---@return table
function Detail:getSize()
    return self.dimen
end

--- 顶栏：Material 返回箭头 +「返回」（贴左）+ 通栏底线。
--- TitleBar 只认 KOReader svg 图标，塞不进 Material 字体图标，故自绘。
--- 热区按内容实际宽度算：固定宽度 + CenterContainer 会让内容溢出
--- （图标越过左对齐线、文字右半在热区外点不到）。
---@param w number 可用宽度，单位像素
---@return table, number 顶栏 widget 与其高度
function Detail:buildTopBar(w)
    local pad = UI.pagePad()
    local bar_h = UI.sz(48)
    local label = Icon.label{ name = "arrow_back", size = 24, text = _("返回") }
    local back_w = label:getSize().w + UI.sz(12)
    local back = BookInfo.tappable(back_w, bar_h, function()
        self:onClose()
    end)
    back[1] = LeftContainer:new{
        dimen = Geom:new{ w = back_w, h = bar_h },
        label,
    }
    local line_h = UI.line()
    local bar = FrameContainer:new{
        bordersize = 0,
        padding = 0,
        background = Blitbuffer.COLOR_WHITE,
        dimen = Geom:new{ w = w, h = bar_h + line_h },
        VerticalGroup:new{
            align = "left",
            HorizontalGroup:new{
                HorizontalSpan:new{ width = pad },
                back,
            },
            LineWidget:new{
                background = UI.rule(),
                dimen = Geom:new{ w = w, h = line_h },
            },
        },
    }
    return bar, bar_h + line_h
end

--- 异步拉本机阅读统计（汇总 + 最近 N 天），完成后重建阅读情况区。
--- 书城预览书未读过，无本机数据可查，直接跳过。
---@return nil
function Detail:fetchStats()
    local book = self.book
    if type(book) ~= "table" or type(book.source_id) ~= "string" or type(book.stable_id) ~= "string" then
        return
    end
    if storeKind(book, self.source, self.store_preview) then
        return
    end
    local StatsDB = require("db.stats")
    self._stats = StatsDB.summaryByBook(book.source_id, book.stable_id)
    self._daily = StatsDB.dailyByBook(book.source_id, book.stable_id, 30)
    if self._closed then return end
    self:updateView()
    require("ui/uimanager"):setDirty(self, "ui")
end

--- 取消详情页尚未结束的数据加载和相关异步工作。
---@return nil
function Detail:onCancel()
    if self._store_detail_job and self._store_detail_job.cancel then self._store_detail_job.cancel() end
    if self._install_job and self._install_job.cancel then self._install_job.cancel() end
    self._store_detail_job = nil
    self._install_job = nil
end

--- 关闭详情并强制重绘下层桌面。
---@return boolean
function Detail:onClose()
    self._closed = true
    self:onCancel()
    local UIManager = require("ui/uimanager")
    local desk = self.desktop
    UIManager:close(self)
    -- 全屏详情关闭后重绘下层桌面；无需为普通 UI 切换强制闪屏。
    UIManager:nextTick(function()
        if desk and desk.lifecycle.state ~= "Destroy" then
            UIManager:setDirty(desk, "ui")
        else
            UIManager:setDirty("all", "ui")
        end
    end)
    return true
end

--- 刮削/编辑结束后重读 books 行并重绘：元数据与封面都只在 rebuild 时取，
--- 光 setDirty 只会把旧数据再画一遍。
--- 走到这说明底层数据已变，打脏标记，关闭详情时桌面要清缓存重建而不是纯重绘。
---@return nil
function Detail:reload()
    self._dirty = true
    if self.desktop and self.desktop.library then
        self.desktop.library.state = nil
    end
    local book = self.book
    local row = require("db.book").get(book.source_id, book.stable_id)
    if self._closed then return end
    if row then
        row.source_id = book.source_id
        row.stable_id = book.stable_id
        self.book = row
    end
    self:updateView()
    require("ui/uimanager"):setDirty(self, "ui")
end

--- Widget 关闭时触发 close_callback。
---@return nil
function Detail:onCloseWidget()
    self._closed = true
    if self[1] and self[1].free then
        self[1]:free()
    end
    local cb = self.close_callback
    self.close_callback = nil
    if cb then
        cb()
    end
end

--- 点按书籍信息 / 底部「继续阅读」开始阅读。
---@return nil
function Detail:openBook()
    local plugin = self.plugin
    local b = self.book
    self:onClose()
    if plugin then require("book.open").book(plugin, b) end
end

--- 缓存章节模式整本正文。
---@return nil
function Detail:cacheAllChapters()
    if self._cache_job and not self._cache_job.done then return end
    if self._closed then return end
    local book = self.book
    local source = bookOwnerSource(book, self.source)
    if not source or type(source.cacheAllChaptersAsync) ~= "function" then return end
    local UIManager = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")
    local job, queued = require("source.cache_queue").enqueue(source, {
        source_id = book.source_id,
        stable_id = book.stable_id,
        book = book,
    })
    if not job then return end
    self._cache_job = job
    UIManager:show(InfoMessage:new{
        text = queued and _("已加入后台缓存队列") or _("全本缓存任务已在后台运行"),
        timeout = 3,
    })
end

--- 书城书动作：zlib 下载导入；源自带书城的书加入远端书架并同步。
---@return nil
function Detail:installStoreBook()
    local book = self.book or {}
    if self._install_job then
        return
    end
    local kind = storeKind(book, self.source, self.store_preview)
    if kind == "source" then
        if not self.source or not self.source.configured or not self.source:configured() then
            require("ui/uimanager"):show(require("ui/widget/infomessage"):new{
                text = _("请先在设置里配置当前数据源"),
            })
            return
        end
        local UIManager = require("ui/uimanager")
        local InfoMessage = require("ui/widget/infomessage")
        local ProgressbarDialog = require("ui/widget/progressbardialog")
        local dialog = ProgressbarDialog:new{
            title = _("正在加入书架…"),
            subtitle = book.title,
            progress_max = 1,
            dismissable = false,
        }
        dialog:show()
        require("ui/network/manager"):runWhenOnline(function()
            if self._closed then
                dialog:close()
                return
            end
            if type(self.source.addStoreBookAsync) ~= "function" then
                dialog:close()
                UIManager:show(InfoMessage:new{ text = _("当前数据源不支持书城") })
                return
            end
            self._install_job = self.source:addStoreBookAsync(book, function(ok, err, title)
                self._install_job = nil
                dialog:close()
                if self._closed then
                    return
                end
                if not ok then
                    UIManager:show(InfoMessage:new{ text = err or _("加入书架失败") })
                    return
                end
                local desk = self.desktop
                self:onClose()
                UIManager:show(InfoMessage:new{
                    text = _("已加入书架：") .. tostring(title or book.title),
                    timeout = 3,
                })
                if desk and desk.lifecycle.state ~= "Destroy" then
                    if desk.library then
                        desk.library.state = nil
                        desk.library.page = 1
                    end
                    desk:switchTab("library")
                end
            end)
        end)
        return
    end
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
            if desk and desk.lifecycle.state ~= "Destroy" then
                if desk.library then
                    desk.library.state = nil
                    desk.library.page = 1
                end
                desk:switchTab("library")
            end
        end)
    end)
end

--- 手动切换已读 / 未读（语义与图书馆长按菜单相同）。
---@return nil
function Detail:toggleRead()
    local book = self.book
    if type(book) ~= "table" or type(book.source_id) ~= "string" or type(book.stable_id) ~= "string" then
        return
    end
    local is_read = tonumber(book.read_state) == 1
    if not require("db.book").setRead(book.source_id, book.stable_id, not is_read) then
        require("ui/uimanager"):show(require("ui/widget/infomessage"):new{
            text = _("更新阅读状态失败"),
            timeout = 2,
        })
        return
    end
    if self._closed then
        return
    end
    self:reload()
end

--- 删除本书：确认后走属主源 deleteBookAsync，成功则关详情并刷新桌面。
---@return nil
function Detail:deleteBook()
    local book = self.book
    if type(book) ~= "table" or type(book.source_id) ~= "string" or type(book.stable_id) ~= "string" then
        return
    end
    local UIManager = require("ui/uimanager")
    UIManager:show(require("ui/widget/confirmbox"):new{
        text = T(_("确定删除《%1》？"), BookInfo.title(book)),
        ok_text = _("删除"),
        ok_callback = function()
            local source = bookOwnerSource(book, self.source)
            if not source or type(source.deleteBookAsync) ~= "function" then
                UIManager:show(require("ui/widget/infomessage"):new{
                    text = _("当前数据源不支持删除本书"),
                })
                return
            end
            source:deleteBookAsync({
                source_id = book.source_id,
                stable_id = book.stable_id,
                book = book,
                source = source,
            }, function(ok, err)
                if not ok then
                    UIManager:show(require("ui/widget/infomessage"):new{
                        text = err or _("删除本书失败"),
                    })
                    return
                end
                if self._closed then
                    return
                end
                self._dirty = true
                local desk = self.desktop
                if desk and desk.library then
                    desk.library.state = nil
                    desk.library.page = 1
                end
                self:onClose()
            end)
        end,
    })
end

--- 库内书底栏动作：工具行 + 最后一行阅读主按钮。
--- 编辑/刮削/下载按属主源能力出现；已读切换与删除只要身份完整就给。
---@param book table 当前书籍
---@param owner table|nil 属主源
---@return table, table|nil tools, primary
function Detail.actionPlan(book, owner)
    local tools = {}
    if bookSupportsEdit(book, owner) then
        tools[#tools + 1] = { id = "edit", icon = "edit", text = _("编辑") }
    end
    if bookSupportsScrape(book, owner) then
        tools[#tools + 1] = { id = "scrape", icon = "search", text = _("刮削") }
    end
    local can_read = owner ~= nil and (owner.type == "book" or owner.type == "chapter")
    local can_cache = can_read and owner.type == "chapter"
        and type(owner.cacheAllChaptersAsync) == "function"
        and not Store.isDownloaded(book)
    if can_cache then
        tools[#tools + 1] = { id = "download", icon = "download", text = _("下载") }
    end
    if type(book) == "table" and type(book.source_id) == "string" and type(book.stable_id) == "string" then
        if tonumber(book.read_state) == 1 then
            tools[#tools + 1] = { id = "unread", icon = "undo", text = _("标记未读") }
        else
            tools[#tools + 1] = { id = "read", icon = "done_all", text = _("标记已读") }
        end
        tools[#tools + 1] = { id = "delete", icon = "delete", text = _("删除") }
    end
    local primary
    if can_read then
        local pct = BookInfo.pct(book)
        primary = {
            id = "open",
            icon = "play_arrow",
            text = pct > 0 and pct < 100 and _("继续阅读") or _("开始阅读"),
        }
    end
    return tools, primary
end

--- 启动刮削（底部按钮入口，条件与原底部按钮一致）。
---@return nil
function Detail:startScrape()
    local book = self.book
    if type(book) ~= "table" then
        return
    end
    if not bookSupportsScrape(book, self.source) then
        require("ui/uimanager"):show(require("ui/widget/infomessage"):new{
            text = _("当前数据源不支持刮削"),
            timeout = 2,
        })
        return
    end
    require("scrape.ui").start(book, book.title, function()
        self:reload()
    end)
end

--- 编辑元信息对话框（书名/作者/分类/系列）。
---@return nil
function Detail:openEditor()
    local book = self.book or {}
    if type(book.source_id) ~= "string" or type(book.stable_id) ~= "string" then
        return
    end
    if not bookSupportsEdit(book, self.source) then
        require("ui/uimanager"):show(require("ui/widget/infomessage"):new{
            text = _("当前数据源不支持编辑"),
            timeout = 2,
        })
        return
    end
    local UIManager = require("ui/uimanager")
    local MultiInputDialog = require("ui/widget/multiinputdialog")
    local dialog
    dialog = MultiInputDialog:new{
        title = _("编辑元信息"),
        fields = {
            { text = book.title or "", hint = _("书名") },
            { text = BookInfo.author(book), hint = _("作者") },
            { text = book.category or "", hint = _("分类") },
            { text = book.series or "", hint = _("系列") },
        },
        buttons = { {
            {
                text = _("取消"),
                id = "close",
                callback = function()
                    UIManager:close(dialog)
                end,
            },
            {
                text = _("保存"),
                is_enter_default = true,
                callback = function()
                    local fields = dialog:getFields()
                    UIManager:close(dialog)
                    self:saveMeta(fields)
                end,
            },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--- 保存编辑结果到 books 表（进度/简介/md5 保留），完成后 reload 重绘。
--- 本地源：分类/系列即目录层级，改动会移动文件、stable_id 跟着变
---（opens/reading_stats/pending_progress 由 moveBook 里的 renameStableId 迁移）。
---@param fields table 对话框字段值：书名/作者/分类/系列
---@return nil
function Detail:saveMeta(fields)
    local book = self.book
    if type(book) ~= "table" or type(fields) ~= "table" then
        return
    end
    if not bookSupportsEdit(book, self.source) then
        return
    end
    --- 空串归一为 nil：空标题才能回退 stable_id 显示
    ---@param s any 待格式化的文本或状态值
    ---@return string|nil
    local function nonempty(s)
        s = Text.trim(type(s) == "string" and s or "")
        return s ~= "" and s or nil
    end
    local title = nonempty(fields[1])
    local authors = nonempty(fields[2])
    local category = nonempty(fields[3])
    local series = nonempty(fields[4])
    local can_move = book.source_id == "local"
        and self.source ~= nil and self.source.id == "local"
        and type(self.source.moveBook) == "function"
    if can_move and not category then
        series = nil -- 本地源系列必须挂在分类下，与扫盘派生语义一致
    end
    local move_err, new_stable_id
    if can_move then
        local moved, err = self.source:moveBook(book.stable_id, category, series)
        if not moved then
            move_err = err
        else
            new_stable_id = moved
        end
    end
    if not move_err then
        local sid = new_stable_id or book.stable_id
        local BookDB = require("db.book")
        local existing = BookDB.get(book.source_id, sid)
        BookDB.upsertLocal({
            source_id = book.source_id,
            stable_id = sid,
            title = title,
            authors = authors,
            category = category,
            series = series,
            intro = existing and existing.intro or nil,
            percent = existing and existing.percent or 0,
            md5 = existing and existing.md5 or nil,
            fetched_at = os.time(),
        })
    end
    if self._closed then
        return
    end
    local UIManager = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")
    if move_err then
        UIManager:show(InfoMessage:new{ text = move_err, timeout = 2 })
        return
    end
    if new_stable_id and new_stable_id ~= book.stable_id and self.book then
        self.book.stable_id = new_stable_id
    end
    self:reload()
    UIManager:show(InfoMessage:new{
        text = _("元数据已更新"),
        timeout = 1.5,
    })
end

--- 最近几天（平铺，无卡片壳）+ PageStrip：行高固定，按可用高度定每页行数，翻页只重建本区。
---@param w number 可用宽度，单位像素
---@param avail_h number 可用高度，单位像素
---@return table|nil, number 区块 widget 与实占高度；放不下返回 nil, 0
function Detail:buildRecent(w, avail_h)
    local daily = self._daily or {}
    if #daily == 0 then
        return nil, 0
    end
    local row_h = UI.sz(22)
    local row_gap = UI.sz(8)
    local header = TextWidget:new{
        text = _("最近几天"),
        face = UI.face("xx_smallinfofont", 12),
        fgcolor = UI.muted(),
    }
    local fixed_h = header:getSize().h + row_gap
    local pager_h = PageStrip.bandH()

    --- 预算内能放的行数。
    ---@param budget number 可用高度
    ---@return number
    local function rowsFit(budget)
        return math.floor((budget - fixed_h) / (row_h + row_gap))
    end

    local per = rowsFit(avail_h)
    if per < 1 then
        return nil, 0
    end
    local show_pager = #daily > per
    if show_pager then
        per = math.max(1, rowsFit(avail_h - pager_h))
    end
    per = math.min(per, #daily)
    local page, pages = PageStrip.clamp(self._daily_page, math.ceil(#daily / per))
    self._daily_page = page

    -- 条形按全部天数里最大当天时长归一
    local max_s = 0
    for _, r in ipairs(daily) do
        if r.seconds > max_s then max_s = r.seconds end
    end
    local date_w = UI.sz(52)
    local dur_w = UI.sz(64)
    local bar_w = math.max(1, w - date_w - dur_w - row_gap * 2)
    local kids = VerticalGroup:new{ align = "left", header }
    for i = (page - 1) * per + 1, math.min(#daily, page * per) do
        local r = daily[i]
        local _y, m, d = tostring(r.ymd):match("^(%d+)%-(%d+)%-(%d+)$")
        table.insert(kids, VerticalSpan:new{ width = row_gap })
        table.insert(kids, HorizontalGroup:new{
            align = "center",
            LeftContainer:new{
                dimen = Geom:new{ w = date_w, h = row_h },
                TextWidget:new{
                    text = (m and d) and (m .. "-" .. d) or tostring(r.ymd),
                    face = UI.face("xx_smallinfofont", 12),
                    fgcolor = UI.muted(),
                },
            },
            HorizontalSpan:new{ width = row_gap },
            UI.progressBar(bar_w, UI.sz(6), max_s > 0 and (r.seconds / max_s * 100) or 0),
            HorizontalSpan:new{ width = row_gap },
            LeftContainer:new{
                dimen = Geom:new{ w = dur_w, h = row_h },
                TextWidget:new{
                    text = Catalog.formatDuration(r.seconds),
                    face = UI.face("xx_smallinfofont", 12),
                    fgcolor = Blitbuffer.COLOR_BLACK,
                },
            },
        })
    end

    local used = kids:getSize().h
    if show_pager then
        --- 翻页：改页码重建。
        ---@param p number 目标页码
        ---@return nil
        local function goto2(p)
            self._daily_page = p
            self:updateView()
            require("ui/uimanager"):setDirty(self, "ui")
        end
        local pager = PageStrip.widget{
            width = w,
            page = page,
            pages = pages,
            on_prev = function() goto2(page - 1) end,
            on_next = function() goto2(page + 1) end,
        }
        table.insert(kids, pager)
        used = used + pager:getSize().h
    end
    return kids, used
end

--- 阅读情况区：KPI 卡片三列 + 最近几天（平铺分页）；无本机记录时单行占位。
---@param w number 可用宽度，单位像素
---@param avail_h number 可用高度，单位像素
---@return table
function Detail:buildStatsArea(w, avail_h)
    local st = self._stats
    if not st or st.pages <= 0 then
        return TextWidget:new{
            text = _("暂无阅读记录"),
            face = UI.face("xx_smallinfofont", 13),
            max_width = w,
            fgcolor = UI.muted(),
        }
    end

    local gap = UI.sz(10)
    local items = {
        { Catalog.formatDuration(st.total_seconds), _("累计时长") },
        { tostring(st.pages), _("已读页数") },
        { st.last_read > 0 and os.date("%Y-%m-%d", st.last_read) or "—", _("上次阅读") },
    }
    local cell_w = math.floor((w - gap * 2) / 3)
    local kpi_row = HorizontalGroup:new{ align = "center" }
    local kpi_h = 0
    for i, item in ipairs(items) do
        if i > 1 then
            table.insert(kpi_row, HorizontalSpan:new{ width = gap })
        end
        local card, card_h = kpiCard(cell_w, item[1], item[2])
        kpi_h = math.max(kpi_h, card_h)
        table.insert(kpi_row, card)
    end
    local kids = VerticalGroup:new{ align = "left", kpi_row }

    local recent, _recent_h = self:buildRecent(w, avail_h - kpi_h - gap)
    if recent then
        table.insert(kids, VerticalSpan:new{ width = gap })
        table.insert(kids, recent)
    end
    return kids
end

--- 重建书籍信息、阅读情况卡片与底部动作行。
---@return nil
function Detail:updateView()
    local book = self.book or {}
    local w = Screen:getWidth()
    local h = Screen:getHeight()
    local pad = UI.pagePad()
    local content_w = w - pad * 2

    local store_kind = storeKind(book, self.source, self.store_preview)
    local store_book = store_kind ~= nil
    local owner = bookOwnerSource(book, self.source)
    local can_read = not store_book and owner ~= nil
        and (owner.type == "book" or owner.type == "chapter")

    local title_bar, title_h = self:buildTopBar(w)

    -- 底部：书城书只有「加入书库/书架」；库内书两行——工具行 + 继续阅读。
    local footer_pad_v = UI.sz(12)
    local footer, footer_h
    if store_book then
        local action_enabled = store_kind == "source"
            and self.source and self.source.configured and self.source:configured()
            or store_kind == "zlib"
                and type(self.source and self.source.importBookAsync) == "function"
        footer = ButtonTable:new{
            width = content_w,
            buttons = { {
                {
                    text = store_kind == "source" and _("加入书架") or _("加入书库"),
                    font_size = UI.buttonFontSize(),
                    enabled = action_enabled,
                    callback = function()
                        self:installStoreBook()
                    end,
                },
            } },
            zero_sep = true,
            show_parent = self,
        }
        footer_h = footer:getSize().h + footer_pad_v * 2
    else
        local tools, primary = Detail.actionPlan(book, owner)
        local fns = {
            edit = function() self:openEditor() end,
            scrape = function() self:startScrape() end,
            download = function() self:cacheAllChapters() end,
            read = function() self:toggleRead() end,
            unread = function() self:toggleRead() end,
            delete = function() self:deleteBook() end,
        }
        local tool_chips = {}
        for _, def in ipairs(tools) do
            tool_chips[#tool_chips + 1] = {
                icon = def.icon,
                text = def.text,
                fn = fns[def.id],
            }
        end
        local tool_h = UI.sz(56)
        local read_h = UI.sz(44)
        local row_gap = UI.sz(8)
        if #tool_chips == 0 and not primary then
            footer = TextWidget:new{
                text = _("暂无可用操作"),
                face = UI.face("xx_smallinfofont", 13),
                max_width = content_w,
                fgcolor = UI.muted(),
            }
            footer_h = footer:getSize().h + footer_pad_v * 2
        else
            local kids = VerticalGroup:new{ align = "center" }
            footer_h = footer_pad_v * 2
            if #tool_chips > 0 then
                table.insert(kids, chipRow(content_w, tool_h, tool_chips, "column"))
                footer_h = footer_h + tool_h
            end
            if primary then
                if #tool_chips > 0 then
                    table.insert(kids, VerticalSpan:new{ width = row_gap })
                    footer_h = footer_h + row_gap
                end
                table.insert(kids, actionChip(content_w, read_h, primary.icon, primary.text, function()
                    self:openBook()
                end))
                footer_h = footer_h + read_h
            end
            footer = kids
        end
    end

    local body_h = math.max(UI.sz(80), h - title_h - footer_h)
    local body_inner_h = math.max(UI.sz(60), body_h - pad - UI.sz(12))

    -- 顶部：书籍信息英雄卡（封面 / 书名 / 作者 / 分类·系列 / 简介摘要 / 进度条）
    local category = book.category
    if type(category) == "string" and category ~= "" then
        category = category:gsub("[,\n]+", " · ")
    else
        category = nil
    end
    local subtitle_parts = {}
    if category then
        subtitle_parts[#subtitle_parts + 1] = category
    end
    if type(book.series) == "string" and book.series ~= "" then
        subtitle_parts[#subtitle_parts + 1] = book.series
    end
    local hero_opts = {
        width = content_w,
        pad = 0,
        subtitle = #subtitle_parts > 0 and table.concat(subtitle_parts, " · ") or nil,
        on_tap = can_read and function()
            self:openBook()
        end or nil,
        show_parent = self,
    }
    if store_book then
        -- 书城书：0% 进度条无意义；简介摘要让位给下方完整简介
        hero_opts.show_progress = false
        hero_opts.show_desc = false
    end
    local hero, hero_h = BookInfo.hero(self.plugin, self.source, book, hero_opts)

    local gap = UI.sz(12)
    local body_kids = { align = "left", hero }

    if store_book then
        -- 书城书：完整简介吃剩余高度
        local desc = BookInfo.desc(book)
        if desc ~= "" then
            local avail = math.max(UI.sz(40), body_inner_h - hero_h - gap - UI.sz(30) - UI.sz(6))
            table.insert(body_kids, VerticalSpan:new{ width = gap })
            table.insert(body_kids, sectionTitle(_("简介"), content_w))
            table.insert(body_kids, VerticalSpan:new{ width = UI.sz(6) })
            table.insert(body_kids, TextBoxWidget:new{
                text = desc,
                face = UI.face("xx_smallinfofont", 14),
                width = content_w,
                height = avail,
                alignment = "left",
                fgcolor = UI.muted(),
            })
        end
    else
        table.insert(body_kids, VerticalSpan:new{ width = gap })
        table.insert(body_kids, self:buildStatsArea(content_w, body_inner_h - hero_h - gap))
    end

    local root_kids = {
        align = "left",
        title_bar,
        FrameContainer:new{
            bordersize = 0,
            padding = pad,
            padding_top = UI.sz(12),
            background = Blitbuffer.COLOR_WHITE,
            dimen = Geom:new{ w = w, h = body_h },
            -- 顶对齐：内容都是满宽的，水平居中无视觉效果；
            -- 用 LeftContainer 会在内容不足时垂直居中（残影式的“飘在��间”）
            TopContainer:new{
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
            footer,
        },
    }

    -- 先接上新树再释放旧树：reload（刮削/编辑后）会反复 rebuild，旧树里的封面
    -- BlitBuffer 只在 free 时释放，不放就是每次刮削漏一张全屏封面。
    local old = self[1]
    self[1] = FrameContainer:new{
        bordersize = 0,
        padding = 0,
        background = Blitbuffer.COLOR_WHITE,
        dimen = Geom:new{ w = w, h = h },
        VerticalGroup:new(root_kids),
    }
    if old and old.free then
        old:free()
    end
    self.dimen = Geom:new{ x = 0, y = 0, w = w, h = h }
end

return Detail
