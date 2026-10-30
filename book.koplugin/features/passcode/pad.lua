--[[--
密码数字键盘：锁屏图（或壁纸）铺底，中间半透明卡片放圆点与 3×4 键盘。

  +----------------------------------+
  |  (背景：compose / screensaver)   |
  |   +--------------------------+   |
  |   |     输入密码解锁         |   |
  |   |     ● ● ○ ○ ○ ○          |   |
  |   |     密码错误             |   |
  |   |            忘记密码      |   |
  |   |   [1]  [2]  [3]          |   |
  |   |   [4]  [5]  [6]          |   |
  |   |   [7]  [8]  [9]          |   |
  |   |   [⌫]  [0]  [✓]          |   |
  |   |      [ 取消 ]            |   |  仅 dismissable
  |   +--------------------------+   |
  +----------------------------------+

键盘按竖屏高度排：横屏（尤其 KPW6）会裁掉底行，0 / 确认进不去。开窗时若当前是横屏，临时扳到
DEVICE_ROTATED_UPRIGHT（不写旋转记忆），关窗后再经 utils.rotation.follow 还原；叠两层（设密码确认）
用引用计数，只在最外层关完时还原。开窗期间吞掉陀螺仪，避免又转回横屏。

on_submit(pin) 返回 true 关窗；返回字符串则清空输入、显示该提示。
dismissable=false（解锁）时返回键、点空白都被吞掉；true（设置页）时多一个取消按钮，返回键也能取消。
header=true（解锁）时左上角画设备头像 + 设备名称；on_forgot 给了、且 forgot() 为真时卡片内出现「忘记密码」。
刚按下的那一位明文显示 REVEAL 秒再变回圆点；每位占固定宽度的格子，换字符时整行不抖。

@module koplugin.book.features.passcode.pad
--]]

