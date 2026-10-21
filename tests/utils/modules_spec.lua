--[[--
插件模块直达加载器：模块名 → 文件表、.lua 优先于 init.lua、不抢 KOReader 的模块名。

@module tests.utils.modules_spec
--]]

local Assert = require("support.assert")
local Modules = require("utils.modules")

local root = "book.koplugin"
local index = Modules.install(root)

Assert.eq(index["utils/modules"], root .. "/utils/modules.lua", "普通模块")
Assert.eq(index["desktop"], root .. "/desktop/init.lua", "目录模块走 init.lua")
Assert.is_nil(index.main, "入口 main 不登记")
Assert.is_nil(index["ui/widget/button"], "KOReader 自己的模块不登记")

local loader = package.loaders[2]
Assert.is_nil(loader("ui.widget.button"), "不认识的模块交回标准搜索")
Assert.eq(type(loader("utils.modules")().install), "function", "点号写法直达加载")
