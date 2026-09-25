--[[--
书籍详情框架：返回栏 + Hero 卡片 + 来源内容区 + 最多两行按钮区。
  单页，禁止 ScrollableContainer；「最近几天」用 PageStrip 分页，不做高度裁剪。
  Z-Library 预览书未入库：无编辑/统计，hero 不显示简介摘要与进度，完整简介直下，
  底栏「加入书库」；图书馆显示统计及源支持的操作。
  Lifecycle.attach：Create → Resume ↔ Pause → Destroy；异步句柄入 lifecycle.http。

布局：
  +-----------------------------------------------+
  | ← 返回                                        | 自绘顶栏 + 通栏底线
  |-----------------------------------------------|
  | +----+  书名                                  |
  | |封面|  作者          ← 点按开始阅读           | BookInfo.hero（正常展示：
  | +----+  源名 · 分类 · 系列 / 简介 / 进度条     |   详情都在这张卡里）
  |-----------------------------------------------|
  | +---------+ +---------+ +---------+           |
  | | 累计时长 | | 已读页数 | | 上次阅读 |           | KPI 卡片
  | +---------+ +---------+ +---------+           |
  | 最近几天（平铺，无卡片）                        |
  | 08-15  ========····  42分钟                    |
  | 08-14  ====········  25分钟                    |
  |           ‹  ● ● ○  ›                         | PageStrip（>1 页才出现）
  |-----------------------------------------------|
  | [编辑] [刮削] [下载] [状态] [删除]             | 工具行：左图标右文字
  | [▶ 继续阅读 / 开始阅读]                        | 主操作行
  +-----------------------------------------------+

@module koplugin.book.ui.detail
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local BookInfo = require("ui.components.bookinfo")
local Icon = require("ui.components.icon")
local UI = require("ui.components.bookui")
local Lifecycle = require("ui.lifecycle")
local Store = require("book.store")
local _ = require("gettext")
local Screen = Device.screen

---@class BookDetailPage : InputContainer, LifecycleOwner
---@field book Book|BookDetail|table
---@field plugin BookPlugin|nil
---@field source BookSource|nil
---@field desktop BookDesktop|nil
---@field origin "store"|"library"
---@field close_callback fun()|nil
---@field lifecycle Lifecycle
---@field _dirty boolean|nil
---@field _stats table|nil
---@field _daily table|nil
---@field _store_detail_job CancelHandle|nil
---@field _install_job CancelHandle|nil
---@field updateView fun(self: BookDetailPage)
---@field onCancel fun(self: BookDetailPage)
---@field onClose fun(self: BookDetailPage): boolean
---@field onCloseWidget fun(self: BookDetailPage)
local Detail = InputContainer:extend{
    name = "book_detail",
    covers_fullscreen = true,
    book = nil,
    plugin = nil,
    source = nil,
    desktop = nil,
}

--- 打开详情浮层。详情页自己的入口，不要经 Desktop:onEvent 分流。
---@param desktop BookDesktop 所属桌面实例
---@param origin "store"|"library" 详情来源
---@param book table 当前操作或展示的书籍数据
function Detail.open(desktop, origin, book)
    if origin ~= "store" and origin ~= "library" then return end
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
        origin = origin,
        plugin = desktop.plugin,
        source = desktop.source,
        desktop = desktop,
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

local storeKind = require("ui.desktop.detail.common").storeKind

--- 初始化全屏尺寸、返回键，挂生命周期后 rebuild 并拉本机阅读统计。
function Detail:init()
    self.lifecycle = Lifecycle.attach(self)
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    if Device:hasKeys() then
        self.key_events = {
            Close = { { Device.input.group.Back } },
        }
    end
    self:onCreate()
    self:onResume()
    self:updateView()
    self:fetchStats()
    local kind = storeKind(self.book, self.source, self.origin)
    if kind == "zlib" then
        self._store_detail_job = self.lifecycle:addHttp(require("zlib.init").getDetailAsync(self.book, function(detail)
            self._store_detail_job = nil
            if not self.lifecycle:uiReady() or not detail then return end
            self.book = detail
            self:updateView()
            require("ui/uimanager"):setDirty(self, "ui")
        end))
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
--- Z-Library 预览书未读过，无本机数据可查，直接跳过。
function Detail:fetchStats()
    local book = self.book
    if type(book) ~= "table" or type(book.source_id) ~= "string" or type(book.stable_id) ~= "string" then
        return
    end
    if self.origin == "store" then
        return
    end
    local StatsDB = require("db.stats")
    self._stats = StatsDB.summaryByBook(book.source_id, book.stable_id)
    self._daily = StatsDB.dailyByBook(book.source_id, book.stable_id, 30)
    if not self.lifecycle:uiReady() then return end
    self:updateView()
    require("ui/uimanager"):setDirty(self, "ui")
end

--- 取消详情页尚未结束的数据加载和相关异步工作。
function Detail:onCancel()
    self.lifecycle:abortWork()
    self._store_detail_job = nil
    self._install_job = nil
end

function Detail:onPause()
    self._store_detail_job = nil
    self._install_job = nil
end

function Detail:onDestroy()
    self._store_detail_job = nil
    self._install_job = nil
end

--- 关闭详情并强制重绘下层桌面。
---@return boolean
function Detail:onClose()
    if self.lifecycle.state ~= "Destroy" then
        self:onDestroy()
    end
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
function Detail:reload()
    self._dirty = true
    if self.desktop and self.desktop.library then
        self.desktop.library.state = nil
    end
    local book = self.book
    local row = require("db.book").get(book.source_id, book.stable_id)
    if not self.lifecycle:uiReady() then return end
    if row then
        row.source_id = book.source_id
        row.stable_id = book.stable_id
        self.book = row
    end
    self:updateView()
    require("ui/uimanager"):setDirty(self, "ui")
end

--- Widget 关闭时走 Destroy（若尚未销毁）并触发 close_callback。
function Detail:onCloseWidget()
    if self.lifecycle.state ~= "Destroy" then
        self:onDestroy()
    end
    if self[1] and self[1].free then
        self[1]:free()
    end
    local cb = self.close_callback
    self.close_callback = nil
    if cb then
        cb()
    end
end

require("ui.desktop.detail.actions")(Detail)
require("ui.desktop.detail.editor")(Detail)
require("ui.desktop.detail.content")(Detail)
require("ui.desktop.detail.layout")(Detail)

return Detail
