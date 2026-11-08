--[[--
知乎独立验证网页回归，无 npm 依赖。
@module tests.source.zhihu.web_spec
--]]
local Assert = require("support.assert")
local status = os.execute("command -v node >/dev/null 2>&1")
if status ~= 0 and status ~= true then Assert.skip("需要 Node 运行网页脚本回归") end
local root = require("support.config").root()
local pipe = assert(io.popen('node "' .. root .. '/tests/source/zhihu/web_spec.js" "' .. root .. '" 2>&1'))
local output = pipe:read("*a")
pipe:close()
Assert.is_true(output:find("zhihu web: OK", 1, true) ~= nil, output)
