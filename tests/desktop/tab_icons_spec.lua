--[[--
底栏自定义图标：记的文件不存在时回落字体图标。
@module tests.desktop.tab_icons_spec
--]]
local Assert = require("support.assert")
local Kit = require("support.widget_stubs")
Kit.install("paper")
local path = os.tmpname()
Kit.sections.desktop = { tab_icons = { home = path, store = "/nonexistent/x.png" } }

local TabIcons = require("desktop.tab_icons")

Assert.eq(TabIcons.file("home"), path)
Assert.is_nil(TabIcons.file("store"))
Assert.is_nil(TabIcons.file("library"))
os.remove(path)
