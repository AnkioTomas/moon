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

--- min / max / 初值里最宽的 hero 数字宽（"130%" 会超出固定宽而被截成省略号）。
---@param field BookThemeSpinField
---@return number
local function digitWidth(field)
    local w = 0
    for _idx, v in ipairs({ field.min, field.max, field.value }) do
        w = math.max(w, Text.line("hero", display(field, v)):getSize().w)
    end
    return w
end

--- 列宽：默认两个按钮高且容得下数字；整行超出 inner 时（年月日时分五列）每列只给数字宽加均分的余量。
---@param fields BookThemeSpinField[]
---@param base number 物理像素
---@param gap number
---@param inner number
---@return number[]
local function columnWidths(fields, base, gap, inner)
    local digits, widths, total, digits_total = {}, {}, gap * (#fields - 1), 0
    for i, field in ipairs(fields) do
        digits[i] = digitWidth(field)
        widths[i] = math.max(base, digits[i])
        total = total + widths[i]
        digits_total = digits_total + digits[i]
    end
    if total <= inner then return widths end
    local avail = inner - gap * (#fields - 1)
    if digits_total > avail then
        -- 极窄屏连数字都放不下：按数字宽等比缩，整行不越界（数字由文本控件截断）。
        for i = 1, #fields do widths[i] = math.max(1, math.floor(avail * digits[i] / digits_total)) end
        return widths
    end
    local extra = math.floor((avail - digits_total) / #fields)
    for i = 1, #fields do widths[i] = digits[i] + extra end
    return widths
end

function Spin:init()
    Modal.init(self)
    local t = self.theme
    local gap = Theme.px(t.space.lg)
    local inner = self:innerWidth()
    local widths = columnWidths(self.fields, Theme.px(t.control.height) * 2, gap, inner)
    self.values, self.labels = {}, {}
    local row = HorizontalGroup:new{ align = "center" }
    for i, field in ipairs(self.fields) do
        local col_w = widths[i]
        self.values[i] = field.value
        self.labels[i] = Text.line("hero", display(field, field.value), { width = col_w })
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
