--[[--
动作弹窗按实测高度分页：混合按钮行 / 正文 / 分组，小屏与锚点不越界，翻页保持面板高度与回调语义。

@module tests.ui.themes.widgets.sheet_spec
--]]

local Assert = require("support.assert")
local Kit = require("support.widget_stubs")
Kit.install("paper")

local Sheet = require("ui.themes.widgets.sheet")
local List = require("ui.themes.widgets.list")
local Box = require("ui.themes.widgets.box")
local Event = require("ui/event")
local calls = {}
local items = { { separator = true } }
local sheet
for i = 1, 25 do
    items[#items + 1] = {
        text = "动作" .. i, enabled = i ~= 25,
        callback = function()
            calls[#calls + 1] = { i, Kit.closed[#Kit.closed] == sheet }
        end,
    }
    if i % 4 == 0 then items[#items + 1] = { separator = true } end
end
items[#items + 1] = { widget = function(width)
    return Box:new{ style = {}, width = width, height = 100 }
end }
items[#items + 1] = { buttons = {
    { text = "复制", callback = function() calls[#calls + 1] = "copy" end },
    { text = "分享", callback = function() calls[#calls + 1] = "share" end },
} }
items[#items + 1] = { separator = true }

for _idx, theme in ipairs({ "paper", "soft", "bold" }) do
    Kit.use(theme)
    for _i, screen in ipairs({ { 600, 800 }, { 800, 400 }, { 320, 320 } }) do
        Kit.SCREEN_W, Kit.SCREEN_H = screen[1], screen[2]
        for _j, anchored in ipairs({ false, true }) do
            local anchor = anchored and { x = 20, y = screen[2] - 50, w = 40, h = 50 } or nil
            sheet = Sheet:new{ title = "操作", items = items, anchor = anchor }
            Assert.is_true(#sheet.pages > 1)
            local height = sheet[1]:getSize().h
            local found = {}
            for page = 1, #sheet.pages do
                sheet:goPage(page)
                Assert.eq(sheet[1]:getSize().h, height, "末页不跳动")
                Assert.is_true(sheet.panel_y >= 0)
                Assert.is_true(sheet.panel_y + height <= screen[2], "含阴影在屏内")
                if anchor then Assert.is_true(sheet.panel_y + height <= anchor.y) end
                for _k, button in ipairs(Kit.buttons(sheet)) do
                    if button.text then found[#found + 1] = button.text end
                end
            end
            Assert.len(found, 27, "每个动作恰好出现一次，多列按钮行不拆开")
            Assert.eq(found[1], "动作1")
            Assert.eq(found[25], "动作25")
            Assert.eq(found[26], "复制")
            Assert.eq(found[27], "分享")
        end
    end
end

Kit.use("paper")
Kit.SCREEN_W, Kit.SCREEN_H = 600, 800
sheet = Sheet:new{ title = "操作", items = items }
sheet:show()
local gesture = Kit.tap(1, 1)
gesture.ges, gesture.direction = "swipe", "west"
Assert.is_true(sheet:handleEvent(Event:new("Gesture", gesture)))
Assert.eq(sheet.page, 2)
sheet:handleEvent(Event:new("BookWindowPage", -1))
Assert.eq(sheet.page, 1)
Kit.buttons(sheet)[1]:onTapThemeButton()
Assert.eq(calls[1][1], 1)
Assert.is_true(calls[1][2], "跨页仍然先关窗再执行")

sheet = Sheet:new{ items = items }
for page = 1, #sheet.pages do
    sheet:goPage(page)
    for _idx, button in ipairs(Kit.buttons(sheet)) do
        if button.text == "动作25" then button:onTapThemeButton() end
        if button.text == "分享" then button:onTapThemeButton() end
    end
end
Assert.len(calls, 2, "禁用项不执行")
Assert.eq(calls[2], "share", "多列按钮行保持各自回调")

-- 屏幕旋转时重算每页容量，而不是把旧的超高面板重新居中。
sheet = Sheet:new{ title = "操作", items = items }
local list = List:new{ title = "添加组件", centered = true, items = items }
local before = #sheet.pages
local per_page = list.per_page
sheet:goPage(before)
list:goPage(list:pages())
Kit.SCREEN_W, Kit.SCREEN_H = 800, 400
sheet:relayout()
list:relayout()
Assert.is_true(#sheet.pages > before)
Assert.is_true(list.per_page < per_page)
Assert.is_true(sheet.panel_y >= 0 and sheet.panel_y + sheet[1]:getSize().h <= 400)
Assert.is_true(list.panel_y >= 0 and list.panel_y + list[1]:getSize().h <= 400)
Kit.SCREEN_W, Kit.SCREEN_H = 600, 800
sheet:relayout()
list:relayout()
Assert.is_true(sheet.page <= #sheet.pages)
Assert.is_true(list.page <= list:pages())

sheet = Sheet:new{ items = { { separator = true }, { text = "关闭" }, { separator = true } } }
Assert.len(sheet.pages, 1)
Assert.len(Kit.buttons(sheet), 1, "单页没有翻页按钮")
Assert.len(sheet.pages[1], 1, "页首尾不留分隔空白")
sheet = Sheet:new{ items = {} }
Assert.len(sheet.pages, 1)
Assert.len(Kit.buttons(sheet), 0)

return true
