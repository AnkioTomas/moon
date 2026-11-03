--[[--
Patch.hasIPv6：UDP 路由探测，本机走不了 IPv6（内核关闭、没地址、没路由）就不连 AAAA。
--]]
---@diagnostic disable: undefined-field, inject-field

local Assert = require("support.assert")
local Patch = require("http.turbo.patch")

local real = package.loaded["socket"]

local function stub(udp6)
    package.loaded["socket"] = { udp6 = udp6 }
end

local closed = 0
local function udp(result)
    return {
        setpeername = function() return result end,
        close = function() closed = closed + 1 end,
    }
end

stub(function() return udp(1) end)
Assert.eq(Patch.hasIPv6(), true)
stub(function() return udp(nil, "Cannot assign requested address") end)
Assert.eq(Patch.hasIPv6(), false)
Assert.eq(closed, 2)
stub(function() return nil, "Address family not supported" end)
Assert.eq(Patch.hasIPv6(), false)
package.loaded["socket"] = {}
Assert.eq(Patch.hasIPv6(), true)
package.loaded["socket"] = real
