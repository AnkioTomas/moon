--[[--
快看腾讯滑块网页回归，使用本机 Node，不增加外部依赖。
@module tests.source.kuaikan.web_spec
--]]
local Assert = require("support.assert")
local root = require("support.config").root()
local pipe = assert(io.popen('node "' .. root .. '/tests/source/kuaikan/web_spec.js" "' .. root .. '" 2>&1'))
local output = pipe:read("*a")
pipe:close()
Assert.is_true(output:find("kuaikan web: OK", 1, true) ~= nil, output)
