--[[--
主题数值选择（替代 SpinWidget / DateTimeWidget）：一列或多列 [+] 值 [-]。

  +-------------------------+
  | 标题                    |
  |    时        分         |   label 可选
  |   [ + ]    [ + ]        |
  |    08   :   30          |
  |   [ - ]    [ - ]        |
  | [ 取消 ]    [█确定█]    |
  +-------------------------+

  Spin:new{
      title = "提醒时间",
      fields = {
          { value = 8, min = 0, max = 23, wrap = true, label = "时", format = fmt2 },
          { value = 30, min = 0, max = 59, step = 5, wrap = true, label = "分", format = fmt2 },
      },
      callback = function(hour, minute) … end,   -- 按列顺序传值
  }:show()

单值就是只有一列：callback 收到一个参数。越界时 wrap 回绕，否则停在边界。
不改调用方的 fields 表，当前值在 self.values。

@module koplugin.book.ui.themes.widgets.spin
--]]

require("l10n").apply()

local CenterContainer = require("ui/widget/container/centercontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Theme = require("ui.themes")
local Button = require("ui.themes.widgets.button")
local Modal = require("ui.themes.widgets.modal")
local Text = require("ui.themes.widgets.text")
local _ = require("gettext")

---@class BookThemeSpinField
---@field value number
---@field min number
---@field max number
---@field step number|nil 缺省 1
---@field wrap boolean|nil
---@field label string|nil
---@field format fun(v: number): string|nil 缺省 tostring

---@class BookThemeSpin : BookThemeModal
---@field title string|nil
---@field fields BookThemeSpinField[]
---@field values number[]
---@field ok_text string|nil
---@field cancel_text string|nil
---@field callback fun(...: number)|nil
---@field cancel_callback fun()|nil
local Spin = Modal:extend{
    title = nil,
    fields = nil,
    ok_text = nil,
    cancel_text = nil,
    callback = nil,
    cancel_callback = nil,
}

---@param field BookThemeSpinField
---@param value number
---@return string
local function display(field, value)
    return field.format and field.format(value) or tostring(value)
end

--- min / max / 初值里最宽的显示串。face 缺省是 hero。
---@param field BookThemeSpinField
---@param face table|nil
---@return number
local function digitWidth(field, face)
    local w = 0
    for _idx, v in ipairs({ field.min, field.max, field.value }) do
        local line = Text.line("hero", display(field, v), face and { face = face } or nil)
        w = math.max(w, line:getSize().w)
        line:free()
    end
    return w
end

--- 数字默认 hero。整行放不下时，在 caption 到 hero 之间取仍放得下的最大字号。
--- 降到 caption 仍放不下才把过宽的宽度交回去，由列宽去截断。
---@param fields BookThemeSpinField[]
---@param gap number
---@param inner number
---@return table|nil face
---@return number[] digit_widths
local function valueFace(fields, gap, inner)
    local function widthsAt(face)
        local widths, total = {}, gap * math.max(0, #fields - 1)
        for i, field in ipairs(fields) do
            widths[i] = digitWidth(field, face)
            total = total + widths[i]
        end
        return widths, total
    end
    local widths, total = widthsAt(nil)
    if total <= inner then return nil, widths end
    local font = Theme.current().font
    local lo, hi = font.caption, font.hero - 1
    local best_face, best_widths
    while lo <= hi do
        local mid = math.floor((lo + hi) / 2)
        local face = Text.face("hero", mid)
        local w, sum = widthsAt(face)
        if sum <= inner then
            best_face, best_widths = face, w
            lo = mid + 1
        else
            hi = mid - 1
        end
    end
    if best_widths then return best_face, best_widths end
    local face = Text.face("hero", font.caption)
    local w = widthsAt(face)
    return face, w
end

--- 列宽：默认两个按钮高且容得下数字。整行超出 inner 时每列只给数字宽加均分的余量。
--- 数字宽本身已经超过 inner（字号降到 caption 仍放不下）才按比例压窄，文字控件截断。
---@param digits number[]
---@param base number 物理像素
---@param gap number
---@param inner number
---@return number[]
local function columnWidths(digits, base, gap, inner)
    local widths, total, digits_total = {}, gap * (#digits - 1), 0
    for i, digit in ipairs(digits) do
        widths[i] = math.max(base, digit)
        total = total + widths[i]
        digits_total = digits_total + digit
    end
    if total <= inner then return widths end
    local avail = inner - gap * (#digits - 1)
    if digits_total > avail then
        for i = 1, #digits do widths[i] = math.max(1, math.floor(avail * digits[i] / digits_total)) end
        return widths
    end
    local extra = math.floor((avail - digits_total) / #digits)
    for i = 1, #digits do widths[i] = digits[i] + extra end
    return widths
end

function Spin:init()
    Modal.init(self)
    local t = self.theme
    local gap = Theme.px(t.space.lg)
    local inner = self:innerWidth()
    local face, digits = valueFace(self.fields, gap, inner)
    local widths = columnWidths(digits, Theme.px(t.control.height) * 2, gap, inner)
    self.values, self.labels = {}, {}
    local row = HorizontalGroup:new{ align = "center" }
    for i, field in ipairs(self.fields) do
        local col_w = widths[i]
        self.values[i] = field.value
        self.labels[i] = Text.line("hero", display(field, field.value), { width = col_w, face = face })
        local col = VerticalGroup:new{ align = "center" }
        if field.label then
            col[#col + 1] = Text.line("caption", field.label, { width = col_w, color = t.color.muted })
            col[#col + 1] = VerticalSpan:new{ width = Theme.px(t.space.xs) }
        end
        col[#col + 1] = Button:new{ icon = "add", width = col_w, callback = function() self:step(i, 1) end }
        col[#col + 1] = CenterContainer:new{
            dimen = Geom:new{ w = col_w, h = self.labels[i]:getSize().h + Theme.px(t.space.md) * 2 },
            self.labels[i],
        }
        col[#col + 1] = Button:new{ icon = "remove", width = col_w, callback = function() self:step(i, -1) end }
        if i > 1 then row[#row + 1] = HorizontalSpan:new{ width = gap } end
        row[#row + 1] = col
    end
    self:setDialog{
        title = self.title,
        body = CenterContainer:new{ dimen = Geom:new{ w = inner, h = row:getSize().h }, row },
        buttons = {
            { text = self.cancel_text or _("取消"), callback = function() self:dismiss() end },
            { text = self.ok_text or _("确定"), variant = "primary", callback = function() self:confirm() end },
        },
    }
end

--- 第 i 列按步长增减一次。
---@param i integer 列序号
---@param dir integer 1 或 -1
function Spin:step(i, dir)
    local field = self.fields[i]
    local v = self.values[i] + dir * (field.step or 1)
    if v > field.max then
        v = field.wrap and field.min or field.max
    elseif v < field.min then
        v = field.wrap and field.max or field.min
    end
    self.values[i] = v
    self.labels[i]:setText(display(field, v))
    UIManager:setDirty(self, function() return "fast", self[1].dimen end)
end

function Spin:confirm()
    self:close()
    if self.callback then self.callback(unpack(self.values)) end
end

function Spin:dismiss()
    self:close()
    if self.cancel_callback then self.cancel_callback() end
end

return Spin
