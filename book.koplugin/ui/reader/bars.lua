--[[--
上下进度条（ReaderView view module）：顶条时间，底条阅读进度 + 细进度线。

纯绘制，不注册 touch zone，不影响输入；仅活跃阅读会话（源身份书籍）绘制。
view / ui 由 ReaderView:registerViewModule 注入。

布局（叠在正文上，paintTo）：
  +-----------------------------------------------+
  |                                    HH:MM      | ← 顶右
  |                                               |
  |              （阅读正文，本模块不画）            |
  |                                               |
  |              NN% · 第p/t页 · 第c/n章          | ← 底右
  | ████████████········                          | ← 贴底细线
  +-----------------------------------------------+

@module koplugin.book.ui.reader.bars
--]]

local _ = require("gettext")

local Bars = {
    view = nil,
    ui = nil,
    _clock = nil,
}

--- 顶条时间文案。
---@param now number|nil os.time 时间戳（缺省当前）
---@return string
function Bars.timeText(now)
    return os.date("%H:%M", now)
end

--- 底条进度文案：百分比 · 页码 · 章号（取得到的才拼）。
---@param cur { percent: number|nil, page: number|nil, total_pages: number|nil, chapter_idx: number|nil, chapter_count: number|nil }|nil
---@return string
function Bars.progressText(cur)
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
    local page, total = tonumber(cur.page), tonumber(cur.total_pages)
    if page and total and total > 0 then
        parts[#parts + 1] = string.format(_("第 %d/%d 页"), page, total)
    end
    local idx, count = tonumber(cur.chapter_idx), tonumber(cur.chapter_count)
    if idx and count and count > 0 then
        parts[#parts + 1] = string.format(_("第 %d/%d 章"), idx, count)
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
        if self.ui and require("ui.reader.session").isActive() then
            UIManager:setDirty(self.ui.dialog, "ui")
        end
        self:startClock()
    end
    UIManager:scheduleIn(61 - tonumber(os.date("%S")), self._clock)
end

--- 绘制顶条（时间）与底条（进度文案 + 细进度线）。
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

    -- 顶条：右上时间（控制台打开时由顶栏接管）
    if common.book_reader_show_top_time ~= false and not require("ui.reader").isToolbarOpen() then
        local time = TextWidget:new{
            text = Bars.timeText(),
            face = UI.face("xx_smallinfofont", 12),
            fgcolor = UI.muted(),
        }
        local ts = time:getSize()
        time:paintTo(bb, x + w - ts.w - pad, y + pad)
    end

    -- 底条：细进度线贴底，进度文案在线上方右对齐
    if common.book_reader_show_bottom_progress ~= false and not require("ui.reader").isToolbarOpen() then
        local pct = math.max(0, math.min(100, tonumber(cur.percent) or 0))
        local line_h = UI.line()
        local fill_w = math.floor(w * pct / 100 + 0.5)
        if fill_w > 0 then
            bb:paintRect(x, y + h - line_h, fill_w, line_h, Blitbuffer.COLOR_GRAY_3)
        end
        local info = TextWidget:new{
            text = Bars.progressText(cur),
            face = UI.face("xx_smallinfofont", 12),
            fgcolor = UI.muted(),
        }
        local is = info:getSize()
        info:paintTo(bb, x + w - is.w - pad, y + h - line_h - is.h - UI.sz(2))
    end
end

return Bars
