--[[--
ui.themes.widgets.path_picker：选文件夹 / 选文件两种模式、目录在前排序、隐藏项、过滤、
进出目录、根目录无回上一级、起始路径回落、当前文件选中。

@module tests.ui.themes.widgets.path_picker_spec
--]]

local Assert = require("support.assert")
local Config = require("support.config")
local Kit = require("support.widget_stubs")
Kit.install("paper")

local lfs = require("libs/libkoreader-lfs")
local PathPicker = require("ui.themes.widgets.path_picker")

local root = Config.dir() .. "/path_picker"
os.execute("rm -rf '" .. root .. "'")
for _idx, dir in ipairs({ "", "/beta", "/Alpha", "/Alpha/inner", "/.hidden" }) do
    Assert.is_true(lfs.mkdir(root .. dir))
end
for _idx, file in ipairs({ "/b.png", "/A.txt", "/c.png", "/.dot.png" }) do
    local f = assert(io.open(root .. file, "w"))
    f:write("x")
    f:close()
end

local function texts(picker)
    local out = {}
    for i, item in ipairs(picker.items) do out[i] = item.text end
    return out
end

-- 选文件夹：首项「选择此文件夹」，只列目录，不分大小写排序，隐藏目录不列。
local picked
local picker = PathPicker:new{ path = root .. "/", on_select = function(p) picked = p end }
Assert.eq(picker.path, root, "去掉尾斜杠")
Assert.eq(table.concat(texts(picker), "|"), "选择此文件夹|Alpha|beta")
Assert.eq(picker.items[1].mandatory, "path_picker")
local shown = Kit.texts(picker)
Assert.contains(shown, "选择文件夹")
Assert.contains(shown, root)
Assert.eq(picker.left_icon, "arrow_upward")

-- 点目录：不关窗、进入并刷新；回上一级。
local closed = #Kit.closed
picker:choose(picker.items[2])
Assert.eq(#Kit.closed, closed, "进目录不关窗")
Assert.eq(picker.path, root .. "/Alpha")
Assert.eq(table.concat(texts(picker), "|"), "选择此文件夹|inner")
Assert.contains(Kit.texts(picker), root .. "/Alpha")
Assert.eq(Kit.dirty[#Kit.dirty].widget, picker)
picker.left_callback()
Assert.eq(picker.path, root)

-- 选当前文件夹：先关窗再回调。
picker:choose(picker.items[1])
Assert.eq(Kit.closed[#Kit.closed], picker)
Assert.eq(picked, root)

-- 选文件：目录在前、文件在后，过滤只作用于文件；path 是文件时从所在目录开始并选中它。
picked = nil
picker = PathPicker:new{ path = root .. "/c.png", select_file = true,
    filter = function(name) return name:match("%.png$") ~= nil end,
    on_select = function(p) picked = p end }
Assert.eq(picker.path, root)
Assert.eq(table.concat(texts(picker), "|"), "Alpha|beta|b.png|c.png")
Assert.contains(Kit.texts(picker), "选择文件")
Assert.len(Kit.find(picker, function(w) return w.text == "radio_button_checked" end), 1, "当前文件选中")
picker:choose(picker.items[3])
Assert.eq(Kit.closed[#Kit.closed], picker)
Assert.eq(picked, root .. "/b.png")

-- 显示隐藏项；无过滤列全部文件。
picker = PathPicker:new{ path = root, select_file = true, show_hidden = true, on_select = function() end }
Assert.eq(table.concat(texts(picker), "|"), ".hidden|Alpha|beta|.dot.png|A.txt|b.png|c.png")

-- 图片文件挂缩略图代替图标，其余文件用文档图标。
local txt, png = picker.items[5], picker.items[6]
Assert.eq(txt.icon, "description")
Assert.is_nil(txt.image)
Assert.is_nil(png.icon)
Assert.eq(png.image, root .. "/b.png")
Assert.len(Kit.find(picker, function(w) return w.icon == "description" or w.text == "description" end), 1)

-- 不存在的路径逐级往上找到存在的目录。
picker = PathPicker:new{ path = root .. "/nope/deeper/x.png", on_select = function() end }
Assert.eq(picker.path, root)

-- 根目录：没有回上一级按钮。
picker = PathPicker:new{ path = "/", on_select = function() end }
Assert.eq(picker.path, "/")
Assert.is_nil(picker.left_icon)
Assert.is_nil(picker.left_callback)

os.execute("rm -rf '" .. root .. "'")
