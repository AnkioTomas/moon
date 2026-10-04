--[[--
ui.themes.widgets.icon_picker：内置名字表、网格分页、翻到当前图标、选中样式、点选关窗回调、
搜索过滤（规范化、plain 匹配、无结果、留空恢复）、左右滑翻页。

@module tests.ui.themes.widgets.icon_picker_spec
--]]

local Assert = require("support.assert")
local Kit = require("support.widget_stubs")
Kit.install("paper")

local IconPicker = require("ui.themes.widgets.icon_picker")
local NAMES = require("ui.themes.widgets.icon.names")

-- 名字表：非空、唯一、升序（生成脚本的契约）。
Assert.is_true(#NAMES > 3000)
local seen = {}
for i, name in ipairs(NAMES) do
    Assert.is_true(name:match("^[a-z0-9_]+$") ~= nil, name)
    Assert.is_nil(seen[name], "重复：" .. name)
    seen[name] = true
    if i > 1 then Assert.is_true(NAMES[i - 1] < name) end
end
for _idx, name in ipairs({ "home", "search", "close", "settings", "book" }) do
    Assert.is_true(seen[name], name)
end

local function indexOf(name)
    for i, n in ipairs(NAMES) do
        if n == name then return i end
    end
end

-- paper：格子 96，600 宽 → 6 列、格宽 100；800 高减标题栏 57 与翻页条 40 → 7 行，每页 42 个。
local picked
local picker = IconPicker:new{ current = "home", on_select = function(name) picked = name end }
Assert.is_false(picker.mask, "全屏不画遮罩")
Assert.eq(picker.cols, 6)
Assert.eq(picker.cell_w, 100)
Assert.eq(picker.per_page, 42)
Assert.eq(picker:pages(), math.ceil(#NAMES / 42))
Assert.eq(picker.page, math.ceil(indexOf("home") / 42), "翻到当前图标所在页")
Assert.eq(picker[1]:getSize().h, 800)
local cells = Kit.taps(picker)
Assert.len(cells, 42)
local texts = Kit.texts(picker)
Assert.contains(texts, "选择图标")
Assert.contains(texts, "共 " .. #NAMES .. " 个")
Assert.contains(texts, "home")

-- 当前图标：取 selected 令牌，paper 的 mark = 2 在格底画 1/3 宽的 ink 指示条，其余格同位置画页面色。
local marks = Kit.find(picker, function(w) return w.dimen and w.dimen.w == 33 and w.dimen.h == 2 end)
Assert.len(marks, 42)
local inked = 0
for _idx, m in ipairs(marks) do
    if m.background == 0x00 then inked = inked + 1 end
end
Assert.eq(inked, 1)

-- 点一格：先关窗，再回调名字。
local slot = (indexOf("home") - 1) % 42 + 1
cells[slot]:onTapThemeArea()
Assert.eq(Kit.closed[#Kit.closed], picker)
Assert.eq(picked, "home")

-- 搜索：小写、去空白、空白当下划线；当前图标不在结果里回第 1 页。
picker = IconPicker:new{ current = "home" }
picker:search("  Arrow Back ")
Assert.eq(picker.query, "arrow_back")
Assert.eq(picker.page, 1)
Assert.is_true(#picker.names > 0)
for _idx, name in ipairs(picker.names) do
    Assert.is_true(name:find("arrow_back", 1, true) ~= nil, name)
end
Assert.contains(Kit.texts(picker), "「arrow_back」：" .. #picker.names .. " 个")
Assert.eq(Kit.dirty[#Kit.dirty].widget, picker)

-- plain 匹配：Lua 模式字符不报错、不误命中；无结果显示占位，单页不画翻页条。
picker:search("%a")
Assert.len(picker.names, 0)
Assert.eq(picker:pages(), 1)
Assert.contains(Kit.texts(picker), "没有匹配的图标")
Assert.len(Kit.taps(picker), 0)
Assert.len(Kit.find(picker, function(w) return w.icon == "chevron_left" end), 0)

-- 结果含当前图标时停在它所在页；留空恢复全部并回到当前页。
picker:search("hom")
Assert.contains(picker.names, "home")
local at
for i, name in ipairs(picker.names) do
    if name == "home" then at = i end
end
Assert.eq(picker.page, math.ceil(at / 42))
picker:search("")
Assert.eq(#picker.names, #NAMES)
Assert.eq(picker.page, math.ceil(indexOf("home") / 42))

-- 左键搜索：弹输入框，预填当前搜索词，确定后过滤。
picker:search("book")
picker:askQuery()
local input = Kit.shown[#Kit.shown]
Assert.eq(input.title, "搜索图标")
Assert.eq(input.fields[1].text, "book")
input.callback("menu_book")
Assert.eq(picker.query, "menu_book")
Assert.contains(picker.names, "menu_book")

-- 左右滑翻页，夹在范围内；上下滑不处理。
picker = IconPicker:new{}
Assert.eq(picker.page, 1)
Assert.is_true(picker:onSwipeIconPicker(nil, { direction = "west" }))
Assert.eq(picker.page, 2)
picker:onSwipeIconPicker(nil, { direction = "east" })
picker:onSwipeIconPicker(nil, { direction = "east" })
Assert.eq(picker.page, 1)
Assert.is_false(picker:onSwipeIconPicker(nil, { direction = "north" }))
picker:goPage(999)
Assert.eq(picker.page, picker:pages())
Assert.is_true(#Kit.taps(picker) >= 1)

return true
