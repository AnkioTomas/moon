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
Assert.is_nil(loader("utils.modules"), "插件目录之外发起的 require 不劫持：别的 koplugin 撞名的 utils/ 要拿自己的")

-- 旧版 a.lua 残留、新版是 a/init.lua：不论目录扫描顺序都取目录版。
local tmp = os.tmpname()
os.remove(tmp)
local other = os.tmpname()
os.remove(other)
os.execute("mkdir -p " .. tmp .. "/src/wechat " .. other)
local function writeFile(path, body)
    local f = assert(io.open(path, "w"))
    f:write(body, "\n")
    f:close()
end
writeFile(tmp .. "/src/wechat.lua", "return { from = 'stale' }")
writeFile(tmp .. "/src/wechat/init.lua", "return { from = 'init' }")
-- 不写 `return require(...)`：尾调用会抹掉发起方的栈帧，加载器就看不到是谁在 require。
writeFile(tmp .. "/caller.lua", "local m = require('src.wechat') return m")
writeFile(other .. "/caller.lua", "local m = require('src.wechat') return m")
Assert.eq(Modules.install(tmp)["src/wechat"], tmp .. "/src/wechat/init.lua", "目录模块压过残留的同名文件")

-- 插件目录内文件发起的 require 直达；目录外（另一个插件）的走标准搜索，这里 package.path 找不到即报错。
package.loaded["src.wechat"] = nil
Assert.eq(dofile(tmp .. "/caller.lua").from, "init", "点号写法直达加载")
package.loaded["src.wechat"] = nil
Assert.errors(function() dofile(other .. "/caller.lua") end, "src.wechat")
package.loaded["src.wechat"] = nil
os.execute("rm -rf " .. tmp .. " " .. other)
