--[[--
上下进度条（ReaderView view module）。

纯绘制，不注册 touch zone，不影响输入；仅活跃阅读会话（源身份书籍）绘制。
view / ui 由 ReaderView:registerViewModule 注入。

布局（叠在正文上，paintTo）：
  +-----------------------------------------------+
  | 章节名称                          HH:MM        | ← 顶
  |                                               |
  |              （阅读正文，本模块不画）            |
  |                                               |
  |  ██···· NN% · 第c/n章 · 第a/b页 · 约X小时Y分 | ← 底（进度条 + 文案同行）
  +-----------------------------------------------+

顶部（章节名 + 时间）由「顶部状态栏」设置控制；
底部（进度文案 + 进度条）由「底部进度」设置控制。

@module koplugin.book.ui.reader.bars
--]]

local _ = require("gettext")

local Bars = {
    view = nil,
    ui = nil,
    _clock = nil,
    _speed_key = nil,
    _summary = nil,
}

--- 顶条时间文案。
---@param now number|nil os.time 时间戳（缺省当前）
---@return string
function Bars.timeText(now)
    return os.date("%H:%M", now)
end

--- 当前章节名称：按章书籍取章节标题，整本书回退书名。
---@param cur ReaderSessionSnapshot|nil
---@param toc BookChapter[]|nil
---@return string
function Bars.chapterTitle(cur, toc)
    if type(cur) ~= "table" or type(cur.identity) ~= "table" then
        return ""
    end
    local identity = cur.identity
    local idx = tonumber(identity.chapter_idx)
    if idx and toc and toc[idx] and toc[idx].title then
        return toc[idx].title
    end
    if identity.book and identity.book.title then
        return identity.book.title
    end
    return ""
end

--- 剩余阅读时间估算（秒）；数据不足或已读完返回 nil。
---@param cur ReaderSessionSnapshot|nil
---@param summary { total_seconds: number, pages: number }|nil 单本书阅读统计
---@return number|nil
function Bars.remainingSeconds(cur, summary)
    if type(cur) ~= "table" or type(summary) ~= "table" then
        return nil
    end
    local page = tonumber(cur.page)
    local total = tonumber(cur.total_pages)
    local total_seconds = tonumber(summary.total_seconds)
    local pages = tonumber(summary.pages)
    if not page or not total or total <= page then
        return nil
    end
    if not total_seconds or total_seconds <= 0 or not pages or pages <= 0 then
        return nil
    end
    return math.floor((total - page) * (total_seconds / pages))
end

--- 剩余阅读时间文案；不足一分钟时为空。
---@param remaining_seconds number|nil
---@return string
function Bars.remainingText(remaining_seconds)
    remaining_seconds = tonumber(remaining_seconds)
    if not remaining_seconds or remaining_seconds < 60 then
        return ""
    end
    local hours = math.floor(remaining_seconds / 3600)
    local minutes = math.floor((remaining_seconds % 3600) / 60)
    if hours > 0 then
        return string.format(_("约 %d 小时 %d 分"), hours, minutes)
    end
    return string.format(_("约 %d 分钟"), minutes)
end

