--[[--
插件模块直达加载器：模块名 → 文件表、init.lua 优先于同名 .lua（覆盖解压残留的旧文件）、不抢 KOReader 的模块名。

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

-- 旧版 a.lua 残留、新版是 a/init.lua：不论目录扫描顺序都取目录版。
local tmp = os.tmpname()
os.remove(tmp)
os.execute("mkdir -p " .. tmp .. "/src/wechat")
for _idx, name in ipairs({ "/src/wechat.lua", "/src/wechat/init.lua" }) do
    local f = assert(io.open(tmp .. name, "w"))
    f:write("return {}\n")
    f:close()
end
Assert.eq(Modules.install(tmp)["src/wechat"], tmp .. "/src/wechat/init.lua", "目录模块压过残留的同名文件")
os.execute("rm -rf " .. tmp)
