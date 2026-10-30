--[[--
手势密码：锁屏图铺底 + 半透明卡片内 3×3 点阵，手指依次划过的点序号（1～9）拼成字符串，如 "1596"。

接口与数字键盘 `pad.lua` 一致：on_submit(seq) 返回 true 关窗；返回字符串则清空、显示该提示。
手指抬起时提交；少于 MIN_LEN 个点直接提示。点序号串当 PIN 用，存储与校验沿用 `Passcode.verify`。
外壳（背景 / 卡片 / 头像 / 忘记密码）复用 `Pad.setUnlockPanel`。
横屏临时竖屏与数字键盘共用 `Pad.holdPortrait` / `releasePortrait`（见 pad.lua 头注释）。

@module koplugin.book.features.passcode.pattern
--]]

local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local LeftContainer = require("ui/widget/container/leftcontainer")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Widget = require("ui/widget/widget")
local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui.themes.widgets.button")
local Modal = require("ui.themes.widgets.modal")
local Pad = require("features.passcode.pad")
local Text = require("ui.themes.widgets.text")
local Theme = require("ui.themes")
require("l10n").apply()
local _ = require("gettext")

local Screen = Device.screen
local Guard = require("ui.guard")

--- 点阵画布：只管画点与连线、把坐标换成点序号。
---@class BookPatternGrid : Widget
---@field side number
---@field ink number
---@field page number
---@field seq number[] 已选点序号
local Grid = Widget:extend{ side = 0 }

function Grid:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.side, h = self.side }
    self.seq = {}
    self.picked = {}
end

--- 第 n 点中心（相对画布）。
function Grid:center(n)
    local cell = self.side / 3
    return math.floor(((n - 1) % 3 + 0.5) * cell), math.floor((math.floor((n - 1) / 3) + 0.5) * cell)
end

--- 屏幕坐标命中的点序号，没命中返回 nil。
---@param pos {x: number, y: number}
---@return number|nil
function Grid:hit(pos)
    local reach = self.side / 12
    for n = 1, 9 do
        local cx, cy = self:center(n)
        local dx, dy = pos.x - self.dimen.x - cx, pos.y - self.dimen.y - cy
        if dx * dx + dy * dy <= reach * reach then
            return n
        end
    end
end

