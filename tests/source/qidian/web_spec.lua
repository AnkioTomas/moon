--[[-- 起点验证码网页回归，使用已有 Node。 @module tests.source.qidian.web_spec --]]
local Assert = require("support.assert")
local root = require("support.config").root()
local pipe = assert(io.popen('node "' .. root .. '/tests/source/qidian/web_spec.js" "' .. root .. '" 2>&1'))
local output = pipe:read("*a")
pipe:close()
Assert.is_true(output:find("qidian web: OK", 1, true) ~= nil, output)