--- 底条进度文案：百分比 · 章号 · 页码 · 剩余时间（取得到的才拼）。
---@param cur ReaderSessionSnapshot|nil
---@param toc BookChapter[]|nil
---@param remaining_seconds number|nil
---@return string
function Bars.progressText(cur, toc, remaining_seconds)
    if type(cur) ~= "table" then
        return ""
    end
    local parts = {}
    local pct = tonumber(cur.percent) or 0
    if pct < 0 then
        pct = 0
    elseif pct > 100 then
        pct = 100
    end
    parts[#parts + 1] = string.format("%.0f%%", pct)
    local identity = cur.identity
    local idx = identity and tonumber(identity.chapter_idx)
    local count = toc and #toc or nil
    if idx and count and count > 0 then
        parts[#parts + 1] = string.format(_("第 %d/%d 章"), idx, count)
    end
    local page, total = tonumber(cur.page), tonumber(cur.total_pages)
    if page and total and total > 0 then
        parts[#parts + 1] = string.format(_("第 %d/%d 页"), page, total)
    end
    local remaining = Bars.remainingText(remaining_seconds)
    if remaining ~= "" then
        parts[#parts + 1] = remaining
    end
    return table.concat(parts, " · ")
end

--- 每分钟顶条时钟；ReaderUI 销毁后自动停摆。
---@return nil
function Bars:startClock()
    local UIManager = require("ui/uimanager")
    self._clock = function()
        if require("apps/reader/readerui").instance ~= self.ui then
            return
        end
        if self.ui and require("ui.reader.session").current() then
            UIManager:setDirty(self.ui.dialog, "ui")
        end
        self:startClock()
    end
    UIManager:scheduleIn(61 - tonumber(os.date("%S")), self._clock)
end

--- 读取当前书的平均阅读时长统计，按身份缓存。
---@param identity BookIdentity|nil
---@return { total_seconds: number, pages: number }|nil
local function summaryFor(identity)
    if type(identity) ~= "table" or not identity.source_id or not identity.stable_id then
        return nil
    end
    local key = identity.source_id .. "/" .. identity.stable_id
    if Bars._speed_key == key then
        return Bars._summary
    end
    Bars._speed_key = key
    Bars._summary = require("utils.db.stats").summaryByBook(identity.source_id, identity.stable_id)
    return Bars._summary
end

--- 顶/底条在正文上占用的高度，供正文 margin 让位。
---@param common table|nil
---@return { top: number, bottom: number }
function Bars.insets(common)
    common = common or require("utils.settings").get()
    local Screen = require("device").screen
    local scale = tonumber(common.ui_scale) or 130
    local function sz(n)
        return math.max(1, math.floor(Screen:scaleBySize(n) * scale / 100 + 0.5))
    end
    -- 顶/底条各一行内容（章节名/时间、进度文案/进度条）加边距。
    local content = sz(20)
    local top, bottom = 0, 0
    if common.book_reader_show_top_time ~= false then
        top = sz(8) + content
    end
    if common.book_reader_show_bottom_progress ~= false then
        bottom = sz(8) + content
    end
    return { top = top, bottom = bottom }
end

--- 给正文加顶/底边距，让正文避开 Book 自绘状态条。
---@param ui table|nil
function Bars.applyInsets(ui)
    local font = ui and ui.font
    local config = font and font.configurable
    if not config or not ui.handleEvent then
        return
    end
    local Event = require("ui/event")
    local insets = Bars.insets()
    local top = (tonumber(config.t_page_margin) or 0) + insets.top
    local bottom = (tonumber(config.b_page_margin) or 0) + insets.bottom
    -- 一次同时设置上下边距，避免 sync_t_b_page_margins 模式把 configurable 基础值污染。
    ui:handleEvent(Event:new("SetPageTopAndBottomMargin", { top, bottom }))
end

--- 绘制顶条（章节名 + 时间）与底条（进度文案 + 圆角进度条）。
---@param bb any blitbuffer
---@param x number ReaderView 原点
---@param y number
---@return nil
function Bars:paintTo(bb, x, y)
    local cur = require("ui.reader.session").current()
    if not cur then
        return
    end
    local common = require("utils.settings").get()
    local UI = require("ui.components.bookui")
    local TextWidget = require("ui/widget/textwidget")
    local Blitbuffer = require("ffi/blitbuffer")
    local dimen = self.view and self.view.dimen or require("device").screen:getSize()
    local w, h = dimen.w, dimen.h
    local pad = UI.sz(8)

    -- 顶条：左上章节名，右上时间
    if common.book_reader_show_top_time ~= false then
        local title = TextWidget:new{
            text = Bars.chapterTitle(cur, require("ui.reader.session").toc()),
            face = UI.face("cfont", 13),
            fgcolor = Blitbuffer.COLOR_BLACK,
            max_width = w - pad * 2 - UI.sz(64),
        }
        title:paintTo(bb, x + pad, y + pad)

        local time = TextWidget:new{
            text = Bars.timeText(),
            face = UI.face("xx_smallinfofont", 12),
            fgcolor = UI.muted(),
        }
        local ts = time:getSize()
        time:paintTo(bb, x + w - ts.w - pad, y + pad)
    end

    -- 底条：圆角进度条在左、进度文案占右侧剩余，同一条水平线
    if common.book_reader_show_bottom_progress ~= false then
        local pct = math.max(0, math.min(100, tonumber(cur.percent) or 0))
        local bar_h = UI.sz(6)
        local gap = UI.sz(8)
        local bar_min = UI.sz(80)
        local remaining = Bars.remainingSeconds(cur, summaryFor(cur.identity))
        local info = TextWidget:new{
            text = Bars.progressText(cur, require("ui.reader.session").toc(), remaining),
            face = UI.face("xx_smallinfofont", 12),
            fgcolor = UI.muted(),
            max_width = w - pad * 2 - gap - bar_min,
        }
        local is = info:getSize()
        local info_y = y + h - is.h - pad
        local bar_w = math.max(1, w - pad * 2 - is.w - gap)
        local bar_y = info_y + (is.h - bar_h) / 2
        UI.progressBar(bar_w, bar_h, pct):paintTo(bb, x + pad, bar_y)
        info:paintTo(bb, x + pad + bar_w + gap, info_y)
    end
end

return Bars
