--[[--
首页编辑叠层：组件上盖遮罩 + 顶部工具条，二者都吞手势；有 on_settings 才画设置；
移动 / 高度 / 边距 / 添加。
@module tests.desktop.pages.home.edit_spec
--]]
local Assert = require("support.assert")
local Kit = require("support.widget_stubs")
Kit.install("paper")
local Themed = require("support.theme_stubs")
Themed.install()

local Edit = require("desktop.pages.home.edit")
local Widget = require("ui/widget/widget")

local calls = {}
local handlers = {
    on_delete = function(id) calls[#calls + 1] = "delete:" .. id end,
    on_move = function(id) calls[#calls + 1] = "move:" .. id end,
    on_height = function(id, range) calls[#calls + 1] = "height:" .. id .. ":" .. range.height end,
    on_margin = function(id) calls[#calls + 1] = "margin:" .. id end,
}
local meta = { id = "clock", width = 300, height = 120, range = { height = 90 }, placement = {} }
local content = Widget:new{ dimen = { w = 300, h = 120 } }

local overlay = Edit.wrap(content, meta, handlers)
Assert.eq(overlay[1], content, "组件在最底层")
local buttons = Kit.buttons(overlay)
Assert.len(buttons, 4, "无 on_settings 不画设置")
for _, b in ipairs(buttons) do b.callback() end
Assert.eq(table.concat(calls, ","), "delete:clock,move:clock,height:clock:90,margin:clock")
Assert.is_true(overlay[2].onHomeEditShieldTap(), "遮罩吞点按")
Assert.is_true(overlay[2].onHomeEditShieldHold())
Assert.is_true(overlay[3].onHomeEditBarSwipe(), "工具条吞滑动")

handlers.on_settings = function(id) calls[#calls + 1] = "settings:" .. id end
buttons = Kit.buttons(Edit.wrap(content, meta, handlers))
Assert.len(buttons, 5)
buttons[5].callback()
Assert.eq(calls[#calls], "settings:clock")

do -- 移动：按能否上下移置灰；下一页缺省可用
    local moved = {}
    Edit.showMoveDialog({
        can_up = false, can_down = true, can_prev_page = false,
        on_up = function() moved[#moved + 1] = "up" end,
        on_down = function() moved[#moved + 1] = "down" end,
        on_next_page = function() moved[#moved + 1] = "next" end,
    })
    local sheet = Themed.last("sheet")
    Assert.eq(sheet.title, "移动组件")
    Assert.is_false(sheet.items[1].buttons[1].enabled)
    Assert.is_true(sheet.items[1].buttons[2].enabled)
    Assert.is_false(sheet.items[2].buttons[1].enabled)
    Assert.is_true(sheet.items[2].buttons[2].enabled)
    sheet.items[1].buttons[2].callback()
    Assert.eq(moved[1], "down")
end

do -- 高度：当前项打勾；自定义走 Spin，按 10 步进、上限夹到 limit
    local applied = {}
    local function open(current)
        Edit.showHeightDialog({
            label = "时钟", range = { height = 90, limit = 400 }, current = current,
            on_apply = function(v) applied[#applied + 1] = v end,
        })
        return Themed.last("list")
    end
    local sheet = open("fill")
    Assert.eq(sheet.items[1].text, "默认高度")
    Assert.eq(sheet.items[2].text, "占满剩余")
    Assert.is_true(sheet.items[2].checked)
    Assert.eq(sheet.items[3].text, "自定义高度…")
    sheet.items[1].callback()
    Assert.eq(applied[1], "default")
    sheet.items[3].callback()
    local field = Themed.last("spin").fields[1]
    Assert.eq(field.value, 90, "未自定义从内容高起步")
    Assert.eq(field.max, 400)
    Assert.eq(field.step, 10)
    Themed.last("spin").callback(123.6)
    Assert.eq(applied[2], 123)
    sheet = open(150)
    Assert.eq(sheet.items[3].text, "自定义（150）")
    Assert.is_true(sheet.items[3].checked)
    sheet.items[3].callback()
    Assert.eq(Themed.last("spin").fields[1].value, 150)
end

do -- 添加：候选走居中分页列表（组件多时翻页，不溢出）
    local picked
    Edit.showAddDialog({ { id = "news", label = "热点新闻" }, { id = "stats", label = "阅读统计" } },
        function(id) picked = id end)
    local list = Themed.last("list")
    Assert.eq(list.title, "添加组件")
    Assert.is_true(list.centered)
    Assert.len(list.items, 2)
    Themed.choose(list, 2)
    Assert.eq(picked, "stats")
end

do -- 边距：四列 Spin，全 0 回调 nil
    local applied
    Edit.showMarginDialog({
        label = "时钟",
        current = { top = 10, right = 0, bottom = 5, left = 20 },
        on_apply = function(m) applied = m end,
    })
    local spin = Themed.last("spin")
    Assert.eq(spin.title, "时钟 · 边距")
    Assert.len(spin.fields, 4)
    Assert.eq(spin.fields[1].label, "上")
    Assert.eq(spin.fields[1].value, 10)
    Assert.eq(spin.fields[1].step, 5)
    Assert.eq(spin.fields[3].value, 5)
    spin.callback(10, 0, 5, 20)
    Assert.eq(applied.top, 10)
    Assert.eq(applied.right, 0)
    Assert.eq(applied.bottom, 5)
    Assert.eq(applied.left, 20)
    Edit.showMarginDialog({ current = nil, on_apply = function(m) applied = m end })
    Themed.last("spin").callback(0, 0, 0, 0)
    Assert.is_nil(applied)
end
