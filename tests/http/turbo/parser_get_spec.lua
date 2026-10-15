--[[--
HTTPParser:get 补丁：Android 上 turbo 的 strncasecmp 为 nil，大小写不敏感查询改走纯 Lua。
--]]
---@diagnostic disable: undefined-field, inject-field

local Assert = require("support.assert")
local ffi = require("ffi")

local function field(k, v)
    return { key = ffi.new("char[?]", #k + 1, k), key_sz = #k, value = ffi.new("char[?]", #v + 1, v), value_sz = #v }
end

local fields = { field("Content-Type", "text/plain"), field("Set-Cookie", "a=1"), field("set-cookie", "b=2") }
local hkv = setmetatable({}, { __index = function(_, i) return fields[i + 1] end })
local Parser = {}
-- 原实现模拟 strncasecmp 缺失：大小写不敏感分支直接炸。
function Parser:get(_, caseinsensitive)
    if caseinsensitive ~= false then error("attempt to call upvalue 'strncasecmp' (a nil value)") end
    return "orig"
end

local saved = { package.loaded["turbo.httputil"], package.loaded["http.turbo.patch"] }
package.loaded["turbo.httputil"] = { HTTPParser = Parser }
package.loaded["http.turbo.patch"] = nil
require("http.turbo.patch").apply()
package.loaded["turbo.httputil"], package.loaded["http.turbo.patch"] = saved[1], saved[2]

local headers = setmetatable({ tpw = { hkv = hkv, hkv_sz = #fields } }, { __index = Parser })
Assert.eq(headers:get("content-type", true), "text/plain")
Assert.eq(headers:get("CONTENT-TYPE"), "text/plain")
local cookies, n = headers:get("Set-Cookie", true)
Assert.eq(n, 2)
Assert.eq(cookies[1], "a=1")
Assert.eq(cookies[2], "b=2")
Assert.eq(headers:get("X-Missing", true), nil)
Assert.eq(headers:get("Content-Type", false), "orig")
Assert.eq(require("http.request").header({ headers = headers }, "content-length"), nil)
local all = require("http.request").headerAll({ headers = headers }, "set-cookie")
Assert.eq(#all, 2)
