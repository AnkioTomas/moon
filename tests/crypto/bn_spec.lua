--[[--
256 位模运算：加减、Montgomery 乘、逆。

@module tests.crypto.bn_spec
--]]

local Assert = require("support.assert")
local Hex = require("crypto.hex")
local Bn = require("crypto.bn")

local P = Hex.from_hex("FFFFFFFEFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF00000000FFFFFFFFFFFFFFFF")
local Fp = Bn.modulus(P)

local function be(n)
    local s = {}
    for _i = 1, 31 do s[_i] = "\0" end
    s[32] = string.char(n)
    return table.concat(s)
end

local function nbe(n)
    return Fp.import(be(n))
end

Assert.eq(Fp.export(nbe(7)), be(7))
Assert.eq(Fp.export(Fp.add(nbe(2), nbe(3))), be(5))
Assert.eq(Fp.export(Fp.add(Fp.sub(nbe(2), nbe(3)), nbe(3))), be(2))

local two, three = nbe(2), nbe(3)
Assert.eq(Fp.export(Fp.muln(two, three)), be(6))
Assert.eq(Fp.export(Fp.from_m(Fp.to_m(two))), be(2))
Assert.eq(Fp.export(Fp.muln(three, Fp.invn(three))), be(1))

local pm1 = Fp.sub(Fp.zero, Fp.one)
Assert.is_true(Fp.is_zero(Fp.add(pm1, Fp.one)))
Assert.errors(function() Fp.import(P) end, "out of range")
Assert.is_true(Fp.is_zero(Fp.import_reduce(P)))
Assert.eq(Fp.export(Fp.pow(nbe(2), "\3")), be(8))
Assert.eq(Fp.export(Fp.pow(nbe(2), "\1")), be(2))
Assert.eq(Fp.export(Fp.pow(nbe(5), "\0")), be(1))
