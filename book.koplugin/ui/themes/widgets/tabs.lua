--[[--
内容区横向页签：文字 + 选中下划线（订阅「未读 / 全部 / 收藏」、插件市场「浏览 / 已安装 / 更新」）。
与底栏等分图标格的 `tabbar` 不同。右侧可接搜索等动作，两端对齐。

  Tabs.row({
      width = w,
      tabs = { { id = "browse", text = "浏览" }, … },
      active = "browse",
      on_tab = function(id) … end,
      trailing = widget,
  })

@module koplugin.book.ui.themes.widgets.tabs
--]]

local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Theme = require("ui.themes")
local Box = require("ui.themes.widgets.box")
local Icon = require("ui.themes.widgets.icon")
local Tap = require("ui.themes.widgets.tap")
local Text = require("ui.themes.widgets.text")

local Tabs = {}

---@param width number
---@param thick number
---@param ink number|nil
---@return table
function Tabs.rule(width, thick, ink)
    return Box:new{
        width = width, height = thick, style = { bg = ink or Theme.current().color.ink }, keep_bg = true,
    }
end

--- 可点击的文字/图标动作（搜索、分类），与页签同一行。
---@param opts { icon: string|nil, text: string, accent: boolean|nil, on_tap: fun() }
---@return table
function Tabs.action(opts)
    local t = Theme.current()
    local sm = Theme.px(t.space.sm)
    local color = opts.accent and t.color.accent or t.color.faint
    local row = HorizontalGroup:new{ align = "center" }
    if opts.icon then
        row[#row + 1] = Icon.widget{ name = opts.icon, size = t.control.icon, color = Theme.color(color) }
        if opts.text and opts.text ~= "" then
            row[#row + 1] = HorizontalSpan:new{ width = sm }
        end
    end
    if opts.text and opts.text ~= "" then
        row[#row + 1] = Text.line("body", opts.text, { color = color, optical = true })
    end
    return Tap.wrap(row, opts.on_tap)
end

--- 全宽页签行（含左右内边距和底部分隔线），选中项为强调色下划线。
---@param opts table width/tabs/active/on_tab/trailing/pad/rule
---@return table
function Tabs.row(opts)
    local t = Theme.current()
    local pad = opts.pad or Theme.px(t.space.lg)
    local sm = Theme.px(t.space.sm)
    local faint, accent = t.color.faint, t.color.accent
    local iw = math.max(1, (opts.width or 0) - pad * 2)
    local tabs = HorizontalGroup:new{ align = "top" }
    for _idx, tab in ipairs(opts.tabs or {}) do
        local active = tab.id == opts.active
        local label = Text.line("body", tab.text, { bold = active, color = active and accent or faint, optical = true })
        local underline = active and math.max(2, Theme.px(2)) or 0
        local cell = VerticalGroup:new{
            align = "center",
            label,
            VerticalSpan:new{ width = sm },
            Tabs.rule(label:getSize().w, underline, accent),
        }
        local function on_tab()
            if opts.on_tab and not active then opts.on_tab(tab.id) end
        end
        tabs[#tabs + 1] = Tap.wrap(HorizontalGroup:new{ cell, HorizontalSpan:new{ width = pad } }, on_tab)
    end
    local right = opts.trailing
    if right then
        -- 页签带下划线、比右侧动作高；右侧补同样高度，两边文字才在同一水平线上。
        local underline = sm + math.max(2, Theme.px(2))
        right = VerticalGroup:new{ align = "right", right, VerticalSpan:new{ width = underline } }
    else
        right = HorizontalSpan:new{ width = 0 }
    end
    local gap = math.max(0, iw - tabs:getSize().w - right:getSize().w)
    local line = HorizontalGroup:new{
        HorizontalSpan:new{ width = pad },
        tabs,
        HorizontalSpan:new{ width = gap },
        right,
        HorizontalSpan:new{ width = pad },
    }
    local out = VerticalGroup:new{
        align = "left",
        VerticalSpan:new{ width = sm },
        line,
    }
    if opts.rule ~= false then
        out[#out + 1] = HorizontalGroup:new{
            HorizontalSpan:new{ width = pad },
            Tabs.rule(iw, 1, faint),
        }
    end
    return out
end

return Tabs
