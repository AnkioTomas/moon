--[[--
浏览器脚本回归：有 Node 时运行真实 JS，无 npm 依赖。
@module tests.features.remote.web_spec
--]]
local Assert = require("support.assert")
if os.execute("command -v node >/dev/null 2>&1") ~= 0 then
    Assert.skip("需要 Node 运行网页脚本回归")
end
local root = require("support.config").root()
local pipe = assert(io.popen('node "' .. root .. '/tests/features/remote/web_spec.js" "' .. root .. '" 2>&1'))
local output = pipe:read("*a")
pipe:close()
Assert.is_true(output:find("remote web: OK", 1, true) ~= nil, output)