local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local LeftContainer = require("ui/widget/container/leftcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local RightContainer = require("ui/widget/container/rightcontainer")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Backdrop = require("features.passcode.backdrop")
local Box = require("ui.themes.widgets.box")
local Button = require("ui.themes.widgets.button")
local Image = require("ui.themes.widgets.image")
local Modal = require("ui.themes.widgets.modal")
local Text = require("ui.themes.widgets.text")
local Theme = require("ui.themes")
local Guard = require("ui.guard")
require("l10n").apply()
local _ = require("gettext")

local Screen = Device.screen

local KEYS = {
    { "1", "2", "3" },
    { "4", "5", "6" },
    { "7", "8", "9" },
    { "del", "0", "ok" },
}

---@class BookPasscodePad : BookThemeModal
---@field title string
---@field header boolean|nil 左上角画设备头像与名称
---@field forgot fun(): boolean|nil 为真时底部显示「忘记了设备密码？」
---@field on_forgot fun()|nil
---@field on_submit fun(pin: string): true|string
local Pad = Modal:extend{
    name = "book_passcode_pad",
    covers_fullscreen = true,
    title = nil,
    header = false,
    forgot = nil,
    on_forgot = nil,
    on_submit = nil,
}

Pad.MIN_LEN = 4
Pad.MAX_LEN = 6
Pad.REVEAL = 1 -- 刚输入的那位明文显示多少秒

-- 横屏 → 临时竖屏：引用计数，手势密码页复用。奇数 mode 即横屏（与 KOReader DEVICE_ROTATED_* 一致）。
local portrait_hold = 0
local portrait_saved ---@type number|nil

--- 开密码页前：横屏则扳竖屏，记住原方向；已竖屏不动。不写 fm/copt 记忆。
function Pad.holdPortrait()
    local mode = Screen:getRotationMode()
    if portrait_hold == 0 and type(mode) == "number" and mode % 2 == 1 then
        portrait_saved = mode
        Screen:setRotationMode(Screen.DEVICE_ROTATED_UPRIGHT or 0)
    end
    portrait_hold = portrait_hold + 1
end

--- 关密码页：最外层才交出要还原的方向；调用方 nextTick 再 follow，避免关窗过程中转屏。
---@return number|nil
function Pad.releasePortrait()
    if portrait_hold == 0 then return end
    portrait_hold = portrait_hold - 1
    if portrait_hold > 0 or portrait_saved == nil then return end
    local mode = portrait_saved
    portrait_saved = nil
    return mode
end

function Pad:init()
    Pad.holdPortrait()
    Modal.init(self)
    self.pin = ""
    self.message = nil
    self.reveal = false
    self.mask = function()
        self.reveal = false
        self:refresh()
    end
    self:updateView()
end

--- 开窗期间禁止改方向：横屏会裁底行；尺寸若变了只按当前屏重排。
---@return boolean
function Pad:onSetRotationMode()
    return true
end

function Pad:onScreenResize()
    UIManager:nextTick(function()
        Guard.call("passcode pad relayout", self.relayout, self)
    end)
    return true
end

function Pad:onCloseWidget()
    UIManager:unschedule(self.mask)
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

---@param key string 数字或 del / ok
function Pad:press(key)
    if key == "ok" then return self:submit() end
    if key == "del" or #self.pin < Pad.MAX_LEN then
        UIManager:unschedule(self.mask)
        self.reveal = key ~= "del"
        if self.reveal then
            self.pin = self.pin .. key
            UIManager:scheduleIn(Pad.REVEAL, self.mask)
        else
            self.pin = self.pin:sub(1, -2)
        end
    end
    self.message = nil
    self:refresh()
end

function Pad:submit()
    local res = self.on_submit(self.pin)
    if res == true then return self:close() end
    self:clear(res)
end

--- 清空输入。
---@param message string|nil 清空后显示的提示
function Pad:clear(message)
    UIManager:unschedule(self.mask)
    self.pin, self.message, self.reveal = "", message, false
    self:refresh()
end

function Pad:refresh()
    self:updateView()
    UIManager:setDirty(self, "ui")
end

--- 整屏窗口撤下后下层要整屏重画，墨水屏顺带清残影。
function Pad:close()
    Modal.close(self)
    UIManager:nextTick(function() UIManager:setDirty("all", "full") end)
end

---@param key string
---@param w number
---@param h number
---@return table
function Pad:key(key, w, h)
    local spec = { width = w, height = h, callback = function() self:press(key) end }
    if key == "del" then
        spec.icon, spec.variant, spec.enabled = "backspace", "ghost", #self.pin > 0
    elseif key == "ok" then
        spec.icon, spec.variant, spec.enabled = "check", "primary", #self.pin >= Pad.MIN_LEN
    else
        spec.text = key
    end
    return Button:new(spec)
end

--- 圆点行：每格固定宽度（取圆点与各数字里最宽的），刚输入的那位在格内换成数字，整行不抖。
---@return table HorizontalGroup
function Pad:dots()
    local n = #self.pin
    local cells = {}
    for i = 1, Pad.MAX_LEN do
        cells[i] = i < n and "●" or i == n and (self.reveal and self.pin:sub(-1) or "●") or "○"
    end
    if not self.cell_w then
        self.cell_w, self.cell_h = 0, 0
        for _idx, glyph in ipairs({ "●", "○", "0", "1", "2", "3", "4", "5", "6", "7", "8", "9" }) do
            local probe = Text.line("hero", glyph)
            local size = probe:getSize()
            self.cell_w, self.cell_h = math.max(self.cell_w, size.w), math.max(self.cell_h, size.h)
            probe:free()
        end
    end
    local row = HorizontalGroup:new{}
    for _idx, glyph in ipairs(cells) do
        row[#row + 1] = CenterContainer:new{
            dimen = Geom:new{ w = self.cell_w, h = self.cell_h },
            Text.line("hero", glyph),
        }
    end
    return row
end

--- 头像条占高（头像 + 上下 padding），算卡片区域用，避免先建再丢。
---@param self BookPasscodePad|BookPasscodePattern
---@return number
function Pad:headerHeight()
    if not self.header then return 0 end
    local t = self.theme
    return Theme.px(t.control.height) + Theme.px(t.space.lg) * 2
end

--- 左上角：圆形设备头像 + 设备名称。
---@param self BookPasscodePad|BookPasscodePattern
---@return table
function Pad:headerWidget()
    local t = self.theme
    local size = Theme.px(t.control.height)
    local round = {}
    for key, value in pairs(t.image) do round[key] = value end
    round.border, round.radius, round.shadow = 0, 999, 0
    local info = require("utils.device")
    return FrameContainer:new{
        bordersize = 0,
        padding = Theme.px(t.space.lg),
        HorizontalGroup:new{
            align = "center",
            Image.widget({ width = size, height = size, src = info.logo(), style = round }),
            HorizontalSpan:new{ width = Theme.px(t.space.md) },
            Text.line("body", info.name()),
        },
    }
end

--- 卡片内右对齐的「忘记密码」。
---@param self BookPasscodePad|BookPasscodePattern
---@param width number 卡片内容宽
---@return table
function Pad:forgotRow(width)
    return RightContainer:new{
        dimen = Geom:new{ w = width, h = Theme.px(self.theme.control.height) },
        Button:new{ text = _("忘记密码"), variant = "ghost", callback = self.on_forgot },
    }
end

--- 锁屏纯图壁纸铺底 + 半透明卡片；头像条独占顶部，卡片在其下居中，互不重叠。
--- 无图时外层纯色底保证不露书页；keep_bg 禁止弹窗壁纸 hollow 摘底。
---@param self BookPasscodePad|BookPasscodePattern
---@param body table 卡片内主内容（VerticalGroup）
function Pad:setUnlockPanel(body)
    local t = self.theme
    local w, h = Screen:getWidth(), Screen:getHeight()
    local margin = Theme.px(t.space.lg) * 2
    local pad = Theme.px(t.space.lg)
    local header = self.header and Pad.headerWidget(self) or nil
    -- 必须量真实占位：估算偏矮时卡片会顶进 logo。
    local header_h = header and header:getSize().h or 0
    local area_h = math.max(1, h - header_h)
    local card_w = math.min(w - margin * 2, math.floor(math.min(w, area_h) * 0.88))

    local card = Box:new{
        style = {
            bg = t.color.page,
            border = 1,
            border_color = t.color.ink,
            radius = 0,
        },
        -- 有背景图时半透明；纯色底上也无害（lighten 白底仍是白）。
        bg_alpha = 78,
        padding = pad,
        width = card_w,
        body,
    }

    local screen = OverlapGroup:new{ dimen = Geom:new{ w = w, h = h } }
    local bg = self._backdrop
    if not bg or bg.width ~= w or bg.height ~= h then
        if bg and bg.free then bg:free() end
        bg = Backdrop.widget(w, h)
        self._backdrop = bg
    end
    if bg and not bg:surface() then
        bg:free()
        bg, self._backdrop = nil, nil
    end
    if bg then screen[#screen + 1] = bg end
    -- 头像单独叠在左上角（不要进 align=center 的 VerticalGroup，否则被居中）。
    if header then screen[#screen + 1] = header end
    -- 卡片水平居中：VerticalGroup 自身宽度只有卡片宽时，OverlapGroup 默认左对齐会整组贴左。
    -- 用整屏宽的 CenterContainer 包住卡片；上下垫高撑满，避免外层 Box 再垂直居中挪位。
    local card_h = card:getSize().h
    local top_gap = math.max(Theme.px(t.space.md), math.floor((area_h - card_h) / 2))
    local bottom_gap = math.max(0, h - header_h - top_gap - card_h)
    screen[#screen + 1] = VerticalGroup:new{
        HorizontalSpan:new{ width = w },
        VerticalSpan:new{ width = header_h + top_gap },
        CenterContainer:new{
            dimen = Geom:new{ w = w, h = card_h },
            card,
        },
        VerticalSpan:new{ width = bottom_gap },
    }

    self:setPanel(Box:new{
        style = { bg = t.color.page },
        keep_bg = true,
        width = w,
        height = h,
        screen,
    })
end

function Pad:updateView()
    local t = self.theme
    local w, h = Screen:getWidth(), Screen:getHeight()
    local gap = Theme.px(t.space.md)
    local key_w = math.floor((math.min(w, h) * 0.62 - gap * 2) / 3)
    local key_h = math.floor(Theme.px(t.control.height) * 1.5)
    local margin = Theme.px(t.space.lg) * 2
    -- 与 setUnlockPanel 同一口径：有头像条时按剩余高度算卡片宽。
    local area_h = math.max(1, h - self:headerHeight())
    local card_w = math.min(w - margin * 2, math.floor(math.min(w, area_h) * 0.88))
    local inner_w = card_w - Theme.px(t.space.lg) * 2

    local col = VerticalGroup:new{
        align = "center",
        LeftContainer:new{
            dimen = Geom:new{ w = inner_w, h = Theme.px(t.control.height) },
            Text.line("title", self.title),
        },
        VerticalSpan:new{ width = Theme.px(t.space.lg) },
        self:dots(),
        VerticalSpan:new{ width = Theme.px(t.space.sm) },
        Text.line("caption", self.message or " ", { color = t.color.muted, width = inner_w }),
        VerticalSpan:new{ width = Theme.px(t.space.md) },
    }
    if self.on_forgot and self.forgot and self.forgot() then
        col[#col + 1] = self:forgotRow(inner_w)
        col[#col + 1] = VerticalSpan:new{ width = Theme.px(t.space.sm) }
    end
    for _idx, keys in ipairs(KEYS) do
        local row = HorizontalGroup:new{}
        for i, key in ipairs(keys) do
            if i > 1 then row[#row + 1] = HorizontalSpan:new{ width = gap } end
            row[#row + 1] = self:key(key, key_w, key_h)
        end
        col[#col + 1] = row
        col[#col + 1] = VerticalSpan:new{ width = gap }
    end
    if self.dismissable then
        col[#col + 1] = Button:new{
            text = _("取消"), variant = "ghost", width = key_w,
            callback = function() self:close() end,
        }
    end
    self:setUnlockPanel(col)
end

return Pad
