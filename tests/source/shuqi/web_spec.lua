--[[--
书旗滑块页的登录环境初始化与失败反馈，不依赖 npm。
@module tests.source.shuqi.web_spec
--]]
local Assert = require("support.assert")
local status = os.execute("command -v node >/dev/null 2>&1")
if status ~= 0 and status ~= true then Assert.skip("需要 Node 运行网页脚本回归") end
local root = require("support.config").root()
local pipe = assert(io.popen('node "' .. root .. '/tests/source/shuqi/web_spec.js" "' .. root .. '" 2>&1'))
local output = pipe:read("*a")
pipe:close()
Assert.is_true(output:find("shuqi web: OK", 1, true) ~= nil, output)
