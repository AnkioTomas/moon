--[[--
安全随机数：系统熵源、缺失 / 短读时的 libcrypto 后备、失败显式传播。

@module tests.utils.random_spec
--]]
---@diagnostic disable: inject-field, assign-type-mismatch, undefined-field
local Assert = require("support.assert")
local Random = require("utils.random")
Assert.eq(#Random.bytes(24), 24)
local hex = Random.hex(24)
Assert.eq(#hex, 48)
Assert.matches(hex, "^%x+$")
Assert.eq(Random.bytes(0), "")
Assert.errors(function() Random.bytes(-1) end)
Assert.errors(function() Random.bytes(1.5) end)

local ffi = require("ffi")
local old_open, old_loadlib = io.open, ffi.loadlib
local loads, closed, result = 0, 0, 1
ffi.loadlib = function(name, version)
    Assert.eq(name, "crypto")
    Assert.eq(version, "57")
    loads = loads + 1
    return { RAND_bytes = function(buffer, n)
        ffi.copy(buffer, string.rep("\255", n), n)
        return result
    end }
end
local short = false
io.open = function(path, mode)
    if path ~= "/dev/urandom" then return old_open(path, mode) end
    if not short then return nil, "unavailable" end
    return { read = function() return "x" end, close = function() closed = closed + 1 end }
end
local ok, err = pcall(function()
    Assert.eq(Random.bytes(4), "\255\255\255\255")
    short = true
    Assert.eq(Random.hex(4), "ffffffff")
    Assert.eq(closed, 1, "短读也关闭熵源文件")
    Assert.eq(loads, 1, "缓存库句柄，不重复加载")
    result = 0
    Assert.errors(function() Random.bytes(4) end, "secure generator failed")
end)
io.open, ffi.loadlib = old_open, old_loadlib
if not ok then error(err) end