--- 采样稀疏时也按经过顺序补上沿途的点，避免快速划动漏点。
---@param pos {x: number, y: number}
---@return boolean changed
function Grid:trace(pos)
    local x, y = pos.x - self.dimen.x, pos.y - self.dimen.y
    local ax, ay = self.last_x or x, self.last_y or y
    local dx, dy = x - ax, y - ay
    local length2 = dx * dx + dy * dy
    local reach2 = (self.side / 12) ^ 2
    local hits = {}
    for n = 1, 9 do
        if not self.picked[n] then
            local cx, cy = self:center(n)
            local t = length2 == 0 and 0 or math.max(0, math.min(1, ((cx - ax) * dx + (cy - ay) * dy) / length2))
            local ex, ey = ax + t * dx - cx, ay + t * dy - cy
            if ex * ex + ey * ey <= reach2 then hits[#hits + 1] = { n = n, t = t } end
        end
    end
    table.sort(hits, function(a, b) return a.t < b.t end)
    for _idx, hit in ipairs(hits) do
        self.picked[hit.n] = true
        self.seq[#self.seq + 1] = hit.n
    end
    self.last_x, self.last_y = x, y
    return #hits > 0
end

---@param bb BlitBuffer
---@param x number
---@param y number
function Grid:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    local ink = Blitbuffer.Color8(self.ink)
    local radius = math.floor(self.side / 18)
    local lw = math.max(2, math.floor(radius / 3))
    local px, py
    local function line(ax, ay, bx, by)
        local steps = math.max(math.abs(bx - ax), math.abs(by - ay))
        for i = 0, steps, math.max(1, math.floor(lw / 2)) do
            local t = steps == 0 and 0 or i / steps
            bb:paintRect(math.floor(x + ax + (bx - ax) * t - lw / 2), math.floor(y + ay + (by - ay) * t - lw / 2), lw, lw, ink)
        end
    end
    for _idx, n in ipairs(self.seq) do
        local cx, cy = self:center(n)
        if px then line(px, py, cx, cy) end
        px, py = cx, cy
    end
    local bg = Blitbuffer.Color8(self.page)
    for n = 1, 9 do
        local cx, cy = self:center(n)
        bb:paintCircle(x + cx, y + cy, radius, ink)
        bb:paintCircle(x + cx, y + cy, radius - lw, self.picked[n] and ink or bg)
    end
end

---@class BookPasscodePattern : BookThemeModal
---@field title string
---@field header boolean|nil
---@field forgot fun(): boolean|nil
---@field on_forgot fun()|nil
---@field on_submit fun(seq: string): true|string
local Pattern = Modal:extend{
    name = "book_passcode_pattern",
    covers_fullscreen = true,
    title = nil,
    header = false,
    forgot = nil,
    on_forgot = nil,
    on_submit = nil,
}

Pattern.MIN_LEN = 4

function Pattern:init()
    Pad.holdPortrait()
    Modal.init(self)
    local t = self.theme
    local w, h = Screen:getWidth(), Screen:getHeight()
    -- 卡片比原先整屏点阵略窄，点阵跟着缩。
    self.grid = Grid:new{ side = math.floor(math.min(w, h) * 0.58), ink = t.color.ink, page = t.color.page }
    local full = Geom:new{ x = 0, y = 0, w = w, h = h }
    self.ges_events.TapModal, self.ges_events.SwipeModal = nil, nil
    self.ges_events.PatternTouch = { GestureRange:new{ ges = "touch", range = full } }
    self.ges_events.PatternPan = {
        GestureRange:new{ ges = "pan", range = full },
        GestureRange:new{ ges = "hold_pan", range = full },
    }
    self.ges_events.PatternRelease = {}
    for _idx, ges in ipairs({ "pan_release", "hold_release", "swipe", "multiswipe", "tap" }) do
        self.ges_events.PatternRelease[#self.ges_events.PatternRelease + 1] = GestureRange:new{ ges = ges, range = full }
    end
    self.message = nil
    self:updateView()
end

--- 手指落在点上就开始新序列，落在别处忽略。
function Pattern:onPatternTouch(_arg, ges)
    self:clear()
    self.touching = self.grid:hit(ges.pos) ~= nil
    if self.touching then self:onPatternPan(nil, ges) end
    return true
end

function Pattern:onPatternPan(_arg, ges)
    if not self.touching then return true end
    if self.grid:trace(ges.pos) then UIManager:setDirty(self, "ui") end
    return true
end

function Pattern:onPatternRelease(_arg, ges)
    if not self.touching then return true end
    self.grid:trace(ges.end_pos or ges.pos)
    self.touching = false
    if #self.grid.seq < Pattern.MIN_LEN then
        self:clear(_("至少连接 4 个点"))
        return true
    end
    local res = self.on_submit(table.concat(self.grid.seq))
    if res == true then self:close() else self:clear(res) end
    return true
end

--- 清空已选点。
---@param message string|nil 清空后显示的提示
function Pattern:clear(message)
    self.grid.seq, self.grid.picked, self.touching = {}, {}, false
    self.grid.last_x, self.grid.last_y = nil, nil
    self.message = message
    self:updateView()
    UIManager:setDirty(self, "ui")
end

function Pattern:close()
    Modal.close(self)
    UIManager:nextTick(function() UIManager:setDirty("all", "full") end)
end

--- 开窗期间禁止改方向，与数字键盘同口径。
---@return boolean
function Pattern:onSetRotationMode()
    return true
end

function Pattern:onScreenResize()
    UIManager:nextTick(function()
        Guard.call("passcode pattern relayout", self.relayout, self)
    end)
    return true
end

function Pattern:onCloseWidget()
    if self._backdrop and self._backdrop.free then self._backdrop:free() end
    self._backdrop = nil
    local mode = Pad.releasePortrait()
    Modal.onCloseWidget(self)
    if mode ~= nil then
        UIManager:nextTick(function()
            Guard.call("passcode restore rotation", require("utils.rotation").follow, mode)
        end)
    end
end

function Pattern:updateView()
    local t = self.theme
    local w, h = Screen:getWidth(), Screen:getHeight()
    local margin = Theme.px(t.space.lg) * 2
    local card_w = math.min(w - margin * 2, math.floor(math.min(w, h) * 0.88))
    local inner_w = card_w - Theme.px(t.space.lg) * 2
    local col = VerticalGroup:new{
        align = "center",
        LeftContainer:new{
            dimen = Geom:new{ w = inner_w, h = Theme.px(t.control.height) },
            Text.line("title", self.title),
        },
        VerticalSpan:new{ width = Theme.px(t.space.sm) },
        Text.line("caption", self.message or " ", { color = t.color.muted, width = inner_w }),
        VerticalSpan:new{ width = Theme.px(t.space.md) },
    }
    if self.on_forgot and self.forgot and self.forgot() then
        col[#col + 1] = Pad.forgotRow(self, inner_w)
        col[#col + 1] = VerticalSpan:new{ width = Theme.px(t.space.sm) }
    end
    col[#col + 1] = self.grid
    if self.dismissable then
        col[#col + 1] = VerticalSpan:new{ width = Theme.px(t.space.lg) }
        col[#col + 1] = Button:new{
            text = _("取消"), variant = "ghost", width = math.floor(self.grid.side * 0.6),
            callback = function() self:close() end,
        }
    end
    Pad.setUnlockPanel(self, col)
end

return Pattern
