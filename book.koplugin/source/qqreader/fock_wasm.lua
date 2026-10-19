-- 由 tools/gen_fock.js 从起点 / QQ阅读的 Fock（wasm2js）转译生成，勿手改。
-- 运行环境见同目录 fock.lua；env = { mem = ffi uint8_t*, imp = { b, c, d, e, f, abort } }。
local bit = require("bit")
local ffi = require("ffi")
local tobit, band, bor, bxor, bnot = bit.tobit, bit.band, bit.bor, bit.bxor, bit.bnot
local lshift, rshift, arshift = bit.lshift, bit.rshift, bit.arshift
local fmod = math.fmod

local function toint(x)
    return tobit(x >= 0 and math.floor(x) or -math.floor(-x))
end

local function imul(a, b)
    a, b = tobit(a), tobit(b)
    return tobit(band(a, 65535) * b + lshift(tobit(rshift(a, 16) * b), 16))
end

local function clz32(x)
    x = tobit(x)
    if x == 0 then return 32 end
    if x < 0 then return 0 end
    local n = 0
    while x > 0 do x = lshift(x, 1); n = n + 1 end
    return n
end

return function(env)
local mem = env.mem
local abort, imp_b, imp_c, imp_d, imp_e, imp_f = env.imp.abort, env.imp.b, env.imp.c, env.imp.d, env.imp.e, env.imp.f
local I8, I16, I32 = ffi.cast("int8_t*", mem), ffi.cast("int16_t*", mem), ffi.cast("int32_t*", mem)
local U8, U16, U32 = ffi.cast("uint8_t*", mem), ffi.cast("uint16_t*", mem), ffi.cast("uint32_t*", mem)
local F64 = ffi.cast("double*", mem)
local B, Iv = 5274112, 0
local scratch = ffi.new("int32_t[4]")
local scratch_f = ffi.cast("double*", scratch)
local function rf_a(i) return scratch[i] end
local function rf_u(i, v) scratch[i] = v end
local function rf_c() return scratch_f[0] end
local function rf_s(v) scratch_f[0] = v end
local F = {}
local UA = { [0] = false }
local YA = UA

F.fI = function(v_A)
local v_r, v_n, v_t, v_e, v_o, v_a, v_u, v_c, v_s, v_l, v_v, v_g = 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
v_n = 0
v_t = 0
v_e = 0
v_o = 0
v_a = 0
v_u = 0
v_c = 0
v_s = 0
v_l = 0
v_v = 0
v_g = 0
v_r = tobit((B - 16))
B = v_r
do
do
do
do
do
do
do
do
do
do
do
do
do
do
do
do
do
do
do
do
do
do
do
do
do
do
do
do
do
do
do
do
do
do
do
do
do
v_A = tobit(v_A)
if ((tobit(v_A) % 4294967296) <= 244) then
do
do
v_a = I32[5461]
local t1 = v_a
v_s = (((tobit(v_A) % 4294967296) < 11) and 16 or band((v_A + 11), (-8)))
v_t = tobit((rshift(v_s, 3) % 4294967296))
v_n = tobit((rshift(t1, v_t) % 4294967296))
if (band(3, v_n) ~= 0) then
do
do
v_e = tobit((v_t + band(1, bxor((-1), v_n))))
v_n = lshift(v_e, 3)
v_o = I32[arshift((21892 + v_n), 2)]
v_A = tobit((v_o + 8))
v_t = I32[arshift((v_o + 8), 2)]
local t2 = bor(0, v_t)
v_n = tobit((v_n + 21884))
if (t2 ~= bor(0, v_n)) then
I32[arshift((v_t + 12), 2)] = tobit(v_n)
I32[arshift((v_n + 8), 2)] = tobit(v_t)
else
I32[5461] = tobit(band(F.fSA((-2), v_e), v_a))
end
v_n = lshift(v_e, 3)
I32[arshift((v_o + 4), 2)] = tobit(bor(3, v_n))
v_n = tobit((v_n + v_o))
I32[arshift((4 + v_n), 2)] = tobit(bor(1, I32[arshift((v_n + 4), 2)]))
end
goto L1
end
end
end
v_v = I32[5463]
if ((tobit(v_v) % 4294967296) >= (tobit(v_s) % 4294967296)) then
goto L12
end
do
if (v_n ~= 0) then
do
do
v_A = lshift(2, v_t)
v_A = band(bor((0 - v_A), v_A), lshift(v_n, v_t))
v_n = tobit((band((0 - v_A), v_A) - 1))
v_A = band((rshift(v_n, 12) % 4294967296), 16)
v_t = v_A
local t3 = v_t
v_n = tobit((rshift(v_n, v_A) % 4294967296))
v_A = band((rshift(v_n, 5) % 4294967296), 8)
v_t = bor(t3, v_A)
local t4 = v_t
v_n = tobit((rshift(v_n, v_A) % 4294967296))
v_A = band((rshift(v_n, 2) % 4294967296), 4)
v_t = bor(t4, v_A)
local t5 = v_t
v_n = tobit((rshift(v_n, v_A) % 4294967296))
v_A = band((rshift(v_n, 1) % 4294967296), 2)
v_t = bor(t5, v_A)
local t6 = v_t
v_n = tobit((rshift(v_n, v_A) % 4294967296))
v_A = band((rshift(v_n, 1) % 4294967296), 1)
v_t = tobit((bor(t6, v_A) + tobit((rshift(v_n, v_A) % 4294967296))))
v_A = lshift(v_t, 3)
v_u = I32[arshift((21892 + v_A), 2)]
v_n = I32[arshift((v_u + 8), 2)]
local t7 = bor(0, v_n)
v_A = tobit((v_A + 21884))
if (t7 ~= bor(0, v_A)) then
I32[arshift((v_n + 12), 2)] = tobit(v_A)
I32[arshift((v_A + 8), 2)] = tobit(v_n)
else
v_a = band(F.fSA((-2), v_t), v_a)
I32[5461] = tobit(v_a)
end
v_A = tobit((v_u + 8))
I32[arshift((v_u + 4), 2)] = tobit(bor(3, v_s))
v_n = lshift(v_t, 3)
v_o = tobit((v_n - v_s))
v_e = tobit((v_u + v_s))
I32[arshift((4 + v_e), 2)] = tobit(bor(1, v_o))
I32[arshift((v_n + v_u), 2)] = tobit(v_o)
if (v_v ~= 0) then
v_n = tobit((rshift(v_v, 3) % 4294967296))
v_t = tobit((21884 + lshift(v_n, 3)))
v_u = I32[5466]
v_n = lshift(1, v_n)
if (band(v_n, v_a) ~= 0) then
v_n = I32[arshift((v_t + 8), 2)]
else
I32[5461] = tobit(bor(v_n, v_a))
v_n = v_t
end
I32[arshift((v_t + 8), 2)] = tobit(v_u)
I32[arshift((v_n + 12), 2)] = tobit(v_u)
I32[arshift((v_u + 12), 2)] = tobit(v_t)
I32[arshift((v_u + 8), 2)] = tobit(v_n)
end
I32[5466] = tobit(v_e)
I32[5463] = tobit(v_o)
end
goto L1
end
end
end
v_c = I32[5462]
if (not (v_c ~= 0)) then
goto L12
end
do
do
do
v_n = tobit((band(v_c, (0 - v_c)) - 1))
v_A = band((rshift(v_n, 12) % 4294967296), 16)
v_t = v_A
local t8 = v_t
v_n = tobit((rshift(v_n, v_A) % 4294967296))
v_A = band((rshift(v_n, 5) % 4294967296), 8)
v_t = bor(t8, v_A)
local t9 = v_t
v_n = tobit((rshift(v_n, v_A) % 4294967296))
v_A = band((rshift(v_n, 2) % 4294967296), 4)
v_t = bor(t9, v_A)
local t10 = v_t
v_n = tobit((rshift(v_n, v_A) % 4294967296))
v_A = band((rshift(v_n, 1) % 4294967296), 2)
v_t = bor(t10, v_A)
local t11 = v_t
v_n = tobit((rshift(v_n, v_A) % 4294967296))
v_A = band((rshift(v_n, 1) % 4294967296), 1)
v_n = I32[arshift((22148 + lshift((bor(t11, v_A) + tobit((rshift(v_n, v_A) % 4294967296))), 2)), 2)]
v_e = tobit((band((-8), I32[arshift((v_n + 4), 2)]) - v_s))
v_t = v_n
end
while true do
do
v_A = I32[arshift((v_t + 16), 2)]
local t12 = (v_A ~= 0)
if not t12 then
v_A = I32[arshift((v_t + 20), 2)]
t12 = (v_A ~= 0)
end
if not t12 then goto B13 end
end
do
v_t = tobit((band((-8), I32[arshift((v_A + 4), 2)]) - v_s))
v_o = (((tobit(v_t) % 4294967296) < (tobit(v_e) % 4294967296)) and 1 or 0)
v_e = ((v_o ~= 0) and v_t or v_e)
v_n = ((v_o ~= 0) and v_A or v_n)
v_t = v_A
end
::C13::
end
end
::B13::
end
v_l = tobit((v_n + v_s))
if ((tobit(v_l) % 4294967296) <= (tobit(v_n) % 4294967296)) then
goto L11
end
v_g = I32[arshift((v_n + 24), 2)]
v_o = I32[arshift((v_n + 12), 2)]
if (bor(0, v_o) ~= bor(0, v_n)) then
v_A = I32[arshift((v_n + 8), 2)]
I32[arshift((v_A + 12), 2)] = tobit(v_o)
I32[arshift((v_o + 8), 2)] = tobit(v_A)
goto L2
end
v_t = tobit((v_n + 20))
v_A = I32[arshift(v_t, 2)]
if (not (v_A ~= 0)) then
v_A = I32[arshift((v_n + 16), 2)]
if (not (v_A ~= 0)) then
goto L10
end
v_t = tobit((v_n + 16))
end
do
do
while true do
do
v_u = v_t
v_o = v_A
v_t = tobit((v_A + 20))
v_A = I32[arshift(v_t, 2)]
local t13 = v_A
if t13 == 0 then
v_t = tobit((v_o + 16))
v_A = I32[arshift((v_o + 16), 2)]
t13 = v_A
end
if not (t13 ~= 0) then goto B14 end
end
do
end
::C14::
end
end
::B14::
end
I32[arshift(v_u, 2)] = tobit(0)
goto L2
end
end
end
do
v_s = (-1)
local t14 = ((not ((tobit(v_A) % 4294967296) > 4294967231)) and 1 or 0)
if t14 ~= 0 then
local t15 = (-8)
v_A = tobit((v_A + 11))
v_s = band(t15, v_A)
v_l = I32[5462]
t14 = v_l
end
if (t14 ~= 0) then
do
do
v_e = tobit((0 - v_s))
v_a = 0
if not ((tobit(v_s) % 4294967296) < 256) then
v_a = 31
if not ((tobit(v_s) % 4294967296) > 16777215) then
v_A = tobit((rshift(v_A, 8) % 4294967296))
local t16 = v_A
v_u = band((rshift((v_A + 1048320), 16) % 4294967296), 8)
v_A = lshift(t16, v_u)
local t17 = v_A
v_t = band((rshift((v_A + 520192), 16) % 4294967296), 4)
v_A = lshift(t17, v_t)
local t18 = v_A
v_n = band((rshift((v_A + 245760), 16) % 4294967296), 2)
v_A = tobit((tobit((rshift(lshift(t18, v_n), 15) % 4294967296)) - bor(bor(v_n, v_t), v_u)))
v_a = tobit((28 + bor(lshift(v_A, 1), band((rshift(v_s, (v_A + 21)) % 4294967296), 1))))
end
end
end
do
do
do
do
do
do
do
v_t = I32[arshift((22148 + lshift(v_a, 2)), 2)]
if (v_t ~= 0) then
do
do
v_A = 0
v_n = lshift(v_s, ((31 == bor(0, v_a)) and 0 or tobit((25 - tobit((rshift(v_a, 1) % 4294967296))))))
while true do
do
do
do
v_u = tobit((band((-8), I32[arshift((v_t + 4), 2)]) - v_s))
local t19 = (((tobit(v_u) % 4294967296) >= (tobit(v_e) % 4294967296)) and 1 or 0)
if t19 == 0 then
v_o = v_t
v_e = v_u
t19 = v_e
end
if (not (t19 ~= 0)) then
v_e = 0
v_A = v_t
goto L16
end
end
v_u = I32[arshift((v_t + 20), 2)]
v_t = I32[arshift((16 + tobit((band((rshift(v_n, 29) % 4294967296), 4) + v_t))), 2)]
v_A = ((v_u ~= 0) and ((bor(0, v_u) == bor(0, v_t)) and v_A or v_u) or v_A)
v_n = lshift(v_n, 1)
if (not (v_t ~= 0)) then
goto B17
end
end
end
::C17::
end
end
::B17::
end
else
v_A = 0
end
end
do
if (not (bor(v_A, v_o) ~= 0)) then
do
v_o = 0
v_A = lshift(2, v_a)
v_A = band(bor((0 - v_A), v_A), v_l)
if (not (v_A ~= 0)) then
goto L12
end
do
v_n = tobit((band(v_A, (0 - v_A)) - 1))
v_A = band((rshift(v_n, 12) % 4294967296), 16)
v_t = v_A
local t20 = v_t
v_n = tobit((rshift(v_n, v_A) % 4294967296))
v_A = band((rshift(v_n, 5) % 4294967296), 8)
v_t = bor(t20, v_A)
local t21 = v_t
v_n = tobit((rshift(v_n, v_A) % 4294967296))
v_A = band((rshift(v_n, 2) % 4294967296), 4)
v_t = bor(t21, v_A)
local t22 = v_t
v_n = tobit((rshift(v_n, v_A) % 4294967296))
v_A = band((rshift(v_n, 1) % 4294967296), 2)
v_t = bor(t22, v_A)
local t23 = v_t
v_n = tobit((rshift(v_n, v_A) % 4294967296))
v_A = band((rshift(v_n, 1) % 4294967296), 1)
v_A = I32[arshift((22148 + lshift((bor(t23, v_A) + tobit((rshift(v_n, v_A) % 4294967296))), 2)), 2)]
end
end
end
end
if (not (v_A ~= 0)) then
goto L15
end
end
end
::L16::
end
do
do
while true do
do
v_n = tobit((band((-8), I32[arshift((v_A + 4), 2)]) - v_s))
v_t = (((tobit(v_n) % 4294967296) < (tobit(v_e) % 4294967296)) and 1 or 0)
v_e = ((v_t ~= 0) and v_n or v_e)
v_o = ((v_t ~= 0) and v_A or v_o)
v_n = I32[arshift((v_A + 16), 2)]
local t24 = v_n
if t24 == 0 then
t24 = I32[arshift((v_A + 20), 2)]
end
v_A = t24
if not (v_A ~= 0) then goto B18 end
end
do
end
::C18::
end
end
::B18::
end
end
end
::L15::
end
do
if (not (bor(((not (v_o ~= 0)) and 1 or 0), (((tobit((I32[5463] - v_s)) % 4294967296) <= (tobit(v_e) % 4294967296)) and 1 or 0)) ~= 0)) then
do
v_c = tobit((v_o + v_s))
if ((tobit(v_c) % 4294967296) <= (tobit(v_o) % 4294967296)) then
goto L11
end
do
v_a = I32[arshift((v_o + 24), 2)]
local t25 = bor(0, v_o)
v_n = I32[arshift((v_o + 12), 2)]
if (t25 ~= bor(0, v_n)) then
v_A = I32[arshift((v_o + 8), 2)]
I32[arshift((v_A + 12), 2)] = tobit(v_n)
I32[arshift((v_n + 8), 2)] = tobit(v_A)
goto L3
end
end
v_t = tobit((v_o + 20))
v_A = I32[arshift(v_t, 2)]
if (not (v_A ~= 0)) then
v_A = I32[arshift((v_o + 16), 2)]
if (not (v_A ~= 0)) then
goto L9
end
v_t = tobit((v_o + 16))
end
do
do
while true do
do
v_u = v_t
v_n = v_A
v_t = tobit((v_A + 20))
v_A = I32[arshift(v_t, 2)]
local t26 = v_A
if t26 == 0 then
v_t = tobit((v_n + 16))
v_A = I32[arshift((v_n + 16), 2)]
t26 = v_A
end
if not (t26 ~= 0) then goto B19 end
end
do
end
::C19::
end
end
::B19::
end
I32[arshift(v_u, 2)] = tobit(0)
goto L3
end
end
end
end
end
end
end
end
::L12::
end
v_t = I32[5463]
if ((tobit(v_t) % 4294967296) >= (tobit(v_s) % 4294967296)) then
v_e = I32[5466]
v_n = tobit((v_t - v_s))
if ((tobit(v_n) % 4294967296) >= 16) then
I32[5463] = tobit(v_n)
v_A = tobit((v_e + v_s))
I32[5466] = tobit(v_A)
I32[arshift((v_A + 4), 2)] = tobit(bor(1, v_n))
I32[arshift((v_t + v_e), 2)] = tobit(v_n)
I32[arshift((v_e + 4), 2)] = tobit(bor(3, v_s))
else
I32[5466] = tobit(0)
I32[5463] = tobit(0)
I32[arshift((v_e + 4), 2)] = tobit(bor(3, v_t))
v_A = tobit((v_t + v_e))
I32[arshift((4 + v_A), 2)] = tobit(bor(1, I32[arshift((v_A + 4), 2)]))
end
v_A = tobit((v_e + 8))
goto L1
end
v_c = I32[5464]
if ((tobit(v_c) % 4294967296) > (tobit(v_s) % 4294967296)) then
v_n = tobit((v_c - v_s))
I32[5464] = tobit(v_n)
v_t = I32[5467]
v_A = tobit((v_t + v_s))
I32[5467] = tobit(v_A)
I32[arshift((v_A + 4), 2)] = tobit(bor(1, v_n))
I32[arshift((v_t + 4), 2)] = tobit(bor(3, v_s))
v_A = tobit((v_t + 8))
goto L1
end
do
v_A = 0
v_l = tobit((v_s + 47))
v_n = v_l
if (I32[5579] ~= 0) then
v_t = I32[5581]
else
I32[5582] = tobit((-1))
I32[5583] = tobit((-1))
I32[5580] = tobit(4096)
I32[5581] = tobit(4096)
I32[5579] = tobit(bxor(band((v_r + 12), (-16)), 1431655768))
I32[5584] = tobit(0)
I32[5572] = tobit(0)
v_t = 4096
end
v_u = tobit((v_n + v_t))
local t27 = v_u
v_o = tobit((0 - v_t))
v_t = band(t27, v_o)
if ((tobit(v_t) % 4294967296) <= (tobit(v_s) % 4294967296)) then
goto L1
end
end
do
v_e = I32[5571]
local t29 = (v_e ~= 0)
if t29 then
local t28 = (tobit(v_e) % 4294967296)
v_n = I32[5569]
v_a = tobit((v_n + v_t))
t29 = (bor(((t28 < (tobit(v_a) % 4294967296)) and 1 or 0), (((tobit(v_n) % 4294967296) >= (tobit(v_a) % 4294967296)) and 1 or 0)) ~= 0)
end
if t29 then
goto L1
end
end
if (band(4, U8[22288]) ~= 0) then
goto L6
end
do
do
do
do
do
do
do
v_e = I32[5467]
if (v_e ~= 0) then
do
do
v_A = 22292
while true do
do
do
do
local t30 = (tobit(v_e) % 4294967296)
v_n = I32[arshift(v_A, 2)]
if ((t30 < (tobit((v_n + I32[arshift((v_A + 4), 2)])) % 4294967296)) and ((tobit(v_n) % 4294967296) <= (tobit(v_e) % 4294967296))) then
goto L21
end
end
v_A = I32[arshift((v_A + 8), 2)]
if (not (v_A ~= 0)) then
goto B22
end
end
end
::C22::
end
end
::B22::
end
end
end
do
local t31 = (-1)
v_n = F.fwA(0)
if (t31 == bor(0, v_n)) then
goto L7
end
end
v_a = v_t
v_e = I32[5580]
v_A = tobit((v_e - 1))
if (band(v_A, v_n) ~= 0) then
v_a = tobit((tobit((v_t - v_n)) + band((v_A + v_n), (0 - v_e))))
end
if (bor((((tobit(v_a) % 4294967296) <= (tobit(v_s) % 4294967296)) and 1 or 0), (((tobit(v_a) % 4294967296) > 2147483646) and 1 or 0)) ~= 0) then
goto L7
end
do
v_e = I32[5571]
local t33 = (v_e ~= 0)
if t33 then
local t32 = (tobit(v_e) % 4294967296)
v_A = I32[5569]
v_o = tobit((v_A + v_a))
t33 = (bor(((t32 < (tobit(v_o) % 4294967296)) and 1 or 0), (((tobit(v_A) % 4294967296) >= (tobit(v_o) % 4294967296)) and 1 or 0)) ~= 0)
end
if t33 then
goto L7
end
end
do
local t34 = bor(0, v_n)
v_A = F.fwA(v_a)
if (t34 ~= bor(0, v_A)) then
goto L20
end
end
goto L5
end
end
::L21::
end
v_a = band(v_o, (v_u - v_c))
if ((tobit(v_a) % 4294967296) > 2147483646) then
goto L7
end
v_n = F.fwA(v_a)
if (bor(0, v_n) == tobit((I32[arshift(v_A, 2)] + I32[arshift((v_A + 4), 2)]))) then
goto L8
end
v_A = v_n
end
end
::L20::
end
if (not (bor((((-1) == bor(0, v_A)) and 1 or 0), (((tobit((v_s + 48)) % 4294967296) <= (tobit(v_a) % 4294967296)) and 1 or 0)) ~= 0)) then
v_n = I32[5581]
v_n = band((v_n + tobit((v_l - v_a))), (0 - v_n))
if ((tobit(v_n) % 4294967296) > 2147483646) then
v_n = v_A
goto L5
end
if ((-1) ~= bor(0, F.fwA(v_n))) then
v_a = tobit((v_n + v_a))
v_n = v_A
goto L5
end
F.fwA(tobit((0 - v_a)))
goto L7
end
v_n = v_A
if ((-1) ~= bor(0, v_A)) then
goto L5
end
goto L7
end
end
::L11::
end
abort()
end
end
::L10::
end
v_o = 0
goto L2
end
end
::L9::
end
v_n = 0
goto L3
end
end
::L8::
end
if ((-1) ~= bor(0, v_n)) then
goto L5
end
end
end
::L7::
end
I32[5572] = tobit(bor(4, I32[5572]))
end
end
::L6::
end
if ((tobit(v_t) % 4294967296) > 2147483646) then
goto L4
end
do
local t35 = (-1)
v_n = F.fwA(v_t)
local t37 = (t35 == bor(0, v_n))
local t36 = (-1)
v_A = F.fwA(0)
if (bor(bor((t37 and 1 or 0), ((t36 == bor(0, v_A)) and 1 or 0)), (((tobit(v_A) % 4294967296) <= (tobit(v_n) % 4294967296)) and 1 or 0)) ~= 0) then
goto L4
end
end
v_a = tobit((v_A - v_n))
if ((tobit(v_a) % 4294967296) <= (tobit((v_s + 40)) % 4294967296)) then
goto L4
end
end
end
::L5::
end
v_A = tobit((I32[5569] + v_a))
I32[5569] = tobit(v_A)
if ((tobit(v_A) % 4294967296) > U32[5570]) then
I32[5570] = tobit(v_A)
end
do
do
do
do
do
do
do
do
do
do
v_u = I32[5467]
if (v_u ~= 0) then
do
do
do
v_A = 22292
while true do
do
do
do
v_e = I32[arshift(v_A, 2)]
local t38 = v_e
v_t = I32[arshift((v_A + 4), 2)]
if (tobit((t38 + v_t)) == bor(0, v_n)) then
goto L25
end
end
v_A = I32[arshift((v_A + 8), 2)]
if (not (v_A ~= 0)) then
goto B26
end
end
end
::C26::
end
end
::B26::
end
goto L24
end
end
end
do
v_A = I32[5465]
if not (((tobit(v_A) % 4294967296) <= (tobit(v_n) % 4294967296)) and (v_A ~= 0)) then
I32[5465] = tobit(v_n)
end
v_A = 0
I32[5574] = tobit(v_a)
I32[5573] = tobit(v_n)
I32[5469] = tobit((-1))
I32[5470] = tobit(I32[5579])
I32[5576] = tobit(0)
while true do
v_e = lshift(v_A, 3)
v_t = tobit((21884 + v_e))
I32[arshift((v_e + 21892), 2)] = tobit(v_t)
I32[arshift((v_e + 21896), 2)] = tobit(v_t)
v_A = tobit((v_A + 1))
if not (32 ~= bor(0, v_A)) then goto B27 end
do
end
::C27::
end
end
::B27::
do
v_e = tobit((v_a - 40))
local t39 = v_e
v_A = ((band((v_n + 8), 7) ~= 0) and band(((-8) - v_n), 7) or 0)
v_t = tobit((t39 - v_A))
I32[5464] = tobit(v_t)
v_A = tobit((v_A + v_n))
I32[5467] = tobit(v_A)
I32[arshift((v_A + 4), 2)] = tobit(bor(1, v_t))
I32[arshift((4 + tobit((v_n + v_e))), 2)] = tobit(40)
I32[5468] = tobit(I32[5583])
end
goto L23
end
end
::L25::
end
if (not (bor(bor(band(8, U8[tobit((v_A + 12))]), (((tobit(v_e) % 4294967296) > (tobit(v_u) % 4294967296)) and 1 or 0)), (((tobit(v_n) % 4294967296) <= (tobit(v_u) % 4294967296)) and 1 or 0)) ~= 0)) then
I32[arshift((v_A + 4), 2)] = tobit((v_t + v_a))
v_A = ((band((v_u + 8), 7) ~= 0) and band(((-8) - v_u), 7) or 0)
v_t = tobit((v_A + v_u))
I32[5467] = tobit(v_t)
v_n = tobit((I32[5464] + v_a))
v_A = tobit((v_n - v_A))
I32[5464] = tobit(v_A)
I32[arshift((v_t + 4), 2)] = tobit(bor(1, v_A))
I32[arshift((4 + tobit((v_n + v_u))), 2)] = tobit(40)
I32[5468] = tobit(I32[5583])
goto L23
end
end
end
::L24::
end
if (U32[5465] > (tobit(v_n) % 4294967296)) then
I32[5465] = tobit(v_n)
end
v_t = tobit((v_n + v_a))
v_A = 22292
do
do
do
do
do
do
do
do
do
do
do
do
do
do
do
do
do
while true do
do
if (bor(0, v_t) ~= I32[arshift(v_A, 2)]) then
v_A = I32[arshift((v_A + 8), 2)]
if (v_A ~= 0) then
goto C34
end
goto L33
end
goto B34
end
::C34::
end
end
::B34::
if (not (band(8, U8[tobit((v_A + 12))]) ~= 0)) then
goto L32
end
end
::L33::
do
do
v_A = 22292
while true do
do
do
do
v_t = I32[arshift(v_A, 2)]
local t40 = ((tobit(v_t) % 4294967296) <= (tobit(v_u) % 4294967296))
if t40 then
v_o = tobit((v_t + I32[arshift((v_A + 4), 2)]))
t40 = ((tobit(v_o) % 4294967296) > (tobit(v_u) % 4294967296))
end
if t40 then
goto L31
end
end
v_A = I32[arshift((v_A + 8), 2)]
end
end
::C35::
end
end
::B35::
end
end
end
::L32::
end
do
I32[arshift(v_A, 2)] = tobit(v_n)
I32[arshift((v_A + 4), 2)] = tobit((I32[arshift((v_A + 4), 2)] + v_a))
v_l = tobit((((band((v_n + 8), 7) ~= 0) and band(((-8) - v_n), 7) or 0) + v_n))
I32[arshift((4 + v_l), 2)] = tobit(bor(3, v_s))
v_a = tobit((v_t + ((band((v_t + 8), 7) ~= 0) and band(((-8) - v_t), 7) or 0)))
local t41 = v_a
v_c = tobit((v_s + v_l))
v_t = tobit((t41 - v_c))
if (bor(0, v_u) == bor(0, v_a)) then
I32[5467] = tobit(v_c)
v_A = tobit((I32[5464] + v_t))
I32[5464] = tobit(v_A)
I32[arshift((v_c + 4), 2)] = tobit(bor(1, v_A))
goto L29
end
end
if (I32[5466] == bor(0, v_a)) then
I32[5466] = tobit(v_c)
v_A = tobit((I32[5463] + v_t))
I32[5463] = tobit(v_A)
I32[arshift((v_c + 4), 2)] = tobit(bor(1, v_A))
I32[arshift((v_A + v_c), 2)] = tobit(v_A)
goto L29
end
do
v_A = I32[arshift((v_a + 4), 2)]
if (1 == band(3, v_A)) then
do
v_u = band((-8), v_A)
do
do
do
if ((tobit(v_A) % 4294967296) <= 255) then
v_e = I32[arshift((v_a + 8), 2)]
v_A = tobit((rshift(v_A, 3) % 4294967296))
v_n = I32[arshift((v_a + 12), 2)]
if (bor(0, v_n) == bor(0, v_e)) then
I32[5461] = tobit(band(I32[5461], F.fSA((-2), v_A)))
goto L36
end
I32[arshift((v_e + 12), 2)] = tobit(v_n)
I32[arshift((v_n + 8), 2)] = tobit(v_e)
else
do
do
v_s = I32[arshift((v_a + 24), 2)]
local t42 = bor(0, v_a)
v_n = I32[arshift((v_a + 12), 2)]
if (t42 == bor(0, v_n)) then
do
v_A = tobit((v_a + 20))
v_e = I32[arshift(v_A, 2)]
local t43 = (v_e ~= 0)
if not t43 then
v_A = tobit((v_a + 16))
v_e = I32[arshift(v_A, 2)]
t43 = (v_e ~= 0)
end
if t43 then
do
do
do
while true do
do
v_o = v_A
v_n = v_e
v_A = tobit((v_n + 20))
v_e = I32[arshift(v_A, 2)]
local t44 = v_e
if t44 == 0 then
v_A = tobit((v_n + 16))
v_e = I32[arshift((v_n + 16), 2)]
t44 = v_e
end
if not (t44 ~= 0) then goto B37 end
end
do
end
::C37::
end
end
::B37::
end
I32[arshift(v_o, 2)] = tobit(0)
end
else
v_n = 0
end
end
else
v_A = I32[arshift((v_a + 8), 2)]
I32[arshift((v_A + 12), 2)] = tobit(v_n)
I32[arshift((v_n + 8), 2)] = tobit(v_A)
end
end
if (v_s ~= 0) then
v_e = I32[arshift((v_a + 28), 2)]
do
v_A = tobit((22148 + lshift(v_e, 2)))
if (I32[arshift(v_A, 2)] == bor(0, v_a)) then
I32[arshift(v_A, 2)] = tobit(v_n)
if (v_n ~= 0) then
goto L38
end
I32[5462] = tobit(band(I32[5462], F.fSA((-2), v_e)))
goto L36
end
I32[arshift((v_s + ((I32[arshift((v_s + 16), 2)] == bor(0, v_a)) and 16 or 20)), 2)] = tobit(v_n)
if (not (v_n ~= 0)) then
goto L36
end
end
::L38::
I32[arshift((v_n + 24), 2)] = tobit(v_s)
v_A = I32[arshift((v_a + 16), 2)]
if (v_A ~= 0) then
I32[arshift((v_n + 16), 2)] = tobit(v_A)
I32[arshift((v_A + 24), 2)] = tobit(v_n)
end
v_A = I32[arshift((v_a + 20), 2)]
if (v_A ~= 0) then
I32[arshift((v_n + 20), 2)] = tobit(v_A)
I32[arshift((v_A + 24), 2)] = tobit(v_n)
end
end
end
end
end
end
::L36::
end
v_a = tobit((v_u + v_a))
v_t = tobit((v_t + v_u))
end
end
end
do
I32[arshift((v_a + 4), 2)] = tobit(band((-2), I32[arshift((v_a + 4), 2)]))
I32[arshift((v_c + 4), 2)] = tobit(bor(1, v_t))
I32[arshift((v_t + v_c), 2)] = tobit(v_t)
if ((tobit(v_t) % 4294967296) <= 255) then
do
do
v_A = tobit((rshift(v_t, 3) % 4294967296))
v_n = tobit((21884 + lshift(v_A, 3)))
v_t = I32[5461]
local t45 = v_t
v_A = lshift(1, v_A)
if (band(t45, v_A) ~= 0) then
v_A = I32[arshift((v_n + 8), 2)]
else
I32[5461] = tobit(bor(v_A, v_t))
v_A = v_n
end
I32[arshift((v_n + 8), 2)] = tobit(v_c)
I32[arshift((v_A + 12), 2)] = tobit(v_c)
I32[arshift((v_c + 12), 2)] = tobit(v_n)
I32[arshift((v_c + 8), 2)] = tobit(v_A)
end
goto L29
end
end
end
do
v_A = 31
if ((tobit(v_t) % 4294967296) <= 16777215) then
v_A = tobit((rshift(v_t, 8) % 4294967296))
local t46 = v_A
v_o = band((rshift((v_A + 1048320), 16) % 4294967296), 8)
v_A = lshift(t46, v_o)
local t47 = v_A
v_e = band((rshift((v_A + 520192), 16) % 4294967296), 4)
v_A = lshift(t47, v_e)
local t48 = v_A
v_n = band((rshift((v_A + 245760), 16) % 4294967296), 2)
v_A = tobit((tobit((rshift(lshift(t48, v_n), 15) % 4294967296)) - bor(bor(v_n, v_e), v_o)))
v_A = tobit((28 + bor(lshift(v_A, 1), band((rshift(v_t, (v_A + 21)) % 4294967296), 1))))
end
I32[arshift((v_c + 28), 2)] = tobit(v_A)
I32[arshift((v_c + 16), 2)] = tobit(0)
I32[arshift((v_c + 20), 2)] = tobit(0)
v_o = tobit((22148 + lshift(v_A, 2)))
v_e = I32[5462]
local t49 = v_e
v_n = lshift(1, v_A)
if (band(t49, v_n) ~= 0) then
do
v_A = lshift(v_t, ((31 == bor(0, v_A)) and 0 or tobit((25 - tobit((rshift(v_A, 1) % 4294967296))))))
v_n = I32[arshift(v_o, 2)]
while true do
do
v_e = v_n
if (band((-8), I32[arshift((v_n + 4), 2)]) == bor(0, v_t)) then
goto L30
end
v_n = tobit((rshift(v_A, 29) % 4294967296))
v_A = lshift(v_A, 1)
v_o = tobit((v_e + band(4, v_n)))
v_n = I32[arshift((16 + v_o), 2)]
if (not (v_n ~= 0)) then
goto B39
end
end
::C39::
end
end
::B39::
I32[arshift((v_o + 16), 2)] = tobit(v_c)
I32[arshift((v_c + 24), 2)] = tobit(v_e)
else
I32[5462] = tobit(bor(v_n, v_e))
I32[arshift(v_o, 2)] = tobit(v_c)
I32[arshift((v_c + 24), 2)] = tobit(v_o)
end
end
I32[arshift((v_c + 12), 2)] = tobit(v_c)
I32[arshift((v_c + 8), 2)] = tobit(v_c)
goto L29
end
end
::L31::
end
do
do
do
v_e = tobit((v_a - 40))
local t50 = v_e
v_A = ((band((v_n + 8), 7) ~= 0) and band(((-8) - v_n), 7) or 0)
v_t = tobit((t50 - v_A))
I32[5464] = tobit(v_t)
v_A = tobit((v_A + v_n))
I32[5467] = tobit(v_A)
I32[arshift((v_A + 4), 2)] = tobit(bor(1, v_t))
I32[arshift((4 + tobit((v_n + v_e))), 2)] = tobit(40)
I32[5468] = tobit(I32[5583])
v_A = tobit((tobit((v_o + ((band((v_o - 39), 7) ~= 0) and band((39 - v_o), 7) or 0))) - 47))
v_t = (((tobit(v_A) % 4294967296) < (tobit((v_u + 16)) % 4294967296)) and v_u or v_A)
I32[arshift((v_t + 4), 2)] = tobit(27)
v_A = I32[5576]
I32[arshift((v_t + 16), 2)] = tobit(I32[5575])
I32[arshift((v_t + 20), 2)] = tobit(v_A)
v_A = I32[5574]
I32[arshift((v_t + 8), 2)] = tobit(I32[5573])
I32[arshift((v_t + 12), 2)] = tobit(v_A)
I32[5575] = tobit((v_t + 8))
I32[5574] = tobit(v_a)
I32[5573] = tobit(v_n)
I32[5576] = tobit(0)
v_A = tobit((v_t + 24))
end
while true do
I32[arshift((v_A + 4), 2)] = tobit(7)
v_n = tobit((v_A + 8))
v_A = tobit((v_A + 4))
if not ((tobit(v_n) % 4294967296) < (tobit(v_o) % 4294967296)) then goto B40 end
do
end
::C40::
end
end
::B40::
end
if (bor(0, v_t) == bor(0, v_u)) then
goto L23
end
do
I32[arshift((v_t + 4), 2)] = tobit(band((-2), I32[arshift((v_t + 4), 2)]))
v_o = tobit((v_t - v_u))
I32[arshift((v_u + 4), 2)] = tobit(bor(1, v_o))
I32[arshift(v_t, 2)] = tobit(v_o)
if ((tobit(v_o) % 4294967296) <= 255) then
do
do
v_A = tobit((rshift(v_o, 3) % 4294967296))
v_n = tobit((21884 + lshift(v_A, 3)))
v_t = I32[5461]
local t51 = v_t
v_A = lshift(1, v_A)
if (band(t51, v_A) ~= 0) then
v_A = I32[arshift((v_n + 8), 2)]
else
I32[5461] = tobit(bor(v_A, v_t))
v_A = v_n
end
I32[arshift((v_n + 8), 2)] = tobit(v_u)
I32[arshift((v_A + 12), 2)] = tobit(v_u)
I32[arshift((v_u + 12), 2)] = tobit(v_n)
I32[arshift((v_u + 8), 2)] = tobit(v_A)
end
goto L23
end
end
end
do
v_A = 31
I32[arshift((v_u + 16), 2)] = tobit(0)
I32[arshift((v_u + 20), 2)] = tobit(0)
if ((tobit(v_o) % 4294967296) <= 16777215) then
v_A = tobit((rshift(v_o, 8) % 4294967296))
local t52 = v_A
v_e = band((rshift((v_A + 1048320), 16) % 4294967296), 8)
v_A = lshift(t52, v_e)
local t53 = v_A
v_t = band((rshift((v_A + 520192), 16) % 4294967296), 4)
v_A = lshift(t53, v_t)
local t54 = v_A
v_n = band((rshift((v_A + 245760), 16) % 4294967296), 2)
v_A = tobit((tobit((rshift(lshift(t54, v_n), 15) % 4294967296)) - bor(bor(v_n, v_t), v_e)))
v_A = tobit((28 + bor(lshift(v_A, 1), band((rshift(v_o, (v_A + 21)) % 4294967296), 1))))
end
I32[arshift((v_u + 28), 2)] = tobit(v_A)
v_e = tobit((22148 + lshift(v_A, 2)))
v_t = I32[5462]
local t55 = v_t
v_n = lshift(1, v_A)
if (band(t55, v_n) ~= 0) then
do
v_A = lshift(v_o, ((31 == bor(0, v_A)) and 0 or tobit((25 - tobit((rshift(v_A, 1) % 4294967296))))))
v_n = I32[arshift(v_e, 2)]
while true do
do
v_t = v_n
if (bor(0, v_o) == band((-8), I32[arshift((v_n + 4), 2)])) then
goto L28
end
v_n = tobit((rshift(v_A, 29) % 4294967296))
v_A = lshift(v_A, 1)
v_e = tobit((v_t + band(4, v_n)))
v_n = I32[arshift((16 + v_e), 2)]
if (not (v_n ~= 0)) then
goto B41
end
end
::C41::
end
end
::B41::
I32[arshift((v_e + 16), 2)] = tobit(v_u)
I32[arshift((v_u + 24), 2)] = tobit(v_t)
else
I32[5462] = tobit(bor(v_n, v_t))
I32[arshift(v_e, 2)] = tobit(v_u)
I32[arshift((v_u + 24), 2)] = tobit(v_e)
end
end
I32[arshift((v_u + 12), 2)] = tobit(v_u)
I32[arshift((v_u + 8), 2)] = tobit(v_u)
goto L23
end
end
::L30::
end
v_A = I32[arshift((v_e + 8), 2)]
I32[arshift((v_A + 12), 2)] = tobit(v_c)
I32[arshift((v_e + 8), 2)] = tobit(v_c)
I32[arshift((v_c + 24), 2)] = tobit(0)
I32[arshift((v_c + 12), 2)] = tobit(v_e)
I32[arshift((v_c + 8), 2)] = tobit(v_A)
end
end
::L29::
end
v_A = tobit((v_l + 8))
goto L1
end
end
::L28::
end
v_A = I32[arshift((v_t + 8), 2)]
I32[arshift((v_A + 12), 2)] = tobit(v_u)
I32[arshift((v_t + 8), 2)] = tobit(v_u)
I32[arshift((v_u + 24), 2)] = tobit(0)
I32[arshift((v_u + 12), 2)] = tobit(v_t)
I32[arshift((v_u + 8), 2)] = tobit(v_A)
end
end
::L23::
end
v_A = I32[5464]
if (not ((tobit(v_A) % 4294967296) <= (tobit(v_s) % 4294967296))) then
v_n = tobit((v_A - v_s))
I32[5464] = tobit(v_n)
v_t = I32[5467]
v_A = tobit((v_t + v_s))
I32[5467] = tobit(v_A)
I32[arshift((v_A + 4), 2)] = tobit(bor(1, v_n))
I32[arshift((v_t + 4), 2)] = tobit(bor(3, v_s))
v_A = tobit((v_t + 8))
goto L1
end
end
end
::L4::
end
I32[5460] = tobit(48)
v_A = 0
goto L1
end
end
::L3::
end
do
if (v_a ~= 0) then
v_t = I32[arshift((v_o + 28), 2)]
do
v_A = tobit((22148 + lshift(v_t, 2)))
if (I32[arshift(v_A, 2)] == bor(0, v_o)) then
I32[arshift(v_A, 2)] = tobit(v_n)
if (v_n ~= 0) then
goto L43
end
v_l = band(F.fSA((-2), v_t), v_l)
I32[5462] = tobit(v_l)
goto L42
end
I32[arshift((v_a + ((I32[arshift((v_a + 16), 2)] == bor(0, v_o)) and 16 or 20)), 2)] = tobit(v_n)
if (not (v_n ~= 0)) then
goto L42
end
end
::L43::
I32[arshift((v_n + 24), 2)] = tobit(v_a)
v_A = I32[arshift((v_o + 16), 2)]
if (v_A ~= 0) then
I32[arshift((v_n + 16), 2)] = tobit(v_A)
I32[arshift((v_A + 24), 2)] = tobit(v_n)
end
v_A = I32[arshift((v_o + 20), 2)]
if (v_A ~= 0) then
I32[arshift((v_n + 20), 2)] = tobit(v_A)
I32[arshift((v_A + 24), 2)] = tobit(v_n)
end
end
end
::L42::
do
do
do
if ((tobit(v_e) % 4294967296) <= 15) then
v_A = tobit((v_e + v_s))
I32[arshift((v_o + 4), 2)] = tobit(bor(3, v_A))
v_A = tobit((v_A + v_o))
I32[arshift((4 + v_A), 2)] = tobit(bor(1, I32[arshift((v_A + 4), 2)]))
else
do
I32[arshift((v_o + 4), 2)] = tobit(bor(3, v_s))
I32[arshift((v_c + 4), 2)] = tobit(bor(1, v_e))
I32[arshift((v_e + v_c), 2)] = tobit(v_e)
if ((tobit(v_e) % 4294967296) <= 255) then
do
v_A = tobit((rshift(v_e, 3) % 4294967296))
v_n = tobit((21884 + lshift(v_A, 3)))
v_t = I32[5461]
local t56 = v_t
v_A = lshift(1, v_A)
if (band(t56, v_A) ~= 0) then
v_A = I32[arshift((v_n + 8), 2)]
else
I32[5461] = tobit(bor(v_A, v_t))
v_A = v_n
end
I32[arshift((v_n + 8), 2)] = tobit(v_c)
I32[arshift((v_A + 12), 2)] = tobit(v_c)
I32[arshift((v_c + 12), 2)] = tobit(v_n)
I32[arshift((v_c + 8), 2)] = tobit(v_A)
end
else
do
do
v_A = 31
if ((tobit(v_e) % 4294967296) <= 16777215) then
v_A = tobit((rshift(v_e, 8) % 4294967296))
local t57 = v_A
v_u = band((rshift((v_A + 1048320), 16) % 4294967296), 8)
v_A = lshift(t57, v_u)
local t58 = v_A
v_t = band((rshift((v_A + 520192), 16) % 4294967296), 4)
v_A = lshift(t58, v_t)
local t59 = v_A
v_n = band((rshift((v_A + 245760), 16) % 4294967296), 2)
v_A = tobit((tobit((rshift(lshift(t59, v_n), 15) % 4294967296)) - bor(bor(v_n, v_t), v_u)))
v_A = tobit((28 + bor(lshift(v_A, 1), band((rshift(v_e, (v_A + 21)) % 4294967296), 1))))
end
I32[arshift((v_c + 28), 2)] = tobit(v_A)
I32[arshift((v_c + 16), 2)] = tobit(0)
I32[arshift((v_c + 20), 2)] = tobit(0)
v_t = tobit((22148 + lshift(v_A, 2)))
end
do
do
do
do
v_n = lshift(1, v_A)
if (band(v_n, v_l) ~= 0) then
do
do
do
v_A = lshift(v_e, ((31 == bor(0, v_A)) and 0 or tobit((25 - tobit((rshift(v_A, 1) % 4294967296))))))
v_s = I32[arshift(v_t, 2)]
while true do
do
do
do
local t60 = (-8)
v_n = v_s
if (band(t60, I32[arshift((v_n + 4), 2)]) == bor(0, v_e)) then
goto L45
end
end
v_t = tobit((rshift(v_A, 29) % 4294967296))
v_A = lshift(v_A, 1)
v_t = tobit((v_n + band(4, v_t)))
v_s = I32[arshift((16 + v_t), 2)]
if (not (v_s ~= 0)) then
goto B46
end
end
end
::C46::
end
end
::B46::
end
I32[arshift((v_t + 16), 2)] = tobit(v_c)
I32[arshift((v_c + 24), 2)] = tobit(v_n)
end
else
I32[5462] = tobit(bor(v_n, v_l))
I32[arshift(v_t, 2)] = tobit(v_c)
I32[arshift((v_c + 24), 2)] = tobit(v_t)
end
end
I32[arshift((v_c + 12), 2)] = tobit(v_c)
I32[arshift((v_c + 8), 2)] = tobit(v_c)
goto L44
end
end
::L45::
end
v_A = I32[arshift((v_n + 8), 2)]
I32[arshift((v_A + 12), 2)] = tobit(v_c)
I32[arshift((v_n + 8), 2)] = tobit(v_c)
I32[arshift((v_c + 24), 2)] = tobit(0)
I32[arshift((v_c + 12), 2)] = tobit(v_n)
I32[arshift((v_c + 8), 2)] = tobit(v_A)
end
end
end
end
end
end
::L44::
end
v_A = tobit((v_o + 8))
goto L1
end
end
::L2::
end
do
if (v_g ~= 0) then
v_t = I32[arshift((v_n + 28), 2)]
do
v_A = tobit((22148 + lshift(v_t, 2)))
if (I32[arshift(v_A, 2)] == bor(0, v_n)) then
I32[arshift(v_A, 2)] = tobit(v_o)
if (v_o ~= 0) then
goto L48
end
I32[5462] = tobit(band(F.fSA((-2), v_t), v_c))
goto L47
end
I32[arshift((((I32[arshift((v_g + 16), 2)] == bor(0, v_n)) and 16 or 20) + v_g), 2)] = tobit(v_o)
if (not (v_o ~= 0)) then
goto L47
end
end
::L48::
I32[arshift((v_o + 24), 2)] = tobit(v_g)
v_A = I32[arshift((v_n + 16), 2)]
if (v_A ~= 0) then
I32[arshift((v_o + 16), 2)] = tobit(v_A)
I32[arshift((v_A + 24), 2)] = tobit(v_o)
end
v_A = I32[arshift((v_n + 20), 2)]
if (v_A ~= 0) then
I32[arshift((v_o + 20), 2)] = tobit(v_A)
I32[arshift((v_A + 24), 2)] = tobit(v_o)
end
end
end
::L47::
if ((tobit(v_e) % 4294967296) <= 15) then
v_A = tobit((v_e + v_s))
I32[arshift((v_n + 4), 2)] = tobit(bor(3, v_A))
v_A = tobit((v_A + v_n))
I32[arshift((4 + v_A), 2)] = tobit(bor(1, I32[arshift((v_A + 4), 2)]))
else
I32[arshift((v_n + 4), 2)] = tobit(bor(3, v_s))
I32[arshift((v_l + 4), 2)] = tobit(bor(1, v_e))
I32[arshift((v_e + v_l), 2)] = tobit(v_e)
if (v_v ~= 0) then
v_A = tobit((rshift(v_v, 3) % 4294967296))
v_t = tobit((21884 + lshift(v_A, 3)))
v_o = I32[5466]
v_A = lshift(1, v_A)
if (band(v_A, v_a) ~= 0) then
v_A = I32[arshift((v_t + 8), 2)]
else
I32[5461] = tobit(bor(v_A, v_a))
v_A = v_t
end
I32[arshift((v_t + 8), 2)] = tobit(v_o)
I32[arshift((v_A + 12), 2)] = tobit(v_o)
I32[arshift((v_o + 12), 2)] = tobit(v_t)
I32[arshift((v_o + 8), 2)] = tobit(v_A)
end
I32[5466] = tobit(v_l)
I32[5463] = tobit(v_e)
end
v_A = tobit((v_n + 8))
end
end
::L1::
end
B = tobit((v_r + 16))
do return bor(0, v_A) end
end

F.fm = function(v_A, v_r, v_n)
local v_e, v_o, v_a, v_u, v_c, v_s, v_l, v_b, v_v, v_p, v_h, v_d, v_k, v_y, v_w, v_C, v_E, v_I, v_m, v_Q, v_O, v_S, v_j, v_x, v_P, v_M, v_T, v_R, v_D, v_G, v_U, v_F, v_Y, v_J, v_L, v_K, v_W, v_H, v_N, v_V, v_z, v_q, v_X = 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
v_o = 0
v_a = 0
v_u = 0
v_c = 0
v_s = 0
v_l = 0
v_b = 0
v_v = 0
v_p = 0
v_h = 0
v_d = 0
v_k = 0
v_y = 0
v_w = 0
v_C = 0
v_E = 0
v_I = 0
v_m = 0
v_Q = 0
v_O = 0
v_S = 0
v_j = 0
v_x = 0
v_P = 0
v_M = 0
v_T = 0
v_R = 0
v_D = 0
v_G = 0
v_U = 0
v_F = 0
v_Y = 0
v_J = 0
v_L = 0
v_K = 0
v_W = 0
v_H = 0
v_N = 0
v_V = 0
v_z = 0
v_q = 0
v_X = 0
v_e = tobit((B + (-64)))
B = v_e
I32[arshift((v_e + 56), 2)] = tobit(0)
I32[arshift((v_e + 60), 2)] = tobit(0)
I32[arshift((v_e + 48), 2)] = tobit(0)
I32[arshift((v_e + 52), 2)] = tobit(0)
I32[arshift((v_e + 40), 2)] = tobit(0)
I32[arshift((v_e + 44), 2)] = tobit(0)
I32[arshift((v_e + 32), 2)] = tobit(0)
I32[arshift((v_e + 36), 2)] = tobit(0)
I32[arshift((v_e + 24), 2)] = tobit(0)
I32[arshift((v_e + 28), 2)] = tobit(0)
I32[arshift((v_e + 16), 2)] = tobit(0)
I32[arshift((v_e + 20), 2)] = tobit(0)
I32[arshift((v_e + 8), 2)] = tobit(0)
I32[arshift((v_e + 12), 2)] = tobit(0)
I32[arshift(v_e, 2)] = tobit(0)
I32[arshift((v_e + 4), 2)] = tobit(0)
F.fOA(tobit((v_A + 4)), 0, 272)
do
do
do
do
do
if (bor(((256 == bor(0, v_n)) and 1 or 0), ((192 == bor(0, v_n)) and 1 or 0)) ~= 0) then
I32[arshift(v_A, 2)] = tobit(4)
v_u = F.fQA(v_e, v_r, tobit((rshift(v_n, 3) % 4294967296)))
v_r = 1
if (192 == bor(0, v_n)) then
goto L51
end
else
v_a = (-36)
if (128 ~= bor(0, v_n)) then
goto L49
end
I32[arshift(v_A, 2)] = tobit(3)
F.fQA(v_e, v_r, tobit((rshift(v_n, 3) % 4294967296)))
v_r = 0
v_T = 1
end
v_s = U8[tobit((v_e + 22))]
v_a = U8[tobit((v_e + 21))]
v_c = U8[tobit((v_e + 20))]
v_l = U8[tobit((v_e + 19))]
v_v = U8[tobit((v_e + 18))]
v_y = U8[tobit((v_e + 17))]
v_d = U8[tobit((v_e + 16))]
goto L50
end
::L51::
v_d = U8[tobit((v_u + 16))]
I8[tobit((v_u + 24))] = tobit(bxor((-1), v_d))
v_y = U8[tobit((v_u + 17))]
I8[tobit((v_u + 25))] = tobit(bxor((-1), v_y))
v_v = U8[tobit((v_u + 18))]
I8[tobit((v_u + 26))] = tobit(bxor((-1), v_v))
v_l = U8[tobit((v_u + 19))]
I8[tobit((v_u + 27))] = tobit(bxor((-1), v_l))
v_c = U8[tobit((v_u + 20))]
I8[tobit((v_u + 28))] = tobit(bxor((-1), v_c))
v_a = U8[tobit((v_u + 21))]
I8[tobit((v_u + 29))] = tobit(bxor((-1), v_a))
v_s = U8[tobit((v_u + 22))]
I8[tobit((v_u + 30))] = tobit(bxor((-1), v_s))
I8[tobit((v_u + 31))] = tobit(bxor((-1), U8[tobit((v_u + 23))]))
end
::L50::
do
v_R = U8[tobit((v_e + 23))]
local t61 = v_R
v_D = bor(lshift(band(255, v_a), 16), lshift(v_c, 24))
v_w = bor(bor(t61, v_D), lshift(band(255, v_s), 8))
v_G = U8[tobit((v_e + 7))]
local t62 = v_G
v_Q = bor(lshift(U8[tobit((v_e + 5))], 16), lshift(U8[tobit((v_e + 4))], 24))
v_u = bor(bor(t62, v_Q), lshift(U8[tobit((v_e + 6))], 8))
v_a = bxor(bxor(v_w, v_u), 1003262091)
v_o = U8[tobit((8576 + tobit((rshift(v_a, 24) % 4294967296))))]
v_s = bor(bor(bor(U8[tobit((8320 + band(255, v_a)))], lshift(U8[tobit((8832 + band((rshift(v_a, 16) % 4294967296), 255)))], 16)), lshift(v_o, 24)), lshift(U8[tobit((9088 + band((rshift(v_a, 8) % 4294967296), 255)))], 8))
v_U = band(255, v_l)
local t63 = v_U
v_F = bor(lshift(band(255, v_y), 16), lshift(v_d, 24))
v_S = bor(bor(t63, v_F), lshift(band(255, v_v), 8))
v_O = U8[tobit((v_e + 3))]
local t64 = v_O
v_y = bor(lshift(U8[tobit((v_e + 1))], 16), lshift(U8[bor(0, v_e)], 24))
v_c = bor(bor(t64, v_y), lshift(U8[tobit((v_e + 2))], 8))
local t66 = bor(v_o, lshift(v_s, 8))
local t65 = (-1600231809)
v_l = bxor(v_S, v_c)
v_a = bxor(t65, v_l)
v_a = bxor(t66, bor(bor(bor(lshift(U8[tobit((8576 + band((rshift(v_a, 16) % 4294967296), 255)))], 16), lshift(U8[tobit((8320 + tobit((rshift(v_a, 24) % 4294967296))))], 24)), lshift(U8[tobit((8832 + band((rshift(v_a, 8) % 4294967296), 255)))], 8)), U8[tobit((9088 + band(255, v_a)))]))
v_s = bxor(F.fSA(v_a, 16), v_s)
v_a = bxor(F.fSA(v_s, 24), v_a)
v_Y = U8[tobit((v_e + 31))]
local t67 = v_Y
v_J = bor(lshift(U8[tobit((v_e + 29))], 16), lshift(U8[tobit((v_e + 28))], 24))
v_j = bor(bor(t67, v_J), lshift(U8[tobit((v_e + 30))], 8))
v_L = U8[tobit((v_e + 15))]
local t68 = v_L
v_x = bor(lshift(U8[tobit((v_e + 13))], 16), lshift(U8[tobit((v_e + 12))], 24))
v_d = bor(bor(t68, v_x), lshift(U8[tobit((v_e + 14))], 8))
v_o = bxor(bxor(bxor(v_a, v_j), v_d), 1286239154)
v_v = U8[tobit((8576 + tobit((rshift(v_o, 24) % 4294967296))))]
local t69 = v_v
v_b = bor(bor(bor(U8[tobit((8320 + band(255, v_o)))], lshift(U8[tobit((8832 + band((rshift(v_o, 16) % 4294967296), 255)))], 16)), lshift(v_v, 24)), lshift(U8[tobit((9088 + band((rshift(v_o, 8) % 4294967296), 255)))], 8))
v_C = bor(t69, lshift(v_b, 8))
local t71 = v_s
v_K = U8[tobit((v_e + 27))]
local t70 = v_K
v_W = bor(lshift(U8[tobit((v_e + 25))], 16), lshift(U8[tobit((v_e + 24))], 24))
v_P = bor(bor(t70, v_W), lshift(U8[tobit((v_e + 26))], 8))
local t73 = bxor(t71, v_P)
v_H = U8[tobit((v_e + 11))]
local t72 = v_H
v_M = bor(lshift(U8[tobit((v_e + 9))], 16), lshift(U8[tobit((v_e + 8))], 24))
v_v = bor(bor(t72, v_M), lshift(U8[tobit((v_e + 10))], 8))
v_h = bxor(bxor(t73, v_v), F.fSA(v_a, 24))
local t74 = v_C
v_o = bxor((-1233459112), v_h)
v_o = bxor(t74, bor(bor(bor(lshift(U8[tobit((8576 + band((rshift(v_o, 16) % 4294967296), 255)))], 16), lshift(U8[tobit((8320 + tobit((rshift(v_o, 24) % 4294967296))))], 24)), lshift(U8[tobit((8832 + band((rshift(v_o, 8) % 4294967296), 255)))], 8)), U8[tobit((9088 + band(255, v_o)))]))
v_b = bxor(F.fSA(v_o, 16), v_b)
v_E = bxor(F.fSA(v_b, 24), v_o)
local t75 = (-380665154)
v_N = bxor(v_E, v_w)
v_o = bxor(t75, v_N)
v_s = U8[tobit((8576 + tobit((rshift(v_o, 24) % 4294967296))))]
v_p = bor(bor(bor(U8[tobit((8320 + band(255, v_o)))], lshift(U8[tobit((8832 + band((rshift(v_o, 16) % 4294967296), 255)))], 16)), lshift(v_s, 24)), lshift(U8[tobit((9088 + band((rshift(v_o, 8) % 4294967296), 255)))], 8))
v_l = bxor(bxor(bxor(v_c, F.fSA(v_E, 24)), v_l), v_b)
local t76 = bor(v_s, lshift(v_p, 8))
v_o = bxor((-957401297), v_l)
v_o = bxor(t76, bor(bor(bor(lshift(U8[tobit((8576 + band((rshift(v_o, 16) % 4294967296), 255)))], 16), lshift(U8[tobit((8320 + tobit((rshift(v_o, 24) % 4294967296))))], 24)), lshift(U8[tobit((8832 + band((rshift(v_o, 8) % 4294967296), 255)))], 8)), U8[tobit((9088 + band(255, v_o)))]))
v_b = bxor(F.fSA(v_o, 16), v_p)
v_C = bxor(F.fSA(v_b, 24), v_o)
local t77 = (-237801700)
v_I = bxor(bxor(v_C, v_a), v_j)
v_o = bxor(t77, v_I)
v_s = U8[tobit((8576 + tobit((rshift(v_o, 24) % 4294967296))))]
local t78 = v_s
v_p = bor(bor(bor(U8[tobit((8320 + band(255, v_o)))], lshift(U8[tobit((8832 + band((rshift(v_o, 16) % 4294967296), 255)))], 16)), lshift(v_s, 24)), lshift(U8[tobit((9088 + band((rshift(v_o, 8) % 4294967296), 255)))], 8))
v_k = bor(t78, lshift(v_p, 8))
v_s = bxor(bxor(bxor(F.fSA(v_C, 24), v_b), v_v), v_h)
local t79 = v_k
v_o = bxor(1426019237, v_s)
v_o = bxor(t79, bor(bor(bor(lshift(U8[tobit((8576 + band((rshift(v_o, 16) % 4294967296), 255)))], 16), lshift(U8[tobit((8320 + tobit((rshift(v_o, 24) % 4294967296))))], 24)), lshift(U8[tobit((8832 + band((rshift(v_o, 8) % 4294967296), 255)))], 8)), U8[tobit((9088 + band(255, v_o)))]))
v_b = bxor(F.fSA(v_o, 16), v_p)
v_k = bxor(F.fSA(v_b, 24), v_o)
v_l = bxor(bxor(F.fSA(v_k, 24), v_l), v_b)
v_b = 0
v_h = 0
v_p = 0
if ((tobit(v_n) % 4294967296) >= 129) then
v_C = bxor(v_C, v_a)
local t80 = (-563598051)
v_h = bxor(v_k, v_E)
v_o = bxor(t80, v_h)
v_b = U8[tobit((8576 + tobit((rshift(v_o, 24) % 4294967296))))]
local t81 = v_b
v_o = bor(bor(bor(U8[tobit((8320 + band(255, v_o)))], lshift(U8[tobit((8832 + band((rshift(v_o, 16) % 4294967296), 255)))], 16)), lshift(v_b, 24)), lshift(U8[tobit((9088 + band((rshift(v_o, 8) % 4294967296), 255)))], 8))
v_p = bor(t81, lshift(v_o, 8))
local t82 = v_p
v_b = bxor(v_l, v_S)
v_a = bxor(283453434, v_b)
v_a = bxor(t82, bor(bor(bor(lshift(U8[tobit((8576 + band((rshift(v_a, 16) % 4294967296), 255)))], 16), lshift(U8[tobit((8320 + tobit((rshift(v_a, 24) % 4294967296))))], 24)), lshift(U8[tobit((8832 + band((rshift(v_a, 8) % 4294967296), 255)))], 8)), U8[tobit((9088 + band(255, v_a)))]))
v_p = bxor(F.fSA(v_a, 16), v_o)
v_E = bxor(F.fSA(v_p, 24), v_a)
local t83 = (-1276722691)
v_m = bxor(v_C, v_E)
v_a = bxor(t83, v_m)
v_o = U8[tobit((8576 + tobit((rshift(v_a, 24) % 4294967296))))]
v_C = v_h
v_h = bor(bor(bor(U8[tobit((8320 + band(255, v_a)))], lshift(U8[tobit((8832 + band((rshift(v_a, 16) % 4294967296), 255)))], 16)), lshift(v_o, 24)), lshift(U8[tobit((9088 + band((rshift(v_a, 8) % 4294967296), 255)))], 8))
v_p = bxor(bxor(bxor(F.fSA(v_E, 24), v_p), v_s), v_P)
local t84 = bor(v_o, lshift(v_h, 8))
v_a = bxor((-1336506174), v_p)
v_a = bxor(t84, bor(bor(bor(lshift(U8[tobit((8576 + band((rshift(v_a, 16) % 4294967296), 255)))], 16), lshift(U8[tobit((8320 + tobit((rshift(v_a, 24) % 4294967296))))], 24)), lshift(U8[tobit((8832 + band((rshift(v_a, 8) % 4294967296), 255)))], 8)), U8[tobit((9088 + band(255, v_a)))]))
v_o = bxor(F.fSA(v_a, 16), v_h)
local t85 = v_C
v_a = bxor(F.fSA(v_o, 24), v_a)
v_h = bxor(t85, v_a)
v_b = bxor(bxor(F.fSA(v_a, 24), v_o), v_b)
end
if not (v_r ~= 0) then
v_V = bor(lshift(v_G, 30), (rshift(v_v, 2) % 4294967296))
v_z = bor(lshift(v_O, 30), (rshift(v_u, 2) % 4294967296))
v_q = bor(lshift(v_L, 30), (rshift(v_c, 2) % 4294967296))
v_X = bor(lshift(v_H, 30), (rshift(v_d, 2) % 4294967296))
end
v_o = tobit((v_A + 4))
v_a = imul(v_r, 80)
I32[arshift((v_o + lshift(I8[tobit((v_a + 8112))], 2)), 2)] = tobit(v_c)
I32[arshift((v_o + lshift(I8[tobit((v_a + 8113))], 2)), 2)] = tobit(v_u)
I32[arshift((v_o + lshift(I8[tobit((v_a + 8114))], 2)), 2)] = tobit(v_v)
I32[arshift((v_o + lshift(I8[tobit((v_a + 8115))], 2)), 2)] = tobit(v_d)
I32[arshift((v_o + lshift(I8[tobit((v_a + 8116))], 2)), 2)] = tobit(bor(lshift(v_c, 15), (rshift(v_Q, 17) % 4294967296)))
I32[arshift((v_o + lshift(I8[tobit((v_a + 8117))], 2)), 2)] = tobit(bor(lshift(v_u, 15), (rshift(v_M, 17) % 4294967296)))
I32[arshift((v_o + lshift(I8[tobit((v_a + 8118))], 2)), 2)] = tobit(bor(lshift(v_v, 15), (rshift(v_x, 17) % 4294967296)))
I32[arshift((v_o + lshift(I8[tobit((v_a + 8119))], 2)), 2)] = tobit(bor(lshift(v_d, 15), (rshift(v_y, 17) % 4294967296)))
v_O = bor(lshift(v_O, 28), (rshift(v_u, 4) % 4294967296))
v_E = bor(lshift(v_d, 13), (rshift(v_y, 19) % 4294967296))
v_x = bor(lshift(v_v, 13), (rshift(v_x, 19) % 4294967296))
v_M = bor(lshift(v_u, 13), (rshift(v_M, 19) % 4294967296))
v_u = bor(lshift(v_c, 13), (rshift(v_Q, 19) % 4294967296))
if not (v_r ~= 0) then
I32[arshift((v_o + lshift(I8[tobit((v_a + 8120))], 2)), 2)] = tobit(v_z)
I32[arshift((v_o + lshift(I8[tobit((v_a + 8121))], 2)), 2)] = tobit(v_V)
I32[arshift((v_o + lshift(I8[tobit((v_a + 8122))], 2)), 2)] = tobit(v_X)
I32[arshift((v_o + lshift(I8[tobit((v_a + 8123))], 2)), 2)] = tobit(v_q)
end
v_k = bxor(v_k, v_N)
v_y = bor(lshift(v_L, 28), (rshift(v_c, 4) % 4294967296))
v_Q = bor(lshift(v_H, 28), (rshift(v_d, 4) % 4294967296))
v_d = bor(lshift(v_G, 28), (rshift(v_v, 4) % 4294967296))
I32[arshift((v_o + lshift(I8[tobit((v_a + 8124))], 2)), 2)] = tobit(v_u)
I32[arshift((v_o + lshift(I8[tobit((v_a + 8125))], 2)), 2)] = tobit(v_M)
I32[arshift((v_o + lshift(I8[tobit((v_a + 8126))], 2)), 2)] = tobit(v_x)
I32[arshift((v_o + lshift(I8[tobit((v_a + 8127))], 2)), 2)] = tobit(v_E)
I32[arshift((v_o + lshift(I8[tobit((v_a + 8128))], 2)), 2)] = tobit(v_O)
end
do
if (v_T ~= 0) then
v_u = tobit((imul(v_r, 80) + 8131))
else
v_c = tobit((v_A + 4))
v_o = imul(v_r, 80)
I32[arshift((v_c + lshift(I8[tobit((v_o + 8129))], 2)), 2)] = tobit(v_d)
I32[arshift((v_c + lshift(I8[tobit((v_o + 8130))], 2)), 2)] = tobit(v_Q)
I32[arshift((v_c + lshift(I8[tobit((v_o + 8131))], 2)), 2)] = tobit(v_y)
if ((tobit(v_n) % 4294967296) < 129) then
goto L52
end
v_o = bor(v_r, v_T)
if not (v_o ~= 0) then
v_x = bor(lshift(v_P, 13), (rshift(v_J, 19) % 4294967296))
v_M = bor(lshift(v_w, 13), (rshift(v_W, 19) % 4294967296))
v_E = bor(lshift(v_j, 13), (rshift(v_F, 19) % 4294967296))
v_u = bor(lshift(v_S, 13), (rshift(v_D, 19) % 4294967296))
end
if not (v_o ~= 0) then
I32[arshift((4 + tobit((lshift(I8[tobit((imul(v_r, 80) + 8132))], 2) + v_A))), 2)] = tobit(v_S)
end
if not (v_o ~= 0) then
I32[arshift((4 + tobit((lshift(I8[tobit((imul(v_r, 80) + 8133))], 2) + v_A))), 2)] = tobit(v_w)
end
if not (v_o ~= 0) then
I32[arshift((4 + tobit((lshift(I8[tobit((imul(v_r, 80) + 8134))], 2) + v_A))), 2)] = tobit(v_P)
end
if not (v_o ~= 0) then
I32[arshift((4 + tobit((lshift(I8[tobit((imul(v_r, 80) + 8135))], 2) + v_A))), 2)] = tobit(v_j)
end
v_v = tobit((v_A + 4))
v_c = imul(v_r, 80)
I32[arshift((v_v + lshift(I8[tobit((v_c + 8136))], 2)), 2)] = tobit(bor(lshift(v_S, 15), (rshift(v_D, 17) % 4294967296)))
I32[arshift((v_v + lshift(I8[tobit((v_c + 8137))], 2)), 2)] = tobit(bor(lshift(v_w, 15), (rshift(v_W, 17) % 4294967296)))
I32[arshift((v_v + lshift(I8[tobit((v_c + 8138))], 2)), 2)] = tobit(bor(lshift(v_P, 15), (rshift(v_J, 17) % 4294967296)))
I32[arshift((v_v + lshift(I8[tobit((v_c + 8139))], 2)), 2)] = tobit(bor(lshift(v_j, 15), (rshift(v_F, 17) % 4294967296)))
I32[arshift((v_v + lshift(I8[tobit((v_c + 8140))], 2)), 2)] = tobit(bor(lshift(v_U, 30), (rshift(v_w, 2) % 4294967296)))
I32[arshift((v_v + lshift(I8[tobit((v_c + 8141))], 2)), 2)] = tobit(bor(lshift(v_R, 30), (rshift(v_P, 2) % 4294967296)))
I32[arshift((v_v + lshift(I8[tobit((v_c + 8142))], 2)), 2)] = tobit(bor(lshift(v_K, 30), (rshift(v_j, 2) % 4294967296)))
I32[arshift((v_v + lshift(I8[tobit((v_c + 8143))], 2)), 2)] = tobit(bor(lshift(v_Y, 30), (rshift(v_S, 2) % 4294967296)))
if not (v_o ~= 0) then
I32[arshift((4 + tobit((lshift(I8[tobit((v_c + 8144))], 2) + v_A))), 2)] = tobit(v_u)
end
if not (v_o ~= 0) then
I32[arshift((4 + tobit((lshift(I8[tobit((imul(v_r, 80) + 8145))], 2) + v_A))), 2)] = tobit(v_M)
end
if not (v_o ~= 0) then
I32[arshift((4 + tobit((lshift(I8[tobit((imul(v_r, 80) + 8146))], 2) + v_A))), 2)] = tobit(v_x)
end
v_Q = bor(lshift(v_K, 28), (rshift(v_j, 4) % 4294967296))
v_d = bor(lshift(v_R, 28), (rshift(v_P, 4) % 4294967296))
v_O = bor(lshift(v_U, 28), (rshift(v_w, 4) % 4294967296))
if not (v_o ~= 0) then
I32[arshift((4 + tobit((lshift(I8[tobit((imul(v_r, 80) + 8147))], 2) + v_A))), 2)] = tobit(v_E)
end
v_y = bor(lshift(v_Y, 28), (rshift(v_S, 4) % 4294967296))
v_o = tobit((v_A + 4))
v_u = imul(v_r, 80)
I32[arshift((v_o + lshift(I8[tobit((v_u + 8148))], 2)), 2)] = tobit(v_O)
I32[arshift((v_o + lshift(I8[tobit((v_u + 8149))], 2)), 2)] = tobit(v_d)
I32[arshift((v_o + lshift(I8[tobit((v_u + 8150))], 2)), 2)] = tobit(v_Q)
v_u = tobit((v_u + 8151))
end
I32[arshift((4 + tobit((lshift(I8[bor(0, v_u)], 2) + v_A))), 2)] = tobit(v_y)
end
::L52::
do
if not (v_r ~= 0) then
v_u = tobit((v_A + 4))
v_a = imul(v_r, 80)
I32[arshift((v_u + lshift(I8[tobit((v_a + 8152))], 2)), 2)] = tobit(v_l)
I32[arshift((v_u + lshift(I8[tobit((v_a + 8153))], 2)), 2)] = tobit(v_k)
I32[arshift((v_u + lshift(I8[tobit((v_a + 8154))], 2)), 2)] = tobit(v_s)
I32[arshift((v_u + lshift(I8[tobit((v_a + 8155))], 2)), 2)] = tobit(v_I)
v_Q = bor(lshift(v_s, 28), (rshift(v_I, 4) % 4294967296))
v_d = bor(lshift(v_k, 28), (rshift(v_s, 4) % 4294967296))
v_O = bor(lshift(v_l, 28), (rshift(v_k, 4) % 4294967296))
v_y = bor(lshift(v_I, 28), (rshift(v_l, 4) % 4294967296))
end
v_v = bor(lshift(v_I, 13), (rshift(v_l, 19) % 4294967296))
v_a = bor(lshift(v_s, 13), (rshift(v_I, 19) % 4294967296))
v_c = bor(lshift(v_k, 13), (rshift(v_s, 19) % 4294967296))
v_w = bor(lshift(v_l, 13), (rshift(v_k, 19) % 4294967296))
v_o = tobit((v_A + 4))
v_u = imul(v_r, 80)
I32[arshift((v_o + lshift(I8[tobit((v_u + 8156))], 2)), 2)] = tobit(bor(lshift(v_l, 15), (rshift(v_k, 17) % 4294967296)))
I32[arshift((v_o + lshift(I8[tobit((v_u + 8157))], 2)), 2)] = tobit(bor(lshift(v_k, 15), (rshift(v_s, 17) % 4294967296)))
I32[arshift((v_o + lshift(I8[tobit((v_u + 8158))], 2)), 2)] = tobit(bor(lshift(v_s, 15), (rshift(v_I, 17) % 4294967296)))
I32[arshift((v_o + lshift(I8[tobit((v_u + 8159))], 2)), 2)] = tobit(bor(lshift(v_I, 15), (rshift(v_l, 17) % 4294967296)))
I32[arshift((v_o + lshift(I8[tobit((v_u + 8160))], 2)), 2)] = tobit(bor(lshift(v_l, 30), (rshift(v_k, 2) % 4294967296)))
I32[arshift((v_o + lshift(I8[tobit((v_u + 8161))], 2)), 2)] = tobit(bor(lshift(v_k, 30), (rshift(v_s, 2) % 4294967296)))
I32[arshift((v_o + lshift(I8[tobit((v_u + 8162))], 2)), 2)] = tobit(bor(lshift(v_s, 30), (rshift(v_I, 2) % 4294967296)))
I32[arshift((v_o + lshift(I8[tobit((v_u + 8163))], 2)), 2)] = tobit(bor(lshift(v_I, 30), (rshift(v_l, 2) % 4294967296)))
if (v_T ~= 0) then
v_s = tobit((v_u + 8166))
v_l = tobit((v_u + 8165))
v_o = v_a
v_u = v_c
else
I32[arshift((v_o + lshift(I8[tobit((v_u + 8164))], 2)), 2)] = tobit(v_w)
I32[arshift((v_o + lshift(I8[tobit((v_u + 8165))], 2)), 2)] = tobit(v_c)
v_s = tobit((v_u + 8167))
v_l = tobit((v_u + 8166))
v_o = v_v
v_u = v_a
end
v_C = lshift(I8[bor(0, v_l)], 2)
local t86 = v_C
v_l = tobit((v_A + 4))
I32[arshift((t86 + v_l), 2)] = tobit(v_u)
I32[arshift((v_l + lshift(I8[bor(0, v_s)], 2)), 2)] = tobit(v_o)
if not (v_r ~= 0) then
v_u = imul(v_r, 80)
I32[arshift((v_l + lshift(I8[tobit((v_u + 8168))], 2)), 2)] = tobit(v_O)
I32[arshift((v_l + lshift(I8[tobit((v_u + 8169))], 2)), 2)] = tobit(v_d)
I32[arshift((v_l + lshift(I8[tobit((v_u + 8170))], 2)), 2)] = tobit(v_Q)
I32[arshift((v_l + lshift(I8[tobit((v_u + 8171))], 2)), 2)] = tobit(v_y)
end
if not (bor((((tobit(v_n) % 4294967296) < 129) and 1 or 0), v_T) ~= 0) then
v_o = bor(v_r, v_T)
if not (v_o ~= 0) then
v_v = bor(lshift(v_m, 13), (rshift(v_b, 19) % 4294967296))
v_c = bor(lshift(v_h, 13), (rshift(v_p, 19) % 4294967296))
v_w = bor(lshift(v_b, 13), (rshift(v_h, 19) % 4294967296))
v_a = bor(lshift(v_p, 13), (rshift(v_m, 19) % 4294967296))
end
v_u = tobit((v_A + 4))
v_n = imul(v_r, 80)
I32[arshift((v_u + lshift(I8[tobit((v_n + 8172))], 2)), 2)] = tobit(v_b)
I32[arshift((v_u + lshift(I8[tobit((v_n + 8173))], 2)), 2)] = tobit(v_h)
I32[arshift((v_u + lshift(I8[tobit((v_n + 8174))], 2)), 2)] = tobit(v_p)
I32[arshift((v_u + lshift(I8[tobit((v_n + 8175))], 2)), 2)] = tobit(v_m)
I32[arshift((v_u + lshift(I8[tobit((v_n + 8176))], 2)), 2)] = tobit(bor(lshift(v_b, 15), (rshift(v_h, 17) % 4294967296)))
I32[arshift((v_u + lshift(I8[tobit((v_n + 8177))], 2)), 2)] = tobit(bor(lshift(v_h, 15), (rshift(v_p, 17) % 4294967296)))
I32[arshift((v_u + lshift(I8[tobit((v_n + 8178))], 2)), 2)] = tobit(bor(lshift(v_p, 15), (rshift(v_m, 17) % 4294967296)))
I32[arshift((v_u + lshift(I8[tobit((v_n + 8179))], 2)), 2)] = tobit(bor(lshift(v_m, 15), (rshift(v_b, 17) % 4294967296)))
I32[arshift((v_u + lshift(I8[tobit((v_n + 8180))], 2)), 2)] = tobit(bor(lshift(v_b, 30), (rshift(v_h, 2) % 4294967296)))
I32[arshift((v_u + lshift(I8[tobit((v_n + 8181))], 2)), 2)] = tobit(bor(lshift(v_h, 30), (rshift(v_p, 2) % 4294967296)))
I32[arshift((v_u + lshift(I8[tobit((v_n + 8182))], 2)), 2)] = tobit(bor(lshift(v_p, 30), (rshift(v_m, 2) % 4294967296)))
I32[arshift((v_u + lshift(I8[tobit((v_n + 8183))], 2)), 2)] = tobit(bor(lshift(v_m, 30), (rshift(v_b, 2) % 4294967296)))
if not (v_o ~= 0) then
I32[arshift((4 + tobit((lshift(I8[tobit((v_n + 8184))], 2) + v_A))), 2)] = tobit(v_w)
end
if not (v_o ~= 0) then
I32[arshift((4 + tobit((lshift(I8[tobit((imul(v_r, 80) + 8185))], 2) + v_A))), 2)] = tobit(v_c)
end
if not (v_o ~= 0) then
I32[arshift((4 + tobit((lshift(I8[tobit((imul(v_r, 80) + 8186))], 2) + v_A))), 2)] = tobit(v_a)
end
if not (v_o ~= 0) then
I32[arshift((4 + tobit((lshift(I8[tobit((imul(v_r, 80) + 8187))], 2) + v_A))), 2)] = tobit(v_v)
end
v_a = tobit((v_A + 4))
v_n = imul(v_r, 80)
I32[arshift((v_a + lshift(I8[tobit((v_n + 8188))], 2)), 2)] = tobit(bor(lshift(v_b, 28), (rshift(v_h, 4) % 4294967296)))
I32[arshift((v_a + lshift(I8[tobit((v_n + 8189))], 2)), 2)] = tobit(bor(lshift(v_h, 28), (rshift(v_p, 4) % 4294967296)))
I32[arshift((v_a + lshift(I8[tobit((v_n + 8190))], 2)), 2)] = tobit(bor(lshift(v_p, 28), (rshift(v_m, 4) % 4294967296)))
I32[arshift((v_a + lshift(I8[tobit((v_n + 8191))], 2)), 2)] = tobit(bor(lshift(v_m, 28), (rshift(v_b, 4) % 4294967296)))
end
v_n = tobit((v_A + 4))
v_c = imul(v_r, 12)
v_u = lshift(v_c, 2)
v_a = imul(v_r, 20)
I32[arshift((v_n + bor(128, v_u)), 2)] = tobit(I32[arshift((v_n + lshift(I8[tobit((v_a + 8272))], 2)), 2)])
I32[arshift((v_n + bor(132, v_u)), 2)] = tobit(I32[arshift((v_n + lshift(I8[tobit((v_a + 8273))], 2)), 2)])
I32[arshift((v_n + bor(136, v_u)), 2)] = tobit(I32[arshift((v_n + lshift(I8[tobit((v_a + 8274))], 2)), 2)])
I32[arshift((v_n + bor(140, v_u)), 2)] = tobit(I32[arshift((v_n + lshift(I8[tobit((v_a + 8275))], 2)), 2)])
if not (v_T ~= 0) then
v_o = tobit((v_n + v_u))
I32[arshift((144 + v_o), 2)] = tobit(I32[arshift((v_n + lshift(I8[tobit((v_a + 8276))], 2)), 2)])
I32[arshift((v_o + 148), 2)] = tobit(I32[arshift((v_n + lshift(I8[tobit((v_a + 8277))], 2)), 2)])
I32[arshift((v_o + 152), 2)] = tobit(I32[arshift((v_n + lshift(I8[tobit((v_a + 8278))], 2)), 2)])
I32[arshift((v_o + 156), 2)] = tobit(I32[arshift((v_n + lshift(I8[tobit((v_a + 8279))], 2)), 2)])
end
v_u = tobit((v_n + v_u))
I32[arshift((160 + v_u), 2)] = tobit(I32[arshift((v_n + lshift(I8[tobit((v_a + 8280))], 2)), 2)])
I32[arshift((v_u + 164), 2)] = tobit(I32[arshift((v_n + lshift(I8[tobit((v_a + 8281))], 2)), 2)])
I32[arshift((v_u + 168), 2)] = tobit(I32[arshift((v_n + lshift(I8[tobit((v_a + 8282))], 2)), 2)])
I32[arshift((v_u + 172), 2)] = tobit(I32[arshift((v_n + lshift(I8[tobit((v_a + 8283))], 2)), 2)])
v_a = 0
if not (v_r ~= 0) then
v_A = tobit((v_A + 4))
v_n = tobit((v_A + lshift(v_c, 2)))
v_r = imul(v_r, 20)
I32[arshift((v_n + 176), 2)] = tobit(I32[arshift((v_A + lshift(I8[tobit((v_r + 8284))], 2)), 2)])
I32[arshift((v_n + 180), 2)] = tobit(I32[arshift((v_A + lshift(I8[tobit((v_r + 8285))], 2)), 2)])
I32[arshift((v_n + 184), 2)] = tobit(I32[arshift((v_A + lshift(I8[tobit((v_r + 8286))], 2)), 2)])
I32[arshift((v_n + 188), 2)] = tobit(I32[arshift((v_A + lshift(I8[tobit((v_r + 8287))], 2)), 2)])
I32[arshift((v_n + 192), 2)] = tobit(I32[arshift((v_A + lshift(I8[tobit((v_r + 8288))], 2)), 2)])
I32[arshift((v_n + 196), 2)] = tobit(I32[arshift((v_A + lshift(I8[tobit((v_r + 8289))], 2)), 2)])
I32[arshift((v_n + 200), 2)] = tobit(I32[arshift((v_A + lshift(I8[tobit((v_r + 8290))], 2)), 2)])
I32[arshift((v_n + 204), 2)] = tobit(I32[arshift((v_A + lshift(I8[tobit((v_r + 8291))], 2)), 2)])
end
end
end
end
::L49::
end
B = tobit((v_e - (-64)))
do return v_a end
end

F.fQ = function(v_A, v_r, v_n, v_e, v_a, v_u, v_c)
local v_s, v_l, v_b, v_p, v_h, v_d, v_k, v_y, v_w, v_C, v_E, v_I, v_m, v_Q, v_O, v_S, v_j = 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
v_p = 0
v_h = 0
v_d = 0
v_k = 0
v_y = 0
v_w = 0
v_C = 0
v_E = 0
v_I = 0
v_m = 0
v_Q = 0
v_O = 0
v_S = 0
v_j = 0
v_s = tobit((B - 80))
B = v_s
I32[arshift((v_s + 76), 2)] = tobit(v_r)
v_b = tobit((v_s + 55))
v_l = tobit((v_s + 56))
v_r = 0
do
do
while true do
do
do
if not (bor(0, v_I) < 0) then
if (tobit((2147483647 - v_I)) < bor(0, v_r)) then
I32[5460] = tobit(61)
v_I = (-1)
else
v_I = tobit((v_r + v_I))
end
end
do
do
do
do
do
do
do
do
do
do
do
do
do
do
do
do
do
do
do
do
do
v_d = v_s
do
do
do
do
do
v_w = I32[arshift((v_s + 76), 2)]
v_r = v_w
v_p = U8[bor(0, v_r)]
if (v_p ~= 0) then
do
while true do
do
do
do
v_p = band(v_p, 255)
if (v_p ~= 0) then
if (37 ~= bor(0, v_p)) then
goto L65
end
do
v_p = v_r
while true do
do
if (37 ~= U8[tobit((v_r + 1))]) then
goto L66
end
v_h = tobit((v_r + 2))
I32[arshift((v_s + 76), 2)] = tobit(v_h)
v_p = tobit((v_p + 1))
v_y = U8[tobit((v_r + 2))]
v_r = v_h
if (37 ~= bor(0, v_y)) then
goto B67
end
end
::C67::
end
end
::B67::
else
v_p = v_r
end
end
::L66::
v_r = tobit((v_p - v_w))
if (v_A ~= 0) then
F.fnA(v_A, v_w, v_r)
end
if (v_r ~= 0) then
goto C53
end
v_h = ((not (F.fPA(I8[tobit((I32[arshift((v_s + 76), 2)] + 1))]) ~= 0)) and 1 or 0)
v_r = I32[arshift((v_s + 76), 2)]
if (bor(v_h, ((36 ~= U8[tobit((v_r + 2))]) and 1 or 0)) ~= 0) then
goto L63
end
v_m = tobit((I8[tobit((v_r + 1))] - 48))
v_O = 1
v_r = tobit((v_r + 3))
goto L62
end
::L65::
v_h = tobit((v_r + 1))
I32[arshift((v_s + 76), 2)] = tobit(v_h)
v_p = U8[tobit((v_r + 1))]
v_r = v_h
end
::C64::
end
end
::B64::
end
v_C = v_I
if (v_A ~= 0) then
goto L55
end
if (not (v_O ~= 0)) then
goto L61
end
do
v_r = 1
while true do
do
v_A = I32[arshift((lshift(v_r, 2) + v_a), 2)]
if (v_A ~= 0) then
F.frA(tobit((lshift(v_r, 3) + v_e)), v_A, v_n, v_c)
v_C = 1
v_r = tobit((v_r + 1))
if (10 ~= bor(0, v_r)) then
goto C68
end
goto L55
end
goto B68
end
::C68::
end
end
::B68::
v_C = 1
if ((tobit(v_r) % 4294967296) >= 10) then
goto L55
end
do
while true do
do
if (I32[arshift((lshift(v_r, 2) + v_a), 2)] ~= 0) then
goto L56
end
v_r = tobit((v_r + 1))
if (10 == bor(0, v_r)) then
goto B69
end
end
::C69::
end
end
::B69::
goto L55
end
::L63::
v_m = (-1)
v_r = tobit((v_r + 1))
end
::L62::
do
I32[arshift((v_d + 76), 2)] = tobit(v_r)
v_d = 0
v_k = I8[bor(0, v_r)]
v_p = tobit((v_k - 32))
local t87 = ((not ((tobit(v_p) % 4294967296) > 31)) and 1 or 0)
if t87 ~= 0 then
v_p = lshift(1, v_p)
t87 = band(75913, v_p)
end
if (t87 ~= 0) then
do
do
do
while true do
do
v_h = tobit((v_r + 1))
I32[arshift((v_s + 76), 2)] = tobit(v_h)
v_k = I8[tobit((v_r + 1))]
v_r = tobit((v_k - 32))
local t88 = ((not ((tobit(v_r) % 4294967296) >= 32)) and 1 or 0)
if t88 ~= 0 then
v_r = lshift(1, v_r)
t88 = band(75913, v_r)
end
if not (t88 ~= 0) then goto B70 end
end
do
v_p = bor(v_p, v_r)
v_r = v_h
end
::C70::
end
end
::B70::
end
v_r = v_h
v_d = v_p
end
end
end
do
do
do
if (42 ~= bor(0, v_k)) then
v_E = F.fCA(tobit((v_s + 76)))
if (bor(0, v_E) < 0) then
goto L56
end
v_r = I32[arshift((v_s + 76), 2)]
else
do
do
v_h = v_s
local t89 = F.fPA(I8[tobit((v_r + 1))])
if t89 ~= 0 then
v_r = I32[arshift((v_s + 76), 2)]
t89 = ((36 == U8[tobit((v_r + 2))]) and 1 or 0)
end
if (t89 ~= 0) then
I32[arshift((tobit((lshift(I8[tobit((v_r + 1))], 2) + v_a)) - 192), 2)] = tobit(10)
v_E = I32[arshift((tobit((lshift(I8[tobit((v_r + 1))], 3) + v_e)) - 384), 2)]
v_O = 1
v_r = tobit((v_r + 3))
else
if (v_O ~= 0) then
goto L56
end
v_O = 0
v_E = 0
if (v_A ~= 0) then
v_r = I32[arshift(v_n, 2)]
I32[arshift(v_n, 2)] = tobit((v_r + 4))
v_E = I32[arshift(v_r, 2)]
end
v_r = tobit((I32[arshift((v_s + 76), 2)] + 1))
end
end
I32[arshift((v_h + 76), 2)] = tobit(v_r)
if (bor(0, v_E) > (-1)) then
goto L71
end
v_E = tobit((0 - v_E))
v_d = bor(v_d, 8192)
end
end
end
end
::L71::
end
v_y = (-1)
do
do
do
if (46 == U8[bor(0, v_r)]) then
do
if (42 ~= U8[tobit((v_r + 1))]) then
I32[arshift((v_s + 76), 2)] = tobit((v_r + 1))
v_y = F.fCA(tobit((v_s + 76)))
v_r = I32[arshift((v_s + 76), 2)]
else
do
do
local t90 = (F.fPA(I8[tobit((v_r + 2))]) ~= 0)
if t90 then
v_r = I32[arshift((v_s + 76), 2)]
t90 = (36 == U8[tobit((v_r + 3))])
end
if t90 then
I32[arshift((tobit((lshift(I8[tobit((v_r + 2))], 2) + v_a)) - 192), 2)] = tobit(10)
v_y = I32[arshift((tobit((lshift(I8[tobit((v_r + 2))], 3) + v_e)) - 384), 2)]
v_r = tobit((v_r + 4))
I32[arshift((v_s + 76), 2)] = tobit(v_r)
goto L72
end
end
if (v_O ~= 0) then
goto L56
end
if (v_A ~= 0) then
v_r = I32[arshift(v_n, 2)]
I32[arshift(v_n, 2)] = tobit((v_r + 4))
v_y = I32[arshift(v_r, 2)]
else
v_y = 0
end
v_r = tobit((I32[arshift((v_s + 76), 2)] + 2))
I32[arshift((v_s + 76), 2)] = tobit(v_r)
end
end
end
end
end
end
::L72::
end
do
v_p = 0
while true do
do
v_Q = v_p
v_C = (-1)
if ((tobit((I8[bor(0, v_r)] - 65)) % 4294967296) > 57) then
goto L55
end
v_k = tobit((v_r + 1))
I32[arshift((v_s + 76), 2)] = tobit(v_k)
v_p = I8[bor(0, v_r)]
v_r = v_k
v_p = U8[tobit((1071 + tobit((v_p + imul(v_Q, 58)))))]
if (not ((tobit((v_p - 1)) % 4294967296) < 8)) then
goto B73
end
end
::C73::
end
end
::B73::
if (19 == bor(0, v_p)) then
goto L59
end
if (not (v_p ~= 0)) then
goto L55
end
if (bor(0, v_m) >= 0) then
I32[arshift((lshift(v_m, 2) + v_a), 2)] = tobit(v_p)
v_r = tobit((lshift(v_m, 3) + v_e))
v_p = I32[arshift((4 + v_r), 2)]
I32[arshift((v_s + 64), 2)] = tobit(I32[arshift(v_r, 2)])
I32[arshift((v_s + 68), 2)] = tobit(v_p)
goto L58
end
if (v_A ~= 0) then
goto L60
end
end
end
::L61::
end
v_C = 0
goto L55
end
end
::L60::
end
F.frA(tobit((v_s - (-64))), v_p, v_n, v_c)
v_k = I32[arshift((v_s + 76), 2)]
goto L57
end
end
::L59::
end
if (bor(0, v_m) > (-1)) then
goto L55
end
end
end
::L58::
end
v_r = 0
if (not (v_A ~= 0)) then
goto C53
end
end
end
::L57::
end
v_h = band((-65537), v_d)
v_p = ((band(8192, v_d) ~= 0) and v_h or v_d)
v_C = 0
v_m = 1029
v_d = v_l
do
do
do
do
do
do
do
do
do
do
do
do
do
do
do
do
do
do
do
do
do
do
do
do
do
do
do
do
do
do
do
do
do
do
do
do
do
v_r = I8[tobit((v_k - 1))]
v_r = (((v_Q ~= 0) and (3 == band(15, v_r))) and band((-33), v_r) or v_r)
do
local sw89 = tobit((v_r - 88))
if sw89 == 11 then goto K89_0
elseif sw89 == 1 then goto K89_1
elseif sw89 == 2 then goto K89_2
elseif sw89 == 3 then goto K89_3
elseif sw89 == 4 then goto K89_4
elseif sw89 == 5 then goto K89_5
elseif sw89 == 6 then goto K89_6
elseif sw89 == 7 then goto K89_7
elseif sw89 == 8 then goto K89_8
elseif sw89 == 10 then goto K89_9
elseif sw89 == 16 then goto K89_10
elseif sw89 == 18 then goto K89_11
elseif sw89 == 19 then goto K89_12
elseif sw89 == 20 then goto K89_13
elseif sw89 == 21 then goto K89_14
elseif sw89 == 25 then goto K89_15
elseif sw89 == 26 then goto K89_16
elseif sw89 == 28 then goto K89_17
elseif sw89 == 30 then goto K89_18
elseif sw89 == 31 then goto K89_19
elseif sw89 == 9 then goto K89_20
elseif sw89 == 13 then goto K89_21
elseif sw89 == 14 then goto K89_22
elseif sw89 == 15 then goto K89_23
elseif sw89 == 27 then goto K89_24
elseif sw89 == 12 then goto K89_25
elseif sw89 == 17 then goto K89_26
elseif sw89 == 23 then goto K89_27
elseif sw89 == 0 then goto K89_28
elseif sw89 == 32 then goto K89_29
elseif sw89 == 24 then goto K89_30
elseif sw89 == 22 then goto K89_31
elseif sw89 == 29 then goto K89_32
else goto S89 end
::K89_0::
do
goto L74
end
::K89_1::
do
end
::K89_2::
do
end
::K89_3::
do
end
::K89_4::
do
end
::K89_5::
do
end
::K89_6::
do
end
::K89_7::
do
end
::K89_8::
do
end
::K89_9::
do
end
::K89_10::
do
end
::K89_11::
do
end
::K89_12::
do
end
::K89_13::
do
end
::K89_14::
do
end
::K89_15::
do
end
::K89_16::
do
end
::K89_17::
do
end
::K89_18::
do
end
::K89_19::
do
goto L54
end
::K89_20::
do
end
::K89_21::
do
end
::K89_22::
do
end
::K89_23::
do
goto L75
end
::K89_24::
do
goto L80
end
::K89_25::
do
end
::K89_26::
do
goto L83
end
::K89_27::
do
goto L84
end
::K89_28::
do
end
::K89_29::
do
goto L85
end
::K89_30::
do
goto L86
end
::K89_31::
do
goto L87
end
::K89_32::
do
goto L88
end
end
::S89::
do
local sw90 = tobit((v_r - 65))
if sw90 == 1 then goto K90_0
elseif sw90 == 3 then goto K90_1
elseif sw90 == 0 then goto K90_2
elseif sw90 == 4 then goto K90_3
elseif sw90 == 5 then goto K90_4
elseif sw90 == 6 then goto K90_5
elseif sw90 == 2 then goto K90_6
else goto S90 end
::K90_0::
do
end
::K90_1::
do
goto L54
end
::K90_2::
do
end
::K90_3::
do
end
::K90_4::
do
end
::K90_5::
do
goto L75
end
::K90_6::
do
goto L78
end
end
::S90::
if (83 == bor(0, v_r)) then
goto L79
end
goto L54
end
::L88::
v_k = I32[arshift((v_s + 64), 2)]
v_h = I32[arshift((v_s + 68), 2)]
v_m = 1029
goto L82
end
::L87::
v_r = 0
do
local sw91 = band(255, v_Q)
if sw91 == 0 then goto K91_0
elseif sw91 == 1 then goto K91_1
elseif sw91 == 2 then goto K91_2
elseif sw91 == 3 then goto K91_3
elseif sw91 == 4 then goto K91_4
elseif sw91 == 6 then goto K91_5
elseif sw91 == 7 then goto K91_6
else goto K91_7 end
::K91_0::
do
end
::K91_1::
do
I32[arshift(I32[arshift((v_s + 64), 2)], 2)] = tobit(v_I)
goto C53
end
::K91_2::
do
v_p = I32[arshift((v_s + 64), 2)]
I32[arshift(v_p, 2)] = tobit(v_I)
I32[arshift((v_p + 4), 2)] = tobit(arshift(v_I, 31))
goto C53
end
::K91_3::
do
I16[arshift(I32[arshift((v_s + 64), 2)], 1)] = tobit(v_I)
goto C53
end
::K91_4::
do
I8[I32[arshift((v_s + 64), 2)]] = tobit(v_I)
goto C53
end
::K91_5::
do
I32[arshift(I32[arshift((v_s + 64), 2)], 2)] = tobit(v_I)
goto C53
end
::K91_6::
do
goto S91
end
::K91_7::
do
goto C53
end
end
::S91::
v_p = I32[arshift((v_s + 64), 2)]
I32[arshift(v_p, 2)] = tobit(v_I)
I32[arshift((v_p + 4), 2)] = tobit(arshift(v_I, 31))
goto C53
end
::L86::
v_y = (((tobit(v_y) % 4294967296) > 8) and v_y or 8)
v_p = bor(v_p, 8)
v_r = 120
end
::L85::
do
v_w = v_l
v_S = band(32, v_r)
v_Q = I32[arshift((v_s + 68), 2)]
v_h = v_Q
local t91 = v_h
v_k = I32[arshift((v_s + 64), 2)]
if (bor(t91, v_k) ~= 0) then
do
while true do
v_w = tobit((v_w - 1))
I8[bor(0, v_w)] = tobit(bor(v_S, U8[tobit((1600 + band(15, v_k)))]))
v_j = bor(band(((not (v_h ~= 0)) and 1 or 0), (((tobit(v_k) % 4294967296) > 15) and 1 or 0)), ((0 ~= bor(0, v_h)) and 1 or 0))
v_Q = v_h
v_h = tobit((rshift(v_h, 4) % 4294967296))
v_k = bor(lshift(band(15, v_Q), 28), (rshift(v_k, 4) % 4294967296))
if not (v_j ~= 0) then goto B92 end
do
end
::C92::
end
end
::B92::
end
end
if (bor(((not (band(8, v_p) ~= 0)) and 1 or 0), ((not (bor(I32[arshift((v_s + 64), 2)], I32[arshift((v_s + 68), 2)]) ~= 0)) and 1 or 0)) ~= 0) then
goto L81
end
v_m = tobit((1029 + tobit((rshift(v_r, 4) % 4294967296))))
v_C = 2
goto L81
end
end
::L84::
end
do
v_r = v_l
v_w = I32[arshift((v_s + 68), 2)]
v_h = v_w
local t92 = v_h
v_k = I32[arshift((v_s + 64), 2)]
if (bor(t92, v_k) ~= 0) then
do
while true do
v_r = tobit((v_r - 1))
I8[bor(0, v_r)] = tobit(bor(band(7, v_k), 48))
v_Q = bor(band(((not (v_h ~= 0)) and 1 or 0), (((tobit(v_k) % 4294967296) > 7) and 1 or 0)), ((0 ~= bor(0, v_h)) and 1 or 0))
v_w = v_h
v_h = tobit((rshift(v_h, 3) % 4294967296))
v_k = bor(lshift(band(7, v_w), 29), (rshift(v_k, 3) % 4294967296))
if not (v_Q ~= 0) then goto B93 end
do
end
::C93::
end
end
::B93::
end
end
v_w = v_r
if (not (band(8, v_p) ~= 0)) then
goto L81
end
v_r = tobit((v_l - v_w))
v_y = ((bor(0, v_r) < bor(0, v_y)) and v_y or tobit((v_r + 1)))
goto L81
end
end
::L83::
end
v_r = I32[arshift((v_s + 68), 2)]
v_h = v_r
v_k = I32[arshift((v_s + 64), 2)]
if ((bor(0, v_r) < (-1)) or (bor(0, v_r) <= (-1))) then
v_h = tobit((0 - tobit((v_h + ((0 ~= bor(0, v_k)) and 1 or 0)))))
v_k = tobit((0 - v_k))
I32[arshift((v_s + 64), 2)] = tobit(v_k)
I32[arshift((v_s + 68), 2)] = tobit(v_h)
v_C = 1
v_m = 1029
else
if (band(2048, v_p) ~= 0) then
v_C = 1
v_m = 1030
else
v_C = band(1, v_p)
v_m = ((v_C ~= 0) and 1031 or 1029)
end
end
end
end
::L82::
end
v_w = F.fbA(v_k, v_h, v_l)
end
end
::L81::
end
v_p = ((bor(0, v_y) > (-1)) and band((-65537), v_p) or v_p)
v_r = I32[arshift((v_s + 68), 2)]
v_h = v_r
v_k = I32[arshift((v_s + 64), 2)]
if (not (bor(bor(((0 ~= bor(0, v_k)) and 1 or 0), ((0 ~= bor(0, v_r)) and 1 or 0)), v_y) ~= 0)) then
v_y = 0
v_w = v_l
goto L54
end
v_r = tobit((((not (bor(v_h, v_k) ~= 0)) and 1 or 0) + tobit((v_l - v_w))))
v_y = ((bor(0, v_r) < bor(0, v_y)) and v_y or v_r)
goto L54
end
end
::L80::
end
v_r = v_y
v_d = ((0 ~= bor(0, v_r)) and 1 or 0)
do
do
do
do
do
do
do
do
do
do
do
do
v_p = I32[arshift((v_s + 64), 2)]
local t93 = v_p
if t93 == 0 then
t93 = 1129
end
v_w = t93
v_p = v_w
if (not (bor(((not (band(3, v_p) ~= 0)) and 1 or 0), ((not (v_r ~= 0)) and 1 or 0)) ~= 0)) then
do
while true do
do
if (not (U8[bor(0, v_p)] ~= 0)) then
goto L96
end
v_r = tobit((v_r - 1))
v_d = ((0 ~= bor(0, v_r)) and 1 or 0)
v_p = tobit((v_p + 1))
if (not (band(3, v_p) ~= 0)) then
goto L97
end
if (not (v_r ~= 0)) then
goto B98
end
end
::C98::
end
end
::B98::
end
end
end
::L97::
end
if (not (v_d ~= 0)) then
goto L95
end
end
end
::L96::
end
do
do
do
if (not (bor(((not (U8[bor(0, v_p)] ~= 0)) and 1 or 0), (((tobit(v_r) % 4294967296) < 4) and 1 or 0)) ~= 0)) then
do
do
while true do
do
do
do
local t94 = (-1)
v_d = I32[arshift(v_p, 2)]
if (band(band(bxor(t94, v_d), (v_d - 16843009)), (-2139062144)) ~= 0) then
goto L99
end
end
v_p = tobit((v_p + 4))
v_r = tobit((v_r - 4))
if (not ((tobit(v_r) % 4294967296) > 3)) then
goto B100
end
end
end
::C100::
end
end
::B100::
end
end
end
end
::L99::
end
if (v_r ~= 0) then
do
while true do
do
v_d = v_p
if (not (U8[bor(0, v_p)] ~= 0)) then
goto L94
end
v_p = tobit((v_p + 1))
v_r = tobit((v_r - 1))
if (not (v_r ~= 0)) then
goto B101
end
end
::C101::
end
end
::B101::
end
end
end
::L95::
end
v_d = 0
end
end
::L94::
end
do
v_r = v_d
local t95 = v_r
if t95 == 0 then
t95 = tobit((v_y + v_w))
end
v_d = t95
v_p = v_h
v_y = ((v_r ~= 0) and tobit((v_r - v_w)) or v_y)
end
goto L54
end
end
::L79::
end
v_d = I32[arshift((v_s + 64), 2)]
if (v_y ~= 0) then
goto L77
end
v_r = 0
F.fdA(v_A, 32, v_E, 0, v_p)
goto L76
end
end
::L78::
end
I32[arshift((v_s + 12), 2)] = tobit(0)
I32[arshift((v_s + 8), 2)] = tobit(I32[arshift((v_s + 64), 2)])
I32[arshift((v_s + 64), 2)] = tobit((v_s + 8))
v_y = (-1)
v_d = tobit((v_s + 8))
end
end
::L77::
end
v_r = 0
do
do
do
do
do
while true do
do
do
v_h = I32[arshift(v_d, 2)]
if (not (v_h ~= 0)) then
goto L102
end
do
v_h = F.feA(tobit((v_s + 4)), v_h)
v_w = ((bor(0, v_h) < 0) and 1 or 0)
if (not (bor(v_w, (((tobit(v_h) % 4294967296) > (tobit((v_y - v_r)) % 4294967296)) and 1 or 0)) ~= 0)) then
do
do
v_d = tobit((v_d + 4))
local t96 = (tobit(v_y) % 4294967296)
v_r = tobit((v_r + v_h))
if (t96 > (tobit(v_r) % 4294967296)) then
goto C103
end
end
goto L102
end
end
end
goto B103
end
end
::C103::
end
end
::B103::
end
v_C = (-1)
if (v_w ~= 0) then
goto L55
end
end
end
::L102::
end
F.fdA(v_A, 32, v_E, v_r, v_p)
if (v_r ~= 0) then
do
v_d = 0
v_k = I32[arshift((v_s + 64), 2)]
while true do
do
v_h = I32[arshift(v_k, 2)]
if (not (v_h ~= 0)) then
goto L76
end
v_h = F.feA(tobit((v_s + 4)), v_h)
v_d = tobit((v_h + v_d))
if (bor(0, v_d) > bor(0, v_r)) then
goto L76
end
F.fnA(v_A, tobit((v_s + 4)), v_h)
v_k = tobit((v_k + 4))
if (not ((tobit(v_r) % 4294967296) > (tobit(v_d) % 4294967296))) then
goto B104
end
end
::C104::
end
end
::B104::
else
v_r = 0
end
end
end
::L76::
end
F.fdA(v_A, 32, v_E, v_r, bxor(8192, v_p))
v_r = ((bor(0, v_r) < bor(0, v_E)) and v_E or v_r)
goto C53
end
end
::L75::
end
v_r = bor(0, UA[bor(0, v_u)](v_A, F64[arshift((v_s + 64), 3)], v_E, v_y, v_p, v_r))
goto C53
end
end
::L74::
end
I8[tobit((v_s + 55))] = tobit(I32[arshift((v_s + 64), 2)])
v_y = 1
v_w = v_b
v_p = v_h
goto L54
end
end
::L56::
end
v_C = (-1)
end
end
::L55::
end
B = tobit((v_s + 80))
do return v_C end
end
end
::L54::
end
do
local t98 = v_A
local t97 = bor(0, v_y)
v_d = tobit((v_d - v_w))
v_y = ((t97 < bor(0, v_d)) and v_d or v_y)
v_h = tobit((v_y + v_C))
v_r = ((bor(0, v_h) > bor(0, v_E)) and v_h or v_E)
F.fdA(t98, 32, v_r, v_h, v_p)
F.fnA(v_A, v_m, v_C)
F.fdA(v_A, 48, v_r, v_h, bxor(65536, v_p))
F.fdA(v_A, 48, v_y, v_d, 0)
F.fnA(v_A, v_w, v_d)
F.fdA(v_A, 32, v_r, v_h, bxor(8192, v_p))
end
end
end
::C53::
end
end
::B53::
end
end

F.fO = function(v_A, v_r, v_n)
local v_e, v_o, v_a, v_u, v_c, v_s, v_l, v_b, v_v, v_g = 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
v_o = 0
v_a = 0
v_u = 0
v_c = 0
v_s = 0
v_l = 0
v_b = 0
v_v = 0
v_g = 0
do
v_e = tobit((B - 2048))
B = v_e
if (not (U8[22404] ~= 0)) then
do
do
do
v_o = 1
while true do
do
I32[arshift((tobit((v_e + 1024)) + lshift(v_s, 2)), 2)] = tobit(v_o)
I32[arshift((lshift(v_o, 2) + v_e), 2)] = tobit(v_s)
v_u = band(arshift(lshift(v_o, 24), 31), 27)
local t99 = v_u
v_o = bxor(v_o, band(lshift(v_o, 1), 254))
v_u = bxor(t99, v_o)
local t100 = tobit((v_e + 1024))
v_a = bor(1, v_s)
I32[arshift((t100 + lshift(v_a, 2)), 2)] = tobit(v_u)
I32[arshift((lshift(v_u, 2) + v_e), 2)] = tobit(v_a)
v_o = bxor(bxor(band(arshift(lshift(v_o, 24), 31), 27), v_u), band(lshift(v_u, 1), 254))
v_s = tobit((v_s + 2))
if not (256 ~= bor(0, v_s)) then goto B105 end
end
do
end
::C105::
end
end
::B105::
end
do
do
I32[5612] = tobit(27)
I32[5613] = tobit(54)
I32[5610] = tobit(64)
I32[5611] = tobit(128)
I32[5608] = tobit(16)
I32[5609] = tobit(32)
I32[5606] = tobit(4)
I32[5607] = tobit(8)
I32[5604] = tobit(1)
I32[5605] = tobit(2)
I8[22464] = tobit(99)
I8[31011] = tobit(0)
v_o = 1
while true do
do
v_u = I32[arshift((2044 + tobit((lshift((0 - I32[arshift((lshift(v_o, 2) + v_e), 2)]), 2) + v_e))), 2)]
v_s = band(255, bor(lshift(v_u, 1), (rshift(v_u, 7) % 4294967296)))
v_a = band(lshift(v_s, 1), 254)
local t101 = (rshift(v_a, 7) % 4294967296)
v_c = bor(v_a, (rshift(v_s, 7) % 4294967296))
v_l = band(lshift(v_c, 1), 254)
v_a = bor(t101, v_l)
v_u = bxor(bxor(bxor(bxor(bxor(v_a, v_c), v_u), v_s), bor(band(lshift(v_a, 1), 254), (rshift(v_l, 7) % 4294967296))), 99)
I8[tobit((v_o + 22464))] = tobit(v_u)
I8[tobit((v_u + 30912))] = tobit(v_o)
v_o = tobit((v_o + 1))
if not (256 ~= bor(0, v_o)) then goto B106 end
end
do
end
::C106::
end
end
::B106::
end
do
v_a = 0
v_s = 99
v_c = I32[arshift((v_e + 44), 2)]
v_l = I32[arshift((v_e + 52), 2)]
v_v = I32[arshift((v_e + 36), 2)]
v_g = I32[arshift((v_e + 56), 2)]
while true do
v_o = bxor(band(arshift(lshift(v_s, 24), 31), 27), band(lshift(v_s, 1), 254))
v_b = bor(bor(v_o, lshift(v_s, 8)), lshift(v_s, 16))
v_o = bxor(v_o, v_s)
v_u = lshift(v_a, 2)
I32[arshift((26816 + v_u), 2)] = tobit(bor(v_b, lshift(v_o, 24)))
v_o = bor(v_o, lshift(v_b, 8))
I32[arshift((v_u + 27840), 2)] = tobit(v_o)
v_o = bor(lshift(v_o, 8), v_s)
I32[arshift((v_u + 28864), 2)] = tobit(v_o)
I32[arshift((v_u + 29888), 2)] = tobit(bor(lshift(v_o, 8), v_s))
v_o = U8[tobit((v_a + 30912))]
if (v_o ~= 0) then
v_o = I32[arshift((lshift(v_o, 2) + v_e), 2)]
v_s = bxor(bxor(lshift(I32[arshift((tobit((v_e + 1024)) + lshift(fmod(tobit((v_o + v_v)), 255), 2)), 2)], 8), I32[arshift((tobit((v_e + 1024)) + lshift(fmod(tobit((v_o + v_g)), 255), 2)), 2)]), lshift(I32[arshift((tobit((v_e + 1024)) + lshift(fmod(tobit((v_o + v_l)), 255), 2)), 2)], 16))
v_o = lshift(I32[arshift((tobit((v_e + 1024)) + lshift(fmod(tobit((v_o + v_c)), 255), 2)), 2)], 24)
else
v_s = 0
v_o = 0
end
v_o = bxor(v_o, v_s)
I32[arshift((v_u + 22720), 2)] = tobit(v_o)
v_o = bor(lshift(v_s, 8), (rshift(v_o, 24) % 4294967296))
I32[arshift((v_u + 23744), 2)] = tobit(v_o)
I32[arshift((v_u + 24768), 2)] = tobit(F.fSA(v_o, 8))
I32[arshift((v_u + 25792), 2)] = tobit(F.fSA(v_o, 16))
v_a = tobit((v_a + 1))
if not (256 ~= bor(0, v_a)) then goto B107 end
do
v_s = U8[tobit((v_a + 22464))]
end
::C107::
end
end
::B107::
I8[22404] = tobit(1)
end
end
end
v_o = v_A
v_u = 10
do
do
do
if (128 ~= bor(0, v_n)) then
if (256 == bor(0, v_n)) then
v_u = 14
else
v_s = (-32)
if (192 ~= bor(0, v_n)) then
goto L108
end
v_u = 12
end
end
do
do
I32[arshift(v_o, 2)] = tobit(v_u)
v_o = tobit((v_A + 8))
I32[arshift((v_A + 4), 2)] = tobit(v_o)
v_s = tobit((rshift(v_n, 5) % 4294967296))
v_a = 0
while true do
do
v_n = lshift(v_a, 2)
I32[arshift((8 + tobit((v_n + v_A))), 2)] = tobit(bor(bor(bor(U8[tobit((v_r + v_n))], lshift(U8[tobit((bor(1, v_n) + v_r))], 8)), lshift(U8[tobit((bor(2, v_n) + v_r))], 16)), lshift(U8[tobit((bor(3, v_n) + v_r))], 24)))
local t102 = bor(0, v_s)
v_a = tobit((v_a + 1))
if not (t102 ~= bor(0, v_a)) then goto B109 end
end
do
end
::C109::
end
end
::B109::
end
v_s = 0
do
local sw110 = tobit((v_u - 10))
if sw110 == 0 then goto K110_0
elseif sw110 == 2 then goto K110_1
elseif sw110 == 4 then goto K110_2
else goto K110_3 end
::K110_0::
do
do
v_r = I32[arshift(v_o, 2)]
v_a = 0
while true do
v_A = I32[arshift((v_o + 12), 2)]
v_r = bxor(bxor(bxor(bxor(bxor(U8[tobit((22464 + band((rshift(v_A, 8) % 4294967296), 255)))], I32[arshift((22416 + lshift(v_a, 2)), 2)]), v_r), lshift(U8[tobit((22464 + band((rshift(v_A, 16) % 4294967296), 255)))], 8)), lshift(U8[tobit((22464 + tobit((rshift(v_A, 24) % 4294967296))))], 16)), lshift(U8[tobit((22464 + band(255, v_A)))], 24))
I32[arshift((v_o + 16), 2)] = tobit(v_r)
v_n = bxor(I32[arshift((v_o + 4), 2)], v_r)
I32[arshift((v_o + 20), 2)] = tobit(v_n)
v_n = bxor(v_n, I32[arshift((v_o + 8), 2)])
I32[arshift((v_o + 24), 2)] = tobit(v_n)
I32[arshift((v_o + 28), 2)] = tobit(bxor(v_A, v_n))
v_o = tobit((v_o + 16))
v_a = tobit((v_a + 1))
if not (10 ~= bor(0, v_a)) then goto B111 end
do
end
::C111::
end
end
::B111::
goto L108
end
::K110_1::
do
v_r = I32[arshift((v_A + 28), 2)]
v_n = bxor(bxor(bxor(bxor(bxor(U8[tobit((22464 + band((rshift(v_r, 8) % 4294967296), 255)))], I32[5604]), I32[arshift((v_A + 8), 2)]), lshift(U8[tobit((22464 + band((rshift(v_r, 16) % 4294967296), 255)))], 8)), lshift(U8[tobit((22464 + tobit((rshift(v_r, 24) % 4294967296))))], 16)), lshift(U8[tobit((22464 + band(255, v_r)))], 24))
I32[arshift((v_A + 32), 2)] = tobit(v_n)
v_u = bxor(v_n, I32[arshift((v_A + 12), 2)])
I32[arshift((v_A + 36), 2)] = tobit(v_u)
v_o = bxor(v_u, I32[arshift((v_A + 16), 2)])
I32[arshift((v_A + 40), 2)] = tobit(v_o)
v_a = bxor(v_o, I32[arshift((v_A + 20), 2)])
I32[arshift((v_A + 44), 2)] = tobit(v_a)
v_c = bxor(v_a, I32[arshift((v_A + 24), 2)])
I32[arshift((v_A + 48), 2)] = tobit(v_c)
v_r = bxor(v_r, v_c)
I32[arshift((v_A + 52), 2)] = tobit(v_r)
v_n = bxor(bxor(bxor(bxor(bxor(U8[tobit((22464 + band((rshift(v_r, 8) % 4294967296), 255)))], v_n), I32[5605]), lshift(U8[tobit((22464 + band((rshift(v_r, 16) % 4294967296), 255)))], 8)), lshift(U8[tobit((22464 + tobit((rshift(v_r, 24) % 4294967296))))], 16)), lshift(U8[tobit((22464 + band(255, v_r)))], 24))
I32[arshift((v_A + 56), 2)] = tobit(v_n)
v_u = bxor(v_u, v_n)
I32[arshift((v_A + 60), 2)] = tobit(v_u)
v_o = bxor(v_o, v_u)
I32[arshift((v_A - (-64)), 2)] = tobit(v_o)
v_a = bxor(v_a, v_o)
I32[arshift((v_A + 68), 2)] = tobit(v_a)
v_c = bxor(v_c, v_a)
I32[arshift((v_A + 72), 2)] = tobit(v_c)
v_r = bxor(v_r, v_c)
I32[arshift((v_A + 76), 2)] = tobit(v_r)
v_n = bxor(bxor(bxor(bxor(bxor(U8[tobit((22464 + band((rshift(v_r, 8) % 4294967296), 255)))], v_n), I32[5606]), lshift(U8[tobit((22464 + band((rshift(v_r, 16) % 4294967296), 255)))], 8)), lshift(U8[tobit((22464 + tobit((rshift(v_r, 24) % 4294967296))))], 16)), lshift(U8[tobit((22464 + band(255, v_r)))], 24))
I32[arshift((v_A + 80), 2)] = tobit(v_n)
v_u = bxor(v_u, v_n)
I32[arshift((v_A + 84), 2)] = tobit(v_u)
v_o = bxor(v_o, v_u)
I32[arshift((v_A + 88), 2)] = tobit(v_o)
v_a = bxor(v_a, v_o)
I32[arshift((v_A + 92), 2)] = tobit(v_a)
v_c = bxor(v_c, v_a)
I32[arshift((v_A + 96), 2)] = tobit(v_c)
v_r = bxor(v_r, v_c)
I32[arshift((v_A + 100), 2)] = tobit(v_r)
v_n = bxor(bxor(bxor(bxor(bxor(U8[tobit((22464 + band((rshift(v_r, 8) % 4294967296), 255)))], v_n), I32[5607]), lshift(U8[tobit((22464 + band((rshift(v_r, 16) % 4294967296), 255)))], 8)), lshift(U8[tobit((22464 + tobit((rshift(v_r, 24) % 4294967296))))], 16)), lshift(U8[tobit((22464 + band(255, v_r)))], 24))
I32[arshift((v_A + 104), 2)] = tobit(v_n)
v_u = bxor(v_u, v_n)
I32[arshift((v_A + 108), 2)] = tobit(v_u)
v_o = bxor(v_o, v_u)
I32[arshift((v_A + 112), 2)] = tobit(v_o)
v_a = bxor(v_a, v_o)
I32[arshift((v_A + 116), 2)] = tobit(v_a)
v_c = bxor(v_c, v_a)
I32[arshift((v_A + 120), 2)] = tobit(v_c)
v_r = bxor(v_r, v_c)
I32[arshift((v_A + 124), 2)] = tobit(v_r)
v_n = bxor(bxor(bxor(bxor(bxor(U8[tobit((22464 + band((rshift(v_r, 8) % 4294967296), 255)))], v_n), I32[5608]), lshift(U8[tobit((22464 + band((rshift(v_r, 16) % 4294967296), 255)))], 8)), lshift(U8[tobit((22464 + tobit((rshift(v_r, 24) % 4294967296))))], 16)), lshift(U8[tobit((22464 + band(255, v_r)))], 24))
I32[arshift((v_A + 128), 2)] = tobit(v_n)
v_u = bxor(v_u, v_n)
I32[arshift((v_A + 132), 2)] = tobit(v_u)
v_o = bxor(v_o, v_u)
I32[arshift((v_A + 136), 2)] = tobit(v_o)
v_a = bxor(v_a, v_o)
I32[arshift((v_A + 140), 2)] = tobit(v_a)
v_c = bxor(v_c, v_a)
I32[arshift((v_A + 144), 2)] = tobit(v_c)
v_r = bxor(v_r, v_c)
I32[arshift((v_A + 148), 2)] = tobit(v_r)
v_n = bxor(bxor(bxor(bxor(bxor(U8[tobit((22464 + band((rshift(v_r, 8) % 4294967296), 255)))], v_n), I32[5609]), lshift(U8[tobit((22464 + band((rshift(v_r, 16) % 4294967296), 255)))], 8)), lshift(U8[tobit((22464 + tobit((rshift(v_r, 24) % 4294967296))))], 16)), lshift(U8[tobit((22464 + band(255, v_r)))], 24))
I32[arshift((v_A + 152), 2)] = tobit(v_n)
v_u = bxor(v_u, v_n)
I32[arshift((v_A + 156), 2)] = tobit(v_u)
v_o = bxor(v_o, v_u)
I32[arshift((v_A + 160), 2)] = tobit(v_o)
v_a = bxor(v_a, v_o)
I32[arshift((v_A + 164), 2)] = tobit(v_a)
v_c = bxor(v_c, v_a)
I32[arshift((v_A + 168), 2)] = tobit(v_c)
v_r = bxor(v_r, v_c)
I32[arshift((v_A + 172), 2)] = tobit(v_r)
v_n = bxor(bxor(bxor(bxor(bxor(U8[tobit((22464 + band((rshift(v_r, 8) % 4294967296), 255)))], v_n), I32[5610]), lshift(U8[tobit((22464 + band((rshift(v_r, 16) % 4294967296), 255)))], 8)), lshift(U8[tobit((22464 + tobit((rshift(v_r, 24) % 4294967296))))], 16)), lshift(U8[tobit((22464 + band(255, v_r)))], 24))
I32[arshift((v_A + 176), 2)] = tobit(v_n)
v_u = bxor(v_u, v_n)
I32[arshift((v_A + 180), 2)] = tobit(v_u)
v_o = bxor(v_o, v_u)
I32[arshift((v_A + 184), 2)] = tobit(v_o)
v_a = bxor(v_a, v_o)
I32[arshift((v_A + 188), 2)] = tobit(v_a)
v_c = bxor(v_c, v_a)
I32[arshift((v_A + 192), 2)] = tobit(v_c)
v_r = bxor(v_r, v_c)
I32[arshift((v_A + 196), 2)] = tobit(v_r)
v_n = bxor(bxor(bxor(bxor(bxor(U8[tobit((22464 + band((rshift(v_r, 8) % 4294967296), 255)))], v_n), I32[5611]), lshift(U8[tobit((22464 + band((rshift(v_r, 16) % 4294967296), 255)))], 8)), lshift(U8[tobit((22464 + tobit((rshift(v_r, 24) % 4294967296))))], 16)), lshift(U8[tobit((22464 + band(255, v_r)))], 24))
I32[arshift((v_A + 200), 2)] = tobit(v_n)
v_n = bxor(v_n, v_u)
I32[arshift((v_A + 204), 2)] = tobit(v_n)
v_n = bxor(v_n, v_o)
I32[arshift((v_A + 208), 2)] = tobit(v_n)
v_n = bxor(v_n, v_a)
I32[arshift((v_A + 212), 2)] = tobit(v_n)
v_n = bxor(v_n, v_c)
I32[arshift((v_A + 216), 2)] = tobit(v_n)
I32[arshift((v_A + 220), 2)] = tobit(bxor(v_r, v_n))
goto L108
end
::K110_2::
do
goto S110
end
::K110_3::
do
goto L108
end
end
::S110::
do
v_a = I32[arshift(v_o, 2)]
v_n = 0
while true do
v_A = I32[arshift((v_o + 28), 2)]
v_a = bxor(bxor(bxor(bxor(bxor(U8[tobit((22464 + band((rshift(v_A, 8) % 4294967296), 255)))], I32[arshift((22416 + lshift(v_n, 2)), 2)]), v_a), lshift(U8[tobit((22464 + band((rshift(v_A, 16) % 4294967296), 255)))], 8)), lshift(U8[tobit((22464 + tobit((rshift(v_A, 24) % 4294967296))))], 16)), lshift(U8[tobit((22464 + band(255, v_A)))], 24))
I32[arshift((v_o + 32), 2)] = tobit(v_a)
v_r = bxor(I32[arshift((v_o + 4), 2)], v_a)
I32[arshift((v_o + 36), 2)] = tobit(v_r)
v_r = bxor(v_r, I32[arshift((v_o + 8), 2)])
I32[arshift((v_o + 40), 2)] = tobit(v_r)
v_r = bxor(v_r, I32[arshift((v_o + 12), 2)])
I32[arshift((v_o + 44), 2)] = tobit(v_r)
v_r = bxor(bxor(bxor(bxor(I32[arshift((v_o + 16), 2)], U8[tobit((22464 + band(255, v_r)))]), lshift(U8[tobit((22464 + band((rshift(v_r, 8) % 4294967296), 255)))], 8)), lshift(U8[tobit((22464 + band((rshift(v_r, 16) % 4294967296), 255)))], 16)), lshift(U8[tobit((22464 + tobit((rshift(v_r, 24) % 4294967296))))], 24))
I32[arshift((v_o + 48), 2)] = tobit(v_r)
v_r = bxor(v_r, I32[arshift((v_o + 20), 2)])
I32[arshift((v_o + 52), 2)] = tobit(v_r)
v_r = bxor(v_r, I32[arshift((v_o + 24), 2)])
I32[arshift((v_o + 56), 2)] = tobit(v_r)
I32[arshift((v_o + 60), 2)] = tobit(bxor(v_A, v_r))
v_o = tobit((v_o + 32))
v_n = tobit((v_n + 1))
if not (7 ~= bor(0, v_n)) then goto B112 end
do
end
::C112::
end
end
::B112::
end
end
::L108::
end
B = tobit((v_e + 2048))
do return v_s end
end

F.fS = function(v_A, v_r, v_n)
local v_e, v_o, v_a, v_u, v_c, v_s, v_l, v_b, v_v, v_g, v_p, v_h, v_d, v_k, v_y, v_w, v_C, v_E, v_I, v_m, v_Q, v_O, v_S, v_j = 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
v_o = 0
v_a = 0
v_u = 0
v_c = 0
v_s = 0
v_l = 0
v_b = 0
v_v = 0
v_g = 0
v_p = 0
v_h = 0
v_d = 0
v_k = 0
v_y = 0
v_w = 0
v_C = 0
v_E = 0
v_I = 0
v_m = 0
v_Q = 0
v_O = 0
v_S = 0
v_j = 0
v_c = I32[arshift((v_A + 4), 2)]
v_o = U8[tobit((v_r + 3))]
v_a = U8[tobit((v_r + 1))]
v_u = U8[tobit((v_r + 2))]
v_e = tobit((B - 48))
v_s = U8[bor(0, v_r)]
I8[tobit((v_e + 40))] = tobit(v_s)
v_o = bxor(I32[arshift(v_c, 2)], bor(bor(bor(v_s, lshift(v_a, 8)), lshift(v_u, 16)), lshift(v_o, 24)))
I8[tobit((v_e + 40))] = tobit(v_o)
I8[tobit((v_e + 39))] = tobit((rshift(v_o, 8) % 4294967296))
I8[tobit((v_e + 38))] = tobit((rshift(v_o, 16) % 4294967296))
I8[tobit((v_e + 37))] = tobit((rshift(v_o, 24) % 4294967296))
v_o = bxor(I32[arshift((v_c + 4), 2)], bor(bor(bor(U8[tobit((v_r + 4))], lshift(U8[tobit((v_r + 5))], 8)), lshift(U8[tobit((v_r + 6))], 16)), lshift(U8[tobit((v_r + 7))], 24)))
I8[tobit((v_e + 36))] = tobit(v_o)
v_l = tobit((rshift(v_o, 8) % 4294967296))
I8[tobit((v_e + 35))] = tobit(v_l)
v_v = tobit((rshift(v_o, 16) % 4294967296))
I8[tobit((v_e + 34))] = tobit(v_v)
v_g = tobit((rshift(v_o, 24) % 4294967296))
I8[tobit((v_e + 33))] = tobit(v_g)
v_a = bor(bor(bor(U8[tobit((v_r + 8))], lshift(U8[tobit((v_r + 9))], 8)), lshift(U8[tobit((v_r + 10))], 16)), lshift(U8[tobit((v_r + 11))], 24))
I32[arshift((v_e + 44), 2)] = tobit((v_c + 12))
v_a = bxor(v_a, I32[arshift((v_c + 8), 2)])
I8[tobit((v_e + 32))] = tobit(v_a)
v_p = tobit((rshift(v_a, 8) % 4294967296))
I8[tobit((v_e + 31))] = tobit(v_p)
v_h = tobit((rshift(v_a, 16) % 4294967296))
I8[tobit((v_e + 30))] = tobit(v_h)
v_d = tobit((rshift(v_a, 24) % 4294967296))
I8[tobit((v_e + 29))] = tobit(v_d)
v_u = bxor(I32[arshift((v_c + 12), 2)], bor(bor(bor(U8[tobit((v_r + 12))], lshift(U8[tobit((v_r + 13))], 8)), lshift(U8[tobit((v_r + 14))], 16)), lshift(U8[tobit((v_r + 15))], 24)))
I8[tobit((v_e + 28))] = tobit(v_u)
v_k = tobit((rshift(v_u, 8) % 4294967296))
I8[tobit((v_e + 27))] = tobit(v_k)
v_y = tobit((rshift(v_u, 16) % 4294967296))
I8[tobit((v_e + 26))] = tobit(v_y)
v_w = tobit((rshift(v_u, 24) % 4294967296))
I8[tobit((v_e + 25))] = tobit(v_w)
v_r = tobit((v_c + 16))
v_A = I32[arshift(v_A, 2)]
if (bor(0, v_A) <= 3) then
v_C = U8[tobit((v_e + 37))]
v_E = U8[tobit((v_e + 38))]
else
do
v_I = tobit((rshift(v_A, 1) % 4294967296))
v_m = U8[tobit((v_e + 39))]
v_C = U8[tobit((v_e + 37))]
v_E = U8[tobit((v_e + 38))]
while true do
v_A = bxor(bxor(bxor(bxor(I32[arshift((25792 + lshift(v_g, 2)), 2)], I32[arshift((24768 + lshift(band(255, v_h), 2)), 2)]), I32[arshift((23744 + lshift(band(255, v_k), 2)), 2)]), I32[arshift((22720 + lshift(U8[tobit((v_e + 40))], 2)), 2)]), I32[arshift(v_r, 2)])
I8[tobit((v_e + 24))] = tobit(v_A)
v_c = bxor(bxor(bxor(bxor(I32[arshift((25792 + lshift(v_d, 2)), 2)], I32[arshift((24768 + lshift(band(255, v_y), 2)), 2)]), I32[arshift((23744 + lshift(band(255, v_m), 2)), 2)]), I32[arshift((22720 + lshift(band(255, v_o), 2)), 2)]), I32[arshift((v_r + 4), 2)])
I8[tobit((v_e + 20))] = tobit(v_c)
v_s = bxor(bxor(bxor(bxor(I32[arshift((25792 + lshift(v_w, 2)), 2)], I32[arshift((24768 + lshift(band(255, v_E), 2)), 2)]), I32[arshift((23744 + lshift(band(255, v_l), 2)), 2)]), I32[arshift((22720 + lshift(band(255, v_a), 2)), 2)]), I32[arshift((v_r + 8), 2)])
I8[tobit((v_e + 16))] = tobit(v_s)
v_b = bxor(bxor(bxor(bxor(I32[arshift((25792 + lshift(v_C, 2)), 2)], I32[arshift((24768 + lshift(band(255, v_v), 2)), 2)]), I32[arshift((23744 + lshift(band(255, v_p), 2)), 2)]), I32[arshift((22720 + lshift(band(255, v_u), 2)), 2)]), I32[arshift((v_r + 12), 2)])
I8[tobit((v_e + 12))] = tobit(v_b)
v_Q = tobit((rshift(v_c, 24) % 4294967296))
v_l = bxor(bxor(bxor(bxor(I32[arshift((25792 + lshift(v_Q, 2)), 2)], I32[arshift((24768 + band((rshift(v_s, 14) % 4294967296), 1020)), 2)]), I32[arshift((23744 + band((rshift(v_b, 6) % 4294967296), 1020)), 2)]), I32[arshift((22720 + lshift(band(255, v_A), 2)), 2)]), I32[arshift((v_r + 16), 2)])
I8[tobit((v_e + 40))] = tobit(v_l)
v_O = tobit((rshift(v_s, 24) % 4294967296))
v_o = bxor(bxor(bxor(bxor(I32[arshift((25792 + lshift(v_O, 2)), 2)], I32[arshift((24768 + band((rshift(v_b, 14) % 4294967296), 1020)), 2)]), I32[arshift((23744 + band((rshift(v_A, 6) % 4294967296), 1020)), 2)]), I32[arshift((22720 + lshift(band(255, v_c), 2)), 2)]), I32[arshift((v_r + 20), 2)])
I8[tobit((v_e + 36))] = tobit(v_o)
v_a = bxor(bxor(bxor(bxor(I32[arshift((25792 + band((rshift(v_b, 22) % 4294967296), 1020)), 2)], I32[arshift((24768 + band((rshift(v_A, 14) % 4294967296), 1020)), 2)]), I32[arshift((23744 + band((rshift(v_c, 6) % 4294967296), 1020)), 2)]), I32[arshift((22720 + lshift(band(255, v_s), 2)), 2)]), I32[arshift((v_r + 24), 2)])
I8[tobit((v_e + 32))] = tobit(v_a)
v_S = tobit((rshift(v_A, 24) % 4294967296))
v_u = bxor(bxor(bxor(bxor(I32[arshift((25792 + lshift(v_S, 2)), 2)], I32[arshift((24768 + band((rshift(v_c, 14) % 4294967296), 1020)), 2)]), I32[arshift((23744 + band((rshift(v_s, 6) % 4294967296), 1020)), 2)]), I32[arshift((22720 + lshift(band(255, v_b), 2)), 2)]), I32[arshift((v_r + 28), 2)])
I8[tobit((v_e + 28))] = tobit(v_u)
v_C = tobit((rshift(v_l, 24) % 4294967296))
v_E = tobit((rshift(v_l, 16) % 4294967296))
v_m = tobit((rshift(v_l, 8) % 4294967296))
v_g = tobit((rshift(v_o, 24) % 4294967296))
v_v = tobit((rshift(v_o, 16) % 4294967296))
v_l = tobit((rshift(v_o, 8) % 4294967296))
v_d = tobit((rshift(v_a, 24) % 4294967296))
v_h = tobit((rshift(v_a, 16) % 4294967296))
v_p = tobit((rshift(v_a, 8) % 4294967296))
v_w = tobit((rshift(v_u, 24) % 4294967296))
v_y = tobit((rshift(v_u, 16) % 4294967296))
v_k = tobit((rshift(v_u, 8) % 4294967296))
v_r = tobit((v_r + 32))
v_j = ((bor(0, v_I) > 2) and 1 or 0)
v_I = tobit((v_I - 1))
if not (v_j ~= 0) then goto B113 end
do
end
::C113::
end
end
::B113::
I8[tobit((v_e + 23))] = tobit((rshift(v_A, 8) % 4294967296))
I8[tobit((v_e + 39))] = tobit(v_m)
I8[tobit((v_e + 22))] = tobit((rshift(v_A, 16) % 4294967296))
I8[tobit((v_e + 21))] = tobit(v_S)
I8[tobit((v_e + 19))] = tobit((rshift(v_c, 8) % 4294967296))
I8[tobit((v_e + 18))] = tobit((rshift(v_c, 16) % 4294967296))
I8[tobit((v_e + 17))] = tobit(v_Q)
I8[tobit((v_e + 15))] = tobit((rshift(v_s, 8) % 4294967296))
I8[tobit((v_e + 14))] = tobit((rshift(v_s, 16) % 4294967296))
I8[tobit((v_e + 13))] = tobit(v_O)
I8[tobit((v_e + 11))] = tobit((rshift(v_b, 8) % 4294967296))
I8[tobit((v_e + 10))] = tobit((rshift(v_b, 16) % 4294967296))
end
v_u = bxor(bxor(bxor(bxor(I32[arshift((25792 + lshift(v_C, 2)), 2)], I32[arshift((24768 + lshift(band(255, v_v), 2)), 2)]), I32[arshift((23744 + lshift(band(255, v_p), 2)), 2)]), I32[arshift((22720 + lshift(band(255, v_u), 2)), 2)]), I32[arshift((v_r + 12), 2)])
v_c = U8[tobit((30912 + band((rshift(v_u, 8) % 4294967296), 255)))]
v_A = bxor(bxor(bxor(bxor(I32[arshift((25792 + lshift(v_w, 2)), 2)], I32[arshift((24768 + lshift(band(255, v_E), 2)), 2)]), I32[arshift((23744 + lshift(band(255, v_l), 2)), 2)]), I32[arshift((22720 + lshift(band(255, v_a), 2)), 2)]), I32[arshift((v_r + 8), 2)])
v_s = U8[tobit((30912 + band((rshift(v_A, 16) % 4294967296), 255)))]
v_b = U8[tobit((30912 + band((rshift(v_u, 16) % 4294967296), 255)))]
v_o = bxor(bxor(bxor(bxor(I32[arshift((25792 + lshift(v_d, 2)), 2)], I32[arshift((24768 + lshift(band(255, v_y), 2)), 2)]), I32[arshift((23744 + lshift(U8[tobit((v_e + 39))], 2)), 2)]), I32[arshift((22720 + lshift(band(255, v_o), 2)), 2)]), I32[arshift((v_r + 4), 2)])
v_C = U8[tobit((30912 + band((rshift(v_o, 8) % 4294967296), 255)))]
v_E = U8[tobit((30912 + band((rshift(v_A, 8) % 4294967296), 255)))]
v_l = U8[tobit((30912 + band((rshift(v_o, 16) % 4294967296), 255)))]
v_v = U8[tobit((30912 + tobit((rshift(v_o, 24) % 4294967296))))]
v_a = bxor(bxor(bxor(bxor(I32[arshift((25792 + lshift(v_g, 2)), 2)], I32[arshift((24768 + lshift(band(255, v_h), 2)), 2)]), I32[arshift((23744 + lshift(band(255, v_k), 2)), 2)]), I32[arshift((22720 + lshift(U8[tobit((v_e + 40))], 2)), 2)]), I32[arshift(v_r, 2)])
v_g = U8[tobit((30912 + band((rshift(v_a, 8) % 4294967296), 255)))]
v_p = U8[tobit((30912 + tobit((rshift(v_A, 24) % 4294967296))))]
v_h = U8[tobit((30912 + band((rshift(v_a, 16) % 4294967296), 255)))]
v_d = U8[tobit((30912 + tobit((rshift(v_u, 24) % 4294967296))))]
v_k = U8[tobit((30912 + tobit((rshift(v_a, 24) % 4294967296))))]
v_y = U8[tobit((30912 + band(255, v_a)))]
v_w = U8[tobit((30912 + band(255, v_o)))]
v_I = U8[tobit((30912 + band(255, v_A)))]
v_A = I32[arshift((v_r + 16), 2)]
v_o = I32[arshift((v_r + 20), 2)]
v_a = I32[arshift((v_r + 24), 2)]
v_r = I32[arshift((v_r + 28), 2)]
I8[tobit((v_n + 12))] = tobit(bxor(v_r, U8[tobit((30912 + band(255, v_u)))]))
I8[tobit((v_n + 8))] = tobit(bxor(v_a, v_I))
I8[tobit((v_n + 4))] = tobit(bxor(v_o, v_w))
I8[bor(0, v_n)] = tobit(bxor(v_A, v_y))
I8[tobit((v_n + 15))] = tobit((rshift(bxor(v_r, lshift(v_k, 24)), 24) % 4294967296))
I8[tobit((v_n + 11))] = tobit((rshift(bxor(v_a, lshift(v_d, 24)), 24) % 4294967296))
I8[tobit((v_n + 10))] = tobit((rshift(bxor(v_a, lshift(v_h, 16)), 16) % 4294967296))
I8[tobit((v_n + 7))] = tobit((rshift(bxor(v_o, lshift(v_p, 24)), 24) % 4294967296))
I8[tobit((v_n + 5))] = tobit((rshift(bxor(v_o, lshift(v_g, 8)), 8) % 4294967296))
I8[tobit((v_n + 3))] = tobit((rshift(bxor(v_A, lshift(v_v, 24)), 24) % 4294967296))
I8[tobit((v_n + 14))] = tobit((rshift(bxor(v_r, lshift(v_l, 16)), 16) % 4294967296))
I8[tobit((v_n + 13))] = tobit((rshift(bxor(v_r, lshift(v_E, 8)), 8) % 4294967296))
I8[tobit((v_n + 9))] = tobit((rshift(bxor(v_a, lshift(v_C, 8)), 8) % 4294967296))
I8[tobit((v_n + 6))] = tobit((rshift(bxor(v_o, lshift(v_b, 16)), 16) % 4294967296))
I8[tobit((v_n + 2))] = tobit((rshift(bxor(v_A, lshift(v_s, 16)), 16) % 4294967296))
I8[tobit((v_n + 1))] = tobit((rshift(bxor(v_A, lshift(v_c, 8)), 8) % 4294967296))
I8[tobit((v_e + 40))] = tobit(0)
I8[tobit((v_e + 39))] = tobit(0)
I8[tobit((v_e + 38))] = tobit(0)
I8[tobit((v_e + 37))] = tobit(0)
I8[tobit((v_e + 36))] = tobit(0)
I8[tobit((v_e + 35))] = tobit(0)
I8[tobit((v_e + 34))] = tobit(0)
I8[tobit((v_e + 33))] = tobit(0)
I8[tobit((v_e + 32))] = tobit(0)
I8[tobit((v_e + 31))] = tobit(0)
I8[tobit((v_e + 30))] = tobit(0)
I8[tobit((v_e + 29))] = tobit(0)
I8[tobit((v_e + 28))] = tobit(0)
I8[tobit((v_e + 27))] = tobit(0)
I8[tobit((v_e + 26))] = tobit(0)
I8[tobit((v_e + 25))] = tobit(0)
I8[tobit((v_e + 24))] = tobit(0)
I8[tobit((v_e + 23))] = tobit(0)
I8[tobit((v_e + 22))] = tobit(0)
I8[tobit((v_e + 21))] = tobit(0)
I8[tobit((v_e + 20))] = tobit(0)
I8[tobit((v_e + 19))] = tobit(0)
I8[tobit((v_e + 18))] = tobit(0)
I8[tobit((v_e + 17))] = tobit(0)
I8[tobit((v_e + 16))] = tobit(0)
I8[tobit((v_e + 15))] = tobit(0)
I8[tobit((v_e + 14))] = tobit(0)
I8[tobit((v_e + 13))] = tobit(0)
I8[tobit((v_e + 12))] = tobit(0)
I8[tobit((v_e + 11))] = tobit(0)
I8[tobit((v_e + 10))] = tobit(0)
I8[tobit((v_e + 9))] = tobit(0)
I8[tobit((v_e + 44))] = tobit(0)
I8[tobit((v_e + 45))] = tobit(0)
I8[tobit((v_e + 46))] = tobit(0)
I8[tobit((v_e + 47))] = tobit(0)
end

F.fj = function(v_A, v_r, v_n)
local v_e, v_o, v_a, v_u, v_c, v_s, v_l, v_b, v_v, v_g, v_p, v_h, v_d, v_k, v_y, v_w, v_C, v_E, v_I, v_m, v_Q, v_O, v_S, v_j = 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
v_o = 0
v_a = 0
v_u = 0
v_c = 0
v_s = 0
v_l = 0
v_b = 0
v_v = 0
v_g = 0
v_p = 0
v_h = 0
v_d = 0
v_k = 0
v_y = 0
v_w = 0
v_C = 0
v_E = 0
v_I = 0
v_m = 0
v_Q = 0
v_O = 0
v_S = 0
v_j = 0
v_c = I32[arshift((v_A + 4), 2)]
v_o = U8[tobit((v_r + 3))]
v_a = U8[tobit((v_r + 1))]
v_u = U8[tobit((v_r + 2))]
v_e = tobit((B - 48))
v_s = U8[bor(0, v_r)]
I8[tobit((v_e + 40))] = tobit(v_s)
v_o = bxor(I32[arshift(v_c, 2)], bor(bor(bor(v_s, lshift(v_a, 8)), lshift(v_u, 16)), lshift(v_o, 24)))
I8[tobit((v_e + 40))] = tobit(v_o)
I8[tobit((v_e + 39))] = tobit((rshift(v_o, 8) % 4294967296))
I8[tobit((v_e + 38))] = tobit((rshift(v_o, 16) % 4294967296))
I8[tobit((v_e + 37))] = tobit((rshift(v_o, 24) % 4294967296))
v_o = bxor(I32[arshift((v_c + 4), 2)], bor(bor(bor(U8[tobit((v_r + 4))], lshift(U8[tobit((v_r + 5))], 8)), lshift(U8[tobit((v_r + 6))], 16)), lshift(U8[tobit((v_r + 7))], 24)))
I8[tobit((v_e + 36))] = tobit(v_o)
v_l = tobit((rshift(v_o, 8) % 4294967296))
I8[tobit((v_e + 35))] = tobit(v_l)
v_v = tobit((rshift(v_o, 16) % 4294967296))
I8[tobit((v_e + 34))] = tobit(v_v)
v_g = tobit((rshift(v_o, 24) % 4294967296))
I8[tobit((v_e + 33))] = tobit(v_g)
v_a = bor(bor(bor(U8[tobit((v_r + 8))], lshift(U8[tobit((v_r + 9))], 8)), lshift(U8[tobit((v_r + 10))], 16)), lshift(U8[tobit((v_r + 11))], 24))
I32[arshift((v_e + 44), 2)] = tobit((v_c + 12))
v_a = bxor(v_a, I32[arshift((v_c + 8), 2)])
I8[tobit((v_e + 32))] = tobit(v_a)
v_p = tobit((rshift(v_a, 8) % 4294967296))
I8[tobit((v_e + 31))] = tobit(v_p)
v_h = tobit((rshift(v_a, 16) % 4294967296))
I8[tobit((v_e + 30))] = tobit(v_h)
v_d = tobit((rshift(v_a, 24) % 4294967296))
I8[tobit((v_e + 29))] = tobit(v_d)
v_u = bxor(I32[arshift((v_c + 12), 2)], bor(bor(bor(U8[tobit((v_r + 12))], lshift(U8[tobit((v_r + 13))], 8)), lshift(U8[tobit((v_r + 14))], 16)), lshift(U8[tobit((v_r + 15))], 24)))
I8[tobit((v_e + 28))] = tobit(v_u)
v_k = tobit((rshift(v_u, 8) % 4294967296))
I8[tobit((v_e + 27))] = tobit(v_k)
v_y = tobit((rshift(v_u, 16) % 4294967296))
I8[tobit((v_e + 26))] = tobit(v_y)
v_w = tobit((rshift(v_u, 24) % 4294967296))
I8[tobit((v_e + 25))] = tobit(v_w)
v_r = tobit((v_c + 16))
v_A = I32[arshift(v_A, 2)]
if (bor(0, v_A) <= 3) then
v_C = U8[tobit((v_e + 37))]
v_E = U8[tobit((v_e + 38))]
else
do
v_I = tobit((rshift(v_A, 1) % 4294967296))
v_m = U8[tobit((v_e + 39))]
v_C = U8[tobit((v_e + 37))]
v_E = U8[tobit((v_e + 38))]
while true do
v_A = bxor(bxor(bxor(bxor(I32[arshift((29888 + lshift(v_w, 2)), 2)], I32[arshift((28864 + lshift(band(255, v_h), 2)), 2)]), I32[arshift((27840 + lshift(band(255, v_l), 2)), 2)]), I32[arshift((26816 + lshift(U8[tobit((v_e + 40))], 2)), 2)]), I32[arshift(v_r, 2)])
I8[tobit((v_e + 24))] = tobit(v_A)
v_c = bxor(bxor(bxor(bxor(I32[arshift((29888 + lshift(v_C, 2)), 2)], I32[arshift((28864 + lshift(band(255, v_y), 2)), 2)]), I32[arshift((27840 + lshift(band(255, v_p), 2)), 2)]), I32[arshift((26816 + lshift(band(255, v_o), 2)), 2)]), I32[arshift((v_r + 4), 2)])
I8[tobit((v_e + 20))] = tobit(v_c)
v_s = bxor(bxor(bxor(bxor(I32[arshift((29888 + lshift(v_g, 2)), 2)], I32[arshift((28864 + lshift(band(255, v_E), 2)), 2)]), I32[arshift((27840 + lshift(band(255, v_k), 2)), 2)]), I32[arshift((26816 + lshift(band(255, v_a), 2)), 2)]), I32[arshift((v_r + 8), 2)])
I8[tobit((v_e + 16))] = tobit(v_s)
v_b = bxor(bxor(bxor(bxor(I32[arshift((29888 + lshift(v_d, 2)), 2)], I32[arshift((28864 + lshift(band(255, v_v), 2)), 2)]), I32[arshift((27840 + lshift(band(255, v_m), 2)), 2)]), I32[arshift((26816 + lshift(band(255, v_u), 2)), 2)]), I32[arshift((v_r + 12), 2)])
I8[tobit((v_e + 12))] = tobit(v_b)
v_l = bxor(bxor(bxor(bxor(I32[arshift((29888 + band((rshift(v_b, 22) % 4294967296), 1020)), 2)], I32[arshift((28864 + band((rshift(v_s, 14) % 4294967296), 1020)), 2)]), I32[arshift((27840 + band((rshift(v_c, 6) % 4294967296), 1020)), 2)]), I32[arshift((26816 + lshift(band(255, v_A), 2)), 2)]), I32[arshift((v_r + 16), 2)])
I8[tobit((v_e + 40))] = tobit(v_l)
v_Q = tobit((rshift(v_A, 24) % 4294967296))
v_o = bxor(bxor(bxor(bxor(I32[arshift((29888 + lshift(v_Q, 2)), 2)], I32[arshift((28864 + band((rshift(v_b, 14) % 4294967296), 1020)), 2)]), I32[arshift((27840 + band((rshift(v_s, 6) % 4294967296), 1020)), 2)]), I32[arshift((26816 + lshift(band(255, v_c), 2)), 2)]), I32[arshift((v_r + 20), 2)])
I8[tobit((v_e + 36))] = tobit(v_o)
v_O = tobit((rshift(v_c, 24) % 4294967296))
v_a = bxor(bxor(bxor(bxor(I32[arshift((29888 + lshift(v_O, 2)), 2)], I32[arshift((28864 + band((rshift(v_A, 14) % 4294967296), 1020)), 2)]), I32[arshift((27840 + band((rshift(v_b, 6) % 4294967296), 1020)), 2)]), I32[arshift((26816 + lshift(band(255, v_s), 2)), 2)]), I32[arshift((v_r + 24), 2)])
I8[tobit((v_e + 32))] = tobit(v_a)
v_S = tobit((rshift(v_s, 24) % 4294967296))
v_u = bxor(bxor(bxor(bxor(I32[arshift((29888 + lshift(v_S, 2)), 2)], I32[arshift((28864 + band((rshift(v_c, 14) % 4294967296), 1020)), 2)]), I32[arshift((27840 + band((rshift(v_A, 6) % 4294967296), 1020)), 2)]), I32[arshift((26816 + lshift(band(255, v_b), 2)), 2)]), I32[arshift((v_r + 28), 2)])
I8[tobit((v_e + 28))] = tobit(v_u)
v_C = tobit((rshift(v_l, 24) % 4294967296))
v_E = tobit((rshift(v_l, 16) % 4294967296))
v_m = tobit((rshift(v_l, 8) % 4294967296))
v_g = tobit((rshift(v_o, 24) % 4294967296))
v_v = tobit((rshift(v_o, 16) % 4294967296))
v_l = tobit((rshift(v_o, 8) % 4294967296))
v_d = tobit((rshift(v_a, 24) % 4294967296))
v_h = tobit((rshift(v_a, 16) % 4294967296))
v_p = tobit((rshift(v_a, 8) % 4294967296))
v_w = tobit((rshift(v_u, 24) % 4294967296))
v_y = tobit((rshift(v_u, 16) % 4294967296))
v_k = tobit((rshift(v_u, 8) % 4294967296))
v_r = tobit((v_r + 32))
v_j = ((bor(0, v_I) > 2) and 1 or 0)
v_I = tobit((v_I - 1))
if not (v_j ~= 0) then goto B114 end
do
end
::C114::
end
end
::B114::
I8[tobit((v_e + 23))] = tobit((rshift(v_A, 8) % 4294967296))
I8[tobit((v_e + 39))] = tobit(v_m)
I8[tobit((v_e + 22))] = tobit((rshift(v_A, 16) % 4294967296))
I8[tobit((v_e + 21))] = tobit(v_Q)
I8[tobit((v_e + 19))] = tobit((rshift(v_c, 8) % 4294967296))
I8[tobit((v_e + 18))] = tobit((rshift(v_c, 16) % 4294967296))
I8[tobit((v_e + 17))] = tobit(v_O)
I8[tobit((v_e + 15))] = tobit((rshift(v_s, 8) % 4294967296))
I8[tobit((v_e + 14))] = tobit((rshift(v_s, 16) % 4294967296))
I8[tobit((v_e + 13))] = tobit(v_S)
I8[tobit((v_e + 11))] = tobit((rshift(v_b, 8) % 4294967296))
I8[tobit((v_e + 10))] = tobit((rshift(v_b, 16) % 4294967296))
end
v_A = bxor(bxor(bxor(bxor(I32[arshift((29888 + lshift(v_C, 2)), 2)], I32[arshift((28864 + lshift(band(255, v_y), 2)), 2)]), I32[arshift((27840 + lshift(band(255, v_p), 2)), 2)]), I32[arshift((26816 + lshift(band(255, v_o), 2)), 2)]), I32[arshift((v_r + 4), 2)])
v_c = U8[tobit((22464 + band((rshift(v_A, 8) % 4294967296), 255)))]
v_o = bxor(bxor(bxor(bxor(I32[arshift((29888 + lshift(v_g, 2)), 2)], I32[arshift((28864 + lshift(band(255, v_E), 2)), 2)]), I32[arshift((27840 + lshift(band(255, v_k), 2)), 2)]), I32[arshift((26816 + lshift(band(255, v_a), 2)), 2)]), I32[arshift((v_r + 8), 2)])
v_s = U8[tobit((22464 + band((rshift(v_o, 16) % 4294967296), 255)))]
v_b = U8[tobit((22464 + band((rshift(v_o, 8) % 4294967296), 255)))]
v_u = bxor(bxor(bxor(bxor(I32[arshift((29888 + lshift(v_d, 2)), 2)], I32[arshift((28864 + lshift(band(255, v_v), 2)), 2)]), I32[arshift((27840 + lshift(U8[tobit((v_e + 39))], 2)), 2)]), I32[arshift((26816 + lshift(band(255, v_u), 2)), 2)]), I32[arshift((v_r + 12), 2)])
v_C = U8[tobit((22464 + band((rshift(v_u, 16) % 4294967296), 255)))]
v_E = U8[tobit((22464 + band((rshift(v_u, 8) % 4294967296), 255)))]
v_v = U8[tobit((22464 + band((rshift(v_A, 16) % 4294967296), 255)))]
v_g = U8[tobit((22464 + tobit((rshift(v_u, 24) % 4294967296))))]
v_a = bxor(bxor(bxor(bxor(I32[arshift((29888 + lshift(v_w, 2)), 2)], I32[arshift((28864 + lshift(band(255, v_h), 2)), 2)]), I32[arshift((27840 + lshift(band(255, v_l), 2)), 2)]), I32[arshift((26816 + lshift(U8[tobit((v_e + 40))], 2)), 2)]), I32[arshift(v_r, 2)])
v_l = U8[tobit((22464 + band((rshift(v_a, 16) % 4294967296), 255)))]
v_p = U8[tobit((22464 + tobit((rshift(v_A, 24) % 4294967296))))]
v_h = U8[tobit((22464 + band((rshift(v_a, 8) % 4294967296), 255)))]
v_d = U8[tobit((22464 + tobit((rshift(v_o, 24) % 4294967296))))]
v_k = U8[tobit((22464 + tobit((rshift(v_a, 24) % 4294967296))))]
v_y = U8[tobit((22464 + band(255, v_a)))]
v_w = U8[tobit((22464 + band(255, v_A)))]
v_I = U8[tobit((22464 + band(255, v_o)))]
v_A = I32[arshift((v_r + 16), 2)]
v_o = I32[arshift((v_r + 20), 2)]
v_a = I32[arshift((v_r + 24), 2)]
v_r = I32[arshift((v_r + 28), 2)]
I8[tobit((v_n + 12))] = tobit(bxor(v_r, U8[tobit((22464 + band(255, v_u)))]))
I8[tobit((v_n + 8))] = tobit(bxor(v_a, v_I))
I8[tobit((v_n + 4))] = tobit(bxor(v_o, v_w))
I8[bor(0, v_n)] = tobit(bxor(v_A, v_y))
I8[tobit((v_n + 7))] = tobit((rshift(bxor(v_o, lshift(v_k, 24)), 24) % 4294967296))
I8[tobit((v_n + 15))] = tobit((rshift(bxor(v_r, lshift(v_d, 24)), 24) % 4294967296))
I8[tobit((v_n + 13))] = tobit((rshift(bxor(v_r, lshift(v_h, 8)), 8) % 4294967296))
I8[tobit((v_n + 11))] = tobit((rshift(bxor(v_a, lshift(v_p, 24)), 24) % 4294967296))
I8[tobit((v_n + 10))] = tobit((rshift(bxor(v_a, lshift(v_l, 16)), 16) % 4294967296))
I8[tobit((v_n + 3))] = tobit((rshift(bxor(v_A, lshift(v_g, 24)), 24) % 4294967296))
I8[tobit((v_n + 14))] = tobit((rshift(bxor(v_r, lshift(v_v, 16)), 16) % 4294967296))
I8[tobit((v_n + 9))] = tobit((rshift(bxor(v_a, lshift(v_E, 8)), 8) % 4294967296))
I8[tobit((v_n + 6))] = tobit((rshift(bxor(v_o, lshift(v_C, 16)), 16) % 4294967296))
I8[tobit((v_n + 5))] = tobit((rshift(bxor(v_o, lshift(v_b, 8)), 8) % 4294967296))
I8[tobit((v_n + 2))] = tobit((rshift(bxor(v_A, lshift(v_s, 16)), 16) % 4294967296))
I8[tobit((v_n + 1))] = tobit((rshift(bxor(v_A, lshift(v_c, 8)), 8) % 4294967296))
I8[tobit((v_e + 40))] = tobit(0)
I8[tobit((v_e + 39))] = tobit(0)
I8[tobit((v_e + 38))] = tobit(0)
I8[tobit((v_e + 37))] = tobit(0)
I8[tobit((v_e + 36))] = tobit(0)
I8[tobit((v_e + 35))] = tobit(0)
I8[tobit((v_e + 34))] = tobit(0)
I8[tobit((v_e + 33))] = tobit(0)
I8[tobit((v_e + 32))] = tobit(0)
I8[tobit((v_e + 31))] = tobit(0)
I8[tobit((v_e + 30))] = tobit(0)
I8[tobit((v_e + 29))] = tobit(0)
I8[tobit((v_e + 28))] = tobit(0)
I8[tobit((v_e + 27))] = tobit(0)
I8[tobit((v_e + 26))] = tobit(0)
I8[tobit((v_e + 25))] = tobit(0)
I8[tobit((v_e + 24))] = tobit(0)
I8[tobit((v_e + 23))] = tobit(0)
I8[tobit((v_e + 22))] = tobit(0)
I8[tobit((v_e + 21))] = tobit(0)
I8[tobit((v_e + 20))] = tobit(0)
I8[tobit((v_e + 19))] = tobit(0)
I8[tobit((v_e + 18))] = tobit(0)
I8[tobit((v_e + 17))] = tobit(0)
I8[tobit((v_e + 16))] = tobit(0)
I8[tobit((v_e + 15))] = tobit(0)
I8[tobit((v_e + 14))] = tobit(0)
I8[tobit((v_e + 13))] = tobit(0)
I8[tobit((v_e + 12))] = tobit(0)
I8[tobit((v_e + 11))] = tobit(0)
I8[tobit((v_e + 10))] = tobit(0)
I8[tobit((v_e + 9))] = tobit(0)
I8[tobit((v_e + 44))] = tobit(0)
I8[tobit((v_e + 45))] = tobit(0)
I8[tobit((v_e + 46))] = tobit(0)
I8[tobit((v_e + 47))] = tobit(0)
end

F.fx = function(v_A, v_r)
local v_n, v_t, v_e, v_o, v_a, v_u, v_c, v_s, v_l, v_b, v_v, v_g, v_p, v_h, v_d, v_k, v_y, v_w, v_C, v_E, v_I, v_m, v_Q, v_O, v_S, v_j = 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
v_t = 0
v_e = 0
v_o = 0
v_a = 0
v_u = 0
v_c = 0
v_s = 0
v_l = 0
v_b = 0
v_v = 0
v_g = 0
v_p = 0
v_h = 0
v_d = 0
v_k = 0
v_y = 0
v_w = 0
v_C = 0
v_E = 0
v_I = 0
v_m = 0
v_Q = 0
v_O = 0
v_S = 0
v_j = 0
do
v_n = tobit((B - 256))
B = v_n
v_s = I32[arshift((v_A + 36), 2)]
v_d = I32[arshift((v_A + 32), 2)]
v_k = I32[arshift((v_A + 28), 2)]
v_y = I32[arshift((v_A + 24), 2)]
v_u = I32[arshift((v_A + 20), 2)]
v_l = I32[arshift((v_A + 16), 2)]
v_p = I32[arshift((v_A + 12), 2)]
v_h = I32[arshift((v_A + 8), 2)]
while true do
v_t = 1
v_o = lshift(v_e, 2)
I32[arshift((v_o + v_n), 2)] = tobit(bor(bor(bor(U8[tobit((bor(3, v_o) + v_r))], lshift(U8[tobit((bor(1, v_o) + v_r))], 16)), lshift(U8[tobit((v_r + v_o))], 24)), lshift(U8[tobit((bor(2, v_o) + v_r))], 8)))
v_e = tobit((v_e + 1))
if not (16 ~= bor(0, v_e)) then goto B115 end
do
end
::C115::
end
end
::B115::
do
do
while true do
do
v_C = lshift(v_S, 2)
v_S = 8
v_o = tobit((tobit((I32[arshift((v_n + v_C), 2)] + tobit((I32[arshift((v_C + 11808), 2)] + tobit((bxor(bxor(F.fSA(v_y, 26), F.fSA(v_y, 21)), F.fSA(v_y, 7)) + v_s)))))) + bxor(band(bxor(v_d, v_k), v_y), v_d)))
v_a = tobit((tobit((v_o + bxor(bxor(F.fSA(v_h, 30), F.fSA(v_h, 19)), F.fSA(v_h, 10)))) + bor(band(bor(v_h, v_p), v_l), band(v_h, v_p))))
v_e = tobit((bxor(bxor(F.fSA(v_a, 30), F.fSA(v_a, 19)), F.fSA(v_a, 10)) + bor(band(bor(v_a, v_h), v_p), band(v_a, v_h))))
v_c = tobit((v_o + v_u))
v_r = bor(4, v_C)
v_o = tobit((tobit((tobit((I32[arshift((11808 + v_r), 2)] + tobit((bxor(band(v_c, bxor(v_y, v_k)), v_k) + v_d)))) + bxor(bxor(F.fSA(v_c, 26), F.fSA(v_c, 21)), F.fSA(v_c, 7)))) + I32[arshift((v_r + v_n), 2)]))
v_b = tobit((v_e + v_o))
v_e = tobit((bxor(bxor(F.fSA(v_b, 30), F.fSA(v_b, 19)), F.fSA(v_b, 10)) + bor(band(bor(v_a, v_b), v_h), band(v_a, v_b))))
v_Q = tobit((v_o + v_l))
v_r = bor(8, v_C)
v_o = tobit((tobit((tobit((tobit((I32[arshift((11808 + v_r), 2)] + v_k)) + I32[arshift((v_r + v_n), 2)])) + bxor(band(v_Q, bxor(v_c, v_y)), v_y))) + bxor(bxor(F.fSA(v_Q, 26), F.fSA(v_Q, 21)), F.fSA(v_Q, 7))))
v_v = tobit((v_e + v_o))
v_e = tobit((bxor(bxor(F.fSA(v_v, 30), F.fSA(v_v, 19)), F.fSA(v_v, 10)) + bor(band(v_a, bor(v_b, v_v)), band(v_b, v_v))))
v_O = tobit((v_o + v_p))
v_r = bor(12, v_C)
v_o = tobit((tobit((tobit((tobit((I32[arshift((11808 + v_r), 2)] + v_y)) + I32[arshift((v_r + v_n), 2)])) + bxor(v_c, band(v_O, bxor(v_c, v_Q))))) + bxor(bxor(F.fSA(v_O, 26), F.fSA(v_O, 21)), F.fSA(v_O, 7))))
v_g = tobit((v_e + v_o))
v_e = tobit((bxor(bxor(F.fSA(v_g, 30), F.fSA(v_g, 19)), F.fSA(v_g, 10)) + bor(band(v_b, bor(v_v, v_g)), band(v_v, v_g))))
local t103 = v_c
v_r = bor(16, v_C)
v_r = tobit((tobit((t103 + I32[arshift((11808 + v_r), 2)])) + I32[arshift((v_r + v_n), 2)]))
local t105 = v_r
local t104 = v_Q
v_c = tobit((v_o + v_h))
v_o = tobit((tobit((t105 + bxor(t104, band(v_c, bxor(v_Q, v_O))))) + bxor(bxor(F.fSA(v_c, 26), F.fSA(v_c, 21)), F.fSA(v_c, 7))))
v_u = tobit((v_e + v_o))
v_e = tobit((bxor(bxor(F.fSA(v_u, 30), F.fSA(v_u, 19)), F.fSA(v_u, 10)) + bor(band(v_v, bor(v_u, v_g)), band(v_u, v_g))))
v_s = tobit((v_o + v_a))
local t106 = v_Q
v_r = bor(20, v_C)
v_o = tobit((tobit((tobit((tobit((t106 + I32[arshift((11808 + v_r), 2)])) + I32[arshift((v_r + v_n), 2)])) + bxor(v_O, band(v_s, bxor(v_c, v_O))))) + bxor(bxor(F.fSA(v_s, 26), F.fSA(v_s, 21)), F.fSA(v_s, 7))))
v_l = tobit((v_e + v_o))
v_e = tobit((bxor(bxor(F.fSA(v_l, 30), F.fSA(v_l, 19)), F.fSA(v_l, 10)) + bor(band(v_g, bor(v_u, v_l)), band(v_u, v_l))))
v_d = tobit((v_o + v_b))
local t107 = v_O
v_r = bor(24, v_C)
v_o = tobit((tobit((tobit((tobit((t107 + I32[arshift((11808 + v_r), 2)])) + I32[arshift((v_r + v_n), 2)])) + bxor(v_c, band(v_d, bxor(v_c, v_s))))) + bxor(bxor(F.fSA(v_d, 26), F.fSA(v_d, 21)), F.fSA(v_d, 7))))
v_k = tobit((v_o + v_v))
v_p = tobit((v_e + v_o))
v_e = tobit((bxor(bxor(F.fSA(v_p, 30), F.fSA(v_p, 19)), F.fSA(v_p, 10)) + bor(band(bor(v_l, v_p), v_u), band(v_l, v_p))))
local t109 = v_e
local t108 = v_c
v_r = bor(28, v_C)
v_r = tobit((tobit((tobit((tobit((t108 + I32[arshift((11808 + v_r), 2)])) + I32[arshift((v_r + v_n), 2)])) + bxor(band(v_k, bxor(v_s, v_d)), v_s))) + bxor(bxor(F.fSA(v_k, 26), F.fSA(v_k, 21)), F.fSA(v_k, 7))))
v_h = tobit((t109 + v_r))
v_y = tobit((v_r + v_g))
v_r = v_t
v_t = 0
if not (v_r ~= 0) then goto B116 end
end
do
end
::C116::
end
end
::B116::
end
do
do
v_e = I32[arshift(v_n, 2)]
v_S = 16
while true do
do
v_r = v_e
v_w = lshift(v_S, 2)
v_e = tobit((v_w + v_n))
v_c = I32[arshift((v_e - 8), 2)]
v_r = tobit((v_r + tobit((I32[arshift((v_e - 28), 2)] + bxor(bxor(F.fSA(v_c, 15), F.fSA(v_c, 13)), (rshift(v_c, 10) % 4294967296))))))
v_t = I32[arshift((v_e - 60), 2)]
v_a = tobit((bxor(bxor(F.fSA(v_t, 25), F.fSA(v_t, 14)), (rshift(v_t, 3) % 4294967296)) + v_r))
I32[arshift(v_e, 2)] = tobit(v_a)
v_r = bor(4, v_w)
v_o = I32[arshift((v_e - 4), 2)]
v_b = tobit((tobit((v_t + I32[arshift((v_e - 24), 2)])) + bxor(bxor(F.fSA(v_o, 15), F.fSA(v_o, 13)), (rshift(v_o, 10) % 4294967296))))
local t110 = v_b
v_t = I32[arshift((v_e - 56), 2)]
v_E = tobit((t110 + bxor(bxor(F.fSA(v_t, 25), F.fSA(v_t, 14)), (rshift(v_t, 3) % 4294967296))))
I32[arshift((v_r + v_n), 2)] = tobit(v_E)
v_b = bor(8, v_w)
v_v = tobit((I32[arshift((v_e - 20), 2)] + tobit((v_t + bxor(bxor(F.fSA(v_a, 15), F.fSA(v_a, 13)), (rshift(v_a, 10) % 4294967296))))))
local t111 = v_v
v_t = I32[arshift((v_e - 52), 2)]
v_I = tobit((t111 + bxor(bxor(F.fSA(v_t, 25), F.fSA(v_t, 14)), (rshift(v_t, 3) % 4294967296))))
I32[arshift((v_b + v_n), 2)] = tobit(v_I)
v_v = bor(12, v_w)
v_g = tobit((I32[arshift((v_e - 16), 2)] + tobit((v_t + bxor(bxor(F.fSA(v_E, 15), F.fSA(v_E, 13)), (rshift(v_E, 10) % 4294967296))))))
local t112 = v_g
v_t = I32[arshift((v_e - 48), 2)]
v_m = tobit((t112 + bxor(bxor(F.fSA(v_t, 25), F.fSA(v_t, 14)), (rshift(v_t, 3) % 4294967296))))
I32[arshift((v_v + v_n), 2)] = tobit(v_m)
v_g = bor(16, v_w)
v_C = tobit((I32[arshift((v_e - 12), 2)] + tobit((v_t + bxor(bxor(F.fSA(v_I, 15), F.fSA(v_I, 13)), (rshift(v_I, 10) % 4294967296))))))
local t113 = v_C
v_t = I32[arshift((v_e - 44), 2)]
v_j = tobit((t113 + bxor(bxor(F.fSA(v_t, 25), F.fSA(v_t, 14)), (rshift(v_t, 3) % 4294967296))))
I32[arshift((v_g + v_n), 2)] = tobit(v_j)
v_Q = bor(20, v_w)
v_c = tobit((tobit((v_t + v_c)) + bxor(bxor(F.fSA(v_m, 15), F.fSA(v_m, 13)), (rshift(v_m, 10) % 4294967296))))
local t114 = v_c
v_t = I32[arshift((v_e - 40), 2)]
v_C = tobit((t114 + bxor(bxor(F.fSA(v_t, 25), F.fSA(v_t, 14)), (rshift(v_t, 3) % 4294967296))))
I32[arshift((v_Q + v_n), 2)] = tobit(v_C)
v_O = bor(24, v_w)
v_o = tobit((tobit((v_t + v_o)) + bxor(bxor(F.fSA(v_j, 15), F.fSA(v_j, 13)), (rshift(v_j, 10) % 4294967296))))
local t115 = v_o
v_t = I32[arshift((v_e - 36), 2)]
v_c = tobit((t115 + bxor(bxor(F.fSA(v_t, 25), F.fSA(v_t, 14)), (rshift(v_t, 3) % 4294967296))))
I32[arshift((v_O + v_n), 2)] = tobit(v_c)
v_o = bor(28, v_w)
v_t = tobit((tobit((v_t + v_a)) + bxor(bxor(F.fSA(v_C, 15), F.fSA(v_C, 13)), (rshift(v_C, 10) % 4294967296))))
local t116 = v_t
v_e = I32[arshift((v_e - 32), 2)]
v_t = tobit((t116 + bxor(bxor(F.fSA(v_e, 25), F.fSA(v_e, 14)), (rshift(v_e, 3) % 4294967296))))
I32[arshift((v_o + v_n), 2)] = tobit(v_t)
v_a = tobit((v_a + tobit((tobit((I32[arshift((v_w + 11808), 2)] + tobit((bxor(bxor(F.fSA(v_y, 26), F.fSA(v_y, 21)), F.fSA(v_y, 7)) + v_s)))) + bxor(band(bxor(v_d, v_k), v_y), v_d)))))
v_w = tobit((tobit((v_a + bxor(bxor(F.fSA(v_h, 30), F.fSA(v_h, 19)), F.fSA(v_h, 10)))) + bor(band(bor(v_h, v_p), v_l), band(v_h, v_p))))
v_s = tobit((bxor(bxor(F.fSA(v_w, 30), F.fSA(v_w, 19)), F.fSA(v_w, 10)) + bor(band(bor(v_h, v_w), v_p), band(v_h, v_w))))
v_a = tobit((v_a + v_u))
v_r = tobit((tobit((tobit((I32[arshift((v_r + 11808), 2)] + tobit((bxor(band(v_a, bxor(v_y, v_k)), v_k) + v_d)))) + bxor(bxor(F.fSA(v_a, 26), F.fSA(v_a, 21)), F.fSA(v_a, 7)))) + v_E))
v_E = tobit((v_s + v_r))
v_u = tobit((bxor(bxor(F.fSA(v_E, 30), F.fSA(v_E, 19)), F.fSA(v_E, 10)) + bor(band(bor(v_w, v_E), v_h), band(v_w, v_E))))
local t118 = v_I
v_s = tobit((I32[arshift((v_b + 11808), 2)] + v_k))
local t117 = v_s
v_b = tobit((v_r + v_l))
v_r = tobit((t118 + tobit((tobit((t117 + bxor(band(v_b, bxor(v_a, v_y)), v_y))) + bxor(bxor(F.fSA(v_b, 26), F.fSA(v_b, 21)), F.fSA(v_b, 7))))))
v_I = tobit((v_u + v_r))
v_u = tobit((bxor(bxor(F.fSA(v_I, 30), F.fSA(v_I, 19)), F.fSA(v_I, 10)) + bor(band(v_w, bor(v_E, v_I)), band(v_E, v_I))))
local t121 = v_m
v_l = tobit((I32[arshift((v_v + 11808), 2)] + v_y))
local t120 = v_l
local t119 = v_a
v_v = tobit((v_r + v_p))
v_r = tobit((tobit((t121 + tobit((t120 + bxor(t119, band(v_v, bxor(v_a, v_b))))))) + bxor(bxor(F.fSA(v_v, 26), F.fSA(v_v, 21)), F.fSA(v_v, 7))))
v_m = tobit((v_u + v_r))
v_u = tobit((bxor(bxor(F.fSA(v_m, 30), F.fSA(v_m, 19)), F.fSA(v_m, 10)) + bor(band(v_E, bor(v_I, v_m)), band(v_I, v_m))))
v_a = tobit((v_j + tobit((v_a + I32[arshift((v_g + 11808), 2)]))))
local t123 = v_a
local t122 = v_b
v_g = tobit((v_r + v_h))
v_r = tobit((tobit((t123 + bxor(t122, band(v_g, bxor(v_b, v_v))))) + bxor(bxor(F.fSA(v_g, 26), F.fSA(v_g, 21)), F.fSA(v_g, 7))))
v_u = tobit((v_u + v_r))
v_a = tobit((bxor(bxor(F.fSA(v_u, 30), F.fSA(v_u, 19)), F.fSA(v_u, 10)) + bor(band(v_I, bor(v_u, v_m)), band(v_u, v_m))))
v_s = tobit((v_r + v_w))
v_r = tobit((tobit((tobit((v_C + tobit((v_b + I32[arshift((v_Q + 11808), 2)])))) + bxor(v_v, band(v_s, bxor(v_v, v_g))))) + bxor(bxor(F.fSA(v_s, 26), F.fSA(v_s, 21)), F.fSA(v_s, 7))))
v_l = tobit((v_a + v_r))
v_a = tobit((bxor(bxor(F.fSA(v_l, 30), F.fSA(v_l, 19)), F.fSA(v_l, 10)) + bor(band(v_m, bor(v_u, v_l)), band(v_u, v_l))))
v_d = tobit((v_r + v_E))
v_r = tobit((tobit((tobit((v_c + tobit((v_v + I32[arshift((v_O + 11808), 2)])))) + bxor(v_g, band(v_d, bxor(v_g, v_s))))) + bxor(bxor(F.fSA(v_d, 26), F.fSA(v_d, 21)), F.fSA(v_d, 7))))
v_k = tobit((v_r + v_I))
v_p = tobit((v_a + v_r))
v_a = tobit((bxor(bxor(F.fSA(v_p, 30), F.fSA(v_p, 19)), F.fSA(v_p, 10)) + bor(band(bor(v_l, v_p), v_u), band(v_l, v_p))))
local t124 = v_a
v_r = tobit((tobit((tobit((tobit((v_g + I32[arshift((v_o + 11808), 2)])) + v_t)) + bxor(band(v_k, bxor(v_s, v_d)), v_s))) + bxor(bxor(F.fSA(v_k, 26), F.fSA(v_k, 21)), F.fSA(v_k, 7))))
v_h = tobit((t124 + v_r))
v_y = tobit((v_r + v_m))
v_r = (((tobit(v_S) % 4294967296) < 56) and 1 or 0)
v_S = tobit((v_S + 8))
if not (v_r ~= 0) then goto B117 end
end
do
end
::C117::
end
end
::B117::
end
I32[arshift((v_A + 8), 2)] = tobit((I32[arshift((v_A + 8), 2)] + v_h))
I32[arshift((v_A + 12), 2)] = tobit((I32[arshift((v_A + 12), 2)] + v_p))
I32[arshift((v_A + 16), 2)] = tobit((I32[arshift((v_A + 16), 2)] + v_l))
I32[arshift((v_A + 20), 2)] = tobit((I32[arshift((v_A + 20), 2)] + v_u))
I32[arshift((v_A + 24), 2)] = tobit((I32[arshift((v_A + 24), 2)] + v_y))
I32[arshift((v_A + 28), 2)] = tobit((I32[arshift((v_A + 28), 2)] + v_k))
I32[arshift((v_A + 32), 2)] = tobit((I32[arshift((v_A + 32), 2)] + v_d))
I32[arshift((v_A + 36), 2)] = tobit((I32[arshift((v_A + 36), 2)] + v_s))
B = tobit((v_n + 256))
end

F.fP = function()
local v_A, v_r = 0, 0
v_r = 0
v_A = tobit((B - 672))
B = v_A
F.fxA(bor(0, imp_d(0)))
v_r = F.fIA()
I32[arshift((v_A + 464), 2)] = tobit(v_r)
F.fsA(tobit((v_A + 640)), tobit((v_A + 464)))
I8[tobit((v_A + 636))] = tobit(0)
I32[arshift((v_A + 632), 2)] = tobit(1768515945)
I32[arshift((v_A + 448), 2)] = tobit(1093)
I32[arshift((v_A + 456), 2)] = tobit(1080)
I32[arshift((v_A + 460), 2)] = tobit(500)
I32[arshift((v_A + 452), 2)] = tobit((v_A + 640))
imp_b(14020, tobit((v_A + 632)), tobit((v_A + 448)))
I8[tobit((v_A + 628))] = tobit(0)
I32[arshift((v_A + 624), 2)] = tobit(1768515945)
I32[arshift((v_A + 432), 2)] = tobit(imul(v_r, 27))
I32[arshift((v_A + 436), 2)] = tobit(imul(v_r, 517))
I32[arshift((v_A + 444), 2)] = tobit(imul(v_r, 197))
I32[arshift((v_A + 440), 2)] = tobit((v_A + 640))
imp_b(14188, tobit((v_A + 624)), tobit((v_A + 432)))
v_r = F.fIA()
I32[arshift((v_A + 416), 2)] = tobit(v_r)
F.fsA(tobit((v_A + 640)), tobit((v_A + 416)))
I8[tobit((v_A + 620))] = tobit(0)
I32[arshift((v_A + 616), 2)] = tobit(1768515945)
I32[arshift((v_A + 400), 2)] = tobit(1093)
I32[arshift((v_A + 408), 2)] = tobit(1080)
I32[arshift((v_A + 412), 2)] = tobit(500)
I32[arshift((v_A + 404), 2)] = tobit((v_A + 640))
imp_b(14729, tobit((v_A + 616)), tobit((v_A + 400)))
I8[tobit((v_A + 612))] = tobit(0)
I32[arshift((v_A + 608), 2)] = tobit(1768515945)
I32[arshift((v_A + 384), 2)] = tobit(imul(v_r, 27))
I32[arshift((v_A + 388), 2)] = tobit(imul(v_r, 517))
I32[arshift((v_A + 396), 2)] = tobit(imul(v_r, 197))
I32[arshift((v_A + 392), 2)] = tobit((v_A + 640))
imp_b(14897, tobit((v_A + 608)), tobit((v_A + 384)))
v_r = F.fIA()
I32[arshift((v_A + 368), 2)] = tobit(v_r)
F.fsA(tobit((v_A + 640)), tobit((v_A + 368)))
I8[tobit((v_A + 604))] = tobit(0)
I32[arshift((v_A + 600), 2)] = tobit(1768515945)
I32[arshift((v_A + 352), 2)] = tobit(1093)
I32[arshift((v_A + 360), 2)] = tobit(1080)
I32[arshift((v_A + 364), 2)] = tobit(500)
I32[arshift((v_A + 356), 2)] = tobit((v_A + 640))
imp_b(15438, tobit((v_A + 600)), tobit((v_A + 352)))
I8[tobit((v_A + 596))] = tobit(0)
I32[arshift((v_A + 592), 2)] = tobit(1768515945)
I32[arshift((v_A + 336), 2)] = tobit(imul(v_r, 27))
I32[arshift((v_A + 340), 2)] = tobit(imul(v_r, 517))
I32[arshift((v_A + 348), 2)] = tobit(imul(v_r, 197))
I32[arshift((v_A + 344), 2)] = tobit((v_A + 640))
imp_b(15606, tobit((v_A + 592)), tobit((v_A + 336)))
v_r = F.fIA()
I32[arshift((v_A + 320), 2)] = tobit(v_r)
F.fsA(tobit((v_A + 640)), tobit((v_A + 320)))
I8[tobit((v_A + 588))] = tobit(0)
I32[arshift((v_A + 584), 2)] = tobit(1768515945)
I32[arshift((v_A + 304), 2)] = tobit(1093)
I32[arshift((v_A + 312), 2)] = tobit(1080)
I32[arshift((v_A + 316), 2)] = tobit(500)
I32[arshift((v_A + 308), 2)] = tobit((v_A + 640))
imp_b(16147, tobit((v_A + 584)), tobit((v_A + 304)))
I8[tobit((v_A + 580))] = tobit(0)
I32[arshift((v_A + 576), 2)] = tobit(1768515945)
I32[arshift((v_A + 288), 2)] = tobit(imul(v_r, 27))
I32[arshift((v_A + 292), 2)] = tobit(imul(v_r, 517))
I32[arshift((v_A + 300), 2)] = tobit(imul(v_r, 197))
I32[arshift((v_A + 296), 2)] = tobit((v_A + 640))
imp_b(16315, tobit((v_A + 576)), tobit((v_A + 288)))
v_r = F.fIA()
I32[arshift((v_A + 272), 2)] = tobit(v_r)
F.fsA(tobit((v_A + 640)), tobit((v_A + 272)))
I8[tobit((v_A + 572))] = tobit(0)
I32[arshift((v_A + 568), 2)] = tobit(1768515945)
I32[arshift((v_A + 256), 2)] = tobit(1093)
I32[arshift((v_A + 264), 2)] = tobit(1080)
I32[arshift((v_A + 268), 2)] = tobit(500)
I32[arshift((v_A + 260), 2)] = tobit((v_A + 640))
imp_b(16856, tobit((v_A + 568)), tobit((v_A + 256)))
I8[tobit((v_A + 564))] = tobit(0)
I32[arshift((v_A + 560), 2)] = tobit(1768515945)
I32[arshift((v_A + 240), 2)] = tobit(imul(v_r, 27))
I32[arshift((v_A + 244), 2)] = tobit(imul(v_r, 517))
I32[arshift((v_A + 252), 2)] = tobit(imul(v_r, 197))
I32[arshift((v_A + 248), 2)] = tobit((v_A + 640))
imp_b(17024, tobit((v_A + 560)), tobit((v_A + 240)))
v_r = F.fIA()
I32[arshift((v_A + 224), 2)] = tobit(v_r)
F.fsA(tobit((v_A + 640)), tobit((v_A + 224)))
I8[tobit((v_A + 556))] = tobit(0)
I32[arshift((v_A + 552), 2)] = tobit(1768515945)
I32[arshift((v_A + 208), 2)] = tobit(1093)
I32[arshift((v_A + 216), 2)] = tobit(1080)
I32[arshift((v_A + 220), 2)] = tobit(500)
I32[arshift((v_A + 212), 2)] = tobit((v_A + 640))
imp_b(17565, tobit((v_A + 552)), tobit((v_A + 208)))
I8[tobit((v_A + 548))] = tobit(0)
I32[arshift((v_A + 544), 2)] = tobit(1768515945)
I32[arshift((v_A + 192), 2)] = tobit(imul(v_r, 27))
I32[arshift((v_A + 196), 2)] = tobit(imul(v_r, 517))
I32[arshift((v_A + 204), 2)] = tobit(imul(v_r, 197))
I32[arshift((v_A + 200), 2)] = tobit((v_A + 640))
imp_b(17733, tobit((v_A + 544)), tobit((v_A + 192)))
v_r = F.fIA()
I32[arshift((v_A + 176), 2)] = tobit(v_r)
F.fsA(tobit((v_A + 640)), tobit((v_A + 176)))
I8[tobit((v_A + 540))] = tobit(0)
I32[arshift((v_A + 536), 2)] = tobit(1768515945)
I32[arshift((v_A + 160), 2)] = tobit(1093)
I32[arshift((v_A + 168), 2)] = tobit(1080)
I32[arshift((v_A + 172), 2)] = tobit(500)
I32[arshift((v_A + 164), 2)] = tobit((v_A + 640))
imp_b(18274, tobit((v_A + 536)), tobit((v_A + 160)))
I8[tobit((v_A + 532))] = tobit(0)
I32[arshift((v_A + 528), 2)] = tobit(1768515945)
I32[arshift((v_A + 144), 2)] = tobit(imul(v_r, 27))
I32[arshift((v_A + 148), 2)] = tobit(imul(v_r, 517))
I32[arshift((v_A + 156), 2)] = tobit(imul(v_r, 197))
I32[arshift((v_A + 152), 2)] = tobit((v_A + 640))
imp_b(18442, tobit((v_A + 528)), tobit((v_A + 144)))
v_r = F.fIA()
I32[arshift((v_A + 128), 2)] = tobit(v_r)
F.fsA(tobit((v_A + 640)), tobit((v_A + 128)))
I8[tobit((v_A + 524))] = tobit(0)
I32[arshift((v_A + 520), 2)] = tobit(1768515945)
I32[arshift((v_A + 112), 2)] = tobit(1093)
I32[arshift((v_A + 120), 2)] = tobit(1080)
I32[arshift((v_A + 124), 2)] = tobit(500)
I32[arshift((v_A + 116), 2)] = tobit((v_A + 640))
imp_b(18983, tobit((v_A + 520)), tobit((v_A + 112)))
I8[tobit((v_A + 516))] = tobit(0)
I32[arshift((v_A + 512), 2)] = tobit(1768515945)
I32[arshift((v_A + 96), 2)] = tobit(imul(v_r, 27))
I32[arshift((v_A + 100), 2)] = tobit(imul(v_r, 517))
I32[arshift((v_A + 108), 2)] = tobit(imul(v_r, 197))
I32[arshift((v_A + 104), 2)] = tobit((v_A + 640))
imp_b(19151, tobit((v_A + 512)), tobit((v_A + 96)))
v_r = F.fIA()
I32[arshift((v_A + 80), 2)] = tobit(v_r)
F.fsA(tobit((v_A + 640)), tobit((v_A + 80)))
I8[tobit((v_A + 508))] = tobit(0)
I32[arshift((v_A + 504), 2)] = tobit(1768515945)
I32[arshift((v_A + 64), 2)] = tobit(1093)
I32[arshift((v_A + 72), 2)] = tobit(1080)
I32[arshift((v_A + 76), 2)] = tobit(500)
I32[arshift((v_A + 68), 2)] = tobit((v_A + 640))
imp_b(19692, tobit((v_A + 504)), tobit((v_A - (-64))))
I8[tobit((v_A + 500))] = tobit(0)
I32[arshift((v_A + 496), 2)] = tobit(1768515945)
I32[arshift((v_A + 48), 2)] = tobit(imul(v_r, 27))
I32[arshift((v_A + 52), 2)] = tobit(imul(v_r, 517))
I32[arshift((v_A + 60), 2)] = tobit(imul(v_r, 197))
I32[arshift((v_A + 56), 2)] = tobit((v_A + 640))
imp_b(19860, tobit((v_A + 496)), tobit((v_A + 48)))
v_r = F.fIA()
I32[arshift((v_A + 32), 2)] = tobit(v_r)
F.fsA(tobit((v_A + 640)), tobit((v_A + 32)))
I8[tobit((v_A + 492))] = tobit(0)
I32[arshift((v_A + 488), 2)] = tobit(1768515945)
I32[arshift((v_A + 16), 2)] = tobit(1093)
I32[arshift((v_A + 24), 2)] = tobit(1080)
I32[arshift((v_A + 28), 2)] = tobit(500)
I32[arshift((v_A + 20), 2)] = tobit((v_A + 640))
imp_b(20401, tobit((v_A + 488)), tobit((v_A + 16)))
I8[tobit((v_A + 484))] = tobit(0)
I32[arshift((v_A + 480), 2)] = tobit(1768515945)
I32[arshift(v_A, 2)] = tobit(imul(v_r, 27))
I32[arshift((v_A + 4), 2)] = tobit(imul(v_r, 517))
I32[arshift((v_A + 12), 2)] = tobit(imul(v_r, 197))
I32[arshift((v_A + 8), 2)] = tobit((v_A + 640))
imp_b(20569, tobit((v_A + 480)), bor(0, v_A))
B = tobit((v_A + 672))
end

F.fM = function(v_A, v_r, v_n, v_e, v_o, v_a)
local v_u, v_c, v_s = 0, 0, 0
v_c = 0
v_s = 0
v_u = tobit((B - 16))
B = v_u
v_s = (-34)
do
if (not (band(15, v_n) ~= 0)) then
do
if (v_r ~= 0) then
v_s = 0
if (not (v_n ~= 0)) then
goto L118
end
if (1 ~= bor(0, v_r)) then
goto L119
end
do
while true do
I8[bor(0, v_a)] = tobit(bxor(U8[bor(0, v_e)], U8[bor(0, v_o)]))
I8[tobit((v_a + 1))] = tobit(bxor(U8[tobit((v_e + 1))], U8[tobit((v_o + 1))]))
I8[tobit((v_a + 2))] = tobit(bxor(U8[tobit((v_e + 2))], U8[tobit((v_o + 2))]))
I8[tobit((v_a + 3))] = tobit(bxor(U8[tobit((v_e + 3))], U8[tobit((v_o + 3))]))
I8[tobit((v_a + 4))] = tobit(bxor(U8[tobit((v_e + 4))], U8[tobit((v_o + 4))]))
I8[tobit((v_a + 5))] = tobit(bxor(U8[tobit((v_e + 5))], U8[tobit((v_o + 5))]))
I8[tobit((v_a + 6))] = tobit(bxor(U8[tobit((v_e + 6))], U8[tobit((v_o + 6))]))
I8[tobit((v_a + 7))] = tobit(bxor(U8[tobit((v_e + 7))], U8[tobit((v_o + 7))]))
I8[tobit((v_a + 8))] = tobit(bxor(U8[tobit((v_e + 8))], U8[tobit((v_o + 8))]))
I8[tobit((v_a + 9))] = tobit(bxor(U8[tobit((v_e + 9))], U8[tobit((v_o + 9))]))
I8[tobit((v_a + 10))] = tobit(bxor(U8[tobit((v_e + 10))], U8[tobit((v_o + 10))]))
I8[tobit((v_a + 11))] = tobit(bxor(U8[tobit((v_e + 11))], U8[tobit((v_o + 11))]))
I8[tobit((v_a + 12))] = tobit(bxor(U8[tobit((v_e + 12))], U8[tobit((v_o + 12))]))
I8[tobit((v_a + 13))] = tobit(bxor(U8[tobit((v_e + 13))], U8[tobit((v_o + 13))]))
I8[tobit((v_a + 14))] = tobit(bxor(U8[tobit((v_e + 14))], U8[tobit((v_o + 14))]))
I8[tobit((v_a + 15))] = tobit(bxor(U8[tobit((v_e + 15))], U8[tobit((v_o + 15))]))
F.fj(v_A, v_a, v_a)
v_r = bor(bor(bor(U8[tobit((v_a + 12))], lshift(U8[tobit((v_a + 13))], 8)), lshift(U8[tobit((v_a + 14))], 16)), lshift(U8[tobit((v_a + 15))], 24))
v_c = bor(bor(bor(U8[tobit((v_a + 8))], lshift(U8[tobit((v_a + 9))], 8)), lshift(U8[tobit((v_a + 10))], 16)), lshift(U8[tobit((v_a + 11))], 24))
I8[tobit((v_e + 8))] = tobit(v_c)
I8[tobit((v_e + 9))] = tobit((rshift(v_c, 8) % 4294967296))
I8[tobit((v_e + 10))] = tobit((rshift(v_c, 16) % 4294967296))
I8[tobit((v_e + 11))] = tobit((rshift(v_c, 24) % 4294967296))
I8[tobit((v_e + 12))] = tobit(v_r)
I8[tobit((v_e + 13))] = tobit((rshift(v_r, 8) % 4294967296))
I8[tobit((v_e + 14))] = tobit((rshift(v_r, 16) % 4294967296))
I8[tobit((v_e + 15))] = tobit((rshift(v_r, 24) % 4294967296))
v_r = bor(bor(bor(U8[tobit((v_a + 4))], lshift(U8[tobit((v_a + 5))], 8)), lshift(U8[tobit((v_a + 6))], 16)), lshift(U8[tobit((v_a + 7))], 24))
v_c = bor(bor(bor(U8[bor(0, v_a)], lshift(U8[tobit((v_a + 1))], 8)), lshift(U8[tobit((v_a + 2))], 16)), lshift(U8[tobit((v_a + 3))], 24))
I8[bor(0, v_e)] = tobit(v_c)
I8[tobit((v_e + 1))] = tobit((rshift(v_c, 8) % 4294967296))
I8[tobit((v_e + 2))] = tobit((rshift(v_c, 16) % 4294967296))
I8[tobit((v_e + 3))] = tobit((rshift(v_c, 24) % 4294967296))
I8[tobit((v_e + 4))] = tobit(v_r)
I8[tobit((v_e + 5))] = tobit((rshift(v_r, 8) % 4294967296))
I8[tobit((v_e + 6))] = tobit((rshift(v_r, 16) % 4294967296))
I8[tobit((v_e + 7))] = tobit((rshift(v_r, 24) % 4294967296))
v_a = tobit((v_a + 16))
v_o = tobit((v_o + 16))
v_n = tobit((v_n - 16))
if not (v_n ~= 0) then goto B120 end
do
end
::C120::
end
end
::B120::
goto L118
end
v_s = 0
if (not (v_n ~= 0)) then
goto L118
end
do
while true do
v_r = bor(bor(bor(U8[tobit((v_o + 4))], lshift(U8[tobit((v_o + 5))], 8)), lshift(U8[tobit((v_o + 6))], 16)), lshift(U8[tobit((v_o + 7))], 24))
I32[arshift(v_u, 2)] = tobit(bor(bor(bor(U8[bor(0, v_o)], lshift(U8[tobit((v_o + 1))], 8)), lshift(U8[tobit((v_o + 2))], 16)), lshift(U8[tobit((v_o + 3))], 24)))
I32[arshift((v_u + 4), 2)] = tobit(v_r)
v_r = bor(bor(bor(U8[tobit((v_o + 12))], lshift(U8[tobit((v_o + 13))], 8)), lshift(U8[tobit((v_o + 14))], 16)), lshift(U8[tobit((v_o + 15))], 24))
I32[arshift((v_u + 8), 2)] = tobit(bor(bor(bor(U8[tobit((v_o + 8))], lshift(U8[tobit((v_o + 9))], 8)), lshift(U8[tobit((v_o + 10))], 16)), lshift(U8[tobit((v_o + 11))], 24)))
I32[arshift((v_u + 12), 2)] = tobit(v_r)
F.fS(v_A, v_o, v_a)
I8[bor(0, v_a)] = tobit(bxor(U8[bor(0, v_e)], U8[bor(0, v_a)]))
I8[tobit((v_a + 1))] = tobit(bxor(U8[tobit((v_e + 1))], U8[tobit((v_a + 1))]))
I8[tobit((v_a + 2))] = tobit(bxor(U8[tobit((v_e + 2))], U8[tobit((v_a + 2))]))
I8[tobit((v_a + 3))] = tobit(bxor(U8[tobit((v_e + 3))], U8[tobit((v_a + 3))]))
I8[tobit((v_a + 4))] = tobit(bxor(U8[tobit((v_e + 4))], U8[tobit((v_a + 4))]))
I8[tobit((v_a + 5))] = tobit(bxor(U8[tobit((v_e + 5))], U8[tobit((v_a + 5))]))
I8[tobit((v_a + 6))] = tobit(bxor(U8[tobit((v_e + 6))], U8[tobit((v_a + 6))]))
I8[tobit((v_a + 7))] = tobit(bxor(U8[tobit((v_e + 7))], U8[tobit((v_a + 7))]))
I8[tobit((v_a + 8))] = tobit(bxor(U8[tobit((v_e + 8))], U8[tobit((v_a + 8))]))
I8[tobit((v_a + 9))] = tobit(bxor(U8[tobit((v_e + 9))], U8[tobit((v_a + 9))]))
I8[tobit((v_a + 10))] = tobit(bxor(U8[tobit((v_e + 10))], U8[tobit((v_a + 10))]))
I8[tobit((v_a + 11))] = tobit(bxor(U8[tobit((v_e + 11))], U8[tobit((v_a + 11))]))
I8[tobit((v_a + 12))] = tobit(bxor(U8[tobit((v_e + 12))], U8[tobit((v_a + 12))]))
I8[tobit((v_a + 13))] = tobit(bxor(U8[tobit((v_e + 13))], U8[tobit((v_a + 13))]))
I8[tobit((v_a + 14))] = tobit(bxor(U8[tobit((v_e + 14))], U8[tobit((v_a + 14))]))
I8[tobit((v_a + 15))] = tobit(bxor(U8[tobit((v_e + 15))], U8[tobit((v_a + 15))]))
v_r = I32[arshift((v_u + 12), 2)]
v_c = I32[arshift((v_u + 8), 2)]
I8[tobit((v_e + 8))] = tobit(v_c)
I8[tobit((v_e + 9))] = tobit((rshift(v_c, 8) % 4294967296))
I8[tobit((v_e + 10))] = tobit((rshift(v_c, 16) % 4294967296))
I8[tobit((v_e + 11))] = tobit((rshift(v_c, 24) % 4294967296))
I8[tobit((v_e + 12))] = tobit(v_r)
I8[tobit((v_e + 13))] = tobit((rshift(v_r, 8) % 4294967296))
I8[tobit((v_e + 14))] = tobit((rshift(v_r, 16) % 4294967296))
I8[tobit((v_e + 15))] = tobit((rshift(v_r, 24) % 4294967296))
v_r = I32[arshift((v_u + 4), 2)]
v_c = I32[arshift(v_u, 2)]
I8[bor(0, v_e)] = tobit(v_c)
I8[tobit((v_e + 1))] = tobit((rshift(v_c, 8) % 4294967296))
I8[tobit((v_e + 2))] = tobit((rshift(v_c, 16) % 4294967296))
I8[tobit((v_e + 3))] = tobit((rshift(v_c, 24) % 4294967296))
I8[tobit((v_e + 4))] = tobit(v_r)
I8[tobit((v_e + 5))] = tobit((rshift(v_r, 8) % 4294967296))
I8[tobit((v_e + 6))] = tobit((rshift(v_r, 16) % 4294967296))
I8[tobit((v_e + 7))] = tobit((rshift(v_r, 24) % 4294967296))
v_a = tobit((v_a + 16))
v_o = tobit((v_o + 16))
v_n = tobit((v_n - 16))
if not (v_n ~= 0) then goto B121 end
do
end
::C121::
end
end
::B121::
goto L118
end
::L119::
do
while true do
I8[bor(0, v_a)] = tobit(bxor(U8[bor(0, v_e)], U8[bor(0, v_o)]))
I8[tobit((v_a + 1))] = tobit(bxor(U8[tobit((v_e + 1))], U8[tobit((v_o + 1))]))
I8[tobit((v_a + 2))] = tobit(bxor(U8[tobit((v_e + 2))], U8[tobit((v_o + 2))]))
I8[tobit((v_a + 3))] = tobit(bxor(U8[tobit((v_e + 3))], U8[tobit((v_o + 3))]))
I8[tobit((v_a + 4))] = tobit(bxor(U8[tobit((v_e + 4))], U8[tobit((v_o + 4))]))
I8[tobit((v_a + 5))] = tobit(bxor(U8[tobit((v_e + 5))], U8[tobit((v_o + 5))]))
I8[tobit((v_a + 6))] = tobit(bxor(U8[tobit((v_e + 6))], U8[tobit((v_o + 6))]))
I8[tobit((v_a + 7))] = tobit(bxor(U8[tobit((v_e + 7))], U8[tobit((v_o + 7))]))
I8[tobit((v_a + 8))] = tobit(bxor(U8[tobit((v_e + 8))], U8[tobit((v_o + 8))]))
I8[tobit((v_a + 9))] = tobit(bxor(U8[tobit((v_e + 9))], U8[tobit((v_o + 9))]))
I8[tobit((v_a + 10))] = tobit(bxor(U8[tobit((v_e + 10))], U8[tobit((v_o + 10))]))
I8[tobit((v_a + 11))] = tobit(bxor(U8[tobit((v_e + 11))], U8[tobit((v_o + 11))]))
I8[tobit((v_a + 12))] = tobit(bxor(U8[tobit((v_e + 12))], U8[tobit((v_o + 12))]))
I8[tobit((v_a + 13))] = tobit(bxor(U8[tobit((v_e + 13))], U8[tobit((v_o + 13))]))
I8[tobit((v_a + 14))] = tobit(bxor(U8[tobit((v_e + 14))], U8[tobit((v_o + 14))]))
I8[tobit((v_a + 15))] = tobit(bxor(U8[tobit((v_e + 15))], U8[tobit((v_o + 15))]))
F.fS(v_A, v_a, v_a)
v_r = bor(bor(bor(U8[tobit((v_a + 12))], lshift(U8[tobit((v_a + 13))], 8)), lshift(U8[tobit((v_a + 14))], 16)), lshift(U8[tobit((v_a + 15))], 24))
v_c = bor(bor(bor(U8[tobit((v_a + 8))], lshift(U8[tobit((v_a + 9))], 8)), lshift(U8[tobit((v_a + 10))], 16)), lshift(U8[tobit((v_a + 11))], 24))
I8[tobit((v_e + 8))] = tobit(v_c)
I8[tobit((v_e + 9))] = tobit((rshift(v_c, 8) % 4294967296))
I8[tobit((v_e + 10))] = tobit((rshift(v_c, 16) % 4294967296))
I8[tobit((v_e + 11))] = tobit((rshift(v_c, 24) % 4294967296))
I8[tobit((v_e + 12))] = tobit(v_r)
I8[tobit((v_e + 13))] = tobit((rshift(v_r, 8) % 4294967296))
I8[tobit((v_e + 14))] = tobit((rshift(v_r, 16) % 4294967296))
I8[tobit((v_e + 15))] = tobit((rshift(v_r, 24) % 4294967296))
v_r = bor(bor(bor(U8[tobit((v_a + 4))], lshift(U8[tobit((v_a + 5))], 8)), lshift(U8[tobit((v_a + 6))], 16)), lshift(U8[tobit((v_a + 7))], 24))
v_c = bor(bor(bor(U8[bor(0, v_a)], lshift(U8[tobit((v_a + 1))], 8)), lshift(U8[tobit((v_a + 2))], 16)), lshift(U8[tobit((v_a + 3))], 24))
I8[bor(0, v_e)] = tobit(v_c)
I8[tobit((v_e + 1))] = tobit((rshift(v_c, 8) % 4294967296))
I8[tobit((v_e + 2))] = tobit((rshift(v_c, 16) % 4294967296))
I8[tobit((v_e + 3))] = tobit((rshift(v_c, 24) % 4294967296))
I8[tobit((v_e + 4))] = tobit(v_r)
I8[tobit((v_e + 5))] = tobit((rshift(v_r, 8) % 4294967296))
I8[tobit((v_e + 6))] = tobit((rshift(v_r, 16) % 4294967296))
I8[tobit((v_e + 7))] = tobit((rshift(v_r, 24) % 4294967296))
v_a = tobit((v_a + 16))
v_o = tobit((v_o + 16))
v_n = tobit((v_n - 16))
if not (v_n ~= 0) then goto B122 end
do
end
::C122::
end
end
::B122::
end
end
::L118::
B = tobit((v_u + 16))
do return v_s end
end

F.fT = function(v_A)
local v_r, v_n, v_e, v_o, v_a, v_u, v_c, v_s = 0, 0, 0, 0, 0, 0, 0, 0
v_e = 0
v_o = 0
v_a = 0
v_u = 0
v_c = 0
v_s = 0
do
v_r = tobit((B - 112))
B = v_r
v_n = F.fI(32)
F.fOA(v_r, 0, 108)
v_e = v_r
I32[arshift(v_r, 2)] = tobit(0)
I32[arshift((v_r + 4), 2)] = tobit(0)
I32[arshift((v_r + 104), 2)] = tobit(0)
I32[arshift((v_r + 8), 2)] = tobit(1779033703)
I32[arshift((v_r + 36), 2)] = tobit(1541459225)
I32[arshift((v_r + 32), 2)] = tobit(528734635)
I32[arshift((v_r + 28), 2)] = tobit((-1694144372))
I32[arshift((v_r + 24), 2)] = tobit(1359893119)
I32[arshift((v_r + 20), 2)] = tobit((-1521486534))
I32[arshift((v_r + 16), 2)] = tobit(1013904242)
I32[arshift((v_r + 12), 2)] = tobit((-1150833019))
v_a = F.flA(v_A)
if (v_a ~= 0) then
do
do
v_o = I32[arshift(v_e, 2)]
v_u = tobit((v_o + v_a))
I32[arshift(v_e, 2)] = tobit(v_u)
if ((tobit(v_o) % 4294967296) > (tobit(v_u) % 4294967296)) then
I32[arshift((v_e + 4), 2)] = tobit((I32[arshift((v_e + 4), 2)] + 1))
end
v_u = 0
v_o = band(v_o, 63)
if (v_o ~= 0) then
v_c = tobit((64 - v_o))
if ((tobit(v_c) % 4294967296) > (tobit(v_a) % 4294967296)) then
v_u = v_o
else
local t125 = v_o
v_s = tobit((v_e + 40))
F.fQA(tobit((t125 + v_s)), v_A, v_c)
F.fx(v_e, v_s)
v_a = tobit((v_a - v_c))
v_A = tobit((v_A + v_c))
end
end
if ((tobit(v_a) % 4294967296) >= 64) then
do
while true do
F.fx(v_e, v_A)
v_A = tobit((v_A - (-64)))
v_a = tobit((v_a + (-64)))
if not ((tobit(v_a) % 4294967296) > 63) then goto B123 end
do
end
::C123::
end
end
::B123::
end
end
if (v_a ~= 0) then
F.fQA(tobit((40 + tobit((v_e + v_u)))), v_A, v_a)
end
end
end
end
do
v_e = tobit((v_r + 40))
v_o = I32[arshift(v_r, 2)]
local t126 = v_e
v_u = band(63, v_o)
I8[tobit((t126 + v_u))] = tobit(128)
v_A = tobit((v_u + 1))
if ((tobit(v_u) % 4294967296) <= 55) then
F.fOA(tobit((40 + tobit((v_A + v_r)))), 0, tobit((55 - v_u)))
else
F.fOA(tobit((40 + tobit((v_A + v_r)))), 0, bxor(63, v_u))
F.fx(v_r, v_e)
I32[arshift((v_e + 48), 2)] = tobit(0)
I32[arshift((v_e + 52), 2)] = tobit(0)
I32[arshift((v_e + 40), 2)] = tobit(0)
I32[arshift((v_e + 44), 2)] = tobit(0)
I32[arshift((v_e + 32), 2)] = tobit(0)
I32[arshift((v_e + 36), 2)] = tobit(0)
I32[arshift((v_e + 24), 2)] = tobit(0)
I32[arshift((v_e + 28), 2)] = tobit(0)
I32[arshift((v_e + 16), 2)] = tobit(0)
I32[arshift((v_e + 20), 2)] = tobit(0)
I32[arshift((v_e + 8), 2)] = tobit(0)
I32[arshift((v_e + 12), 2)] = tobit(0)
I32[arshift(v_e, 2)] = tobit(0)
I32[arshift((v_e + 4), 2)] = tobit(0)
v_o = I32[arshift(v_r, 2)]
end
I8[tobit((v_r + 103))] = tobit(lshift(v_o, 3))
I8[tobit((v_r + 102))] = tobit((rshift(v_o, 5) % 4294967296))
I8[tobit((v_r + 101))] = tobit((rshift(v_o, 13) % 4294967296))
I8[tobit((v_r + 100))] = tobit((rshift(v_o, 21) % 4294967296))
v_A = I32[arshift((v_r + 4), 2)]
I8[tobit((v_r + 98))] = tobit((rshift(v_A, 5) % 4294967296))
I8[tobit((v_r + 97))] = tobit((rshift(v_A, 13) % 4294967296))
I8[tobit((v_r + 96))] = tobit((rshift(v_A, 21) % 4294967296))
I8[tobit((v_r + 99))] = tobit(bor(lshift(v_A, 3), (rshift(v_o, 29) % 4294967296)))
F.fx(v_r, v_e)
I8[bor(0, v_n)] = tobit(U8[tobit((v_r + 11))])
I8[tobit((v_n + 1))] = tobit(U16[arshift((v_r + 10), 1)])
I8[tobit((v_n + 2))] = tobit((rshift(I32[arshift((v_r + 8), 2)], 8) % 4294967296))
I8[tobit((v_n + 3))] = tobit(I32[arshift((v_r + 8), 2)])
I8[tobit((v_n + 4))] = tobit(U8[tobit((v_r + 15))])
I8[tobit((v_n + 5))] = tobit(U16[arshift((v_r + 14), 1)])
I8[tobit((v_n + 6))] = tobit((rshift(I32[arshift((v_r + 12), 2)], 8) % 4294967296))
I8[tobit((v_n + 7))] = tobit(I32[arshift((v_r + 12), 2)])
I8[tobit((v_n + 8))] = tobit(U8[tobit((v_r + 19))])
I8[tobit((v_n + 9))] = tobit(U16[arshift((v_r + 18), 1)])
I8[tobit((v_n + 10))] = tobit((rshift(I32[arshift((v_r + 16), 2)], 8) % 4294967296))
I8[tobit((v_n + 11))] = tobit(I32[arshift((v_r + 16), 2)])
I8[tobit((v_n + 12))] = tobit(U8[tobit((v_r + 23))])
I8[tobit((v_n + 13))] = tobit(U16[arshift((v_r + 22), 1)])
I8[tobit((v_n + 14))] = tobit((rshift(I32[arshift((v_r + 20), 2)], 8) % 4294967296))
I8[tobit((v_n + 15))] = tobit(I32[arshift((v_r + 20), 2)])
I8[tobit((v_n + 16))] = tobit(U8[tobit((v_r + 27))])
I8[tobit((v_n + 17))] = tobit(U16[arshift((v_r + 26), 1)])
I8[tobit((v_n + 18))] = tobit((rshift(I32[arshift((v_r + 24), 2)], 8) % 4294967296))
I8[tobit((v_n + 19))] = tobit(I32[arshift((v_r + 24), 2)])
I8[tobit((v_n + 20))] = tobit(U8[tobit((v_r + 31))])
I8[tobit((v_n + 21))] = tobit(U16[arshift((v_r + 30), 1)])
I8[tobit((v_n + 22))] = tobit((rshift(I32[arshift((v_r + 28), 2)], 8) % 4294967296))
I8[tobit((v_n + 23))] = tobit(I32[arshift((v_r + 28), 2)])
I8[tobit((v_n + 24))] = tobit(U8[tobit((v_r + 35))])
I8[tobit((v_n + 25))] = tobit(U16[arshift((v_r + 34), 1)])
I8[tobit((v_n + 26))] = tobit((rshift(I32[arshift((v_r + 32), 2)], 8) % 4294967296))
I8[tobit((v_n + 27))] = tobit(I32[arshift((v_r + 32), 2)])
if not (I32[arshift((v_r + 104), 2)] ~= 0) then
I8[tobit((v_n + 28))] = tobit(U8[tobit((v_r + 39))])
I8[tobit((v_n + 29))] = tobit(U16[arshift((v_r + 38), 1)])
I8[tobit((v_n + 30))] = tobit((rshift(I32[arshift((v_r + 36), 2)], 8) % 4294967296))
I8[tobit((v_n + 31))] = tobit(I32[arshift((v_r + 36), 2)])
end
if (v_r ~= 0) then
I8[bor(0, v_r)] = tobit(0)
I8[tobit((v_r + 1))] = tobit(0)
I8[tobit((v_r + 2))] = tobit(0)
I8[tobit((v_r + 3))] = tobit(0)
I8[tobit((v_r + 4))] = tobit(0)
I8[tobit((v_r + 5))] = tobit(0)
I8[tobit((v_r + 6))] = tobit(0)
I8[tobit((v_r + 7))] = tobit(0)
I8[tobit((v_r + 8))] = tobit(0)
I8[tobit((v_r + 9))] = tobit(0)
I8[tobit((v_r + 10))] = tobit(0)
I8[tobit((v_r + 11))] = tobit(0)
I8[tobit((v_r + 12))] = tobit(0)
I8[tobit((v_r + 13))] = tobit(0)
I8[tobit((v_r + 14))] = tobit(0)
I8[tobit((v_r + 15))] = tobit(0)
I8[tobit((v_r + 16))] = tobit(0)
I8[tobit((v_r + 17))] = tobit(0)
I8[tobit((v_r + 18))] = tobit(0)
I8[tobit((v_r + 19))] = tobit(0)
I8[tobit((v_r + 20))] = tobit(0)
I8[tobit((v_r + 21))] = tobit(0)
I8[tobit((v_r + 22))] = tobit(0)
I8[tobit((v_r + 23))] = tobit(0)
I8[tobit((v_r + 24))] = tobit(0)
I8[tobit((v_r + 25))] = tobit(0)
I8[tobit((v_r + 26))] = tobit(0)
I8[tobit((v_r + 27))] = tobit(0)
I8[tobit((v_r + 28))] = tobit(0)
I8[tobit((v_r + 29))] = tobit(0)
I8[tobit((v_r + 30))] = tobit(0)
I8[tobit((v_r + 31))] = tobit(0)
I8[tobit((v_r + 32))] = tobit(0)
I8[tobit((v_r + 33))] = tobit(0)
I8[tobit((v_r + 34))] = tobit(0)
I8[tobit((v_r + 35))] = tobit(0)
I8[tobit((v_r + 36))] = tobit(0)
I8[tobit((v_r + 37))] = tobit(0)
I8[tobit((v_r + 38))] = tobit(0)
I8[tobit((v_r + 39))] = tobit(0)
I8[tobit((v_r + 40))] = tobit(0)
I8[tobit((v_r + 41))] = tobit(0)
I8[tobit((v_r + 42))] = tobit(0)
I8[tobit((v_r + 43))] = tobit(0)
I8[tobit((v_r + 44))] = tobit(0)
I8[tobit((v_r + 45))] = tobit(0)
I8[tobit((v_r + 46))] = tobit(0)
I8[tobit((v_r + 47))] = tobit(0)
I8[tobit((v_r + 48))] = tobit(0)
I8[tobit((v_r + 49))] = tobit(0)
I8[tobit((v_r + 50))] = tobit(0)
I8[tobit((v_r + 51))] = tobit(0)
I8[tobit((v_r + 52))] = tobit(0)
I8[tobit((v_r + 53))] = tobit(0)
I8[tobit((v_r + 54))] = tobit(0)
I8[tobit((v_r + 55))] = tobit(0)
I8[tobit((v_r + 56))] = tobit(0)
I8[tobit((v_r + 57))] = tobit(0)
I8[tobit((v_r + 58))] = tobit(0)
I8[tobit((v_r + 59))] = tobit(0)
I8[tobit((v_r + 60))] = tobit(0)
I8[tobit((v_r + 61))] = tobit(0)
I8[tobit((v_r + 62))] = tobit(0)
I8[tobit((v_r + 63))] = tobit(0)
I8[tobit((v_r - (-64)))] = tobit(0)
I8[tobit((v_r + 65))] = tobit(0)
I8[tobit((v_r + 66))] = tobit(0)
I8[tobit((v_r + 67))] = tobit(0)
I8[tobit((v_r + 68))] = tobit(0)
I8[tobit((v_r + 69))] = tobit(0)
I8[tobit((v_r + 70))] = tobit(0)
I8[tobit((v_r + 71))] = tobit(0)
I8[tobit((v_r + 72))] = tobit(0)
I8[tobit((v_r + 73))] = tobit(0)
I8[tobit((v_r + 74))] = tobit(0)
I8[tobit((v_r + 75))] = tobit(0)
I8[tobit((v_r + 76))] = tobit(0)
I8[tobit((v_r + 77))] = tobit(0)
I8[tobit((v_r + 78))] = tobit(0)
I8[tobit((v_r + 79))] = tobit(0)
I8[tobit((v_r + 80))] = tobit(0)
I8[tobit((v_r + 81))] = tobit(0)
I8[tobit((v_r + 82))] = tobit(0)
I8[tobit((v_r + 83))] = tobit(0)
I8[tobit((v_r + 84))] = tobit(0)
I8[tobit((v_r + 85))] = tobit(0)
I8[tobit((v_r + 86))] = tobit(0)
I8[tobit((v_r + 87))] = tobit(0)
I8[tobit((v_r + 88))] = tobit(0)
I8[tobit((v_r + 89))] = tobit(0)
I8[tobit((v_r + 90))] = tobit(0)
I8[tobit((v_r + 91))] = tobit(0)
I8[tobit((v_r + 92))] = tobit(0)
I8[tobit((v_r + 93))] = tobit(0)
I8[tobit((v_r + 94))] = tobit(0)
I8[tobit((v_r + 95))] = tobit(0)
I8[tobit((v_r + 96))] = tobit(0)
I8[tobit((v_r + 97))] = tobit(0)
I8[tobit((v_r + 98))] = tobit(0)
I8[tobit((v_r + 99))] = tobit(0)
I8[tobit((v_r + 100))] = tobit(0)
I8[tobit((v_r + 101))] = tobit(0)
I8[tobit((v_r + 102))] = tobit(0)
I8[tobit((v_r + 103))] = tobit(0)
I8[tobit((v_r + 104))] = tobit(0)
I8[tobit((v_r + 105))] = tobit(0)
I8[tobit((v_r + 106))] = tobit(0)
I8[tobit((v_r + 107))] = tobit(0)
end
B = tobit((v_r + 112))
do return v_n end
end
end

F.fR = function(v_A)
local v_r, v_n, v_t, v_e, v_o, v_f, v_a = 0, 0, 0, 0, 0, 0, 0
v_r = 0
v_n = 0
v_t = 0
v_e = 0
v_o = 0
v_f = 0
v_a = 0
do
do
do
v_A = tobit(v_A)
if (v_A ~= 0) then
do
do
v_t = tobit((v_A - 8))
local t128 = v_t
local t127 = (-8)
v_r = I32[arshift((v_A - 4), 2)]
v_A = band(t127, v_r)
v_o = tobit((t128 + v_A))
end
do
do
do
if (not (band(1, v_r) ~= 0)) then
do
if (not (band(3, v_r) ~= 0)) then
goto L124
end
do
local t129 = v_t
v_r = I32[arshift(v_t, 2)]
v_t = tobit((t129 - v_r))
if ((tobit(v_t) % 4294967296) < U32[5465]) then
goto L124
end
end
do
v_A = tobit((v_A + v_r))
if (I32[5466] == bor(0, v_t)) then
v_r = I32[arshift((v_o + 4), 2)]
if (3 == band(3, v_r)) then
I32[5463] = tobit(v_A)
I32[arshift((v_o + 4), 2)] = tobit(band((-2), v_r))
I32[arshift((v_t + 4), 2)] = tobit(bor(1, v_A))
I32[arshift((v_A + v_t), 2)] = tobit(v_A)
do return end
end
else
do
if ((tobit(v_r) % 4294967296) <= 255) then
v_e = I32[arshift((v_t + 8), 2)]
v_r = tobit((rshift(v_r, 3) % 4294967296))
v_n = I32[arshift((v_t + 12), 2)]
if (bor(0, v_n) == bor(0, v_e)) then
I32[5461] = tobit(band(I32[5461], F.fSA((-2), v_r)))
goto L125
end
I32[arshift((v_e + 12), 2)] = tobit(v_n)
I32[arshift((v_n + 8), 2)] = tobit(v_e)
goto L125
end
do
v_a = I32[arshift((v_t + 24), 2)]
local t130 = bor(0, v_t)
v_r = I32[arshift((v_t + 12), 2)]
if (t130 == bor(0, v_r)) then
do
v_e = tobit((v_t + 20))
v_n = I32[arshift(v_e, 2)]
local t131 = (v_n ~= 0)
if not t131 then
v_e = tobit((v_t + 16))
v_n = I32[arshift(v_e, 2)]
t131 = (v_n ~= 0)
end
if t131 then
do
do
do
while true do
do
v_f = v_e
v_r = v_n
v_e = tobit((v_r + 20))
v_n = I32[arshift(v_e, 2)]
local t132 = v_n
if t132 == 0 then
v_e = tobit((v_r + 16))
v_n = I32[arshift((v_r + 16), 2)]
t132 = v_n
end
if not (t132 ~= 0) then goto B126 end
end
do
end
::C126::
end
end
::B126::
end
I32[arshift(v_f, 2)] = tobit(0)
end
else
v_r = 0
end
end
else
v_n = I32[arshift((v_t + 8), 2)]
I32[arshift((v_n + 12), 2)] = tobit(v_r)
I32[arshift((v_r + 8), 2)] = tobit(v_n)
end
end
if (not (v_a ~= 0)) then
goto L125
end
v_e = I32[arshift((v_t + 28), 2)]
do
v_n = tobit((22148 + lshift(v_e, 2)))
if (I32[arshift(v_n, 2)] == bor(0, v_t)) then
I32[arshift(v_n, 2)] = tobit(v_r)
if (v_r ~= 0) then
goto L127
end
I32[5462] = tobit(band(I32[5462], F.fSA((-2), v_e)))
goto L125
end
I32[arshift((v_a + ((I32[arshift((v_a + 16), 2)] == bor(0, v_t)) and 16 or 20)), 2)] = tobit(v_r)
if (not (v_r ~= 0)) then
goto L125
end
end
::L127::
I32[arshift((v_r + 24), 2)] = tobit(v_a)
v_n = I32[arshift((v_t + 16), 2)]
if (v_n ~= 0) then
I32[arshift((v_r + 16), 2)] = tobit(v_n)
I32[arshift((v_n + 24), 2)] = tobit(v_r)
end
v_n = I32[arshift((v_t + 20), 2)]
if (not (v_n ~= 0)) then
goto L125
end
I32[arshift((v_r + 20), 2)] = tobit(v_n)
I32[arshift((v_n + 24), 2)] = tobit(v_r)
end
end
end
end
end
end
end
::L125::
end
do
local t133 = (not ((tobit(v_t) % 4294967296) >= (tobit(v_o) % 4294967296)))
if t133 then
v_r = I32[arshift((v_o + 4), 2)]
t133 = (band(1, v_r) ~= 0)
end
if t133 then
do
do
do
do
do
if (not (band(2, v_r) ~= 0)) then
do
if (I32[5467] == bor(0, v_o)) then
I32[5467] = tobit(v_t)
v_A = tobit((I32[5464] + v_A))
I32[5464] = tobit(v_A)
I32[arshift((v_t + 4), 2)] = tobit(bor(1, v_A))
if (I32[5466] ~= bor(0, v_t)) then
goto L124
end
I32[5463] = tobit(0)
I32[5466] = tobit(0)
do return end
end
if (I32[5466] == bor(0, v_o)) then
I32[5466] = tobit(v_t)
v_A = tobit((I32[5463] + v_A))
I32[5463] = tobit(v_A)
I32[arshift((v_t + 4), 2)] = tobit(bor(1, v_A))
I32[arshift((v_A + v_t), 2)] = tobit(v_A)
do return end
end
v_A = tobit((band((-8), v_r) + v_A))
do
do
do
if ((tobit(v_r) % 4294967296) <= 255) then
v_e = I32[arshift((v_o + 8), 2)]
v_r = tobit((rshift(v_r, 3) % 4294967296))
v_n = I32[arshift((v_o + 12), 2)]
if (bor(0, v_n) == bor(0, v_e)) then
I32[5461] = tobit(band(I32[5461], F.fSA((-2), v_r)))
goto L129
end
I32[arshift((v_e + 12), 2)] = tobit(v_n)
I32[arshift((v_n + 8), 2)] = tobit(v_e)
else
do
do
v_a = I32[arshift((v_o + 24), 2)]
local t134 = bor(0, v_o)
v_r = I32[arshift((v_o + 12), 2)]
if (t134 == bor(0, v_r)) then
do
v_e = tobit((v_o + 20))
v_n = I32[arshift(v_e, 2)]
local t135 = (v_n ~= 0)
if not t135 then
v_e = tobit((v_o + 16))
v_n = I32[arshift(v_e, 2)]
t135 = (v_n ~= 0)
end
if t135 then
do
do
do
while true do
do
v_f = v_e
v_r = v_n
v_e = tobit((v_r + 20))
v_n = I32[arshift(v_e, 2)]
local t136 = v_n
if t136 == 0 then
v_e = tobit((v_r + 16))
v_n = I32[arshift((v_r + 16), 2)]
t136 = v_n
end
if not (t136 ~= 0) then goto B130 end
end
do
end
::C130::
end
end
::B130::
end
I32[arshift(v_f, 2)] = tobit(0)
end
else
v_r = 0
end
end
else
v_n = I32[arshift((v_o + 8), 2)]
I32[arshift((v_n + 12), 2)] = tobit(v_r)
I32[arshift((v_r + 8), 2)] = tobit(v_n)
end
end
if (v_a ~= 0) then
v_e = I32[arshift((v_o + 28), 2)]
do
v_n = tobit((22148 + lshift(v_e, 2)))
if (I32[arshift(v_n, 2)] == bor(0, v_o)) then
I32[arshift(v_n, 2)] = tobit(v_r)
if (v_r ~= 0) then
goto L131
end
I32[5462] = tobit(band(I32[5462], F.fSA((-2), v_e)))
goto L129
end
I32[arshift((v_a + ((I32[arshift((v_a + 16), 2)] == bor(0, v_o)) and 16 or 20)), 2)] = tobit(v_r)
if (not (v_r ~= 0)) then
goto L129
end
end
::L131::
I32[arshift((v_r + 24), 2)] = tobit(v_a)
v_n = I32[arshift((v_o + 16), 2)]
if (v_n ~= 0) then
I32[arshift((v_r + 16), 2)] = tobit(v_n)
I32[arshift((v_n + 24), 2)] = tobit(v_r)
end
v_n = I32[arshift((v_o + 20), 2)]
if (v_n ~= 0) then
I32[arshift((v_r + 20), 2)] = tobit(v_n)
I32[arshift((v_n + 24), 2)] = tobit(v_r)
end
end
end
end
end
end
::L129::
end
I32[arshift((v_t + 4), 2)] = tobit(bor(1, v_A))
I32[arshift((v_A + v_t), 2)] = tobit(v_A)
if (I32[5466] ~= bor(0, v_t)) then
goto L128
end
I32[5463] = tobit(v_A)
do return end
end
end
end
I32[arshift((v_o + 4), 2)] = tobit(band((-2), v_r))
I32[arshift((v_t + 4), 2)] = tobit(bor(1, v_A))
I32[arshift((v_A + v_t), 2)] = tobit(v_A)
end
end
::L128::
end
do
if ((tobit(v_A) % 4294967296) <= 255) then
do
v_A = tobit((rshift(v_A, 3) % 4294967296))
v_r = tobit((21884 + lshift(v_A, 3)))
v_n = I32[5461]
local t137 = v_n
v_A = lshift(1, v_A)
if (band(t137, v_A) ~= 0) then
v_A = I32[arshift((v_r + 8), 2)]
else
I32[5461] = tobit(bor(v_A, v_n))
v_A = v_r
end
I32[arshift((v_r + 8), 2)] = tobit(v_t)
I32[arshift((v_A + 12), 2)] = tobit(v_t)
I32[arshift((v_t + 12), 2)] = tobit(v_r)
I32[arshift((v_t + 8), 2)] = tobit(v_A)
do return end
end
end
end
do
v_e = 31
I32[arshift((v_t + 16), 2)] = tobit(0)
I32[arshift((v_t + 20), 2)] = tobit(0)
if ((tobit(v_A) % 4294967296) <= 16777215) then
v_r = tobit((rshift(v_A, 8) % 4294967296))
local t138 = v_r
v_f = band((rshift((v_r + 1048320), 16) % 4294967296), 8)
v_r = lshift(t138, v_f)
local t139 = v_r
v_e = band((rshift((v_r + 520192), 16) % 4294967296), 4)
v_r = lshift(t139, v_e)
local t140 = v_r
v_n = band((rshift((v_r + 245760), 16) % 4294967296), 2)
v_r = tobit((tobit((rshift(lshift(t140, v_n), 15) % 4294967296)) - bor(bor(v_n, v_e), v_f)))
v_e = tobit((28 + bor(lshift(v_r, 1), band((rshift(v_A, (v_r + 21)) % 4294967296), 1))))
end
I32[arshift((v_t + 28), 2)] = tobit(v_e)
v_f = tobit((22148 + lshift(v_e, 2)))
end
do
do
do
do
do
do
do
v_n = I32[5462]
local t141 = v_n
v_r = lshift(1, v_e)
if (band(t141, v_r) ~= 0) then
do
v_e = lshift(v_A, ((31 == bor(0, v_e)) and 0 or tobit((25 - tobit((rshift(v_e, 1) % 4294967296))))))
v_r = I32[arshift(v_f, 2)]
while true do
do
v_n = v_r
if (band((-8), I32[arshift((v_r + 4), 2)]) == bor(0, v_A)) then
goto L133
end
v_r = tobit((rshift(v_e, 29) % 4294967296))
v_e = lshift(v_e, 1)
v_f = tobit((v_n + band(4, v_r)))
v_r = I32[arshift((16 + v_f), 2)]
if (not (v_r ~= 0)) then
goto B134
end
end
::C134::
end
end
::B134::
I32[arshift((v_f + 16), 2)] = tobit(v_t)
I32[arshift((v_t + 24), 2)] = tobit(v_n)
else
I32[5462] = tobit(bor(v_r, v_n))
I32[arshift(v_f, 2)] = tobit(v_t)
I32[arshift((v_t + 24), 2)] = tobit(v_f)
end
end
I32[arshift((v_t + 12), 2)] = tobit(v_t)
I32[arshift((v_t + 8), 2)] = tobit(v_t)
goto L132
end
end
::L133::
end
v_A = I32[arshift((v_n + 8), 2)]
I32[arshift((v_A + 12), 2)] = tobit(v_t)
I32[arshift((v_n + 8), 2)] = tobit(v_t)
I32[arshift((v_t + 24), 2)] = tobit(0)
I32[arshift((v_t + 12), 2)] = tobit(v_n)
I32[arshift((v_t + 8), 2)] = tobit(v_A)
end
end
::L132::
end
do
v_A = tobit((I32[5469] - 1))
local t142 = v_A
if t142 == 0 then
t142 = (-1)
end
I32[5469] = tobit(t142)
end
end
end
end
end
end
end
end
::L124::
end
end

F.fD = function(v_A, v_r, v_n)
local v_e, v_o, v_a, v_u, v_c, v_s, v_l, v_b, v_v, v_g = 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
v_e = 0
v_o = 0
v_a = 0
v_u = 0
v_c = 0
v_s = 0
v_l = 0
v_b = 0
v_v = 0
v_g = 0
do
v_e = bor(bor(bor(U8[tobit((v_r + 12))], lshift(U8[tobit((v_r + 13))], 8)), lshift(U8[tobit((v_r + 14))], 16)), lshift(U8[tobit((v_r + 15))], 24))
v_a = bxor(I32[arshift((v_A + 16), 2)], bor(bor(bor(lshift(v_e, 24), band(lshift(v_e, 8), 16711680)), band((rshift(v_e, 8) % 4294967296), 65280)), (rshift(v_e, 24) % 4294967296)))
v_e = bor(bor(bor(U8[tobit((v_r + 8))], lshift(U8[tobit((v_r + 9))], 8)), lshift(U8[tobit((v_r + 10))], 16)), lshift(U8[tobit((v_r + 11))], 24))
v_l = bxor(I32[arshift((v_A + 12), 2)], bor(bor(bor(lshift(v_e, 24), band(lshift(v_e, 8), 16711680)), band((rshift(v_e, 8) % 4294967296), 65280)), (rshift(v_e, 24) % 4294967296)))
v_e = bor(bor(bor(U8[tobit((v_r + 4))], lshift(U8[tobit((v_r + 5))], 8)), lshift(U8[tobit((v_r + 6))], 16)), lshift(U8[tobit((v_r + 7))], 24))
v_u = bxor(I32[arshift((v_A + 8), 2)], bor(bor(bor(lshift(v_e, 24), band(lshift(v_e, 8), 16711680)), band((rshift(v_e, 8) % 4294967296), 65280)), (rshift(v_e, 24) % 4294967296)))
v_r = bor(bor(bor(U8[bor(0, v_r)], lshift(U8[tobit((v_r + 1))], 8)), lshift(U8[tobit((v_r + 2))], 16)), lshift(U8[tobit((v_r + 3))], 24))
v_e = bxor(I32[arshift((v_A + 4), 2)], bor(bor(bor(lshift(v_r, 24), band(lshift(v_r, 8), 16711680)), band((rshift(v_r, 8) % 4294967296), 65280)), (rshift(v_r, 24) % 4294967296)))
v_r = tobit((v_A + 20))
v_v = I32[arshift(v_A, 2)]
if (v_v ~= 0) then
do
do
while true do
do
do
do
v_A = bxor(I32[arshift((v_r + 4), 2)], v_u)
v_o = U8[tobit((8576 + tobit((rshift(v_A, 24) % 4294967296))))]
v_g = v_a
v_a = bor(bor(bor(U8[tobit((8320 + band(255, v_A)))], lshift(U8[tobit((8832 + band((rshift(v_A, 16) % 4294967296), 255)))], 16)), lshift(v_o, 24)), lshift(U8[tobit((9088 + band((rshift(v_A, 8) % 4294967296), 255)))], 8))
v_A = bxor(I32[arshift(v_r, 2)], v_e)
v_A = bxor(bor(v_o, lshift(v_a, 8)), bor(bor(bor(lshift(U8[tobit((8576 + band((rshift(v_A, 16) % 4294967296), 255)))], 16), lshift(U8[tobit((8320 + tobit((rshift(v_A, 24) % 4294967296))))], 24)), lshift(U8[tobit((8832 + band((rshift(v_A, 8) % 4294967296), 255)))], 8)), U8[tobit((9088 + band(255, v_A)))]))
v_s = bxor(F.fSA(v_A, 16), v_a)
local t143 = v_g
v_b = bxor(F.fSA(v_s, 24), v_A)
v_a = bxor(t143, v_b)
v_A = bxor(v_a, I32[arshift((v_r + 12), 2)])
v_o = U8[tobit((8576 + tobit((rshift(v_A, 24) % 4294967296))))]
v_c = bor(bor(bor(U8[tobit((8320 + band(255, v_A)))], lshift(U8[tobit((8832 + band((rshift(v_A, 16) % 4294967296), 255)))], 16)), lshift(v_o, 24)), lshift(U8[tobit((9088 + band((rshift(v_A, 8) % 4294967296), 255)))], 8))
v_l = bxor(bxor(F.fSA(v_b, 24), v_l), v_s)
v_A = bxor(v_l, I32[arshift((v_r + 8), 2)])
v_A = bxor(bor(v_o, lshift(v_c, 8)), bor(bor(bor(lshift(U8[tobit((8576 + band((rshift(v_A, 16) % 4294967296), 255)))], 16), lshift(U8[tobit((8320 + tobit((rshift(v_A, 24) % 4294967296))))], 24)), lshift(U8[tobit((8832 + band((rshift(v_A, 8) % 4294967296), 255)))], 8)), U8[tobit((9088 + band(255, v_A)))]))
v_s = bxor(F.fSA(v_A, 16), v_c)
local t144 = v_u
v_b = bxor(F.fSA(v_s, 24), v_A)
v_u = bxor(t144, v_b)
v_A = bxor(v_u, I32[arshift((v_r + 20), 2)])
v_o = U8[tobit((8576 + tobit((rshift(v_A, 24) % 4294967296))))]
v_c = bor(bor(bor(U8[tobit((8320 + band(255, v_A)))], lshift(U8[tobit((8832 + band((rshift(v_A, 16) % 4294967296), 255)))], 16)), lshift(v_o, 24)), lshift(U8[tobit((9088 + band((rshift(v_A, 8) % 4294967296), 255)))], 8))
v_e = bxor(bxor(F.fSA(v_b, 24), v_e), v_s)
v_A = bxor(v_e, I32[arshift((v_r + 16), 2)])
v_A = bxor(bor(v_o, lshift(v_c, 8)), bor(bor(bor(lshift(U8[tobit((8576 + band((rshift(v_A, 16) % 4294967296), 255)))], 16), lshift(U8[tobit((8320 + tobit((rshift(v_A, 24) % 4294967296))))], 24)), lshift(U8[tobit((8832 + band((rshift(v_A, 8) % 4294967296), 255)))], 8)), U8[tobit((9088 + band(255, v_A)))]))
v_s = bxor(F.fSA(v_A, 16), v_c)
local t145 = v_a
v_b = bxor(F.fSA(v_s, 24), v_A)
v_a = bxor(t145, v_b)
v_A = bxor(v_a, I32[arshift((v_r + 28), 2)])
v_o = U8[tobit((8576 + tobit((rshift(v_A, 24) % 4294967296))))]
v_c = bor(bor(bor(U8[tobit((8320 + band(255, v_A)))], lshift(U8[tobit((8832 + band((rshift(v_A, 16) % 4294967296), 255)))], 16)), lshift(v_o, 24)), lshift(U8[tobit((9088 + band((rshift(v_A, 8) % 4294967296), 255)))], 8))
v_l = bxor(bxor(F.fSA(v_b, 24), v_l), v_s)
v_A = bxor(v_l, I32[arshift((v_r + 24), 2)])
v_A = bxor(bor(v_o, lshift(v_c, 8)), bor(bor(bor(lshift(U8[tobit((8576 + band((rshift(v_A, 16) % 4294967296), 255)))], 16), lshift(U8[tobit((8320 + tobit((rshift(v_A, 24) % 4294967296))))], 24)), lshift(U8[tobit((8832 + band((rshift(v_A, 8) % 4294967296), 255)))], 8)), U8[tobit((9088 + band(255, v_A)))]))
v_s = bxor(F.fSA(v_A, 16), v_c)
local t146 = v_u
v_b = bxor(F.fSA(v_s, 24), v_A)
v_u = bxor(t146, v_b)
v_A = bxor(v_u, I32[arshift((v_r + 36), 2)])
v_o = U8[tobit((8576 + tobit((rshift(v_A, 24) % 4294967296))))]
v_c = bor(bor(bor(U8[tobit((8320 + band(255, v_A)))], lshift(U8[tobit((8832 + band((rshift(v_A, 16) % 4294967296), 255)))], 16)), lshift(v_o, 24)), lshift(U8[tobit((9088 + band((rshift(v_A, 8) % 4294967296), 255)))], 8))
v_e = bxor(bxor(F.fSA(v_b, 24), v_e), v_s)
v_A = bxor(v_e, I32[arshift((v_r + 32), 2)])
v_A = bxor(bor(v_o, lshift(v_c, 8)), bor(bor(bor(lshift(U8[tobit((8576 + band((rshift(v_A, 16) % 4294967296), 255)))], 16), lshift(U8[tobit((8320 + tobit((rshift(v_A, 24) % 4294967296))))], 24)), lshift(U8[tobit((8832 + band((rshift(v_A, 8) % 4294967296), 255)))], 8)), U8[tobit((9088 + band(255, v_A)))]))
v_c = bxor(F.fSA(v_A, 16), v_c)
local t147 = v_a
v_s = bxor(F.fSA(v_c, 24), v_A)
v_a = bxor(t147, v_s)
v_A = bxor(v_a, I32[arshift((v_r + 44), 2)])
v_o = U8[tobit((8576 + tobit((rshift(v_A, 24) % 4294967296))))]
v_g = v_u
v_u = bor(bor(bor(U8[tobit((8320 + band(255, v_A)))], lshift(U8[tobit((8832 + band((rshift(v_A, 16) % 4294967296), 255)))], 16)), lshift(v_o, 24)), lshift(U8[tobit((9088 + band((rshift(v_A, 8) % 4294967296), 255)))], 8))
v_l = bxor(bxor(F.fSA(v_s, 24), v_c), v_l)
v_A = bxor(v_l, I32[arshift((v_r + 40), 2)])
v_A = bxor(bor(v_o, lshift(v_u, 8)), bor(bor(bor(lshift(U8[tobit((8576 + band((rshift(v_A, 16) % 4294967296), 255)))], 16), lshift(U8[tobit((8320 + tobit((rshift(v_A, 24) % 4294967296))))], 24)), lshift(U8[tobit((8832 + band((rshift(v_A, 8) % 4294967296), 255)))], 8)), U8[tobit((9088 + band(255, v_A)))]))
v_o = bxor(F.fSA(v_A, 16), v_u)
local t148 = v_g
v_A = bxor(F.fSA(v_o, 24), v_A)
v_u = bxor(t148, v_A)
v_e = bxor(bxor(F.fSA(v_A, 24), v_e), v_o)
v_v = tobit((v_v - 1))
if (not (v_v ~= 0)) then
v_r = tobit((v_r + 48))
goto B135
end
end
v_l = bxor(bor(I32[arshift((v_r + 60), 2)], v_a), v_l)
v_a = bxor(F.fSA(band(v_l, I32[arshift((v_r + 56), 2)]), 1), v_a)
v_u = bxor(F.fSA(band(I32[arshift((v_r + 48), 2)], v_e), 1), v_u)
v_e = bxor(bor(v_u, I32[arshift((v_r + 52), 2)]), v_e)
v_r = tobit((v_r - (-64)))
end
end
::C135::
end
end
::B135::
end
end
end
v_v = I32[arshift(v_r, 2)]
v_o = I32[arshift((v_r + 4), 2)]
v_c = I32[arshift((v_r + 8), 2)]
v_A = bxor(I32[arshift((v_r + 12), 2)], v_u)
I8[tobit((v_n + 15))] = tobit(v_A)
v_r = bxor(v_e, v_c)
I8[tobit((v_n + 11))] = tobit(v_r)
v_e = bxor(v_o, v_a)
I8[tobit((v_n + 7))] = tobit(v_e)
v_a = bxor(v_l, v_v)
I8[tobit((v_n + 3))] = tobit(v_a)
I8[tobit((v_n + 14))] = tobit((rshift(v_A, 8) % 4294967296))
I8[tobit((v_n + 13))] = tobit((rshift(v_A, 16) % 4294967296))
I8[tobit((v_n + 12))] = tobit((rshift(v_A, 24) % 4294967296))
I8[tobit((v_n + 10))] = tobit((rshift(v_r, 8) % 4294967296))
I8[tobit((v_n + 9))] = tobit((rshift(v_r, 16) % 4294967296))
I8[tobit((v_n + 8))] = tobit((rshift(v_r, 24) % 4294967296))
I8[tobit((v_n + 6))] = tobit((rshift(v_e, 8) % 4294967296))
I8[tobit((v_n + 5))] = tobit((rshift(v_e, 16) % 4294967296))
I8[tobit((v_n + 4))] = tobit((rshift(v_e, 24) % 4294967296))
I8[tobit((v_n + 2))] = tobit((rshift(v_a, 8) % 4294967296))
I8[tobit((v_n + 1))] = tobit((rshift(v_a, 16) % 4294967296))
I8[bor(0, v_n)] = tobit((rshift(v_a, 24) % 4294967296))
do return 0 end
end

F.fG = function(v_A, v_r, v_n)
local v_e, v_o, v_a, v_u, v_c, v_s = 0, 0, 0, 0, 0, 0
v_e = 0
v_o = 0
v_a = 0
v_u = 0
v_c = 0
v_s = 0
do
do
do
v_e = bor(bor(bor(U8[bor(0, v_r)], lshift(U8[tobit((v_r + 1))], 8)), lshift(U8[tobit((v_r + 2))], 16)), lshift(U8[tobit((v_r + 3))], 24))
v_e = bor(bor(bor(lshift(v_e, 24), band(lshift(v_e, 8), 16711680)), band((rshift(v_e, 8) % 4294967296), 65280)), (rshift(v_e, 24) % 4294967296))
local t150 = v_e
local t149 = (rshift(v_e, 4) % 4294967296)
v_r = bor(bor(bor(U8[tobit((v_r + 4))], lshift(U8[tobit((v_r + 5))], 8)), lshift(U8[tobit((v_r + 6))], 16)), lshift(U8[tobit((v_r + 7))], 24))
v_r = bor(bor(bor(lshift(v_r, 24), band(lshift(v_r, 8), 16711680)), band((rshift(v_r, 8) % 4294967296), 65280)), (rshift(v_r, 24) % 4294967296))
v_o = band(252645135, bxor(t149, v_r))
v_e = bxor(t150, lshift(v_o, 4))
v_o = bxor(v_o, v_r)
local t151 = v_o
v_r = bxor((rshift(v_e, 16) % 4294967296), band(65535, v_o))
v_o = bxor(t151, v_r)
local t153 = v_o
local t152 = (rshift(v_o, 2) % 4294967296)
v_r = bxor(v_e, lshift(v_r, 16))
v_e = band(858993459, bxor(t152, v_r))
v_o = bxor(t153, lshift(v_e, 2))
local t154 = (rshift(v_o, 8) % 4294967296)
v_r = bxor(v_r, v_e)
v_e = band(16711935, bxor(t154, v_r))
v_o = F.fSA(bxor(lshift(v_e, 8), v_o), 1)
local t156 = v_o
local t155 = (-1431655766)
v_r = bxor(v_r, v_e)
v_e = band(t155, bxor(v_r, v_o))
v_o = bxor(t156, v_e)
v_r = F.fSA(bxor(v_r, v_e), 1)
v_e = v_A
v_u = 1
end
while true do
v_s = v_o
v_c = bxor(I32[arshift((v_e + 4), 2)], F.fSA(v_o, 28))
v_a = v_r
v_r = bxor(I32[arshift(v_e, 2)], v_o)
v_r = bxor(bxor(bxor(bxor(bxor(bxor(bxor(bxor(I32[arshift((2912 + lshift(band(63, v_c), 2)), 2)], v_a), I32[arshift((1888 + lshift(band(63, v_r), 2)), 2)]), I32[arshift((2144 + band((rshift(v_r, 6) % 4294967296), 252)), 2)]), I32[arshift((2400 + band((rshift(v_r, 14) % 4294967296), 252)), 2)]), I32[arshift((2656 + band((rshift(v_r, 22) % 4294967296), 252)), 2)]), I32[arshift((3168 + band((rshift(v_c, 6) % 4294967296), 252)), 2)]), I32[arshift((3424 + band((rshift(v_c, 14) % 4294967296), 252)), 2)]), I32[arshift((3680 + band((rshift(v_c, 22) % 4294967296), 252)), 2)])
v_o = bxor(v_r, I32[arshift((v_e + 8), 2)])
v_a = bxor(bxor(bxor(bxor(v_s, I32[arshift((1888 + lshift(band(63, v_o), 2)), 2)]), I32[arshift((2144 + band((rshift(v_o, 6) % 4294967296), 252)), 2)]), I32[arshift((2400 + band((rshift(v_o, 14) % 4294967296), 252)), 2)]), I32[arshift((2656 + band((rshift(v_o, 22) % 4294967296), 252)), 2)])
v_o = bxor(I32[arshift((v_e + 12), 2)], F.fSA(v_r, 28))
v_o = bxor(bxor(bxor(bxor(v_a, I32[arshift((2912 + lshift(band(63, v_o), 2)), 2)]), I32[arshift((3168 + band((rshift(v_o, 6) % 4294967296), 252)), 2)]), I32[arshift((3424 + band((rshift(v_o, 14) % 4294967296), 252)), 2)]), I32[arshift((3680 + band((rshift(v_o, 22) % 4294967296), 252)), 2)])
if not (8 ~= bor(0, v_u)) then goto B136 end
do
v_e = tobit((v_e + 16))
v_u = tobit((v_u + 1))
end
::C136::
end
end
::B136::
end
do
v_e = tobit((v_A + 128))
v_u = 1
while true do
v_a = v_r
v_c = bxor(I32[arshift((v_e + 4), 2)], F.fSA(v_r, 28))
v_r = bxor(I32[arshift(v_e, 2)], v_r)
v_o = bxor(bxor(bxor(bxor(bxor(bxor(bxor(bxor(I32[arshift((2912 + lshift(band(63, v_c), 2)), 2)], I32[arshift((1888 + lshift(band(63, v_r), 2)), 2)]), v_o), I32[arshift((2144 + band((rshift(v_r, 6) % 4294967296), 252)), 2)]), I32[arshift((2400 + band((rshift(v_r, 14) % 4294967296), 252)), 2)]), I32[arshift((2656 + band((rshift(v_r, 22) % 4294967296), 252)), 2)]), I32[arshift((3168 + band((rshift(v_c, 6) % 4294967296), 252)), 2)]), I32[arshift((3424 + band((rshift(v_c, 14) % 4294967296), 252)), 2)]), I32[arshift((3680 + band((rshift(v_c, 22) % 4294967296), 252)), 2)])
v_r = bxor(v_o, I32[arshift((v_e + 8), 2)])
v_a = bxor(bxor(bxor(bxor(v_a, I32[arshift((1888 + lshift(band(63, v_r), 2)), 2)]), I32[arshift((2144 + band((rshift(v_r, 6) % 4294967296), 252)), 2)]), I32[arshift((2400 + band((rshift(v_r, 14) % 4294967296), 252)), 2)]), I32[arshift((2656 + band((rshift(v_r, 22) % 4294967296), 252)), 2)])
v_r = bxor(I32[arshift((v_e + 12), 2)], F.fSA(v_o, 28))
v_r = bxor(bxor(bxor(bxor(v_a, I32[arshift((2912 + lshift(band(63, v_r), 2)), 2)]), I32[arshift((3168 + band((rshift(v_r, 6) % 4294967296), 252)), 2)]), I32[arshift((3424 + band((rshift(v_r, 14) % 4294967296), 252)), 2)]), I32[arshift((3680 + band((rshift(v_r, 22) % 4294967296), 252)), 2)])
if not (8 ~= bor(0, v_u)) then goto B137 end
do
v_e = tobit((v_e + 16))
v_u = tobit((v_u + 1))
end
::C137::
end
end
::B137::
do
v_e = tobit((v_A + 256))
v_u = 1
while true do
v_A = bxor(I32[arshift((v_e + 4), 2)], F.fSA(v_o, 28))
v_a = v_r
v_r = bxor(I32[arshift(v_e, 2)], v_o)
v_r = bxor(bxor(bxor(bxor(bxor(bxor(bxor(bxor(I32[arshift((2912 + lshift(band(63, v_A), 2)), 2)], v_a), I32[arshift((1888 + lshift(band(63, v_r), 2)), 2)]), I32[arshift((2144 + band((rshift(v_r, 6) % 4294967296), 252)), 2)]), I32[arshift((2400 + band((rshift(v_r, 14) % 4294967296), 252)), 2)]), I32[arshift((2656 + band((rshift(v_r, 22) % 4294967296), 252)), 2)]), I32[arshift((3168 + band((rshift(v_A, 6) % 4294967296), 252)), 2)]), I32[arshift((3424 + band((rshift(v_A, 14) % 4294967296), 252)), 2)]), I32[arshift((3680 + band((rshift(v_A, 22) % 4294967296), 252)), 2)])
v_A = bxor(v_r, I32[arshift((v_e + 8), 2)])
v_a = bxor(bxor(bxor(bxor(I32[arshift((1888 + lshift(band(63, v_A), 2)), 2)], v_o), I32[arshift((2144 + band((rshift(v_A, 6) % 4294967296), 252)), 2)]), I32[arshift((2400 + band((rshift(v_A, 14) % 4294967296), 252)), 2)]), I32[arshift((2656 + band((rshift(v_A, 22) % 4294967296), 252)), 2)])
v_A = bxor(I32[arshift((v_e + 12), 2)], F.fSA(v_r, 28))
v_o = bxor(bxor(bxor(bxor(v_a, I32[arshift((2912 + lshift(band(63, v_A), 2)), 2)]), I32[arshift((3168 + band((rshift(v_A, 6) % 4294967296), 252)), 2)]), I32[arshift((3424 + band((rshift(v_A, 14) % 4294967296), 252)), 2)]), I32[arshift((3680 + band((rshift(v_A, 22) % 4294967296), 252)), 2)])
if not (8 ~= bor(0, v_u)) then goto B138 end
do
v_e = tobit((v_e + 16))
v_u = tobit((v_u + 1))
end
::C138::
end
end
::B138::
do
v_s = lshift(v_r, 31)
local t159 = v_s
v_a = v_r
local t158 = v_a
local t157 = (-1431655766)
v_A = F.fSA(v_o, 31)
v_r = band(t157, bxor(v_A, v_r))
v_e = bor(t159, (rshift(bxor(t158, v_r), 1) % 4294967296))
local t161 = v_e
local t160 = (rshift(v_e, 8) % 4294967296)
v_A = bxor(v_A, v_r)
v_r = band(16711935, bxor(t160, v_A))
v_e = bxor(t161, lshift(v_r, 8))
local t163 = v_e
local t162 = (rshift(v_e, 2) % 4294967296)
v_A = bxor(v_A, v_r)
v_r = band(858993459, bxor(t162, v_A))
v_e = bxor(t163, lshift(v_r, 2))
local t164 = band(65535, v_e)
v_A = bxor(v_A, v_r)
v_r = bxor(t164, (rshift(v_A, 16) % 4294967296))
v_o = bxor(lshift(v_r, 16), v_A)
v_A = bxor(v_r, v_e)
local t165 = v_A
v_r = band(252645135, bxor((rshift(v_o, 4) % 4294967296), v_A))
v_A = bxor(t165, v_r)
I8[tobit((v_n + 7))] = tobit(v_A)
I8[tobit((v_n + 6))] = tobit((rshift(v_A, 8) % 4294967296))
I8[tobit((v_n + 5))] = tobit((rshift(v_A, 16) % 4294967296))
I8[tobit((v_n + 4))] = tobit((rshift(v_A, 24) % 4294967296))
v_A = bxor(v_o, lshift(v_r, 4))
I8[tobit((v_n + 3))] = tobit(v_A)
I8[tobit((v_n + 2))] = tobit((rshift(v_A, 8) % 4294967296))
I8[tobit((v_n + 1))] = tobit((rshift(v_A, 16) % 4294967296))
I8[bor(0, v_n)] = tobit((rshift(v_A, 24) % 4294967296))
do return 0 end
end
end

F.fU = function(v_A, v_r, v_n, v_t)
local v_e, v_o, v_a, v_u, v_c, v_s, v_l, v_b, v_v, v_g, v_p, v_h, v_d, v_k, v_y, v_w, v_C, v_I, v_m, v_Q, v_O, v_S, v_j, v_x, v_P, v_M, v_T, v_R, v_D, v_G = 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
v_o = 0
v_a = 0
v_u = 0
v_c = 0
v_s = 0
v_l = 0
v_b = 0
v_v = 0
v_g = 0
v_p = 0
v_h = 0
v_d = 0
v_k = 0
v_y = 0
v_w = 0
v_C = 0
v_I = 0
v_m = 0
v_Q = 0
v_O = 0
v_S = 0
v_j = 0
v_x = 0
v_P = 0
v_M = 0
v_T = 0
v_R = 0
v_D = 0
v_G = 0
do
v_e = tobit((B - 32))
B = v_e
v_g = (-20)
v_r = F.fkA(v_r, v_t)
if not (bor(((not (v_r ~= 0)) and 1 or 0), ((16 ~= I32[arshift((v_r + 24), 2)]) and 1 or 0)) ~= 0) then
F.fX(v_A)
v_g = F.faA(v_A, v_r)
local t166 = (v_g ~= 0)
if not t166 then
v_g = F.fyA(v_A, v_n, v_t)
t166 = (v_g ~= 0)
end
if not t166 then
v_r = v_e
I32[arshift((v_r + 16), 2)] = tobit(0)
I32[arshift((v_r + 20), 2)] = tobit(0)
I32[arshift((v_r + 24), 2)] = tobit(0)
I32[arshift((v_r + 28), 2)] = tobit(0)
I32[arshift((v_r + 12), 2)] = tobit(0)
v_g = F.fK(v_A, tobit((v_r + 16)), tobit((v_r + 16)), tobit((v_r + 12)))
if not (v_g ~= 0) then
v_n = v_e
v_I = U8[tobit((v_n + 31))]
v_m = U8[tobit((v_n + 30))]
v_Q = U8[tobit((v_n + 27))]
v_P = U8[tobit((v_n + 26))]
v_O = U8[tobit((v_n + 25))]
v_M = U8[tobit((v_n + 24))]
v_k = U8[tobit((v_n + 29))]
v_a = U8[tobit((v_n + 28))]
v_t = U8[tobit((v_n + 23))]
v_c = U8[tobit((v_n + 22))]
v_u = U8[tobit((v_n + 19))]
v_s = U8[tobit((v_n + 18))]
v_v = U8[tobit((v_n + 17))]
v_y = U8[tobit((v_n + 16))]
v_r = U8[tobit((v_n + 21))]
v_o = U8[tobit((v_n + 20))]
I32[arshift((v_A + 192), 2)] = tobit(0)
I32[arshift((v_A + 196), 2)] = tobit(0)
I32[arshift((v_A + 64), 2)] = tobit(0)
I32[arshift((v_A + 68), 2)] = tobit(0)
v_n = v_r
local t167 = (rshift(v_o, 8) % 4294967296)
v_r = tobit((rshift(v_r, 16) % 4294967296))
v_w = bor(t167, v_r)
local t168 = lshift(v_c, 8)
v_S = bor(lshift(v_n, 16), lshift(v_o, 24))
v_l = bor(bor(t168, v_S), v_t)
local t169 = lshift(v_s, 8)
v_v = bor(lshift(v_v, 16), lshift(v_y, 24))
v_r = bor(bor(t169, v_v), v_u)
v_r = bor(bor(v_r, v_w), (rshift(v_c, 24) % 4294967296))
v_c = v_r
I32[arshift((v_A + 256), 2)] = tobit(v_l)
I32[arshift((v_A + 260), 2)] = tobit(v_r)
v_r = tobit((rshift(v_a, 8) % 4294967296))
local t170 = v_r
v_n = tobit((rshift(v_k, 16) % 4294967296))
v_u = bor(t170, v_n)
local t171 = lshift(v_P, 8)
v_s = bor(lshift(v_O, 16), lshift(v_M, 24))
v_r = bor(bor(t171, v_s), v_Q)
v_r = bor(bor(v_r, v_u), (rshift(v_m, 24) % 4294967296))
v_u = v_r
local t172 = lshift(v_m, 8)
v_a = bor(lshift(v_k, 16), lshift(v_a, 24))
v_o = v_a
v_b = bor(bor(t172, v_o), v_I)
I32[arshift((v_A + 128), 2)] = tobit(v_b)
I32[arshift((v_A + 132), 2)] = tobit(v_r)
v_n = v_c
v_r = tobit((rshift(v_n, 1) % 4294967296))
v_a = bor(lshift(band(1, v_n), 31), (rshift(v_l, 1) % 4294967296))
v_h = bxor(F.fhA(band(1, v_I), 0, 0, (-520093696)), v_a)
v_r = bxor(v_r, Iv)
v_s = v_r
I32[arshift((v_A + 224), 2)] = tobit(v_h)
I32[arshift((v_A + 228), 2)] = tobit(v_r)
v_o = v_u
v_r = tobit((rshift(v_o, 1) % 4294967296))
v_p = bor(lshift(band(1, v_o), 31), (rshift(v_b, 1) % 4294967296))
local t173 = v_r
v_t = lshift(v_t, 31)
v_r = bor(t173, v_t)
v_v = v_r
I32[arshift((v_A + 96), 2)] = tobit(v_p)
I32[arshift((v_A + 100), 2)] = tobit(v_r)
v_t = v_r
v_r = tobit((rshift(v_r, 1) % 4294967296))
v_d = bor(lshift(band(1, v_t), 31), (rshift(v_p, 1) % 4294967296))
local t174 = v_r
v_n = lshift(v_a, 31)
v_r = bor(t174, v_n)
v_y = v_r
I32[arshift((v_A + 80), 2)] = tobit(v_d)
I32[arshift((v_A + 84), 2)] = tobit(v_r)
v_n = v_s
v_r = tobit((rshift(v_n, 1) % 4294967296))
v_a = bor(lshift(band(1, v_n), 31), (rshift(v_h, 1) % 4294967296))
v_C = bxor(F.fhA(band(1, v_p), 0, 0, (-520093696)), v_a)
v_n = bxor(Iv, v_r)
v_j = v_n
I32[arshift((v_A + 208), 2)] = tobit(v_C)
I32[arshift((v_A + 212), 2)] = tobit(v_n)
v_n = bxor(v_t, v_y)
v_I = v_n
v_D = bxor(v_p, v_d)
I32[arshift((v_A + 112), 2)] = tobit(v_D)
I32[arshift((v_A + 116), 2)] = tobit(v_n)
v_t = v_y
v_r = tobit((rshift(v_t, 1) % 4294967296))
v_x = bor(lshift(band(1, v_t), 31), (rshift(v_d, 1) % 4294967296))
local t175 = v_r
v_n = lshift(v_a, 31)
v_r = bor(t175, v_n)
v_T = v_r
I32[arshift((v_A + 72), 2)] = tobit(v_x)
I32[arshift((v_A + 76), 2)] = tobit(v_r)
v_r = bxor(v_s, v_j)
v_m = v_r
v_Q = bxor(v_h, v_C)
I32[arshift((v_A + 240), 2)] = tobit(v_Q)
I32[arshift((v_A + 244), 2)] = tobit(v_r)
v_n = v_j
v_r = tobit((rshift(v_n, 1) % 4294967296))
v_o = bxor(F.fhA(band(1, v_d), 0, 0, (-520093696)), bor(lshift(band(1, v_n), 31), (rshift(v_C, 1) % 4294967296)))
v_r = bxor(v_r, Iv)
v_n = v_r
I32[arshift((v_A + 200), 2)] = tobit(v_o)
I32[arshift((v_A + 204), 2)] = tobit(v_r)
v_r = bxor(v_t, v_T)
v_G = v_r
v_R = bxor(v_d, v_x)
I32[arshift((v_A + 88), 2)] = tobit(v_R)
I32[arshift((v_A + 92), 2)] = tobit(v_r)
v_r = bxor(v_v, v_T)
v_P = v_r
v_O = bxor(v_p, v_x)
I32[arshift((v_A + 104), 2)] = tobit(v_O)
I32[arshift((v_A + 108), 2)] = tobit(v_r)
v_r = bxor(v_n, v_j)
v_S = v_r
v_w = bxor(v_o, v_C)
I32[arshift((v_A + 216), 2)] = tobit(v_w)
I32[arshift((v_A + 220), 2)] = tobit(v_r)
v_r = bxor(v_n, v_s)
v_M = v_r
v_k = bxor(v_o, v_h)
I32[arshift((v_A + 232), 2)] = tobit(v_k)
I32[arshift((v_A + 236), 2)] = tobit(v_r)
I32[arshift((v_A + 264), 2)] = tobit(bxor(v_o, v_l))
I32[arshift((v_A + 268), 2)] = tobit(bxor(v_n, v_c))
v_r = bxor(v_v, v_G)
v_a = v_r
v_o = bxor(v_p, v_R)
I32[arshift((v_A + 120), 2)] = tobit(v_o)
I32[arshift((v_A + 124), 2)] = tobit(v_r)
v_t = bxor(v_s, v_S)
v_n = v_t
v_r = bxor(v_h, v_w)
I32[arshift((v_A + 248), 2)] = tobit(v_r)
I32[arshift((v_A + 252), 2)] = tobit(v_n)
I32[arshift((v_A + 272), 2)] = tobit(bxor(v_l, v_C))
I32[arshift((v_A + 276), 2)] = tobit(bxor(v_c, v_j))
I32[arshift((v_A + 136), 2)] = tobit(bxor(v_b, v_x))
I32[arshift((v_A + 140), 2)] = tobit(bxor(v_u, v_T))
I32[arshift((v_A + 144), 2)] = tobit(bxor(v_b, v_d))
I32[arshift((v_A + 148), 2)] = tobit(bxor(v_u, v_y))
I32[arshift((v_A + 280), 2)] = tobit(bxor(v_l, v_w))
I32[arshift((v_A + 284), 2)] = tobit(bxor(v_c, v_S))
I32[arshift((v_A + 152), 2)] = tobit(bxor(v_b, v_R))
I32[arshift((v_A + 156), 2)] = tobit(bxor(v_u, v_G))
I32[arshift((v_A + 288), 2)] = tobit(bxor(v_l, v_h))
I32[arshift((v_A + 292), 2)] = tobit(bxor(v_c, v_s))
I32[arshift((v_A + 160), 2)] = tobit(bxor(v_b, v_p))
I32[arshift((v_A + 164), 2)] = tobit(bxor(v_u, v_v))
I32[arshift((v_A + 296), 2)] = tobit(bxor(v_l, v_k))
I32[arshift((v_A + 300), 2)] = tobit(bxor(v_c, v_M))
I32[arshift((v_A + 168), 2)] = tobit(bxor(v_b, v_O))
I32[arshift((v_A + 172), 2)] = tobit(bxor(v_u, v_P))
I32[arshift((v_A + 304), 2)] = tobit(bxor(v_l, v_Q))
I32[arshift((v_A + 308), 2)] = tobit(bxor(v_c, v_m))
I32[arshift((v_A + 176), 2)] = tobit(bxor(v_b, v_D))
I32[arshift((v_A + 180), 2)] = tobit(bxor(v_u, v_I))
I32[arshift((v_A + 312), 2)] = tobit(bxor(v_r, v_l))
I32[arshift((v_A + 316), 2)] = tobit(bxor(v_n, v_c))
I32[arshift((v_A + 184), 2)] = tobit(bxor(v_o, v_b))
I32[arshift((v_A + 188), 2)] = tobit(bxor(v_u, v_a))
end
end
end
B = tobit((v_e + 32))
do return v_g end
end
end

F.fF = function(v_A, v_r, v_n, v_e)
local v_o, v_a, v_u, v_c, v_s, v_l, v_b, v_v, v_g, v_p, v_h, v_d, v_k, v_y, v_w, v_C, v_E, v_I, v_m, v_Q, v_O = 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
v_a = 0
v_u = 0
v_c = 0
v_s = 0
v_l = 0
v_b = 0
v_v = 0
v_g = 0
v_p = 0
v_h = 0
v_d = 0
v_k = 0
v_y = 0
v_w = 0
v_C = 0
v_E = 0
v_I = 0
v_m = 0
v_Q = 0
v_O = 0
v_o = tobit((B - 32))
B = v_o
I32[arshift((v_o + 12), 2)] = tobit(0)
do
do
do
local t176 = (((tobit(v_n) % 4294967296) < (tobit(v_e) % 4294967296)) and 1 or 0)
if t176 ~= 0 then
v_a = (-20)
t176 = (((tobit((v_e - v_n)) % 4294967296) < (tobit(v_r) % 4294967296)) and 1 or 0)
end
local t177 = t176
if t177 == 0 then
v_a = (-20)
v_s = I32[arshift((v_A + 324), 2)]
v_u = v_s
v_l = I32[arshift((v_A + 320), 2)]
local t178 = v_l
v_c = v_r
v_v = tobit((t178 + v_c))
v_u = (((tobit(v_v) % 4294967296) < (tobit(v_c) % 4294967296)) and tobit((v_u + 1)) or v_u)
v_c = v_u
t177 = bor(bor(bor(band(((bor(0, v_s) == bor(0, v_u)) and 1 or 0), (((tobit(v_l) % 4294967296) > (tobit(v_v) % 4294967296)) and 1 or 0)), (((tobit(v_u) % 4294967296) < (tobit(v_s) % 4294967296)) and 1 or 0)), band(((15 == bor(0, v_u)) and 1 or 0), (((tobit(v_v) % 4294967296) > 4294967264) and 1 or 0))), (((tobit(v_u) % 4294967296) > 15) and 1 or 0))
end
if (not (t177 ~= 0)) then
do
do
I32[arshift((v_A + 320), 2)] = tobit(v_v)
I32[arshift((v_A + 324), 2)] = tobit(v_c)
if (v_r ~= 0) then
do
do
v_s = tobit((v_A + 368))
v_E = tobit((v_A + 352))
while true do
do
do
v_u = tobit((U8[tobit((v_A + 367))] + 1))
I8[tobit((v_A + 367))] = tobit(v_u)
if (bor(0, v_u) ~= band(255, v_u)) then
v_u = tobit((U8[tobit((v_A + 366))] + 1))
I8[tobit((v_A + 366))] = tobit(v_u)
if (bor(0, v_u) ~= band(255, v_u)) then
v_u = tobit((U8[tobit((v_A + 365))] + 1))
I8[tobit((v_A + 365))] = tobit(v_u)
if (bor(0, v_u) ~= band(255, v_u)) then
I8[tobit((v_A + 364))] = tobit((U8[tobit((v_A + 364))] + 1))
end
end
end
v_a = F.fK(v_A, v_E, tobit((v_o + 16)), tobit((v_o + 12)))
if (v_a ~= 0) then
goto L139
end
do
do
v_d = (((tobit(v_r) % 4294967296) < 16) and v_r or 16)
v_u = (((tobit(v_d) % 4294967296) > 1) and v_d or 1)
v_a = 0
while true do
do
if not (I32[arshift((v_A + 384), 2)] ~= 0) then
v_c = tobit((v_A + v_a))
I8[tobit((368 + v_c))] = tobit(bxor(U8[tobit((v_c + 368))], U8[tobit((v_n + v_a))]))
end
v_c = bxor(U8[tobit((v_n + v_a))], U8[tobit((tobit((v_o + 16)) + v_a))])
I8[tobit((v_e + v_a))] = tobit(v_c)
if (1 == I32[arshift((v_A + 384), 2)]) then
v_v = tobit((v_A + v_a))
I8[tobit((368 + v_v))] = tobit(bxor(v_c, U8[tobit((v_v + 368))]))
end
local t179 = bor(0, v_u)
v_a = tobit((v_a + 1))
if not (t179 ~= bor(0, v_a)) then goto B141 end
end
do
end
::C141::
end
end
::B141::
end
do
do
do
v_I = v_s
v_k = tobit((v_A - (-64)))
v_u = U8[tobit((v_s + 15))]
local t180 = v_k
v_p = band((rshift(v_u, 1) % 4294967296), 120)
v_c = tobit((t180 + v_p))
v_l = I32[arshift(v_c, 2)]
v_h = I32[arshift((v_c + 4), 2)]
v_y = tobit((v_A + 192))
local t181 = v_y
v_b = lshift(band(15, v_u), 3)
v_c = tobit((t181 + v_b))
v_u = I32[arshift((4 + v_c), 2)]
v_v = I32[arshift(v_c, 2)]
v_c = lshift(v_v, 28)
v_g = v_l
local t183 = v_g
v_a = tobit((v_b + v_k))
v_l = I32[arshift((4 + v_a), 2)]
local t182 = lshift(band(15, v_l), 28)
v_b = I32[arshift(v_a, 2)]
v_g = bxor(t183, bor(t182, (rshift(v_b, 4) % 4294967296)))
v_c = bxor(bor((rshift(v_l, 4) % 4294967296), v_c), v_h)
v_a = tobit((v_p + v_y))
v_l = I32[arshift(v_a, 2)]
v_p = I32[arshift((v_a + 4), 2)]
v_a = tobit((11680 + lshift(band(15, v_b), 3)))
v_b = bxor(bor(lshift(band(15, v_u), 28), (rshift(v_v, 4) % 4294967296)), v_l)
local t184 = (rshift(v_u, 4) % 4294967296)
v_a = lshift(I32[arshift(v_a, 2)], 16)
v_u = bxor(bxor(t184, v_a), v_p)
v_a = 14
end
while true do
do
v_v = v_a
v_a = U8[tobit((v_a + v_I))]
v_w = band((rshift(v_a, 1) % 4294967296), 120)
v_l = tobit((v_w + v_k))
v_m = I32[arshift(v_l, 2)]
v_Q = I32[arshift((v_l + 4), 2)]
v_C = lshift(band(15, v_a), 3)
v_a = tobit((v_C + v_y))
v_l = I32[arshift(v_a, 2)]
v_h = I32[arshift((v_a + 4), 2)]
v_a = tobit((11680 + lshift(band(15, v_g), 3)))
v_p = lshift(I32[arshift(v_a, 2)], 16)
v_a = tobit((rshift(v_u, 4) % 4294967296))
v_p = bxor(bxor(v_a, v_p), v_h)
v_l = bxor(v_l, bor(lshift(band(15, v_u), 28), (rshift(v_b, 4) % 4294967296)))
v_h = lshift(v_l, 28)
v_a = tobit((v_k + v_C))
v_C = I32[arshift(v_a, 2)]
v_O = I32[arshift((v_a + 4), 2)]
local t185 = (rshift(v_c, 4) % 4294967296)
v_a = lshift(v_b, 28)
v_b = bxor(bor(t185, v_a), v_O)
local t187 = lshift(band(15, v_b), 28)
local t186 = bor(lshift(band(15, v_c), 28), (rshift(v_g, 4) % 4294967296))
v_u = 0
v_u = bxor(bor(t186, v_u), v_C)
v_g = bxor(bor(t187, (rshift(v_u, 4) % 4294967296)), v_m)
v_c = bxor(bor((rshift(v_b, 4) % 4294967296), v_h), v_Q)
v_a = tobit((v_y + v_w))
v_h = I32[arshift(v_a, 2)]
v_w = I32[arshift((v_a + 4), 2)]
v_u = tobit((11680 + lshift(band(15, v_u), 3)))
v_a = lshift(I32[arshift(v_u, 2)], 16)
v_u = v_p
v_b = bxor(bor(lshift(band(15, v_u), 28), (rshift(v_l, 4) % 4294967296)), v_h)
v_u = bxor(bxor((rshift(v_u, 4) % 4294967296), v_a), v_w)
v_a = tobit((v_v - 1))
if not (v_v ~= 0) then goto B142 end
end
do
end
::C142::
end
end
::B142::
end
I8[tobit((v_s + 15))] = tobit(v_g)
I8[tobit((v_s + 7))] = tobit(v_b)
v_a = v_c
I8[tobit((v_s + 14))] = tobit(bor(lshift(band(255, v_a), 24), (rshift(v_g, 8) % 4294967296)))
I8[tobit((v_s + 13))] = tobit(bor(lshift(band(65535, v_a), 16), (rshift(v_g, 16) % 4294967296)))
I8[tobit((v_s + 12))] = tobit(bor(lshift(band(16777215, v_a), 8), (rshift(v_g, 24) % 4294967296)))
I8[tobit((v_s + 11))] = tobit(v_a)
I8[tobit((v_s + 10))] = tobit((rshift(v_a, 8) % 4294967296))
I8[tobit((v_s + 9))] = tobit((rshift(v_a, 16) % 4294967296))
I8[tobit((v_s + 8))] = tobit((rshift(v_a, 24) % 4294967296))
I8[tobit((v_s + 6))] = tobit(bor(lshift(band(255, v_u), 24), (rshift(v_b, 8) % 4294967296)))
I8[tobit((v_s + 5))] = tobit(bor(lshift(band(65535, v_u), 16), (rshift(v_b, 16) % 4294967296)))
I8[tobit((v_s + 4))] = tobit(bor(lshift(band(16777215, v_u), 8), (rshift(v_b, 24) % 4294967296)))
I8[tobit((v_s + 3))] = tobit(v_u)
I8[tobit((v_s + 2))] = tobit((rshift(v_u, 8) % 4294967296))
I8[tobit((v_s + 1))] = tobit((rshift(v_u, 16) % 4294967296))
I8[bor(0, v_s)] = tobit((rshift(v_u, 24) % 4294967296))
v_e = tobit((v_e + v_d))
v_n = tobit((v_n + v_d))
v_r = tobit((v_r - v_d))
if (not (v_r ~= 0)) then
goto B140
end
end
end
::C140::
end
end
::B140::
end
end
end
v_a = 0
end
end
end
end
::L139::
end
B = tobit((v_o + 32))
do return v_a end
end

F.fY = function()
local v_A, v_r, v_n, v_e, v_o, v_a = 0, 0, 0, 0, 0, 0
v_r = 0
v_n = 0
v_e = 0
v_o = 0
v_a = 0
v_A = tobit((B - 384))
B = v_A
F.fMA(tobit((v_A + 104)))
I8[tobit((v_A + 56))] = tobit(97)
I8[tobit((v_A + 57))] = tobit(122)
I8[tobit((v_A + 58))] = tobit(118)
I8[tobit((v_A + 59))] = tobit(102)
I8[tobit((v_A + 60))] = tobit(110)
I8[tobit((v_A + 61))] = tobit(114)
I8[tobit((v_A + 62))] = tobit(101)
I8[tobit((v_A + 63))] = tobit(109)
I8[tobit((v_A + 48))] = tobit(50)
I8[tobit((v_A + 49))] = tobit(111)
I8[tobit((v_A + 50))] = tobit(56)
I8[tobit((v_A + 51))] = tobit(106)
I8[tobit((v_A + 52))] = tobit(99)
I8[tobit((v_A + 53))] = tobit(112)
I8[tobit((v_A + 54))] = tobit(55)
I8[tobit((v_A + 55))] = tobit(117)
F.fH(tobit((v_A + 104)), tobit((v_A + 48)), 128)
v_r = bor(bor(bor(U8[13100], lshift(U8[13101], 8)), lshift(U8[13102], 16)), lshift(U8[13103], 24))
I32[arshift((v_A + 8), 2)] = tobit(bor(bor(bor(U8[13096], lshift(U8[13097], 8)), lshift(U8[13098], 16)), lshift(U8[13099], 24)))
I32[arshift((v_A + 12), 2)] = tobit(v_r)
v_r = bor(bor(bor(U8[13108], lshift(U8[13109], 8)), lshift(U8[13110], 16)), lshift(U8[13111], 24))
I32[arshift((v_A + 16), 2)] = tobit(bor(bor(bor(U8[13104], lshift(U8[13105], 8)), lshift(U8[13106], 16)), lshift(U8[13107], 24)))
I32[arshift((v_A + 20), 2)] = tobit(v_r)
v_r = bor(bor(bor(U8[13116], lshift(U8[13117], 8)), lshift(U8[13118], 16)), lshift(U8[13119], 24))
I32[arshift((v_A + 24), 2)] = tobit(bor(bor(bor(U8[13112], lshift(U8[13113], 8)), lshift(U8[13114], 16)), lshift(U8[13115], 24)))
I32[arshift((v_A + 28), 2)] = tobit(v_r)
I8[tobit((v_A + 40))] = tobit(57)
I8[tobit((v_A + 41))] = tobit(51)
I8[tobit((v_A + 42))] = tobit(111)
I8[tobit((v_A + 43))] = tobit(103)
I8[tobit((v_A + 44))] = tobit(114)
I8[tobit((v_A + 45))] = tobit(54)
I8[tobit((v_A + 46))] = tobit(117)
I8[tobit((v_A + 47))] = tobit(50)
I8[tobit((v_A + 32))] = tobit(98)
I8[tobit((v_A + 33))] = tobit(107)
I8[tobit((v_A + 34))] = tobit(105)
I8[tobit((v_A + 35))] = tobit(99)
I8[tobit((v_A + 36))] = tobit(110)
I8[tobit((v_A + 37))] = tobit(104)
I8[tobit((v_A + 38))] = tobit(116)
I8[tobit((v_A + 39))] = tobit(100)
v_r = bor(bor(bor(U8[13092], lshift(U8[13093], 8)), lshift(U8[13094], 16)), lshift(U8[13095], 24))
I32[arshift(v_A, 2)] = tobit(bor(bor(bor(U8[13088], lshift(U8[13089], 8)), lshift(U8[13090], 16)), lshift(U8[13091], 24)))
I32[arshift((v_A + 4), 2)] = tobit(v_r)
v_o = 32
F.fM(tobit((v_A + 104)), 0, 32, tobit((v_A + 32)), v_A, tobit((v_A - (-64))))
F.fvA(tobit((v_A + 104)))
do
do
do
v_n = U8[tobit((v_A + 95))]
local t188 = (((tobit(band((v_n - 1), 255)) % 4294967296) > 15) and 1 or 0)
if t188 == 0 then
v_r = 2
v_o = 31
t188 = (((tobit(v_n) % 4294967296) < 2) and 1 or 0)
end
if (not (t188 ~= 0)) then
do
v_o = 30
while true do
do
if (bor(((bor(0, v_n) ~= U8[tobit((tobit((v_A - (-64))) + v_o))]) and 1 or 0), (((tobit(v_n) % 4294967296) <= (tobit(band(255, v_r)) % 4294967296)) and 1 or 0)) ~= 0) then
goto L143
end
v_r = tobit((v_r + 1))
v_o = tobit((v_o - 1))
end
::C144::
end
end
::B144::
end
end
end
::L143::
end
v_r = F.fI(tobit((v_o + 1)))
F.fOA(tobit((v_r + v_o)), 0, (((-1) ~= bor(0, v_o)) and 1 or 0))
v_n = F.fQA(v_r, tobit((v_A - (-64))), v_o)
v_e = I32[7793]
v_r = tobit((v_e + 17))
v_a = F.fI(v_r)
v_o = I32[7792]
v_r = F.fOA(tobit((v_e + v_a)), 0, (((tobit(v_r) % 4294967296) > (tobit(v_e) % 4294967296)) and 17 or 0))
v_o = F.fQA(v_a, v_o, v_e)
v_e = bor(bor(bor(U8[tobit((v_n + 12))], lshift(U8[tobit((v_n + 13))], 8)), lshift(U8[tobit((v_n + 14))], 16)), lshift(U8[tobit((v_n + 15))], 24))
v_a = bor(bor(bor(U8[tobit((v_n + 8))], lshift(U8[tobit((v_n + 9))], 8)), lshift(U8[tobit((v_n + 10))], 16)), lshift(U8[tobit((v_n + 11))], 24))
I8[tobit((v_r + 8))] = tobit(v_a)
I8[tobit((v_r + 9))] = tobit((rshift(v_a, 8) % 4294967296))
I8[tobit((v_r + 10))] = tobit((rshift(v_a, 16) % 4294967296))
I8[tobit((v_r + 11))] = tobit((rshift(v_a, 24) % 4294967296))
I8[tobit((v_r + 12))] = tobit(v_e)
I8[tobit((v_r + 13))] = tobit((rshift(v_e, 8) % 4294967296))
I8[tobit((v_r + 14))] = tobit((rshift(v_e, 16) % 4294967296))
I8[tobit((v_r + 15))] = tobit((rshift(v_e, 24) % 4294967296))
v_e = bor(bor(bor(U8[tobit((v_n + 4))], lshift(U8[tobit((v_n + 5))], 8)), lshift(U8[tobit((v_n + 6))], 16)), lshift(U8[tobit((v_n + 7))], 24))
v_a = bor(bor(bor(U8[bor(0, v_n)], lshift(U8[tobit((v_n + 1))], 8)), lshift(U8[tobit((v_n + 2))], 16)), lshift(U8[tobit((v_n + 3))], 24))
I8[bor(0, v_r)] = tobit(v_a)
I8[tobit((v_r + 1))] = tobit((rshift(v_a, 8) % 4294967296))
I8[tobit((v_r + 2))] = tobit((rshift(v_a, 16) % 4294967296))
I8[tobit((v_r + 3))] = tobit((rshift(v_a, 24) % 4294967296))
I8[tobit((v_r + 4))] = tobit(v_e)
I8[tobit((v_r + 5))] = tobit((rshift(v_e, 8) % 4294967296))
I8[tobit((v_r + 6))] = tobit((rshift(v_e, 16) % 4294967296))
I8[tobit((v_r + 7))] = tobit((rshift(v_e, 24) % 4294967296))
F.fR(v_n)
B = tobit((v_A + 384))
do return v_o end
end

F.fJ = function(v_A, v_r)
local v_n, v_t, v_e, v_o, v_a, v_u, v_c, v_s, v_l, v_b, v_v, v_g, v_p, v_h = 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
v_n = 0
v_t = 0
v_e = 0
v_o = 0
v_a = 0
v_u = 0
v_c = 0
v_s = 0
v_l = 0
v_b = 0
v_v = 0
v_g = 0
v_p = 0
v_h = 0
do
do
do
v_n = bor(bor(bor(U8[tobit((v_r + 4))], lshift(U8[tobit((v_r + 5))], 8)), lshift(U8[tobit((v_r + 6))], 16)), lshift(U8[tobit((v_r + 7))], 24))
v_t = bor(bor(bor(lshift(v_n, 24), band(lshift(v_n, 8), 16711680)), band((rshift(v_n, 8) % 4294967296), 65280)), (rshift(v_n, 24) % 4294967296))
v_e = U8[bor(0, v_r)]
v_n = bor(bor(bor(U8[tobit((v_r + 3))], lshift(U8[tobit((v_r + 1))], 16)), lshift(v_e, 24)), lshift(U8[tobit((v_r + 2))], 8))
local t189 = (-269488145)
v_a = band(252645135, bxor((rshift(v_t, 4) % 4294967296), v_n))
v_r = bor(band(t189, bxor(lshift(v_a, 4), v_t)), band(269488144, v_n))
v_o = band(268435455, bor(bor(bor(bor(bor(bor(bor(lshift(I32[arshift((1824 + band((rshift(v_r, 7) % 4294967296), 60)), 2)], 2), lshift(I32[arshift((1824 + band(lshift(v_r, 1), 60)), 2)], 3)), lshift(I32[arshift((1824 + band((rshift(v_r, 15) % 4294967296), 60)), 2)], 1)), I32[arshift((1824 + band((rshift(v_r, 23) % 4294967296), 60)), 2)]), lshift(I32[arshift((1824 + band((rshift(v_r, 2) % 4294967296), 60)), 2)], 7)), lshift(I32[arshift((1824 + band((rshift(v_r, 10) % 4294967296), 60)), 2)], 6)), lshift(I32[arshift((1824 + band((rshift(v_r, 18) % 4294967296), 60)), 2)], 5)), lshift(I32[arshift((1824 + band((rshift(v_r, 26) % 4294967296), 60)), 2)], 4)))
v_r = bxor(v_n, v_a)
v_t = band(268435455, bor(bor(bor(bor(bor(bor(bor(lshift(I32[arshift((1760 + band((rshift(v_r, 6) % 4294967296), 60)), 2)], 2), lshift(I32[arshift((1760 + lshift(band(15, v_r), 2)), 2)], 3)), lshift(I32[arshift((1760 + band((rshift(v_r, 14) % 4294967296), 60)), 2)], 1)), I32[arshift((1760 + band((rshift(v_r, 22) % 4294967296), 60)), 2)]), lshift(I32[arshift((1760 + band((rshift(v_r, 3) % 4294967296), 60)), 2)], 7)), lshift(I32[arshift((1760 + band((rshift(v_r, 11) % 4294967296), 60)), 2)], 6)), lshift(I32[arshift((1760 + band((rshift(v_r, 19) % 4294967296), 60)), 2)], 5)), lshift(I32[arshift((1760 + band((rshift(v_e, 3) % 4294967296), 28)), 2)], 4)))
end
while true do
if (bor(((not (band(lshift(1, v_c), 33027) ~= 0)) and 1 or 0), (((tobit(v_c) % 4294967296) > 15) and 1 or 0)) ~= 0) then
v_a = tobit((rshift(v_t, 26) % 4294967296))
v_s = tobit((rshift(v_o, 26) % 4294967296))
v_r = lshift(v_o, 2)
v_u = band(268435452, v_r)
v_n = lshift(v_t, 2)
v_e = band(268435452, v_n)
else
v_a = tobit((rshift(v_t, 27) % 4294967296))
v_s = tobit((rshift(v_o, 27) % 4294967296))
v_r = lshift(v_o, 1)
v_u = band(268435454, v_r)
v_n = lshift(v_t, 1)
v_e = band(268435454, v_n)
end
v_t = bor(v_e, v_a)
v_l = lshift(v_t, 10)
v_o = bor(v_u, v_s)
v_b = tobit((rshift(v_o, 3) % 4294967296))
v_u = tobit((rshift(v_u, 14) % 4294967296))
I32[arshift(v_A, 2)] = tobit(bor(bor(bor(bor(bor(bor(bor(bor(bor(bor(bor(bor(bor(bor(bor(bor(bor(bor(bor(bor(bor(band((rshift(v_r, 24) % 4294967296), 1), band((rshift(v_r, 26) % 4294967296), 2)), band((rshift(v_r, 18) % 4294967296), 4)), band(8, v_b)), band((rshift(v_r, 10) % 4294967296), 16)), band((rshift(v_r, 5) % 4294967296), 32)), band(512, v_u)), band((rshift(v_r, 1) % 4294967296), 1024)), band(lshift(v_o, 6), 2048)), band((rshift(v_r, 4) % 4294967296), 4096)), band((rshift(v_r, 13) % 4294967296), 8192)), band(256, v_r)), band((rshift(v_n, 10) % 4294967296), 65536)), band(lshift(v_e, 2), 131072)), band(262144, v_l)), band((rshift(v_n, 1) % 4294967296), 1048576)), band(lshift(v_n, 9), 2097152)), band(lshift(v_n, 6), 16777216)), band(lshift(v_t, 18), 34078720)), band(lshift(v_n, 14), 134217728)), band(lshift(v_e, 4), 603979776)), band(lshift(v_a, 28), 268435456)))
v_a = band((rshift(v_r, 21) % 4294967296), 2)
v_v = band((rshift(v_r, 7) % 4294967296), 32)
v_g = band((rshift(v_r, 9) % 4294967296), 1024)
v_p = band((rshift(v_r, 2) % 4294967296), 8192)
v_h = band(512, v_r)
v_r = lshift(v_t, 15)
I32[arshift((v_A + 4), 2)] = tobit(bor(bor(bor(bor(bor(bor(bor(bor(bor(bor(bor(bor(bor(bor(bor(bor(bor(bor(bor(bor(bor(v_a, band(lshift(v_s, 2), 4)), band(17, v_b)), v_v), band(lshift(v_o, 7), 256)), v_g), band(2056, v_u)), band(lshift(v_o, 8), 4096)), v_p), v_h), band((rshift(v_n, 4) % 4294967296), 65536)), band((rshift(v_n, 6) % 4294967296), 262144)), band(lshift(v_e, 3), 524288)), band(lshift(v_n, 11), 1048576)), band(lshift(v_t, 16), 2097152)), band(lshift(v_e, 1), 16777216)), band((rshift(v_n, 2) % 4294967296), 33554432)), band(lshift(v_t, 22), 67108864)), band(134217728, v_l)), band(536870912, v_r)), band(lshift(v_n, 17), 268435456)), band(131072, v_r)))
v_A = tobit((v_A + 8))
v_c = tobit((v_c + 1))
if not (16 ~= bor(0, v_c)) then goto B145 end
do
end
::C145::
end
end
::B145::
end
end

F.fL = function(v_A)

if (v_A ~= 0) then
I8[bor(0, v_A)] = tobit(0)
I8[tobit((v_A + 1))] = tobit(0)
I8[tobit((v_A + 2))] = tobit(0)
I8[tobit((v_A + 3))] = tobit(0)
I8[tobit((v_A + 4))] = tobit(0)
I8[tobit((v_A + 5))] = tobit(0)
I8[tobit((v_A + 6))] = tobit(0)
I8[tobit((v_A + 7))] = tobit(0)
I8[tobit((v_A + 8))] = tobit(0)
I8[tobit((v_A + 9))] = tobit(0)
I8[tobit((v_A + 10))] = tobit(0)
I8[tobit((v_A + 11))] = tobit(0)
I8[tobit((v_A + 12))] = tobit(0)
I8[tobit((v_A + 13))] = tobit(0)
I8[tobit((v_A + 14))] = tobit(0)
I8[tobit((v_A + 15))] = tobit(0)
I8[tobit((v_A + 16))] = tobit(0)
I8[tobit((v_A + 17))] = tobit(0)
I8[tobit((v_A + 18))] = tobit(0)
I8[tobit((v_A + 19))] = tobit(0)
I8[tobit((v_A + 20))] = tobit(0)
I8[tobit((v_A + 21))] = tobit(0)
I8[tobit((v_A + 22))] = tobit(0)
I8[tobit((v_A + 23))] = tobit(0)
I8[tobit((v_A + 24))] = tobit(0)
I8[tobit((v_A + 25))] = tobit(0)
I8[tobit((v_A + 26))] = tobit(0)
I8[tobit((v_A + 27))] = tobit(0)
I8[tobit((v_A + 28))] = tobit(0)
I8[tobit((v_A + 29))] = tobit(0)
I8[tobit((v_A + 30))] = tobit(0)
I8[tobit((v_A + 31))] = tobit(0)
I8[tobit((v_A + 32))] = tobit(0)
I8[tobit((v_A + 33))] = tobit(0)
I8[tobit((v_A + 34))] = tobit(0)
I8[tobit((v_A + 35))] = tobit(0)
I8[tobit((v_A + 36))] = tobit(0)
I8[tobit((v_A + 37))] = tobit(0)
I8[tobit((v_A + 38))] = tobit(0)
I8[tobit((v_A + 39))] = tobit(0)
I8[tobit((v_A + 40))] = tobit(0)
I8[tobit((v_A + 41))] = tobit(0)
I8[tobit((v_A + 42))] = tobit(0)
I8[tobit((v_A + 43))] = tobit(0)
I8[tobit((v_A + 44))] = tobit(0)
I8[tobit((v_A + 45))] = tobit(0)
I8[tobit((v_A + 46))] = tobit(0)
I8[tobit((v_A + 47))] = tobit(0)
I8[tobit((v_A + 48))] = tobit(0)
I8[tobit((v_A + 49))] = tobit(0)
I8[tobit((v_A + 50))] = tobit(0)
I8[tobit((v_A + 51))] = tobit(0)
I8[tobit((v_A + 52))] = tobit(0)
I8[tobit((v_A + 53))] = tobit(0)
I8[tobit((v_A + 54))] = tobit(0)
I8[tobit((v_A + 55))] = tobit(0)
I8[tobit((v_A + 56))] = tobit(0)
I8[tobit((v_A + 57))] = tobit(0)
I8[tobit((v_A + 58))] = tobit(0)
I8[tobit((v_A + 59))] = tobit(0)
I8[tobit((v_A + 60))] = tobit(0)
I8[tobit((v_A + 61))] = tobit(0)
I8[tobit((v_A + 62))] = tobit(0)
I8[tobit((v_A + 63))] = tobit(0)
I8[tobit((v_A + 64))] = tobit(0)
I8[tobit((v_A + 65))] = tobit(0)
I8[tobit((v_A + 66))] = tobit(0)
I8[tobit((v_A + 67))] = tobit(0)
I8[tobit((v_A + 68))] = tobit(0)
I8[tobit((v_A + 69))] = tobit(0)
I8[tobit((v_A + 70))] = tobit(0)
I8[tobit((v_A + 71))] = tobit(0)
I8[tobit((v_A + 72))] = tobit(0)
I8[tobit((v_A + 73))] = tobit(0)
I8[tobit((v_A + 74))] = tobit(0)
I8[tobit((v_A + 75))] = tobit(0)
I8[tobit((v_A + 76))] = tobit(0)
I8[tobit((v_A + 77))] = tobit(0)
I8[tobit((v_A + 78))] = tobit(0)
I8[tobit((v_A + 79))] = tobit(0)
I8[tobit((v_A + 80))] = tobit(0)
I8[tobit((v_A + 81))] = tobit(0)
I8[tobit((v_A + 82))] = tobit(0)
I8[tobit((v_A + 83))] = tobit(0)
I8[tobit((v_A + 84))] = tobit(0)
I8[tobit((v_A + 85))] = tobit(0)
I8[tobit((v_A + 86))] = tobit(0)
I8[tobit((v_A + 87))] = tobit(0)
I8[tobit((v_A + 88))] = tobit(0)
I8[tobit((v_A + 89))] = tobit(0)
I8[tobit((v_A + 90))] = tobit(0)
I8[tobit((v_A + 91))] = tobit(0)
I8[tobit((v_A + 92))] = tobit(0)
I8[tobit((v_A + 93))] = tobit(0)
I8[tobit((v_A + 94))] = tobit(0)
I8[tobit((v_A + 95))] = tobit(0)
I8[tobit((v_A + 96))] = tobit(0)
I8[tobit((v_A + 97))] = tobit(0)
I8[tobit((v_A + 98))] = tobit(0)
I8[tobit((v_A + 99))] = tobit(0)
I8[tobit((v_A + 100))] = tobit(0)
I8[tobit((v_A + 101))] = tobit(0)
I8[tobit((v_A + 102))] = tobit(0)
I8[tobit((v_A + 103))] = tobit(0)
I8[tobit((v_A + 104))] = tobit(0)
I8[tobit((v_A + 105))] = tobit(0)
I8[tobit((v_A + 106))] = tobit(0)
I8[tobit((v_A + 107))] = tobit(0)
I8[tobit((v_A + 108))] = tobit(0)
I8[tobit((v_A + 109))] = tobit(0)
I8[tobit((v_A + 110))] = tobit(0)
I8[tobit((v_A + 111))] = tobit(0)
I8[tobit((v_A + 112))] = tobit(0)
I8[tobit((v_A + 113))] = tobit(0)
I8[tobit((v_A + 114))] = tobit(0)
I8[tobit((v_A + 115))] = tobit(0)
I8[tobit((v_A + 116))] = tobit(0)
I8[tobit((v_A + 117))] = tobit(0)
I8[tobit((v_A + 118))] = tobit(0)
I8[tobit((v_A + 119))] = tobit(0)
I8[tobit((v_A + 120))] = tobit(0)
I8[tobit((v_A + 121))] = tobit(0)
I8[tobit((v_A + 122))] = tobit(0)
I8[tobit((v_A + 123))] = tobit(0)
I8[tobit((v_A + 124))] = tobit(0)
I8[tobit((v_A + 125))] = tobit(0)
I8[tobit((v_A + 126))] = tobit(0)
I8[tobit((v_A + 127))] = tobit(0)
end
end

F.fK = function(v_A, v_r, v_n, v_t)
local v_e, v_o, v_f, v_a, v_u = 0, 0, 0, 0, 0
v_e = 0
v_o = 0
v_f = 0
v_a = 0
v_u = 0
v_a = 16
v_e = (-24832)
do
do
do
local t190 = (v_A ~= 0)
if t190 then
v_o = I32[arshift(v_A, 2)]
t190 = (not (bor(((not (v_o ~= 0)) and 1 or 0), ((not (v_t ~= 0)) and 1 or 0)) ~= 0))
end
if t190 then
do
I32[arshift(v_t, 2)] = tobit(0)
v_f = I32[arshift((v_o + 24), 2)]
if (not (v_f ~= 0)) then
do return (-25472) end
end
do
do
v_u = I32[arshift((v_o + 4), 2)]
do
local sw149 = tobit((v_u - 1))
if sw149 == 5 then goto K149_0
elseif sw149 == 0 then goto K149_1
else goto K149_2 end
::K149_0::
do
goto L148
end
::K149_1::
do
goto S149
end
::K149_2::
do
goto L147
end
end
::S149::
v_e = (-25216)
if (16 ~= bor(0, v_f)) then
goto L146
end
I32[arshift(v_t, 2)] = tobit(16)
do return bor(0, UA[I32[arshift((I32[arshift((v_o + 28), 2)] + 4), 2)]](I32[arshift((v_A + 60), 2)], I32[arshift((v_A + 8), 2)], v_r, v_n)) end
end
::L148::
I32[arshift(v_t, 2)] = tobit(16)
do return F.fF(I32[arshift((v_A + 60), 2)], 16, v_r, v_n) end
end
::L147::
do
local t191 = bor(I32[arshift((v_A + 36), 2)], fmod(16, (tobit(v_f) % 4294967296)))
if t191 ~= 0 then
t191 = ((bor(0, v_r) == bor(0, v_n)) and 1 or 0)
end
if (not (t191 ~= 0)) then
do
v_e = (-24704)
do
do
do
do
do
do
do
do
do
do
do
local sw153 = tobit((v_u - 2))
if sw153 == 0 then goto K153_0
elseif sw153 == 1 then goto K153_1
elseif sw153 == 3 then goto K153_2
elseif sw153 == 5 then goto K153_3
else goto K153_4 end
::K153_0::
do
do
do
do
do
do
do
do
do
local sw156 = I32[arshift((v_A + 8), 2)]
if sw156 == 0 then goto K156_0
elseif sw156 == 1 then goto K156_1
else goto K156_2 end
::K156_0::
do
do
local t192 = v_f
v_e = I32[arshift((v_A + 36), 2)]
v_o = tobit((t192 - v_e))
if (not (I32[arshift((v_A + 12), 2)] ~= 0)) then
goto L155
end
end
if ((tobit(v_o) % 4294967296) >= 16) then
goto L151
end
goto L154
end
::K156_1::
do
goto S156
end
::K156_2::
do
goto L154
end
end
::S156::
end
do
local t193 = v_f
v_e = I32[arshift((v_A + 36), 2)]
if ((tobit((t193 - v_e)) % 4294967296) <= 16) then
goto L154
end
end
goto L151
end
end
::L155::
end
if ((tobit(v_o) % 4294967296) > 16) then
goto L151
end
end
end
::L154::
end
do
v_e = I32[arshift((v_A + 36), 2)]
if (v_e ~= 0) then
do
do
v_a = tobit((v_A + 20))
local t194 = tobit((v_a + v_e))
local t195 = v_r
v_o = tobit((v_f - v_e))
F.fQA(t194, t195, v_o)
v_e = bor(0, UA[I32[arshift((I32[arshift((I32[arshift(v_A, 2)] + 28), 2)] + 8), 2)]](I32[arshift((v_A + 60), 2)], I32[arshift((v_A + 8), 2)], v_f, tobit((v_A + 40)), v_a, v_n))
if (v_e ~= 0) then
goto L146
end
end
I32[arshift(v_t, 2)] = tobit((v_f + I32[arshift(v_t, 2)]))
I32[arshift((v_A + 36), 2)] = tobit(0)
v_a = tobit((16 - v_o))
v_n = tobit((v_n + v_f))
v_r = tobit((v_r + v_o))
end
end
end
v_e = 0
if (not (v_a ~= 0)) then
goto L146
end
do
v_o = tobit(fmod((tobit(v_a) % 4294967296), (tobit(v_f) % 4294967296)))
if not (v_o ~= 0) then
v_o = 0
if not (I32[arshift((v_A + 8), 2)] ~= 0) then
v_o = ((I32[arshift((v_A + 12), 2)] ~= 0) and v_f or 0)
end
end
local t196 = tobit((v_A + 20))
v_f = tobit((v_a - v_o))
F.fQA(t196, tobit((v_f + v_r)), v_o)
I32[arshift((v_A + 36), 2)] = tobit((I32[arshift((v_A + 36), 2)] + v_o))
if (not (v_f ~= 0)) then
goto L146
end
end
v_e = bor(0, UA[I32[arshift((I32[arshift((I32[arshift(v_A, 2)] + 28), 2)] + 8), 2)]](I32[arshift((v_A + 60), 2)], I32[arshift((v_A + 8), 2)], v_f, tobit((v_A + 40)), v_r, v_n))
if (v_e ~= 0) then
goto L146
end
I32[arshift(v_t, 2)] = tobit((v_f + I32[arshift(v_t, 2)]))
goto L150
end
::K153_1::
do
v_e = bor(0, UA[I32[arshift((I32[arshift((v_o + 28), 2)] + 12), 2)]](I32[arshift((v_A + 60), 2)], I32[arshift((v_A + 8), 2)], 16, tobit((v_A + 36)), tobit((v_A + 40)), v_r, v_n))
if (not (v_e ~= 0)) then
goto L152
end
goto L146
end
::K153_2::
do
v_e = bor(0, UA[I32[arshift((I32[arshift((v_o + 28), 2)] + 16), 2)]](I32[arshift((v_A + 60), 2)], 16, tobit((v_A + 36)), tobit((v_A + 40)), tobit((v_A + 20)), v_r, v_n))
if (not (v_e ~= 0)) then
goto L152
end
goto L146
end
::K153_3::
do
goto S153
end
::K153_4::
do
goto L146
end
end
::S153::
end
v_e = bor(0, UA[I32[arshift((I32[arshift((v_o + 28), 2)] + 20), 2)]](I32[arshift((v_A + 60), 2)], 16, v_r, v_n))
if (v_e ~= 0) then
goto L146
end
end
end
::L152::
end
I32[arshift(v_t, 2)] = tobit(16)
goto L150
end
end
::L151::
end
F.fQA(tobit((20 + tobit((v_A + v_e)))), v_r, 16)
I32[arshift((v_A + 36), 2)] = tobit((I32[arshift((v_A + 36), 2)] + 16))
end
end
::L150::
end
v_e = 0
end
end
end
end
end
end
end
::L146::
end
do return v_e end
end

F.fW = function(v_A)
local v_r, v_n, v_e, v_o, v_a, v_u = 0, 0, 0, 0, 0, 0
v_r = 0
v_n = 0
v_e = 0
v_o = 0
v_a = 0
v_u = 0
do
local t197 = (v_A ~= 0)
if not t197 then
v_A = I32[7798]
t197 = (v_A ~= 0)
end
if t197 then
do
v_e = 1127
v_o = tobit((B - 32))
I32[arshift((24 + v_o), 2)] = tobit(0)
I32[arshift((v_o + 28), 2)] = tobit(0)
I32[arshift((v_o + 16), 2)] = tobit(0)
I32[arshift((v_o + 20), 2)] = tobit(0)
I32[arshift((v_o + 8), 2)] = tobit(0)
I32[arshift((v_o + 12), 2)] = tobit(0)
I32[arshift(v_o, 2)] = tobit(0)
I32[arshift((v_o + 4), 2)] = tobit(0)
v_n = 0
v_r = U8[1127]
if (v_r ~= 0) then
v_u = v_A
v_n = U8[1128]
if (v_n ~= 0) then
do
v_a = tobit((v_o + band((rshift(v_r, 3) % 4294967296), 28)))
I32[arshift(v_a, 2)] = tobit(bor(I32[arshift(v_a, 2)], lshift(1, v_r)))
while true do
v_r = band(31, v_n)
v_a = tobit((rshift(v_n, 3) % 4294967296))
v_n = U8[tobit((v_e + 2))]
v_a = tobit((v_o + band(28, v_a)))
I32[arshift(v_a, 2)] = tobit(bor(I32[arshift(v_a, 2)], lshift(1, v_r)))
v_e = tobit((v_e + 1))
if not (v_n ~= 0) then goto B157 end
do
end
::C157::
end
end
::B157::
v_r = v_A
do
v_n = U8[bor(0, v_u)]
if (v_n ~= 0) then
do
v_e = v_u
while true do
do
if (not (band((rshift(I32[arshift((v_o + band((rshift(v_n, 3) % 4294967296), 28)), 2)], v_n) % 4294967296), 1) ~= 0)) then
v_r = v_e
goto L158
end
v_n = U8[tobit((v_e + 1))]
v_r = tobit((v_e + 1))
v_e = v_r
if (not (v_n ~= 0)) then
goto B159
end
end
::C159::
end
end
::B159::
end
end
::L158::
v_n = tobit((v_r - v_u))
else
do
v_n = v_A
while true do
v_e = v_n
v_n = tobit((v_n + 1))
if not (bor(0, v_r) == U8[bor(0, v_e)]) then goto B160 end
do
end
::C160::
end
end
::B160::
v_n = tobit((v_e - v_u))
end
end
v_n = tobit((v_n + v_A))
if (not (U8[bor(0, v_n)] ~= 0)) then
I32[7798] = tobit(0)
do return 0 end
end
v_u = v_n
v_A = 1127
v_o = tobit((B - 32))
B = v_o
v_a = I8[1127]
do
do
do
if ((U8[1128] ~= 0) and (v_a ~= 0)) then
F.fOA(v_o, 0, 32)
v_r = U8[1127]
if (v_r ~= 0) then
do
while true do
v_e = tobit((v_o + band((rshift(v_r, 3) % 4294967296), 28)))
I32[arshift(v_e, 2)] = tobit(bor(I32[arshift(v_e, 2)], lshift(1, v_r)))
v_r = U8[tobit((v_A + 1))]
v_A = tobit((v_A + 1))
if not (v_r ~= 0) then goto B162 end
do
end
::C162::
end
end
::B162::
end
v_e = v_n
v_r = U8[bor(0, v_n)]
if (v_r ~= 0) then
do
v_A = v_u
while true do
do
if (band((rshift(I32[arshift((v_o + band((rshift(v_r, 3) % 4294967296), 28)), 2)], v_r) % 4294967296), 1) ~= 0) then
v_e = v_A
goto L161
end
v_r = U8[tobit((v_A + 1))]
v_e = tobit((v_A + 1))
v_A = v_e
if (not (v_r ~= 0)) then
goto B163
end
end
::C163::
end
end
::B163::
end
else
do
v_A = v_n
do
do
do
v_e = band(255, v_a)
if (v_e ~= 0) then
do
if (band(3, v_A) ~= 0) then
do
while true do
do
v_r = U8[bor(0, v_A)]
if (bor(((not (v_r ~= 0)) and 1 or 0), ((bor(0, v_r) == band(255, v_a)) and 1 or 0)) ~= 0) then
goto L164
end
v_A = tobit((v_A + 1))
if (not (band(3, v_A) ~= 0)) then
goto B165
end
end
::C165::
end
end
::B165::
end
do
do
do
local t198 = (-1)
v_r = I32[arshift(v_A, 2)]
if (not (band(band(bxor(t198, v_r), (v_r - 16843009)), (-2139062144)) ~= 0)) then
do
do
v_e = imul(v_e, 16843009)
while true do
do
do
do
local t199 = (-1)
v_r = bxor(v_r, v_e)
if (band(band(bxor(t199, v_r), (v_r - 16843009)), (-2139062144)) ~= 0) then
goto L166
end
end
v_r = I32[arshift((v_A + 4), 2)]
v_A = tobit((v_A + 4))
if (band(band((v_r - 16843009), bxor((-1), v_r)), (-2139062144)) ~= 0) then
goto B167
end
end
end
::C167::
end
end
::B167::
end
end
end
end
::L166::
end
do
do
while true do
do
v_e = v_A
v_r = U8[bor(0, v_A)]
local t200 = v_r
if t200 ~= 0 then
v_A = tobit((v_e + 1))
t200 = ((bor(0, v_r) ~= band(255, v_a)) and 1 or 0)
end
if not (t200 ~= 0) then goto B168 end
end
do
end
::C168::
end
end
::B168::
end
v_A = v_e
end
else
v_A = tobit((F.flA(v_A) + v_A))
end
end
end
::L164::
end
v_e = v_A
end
end
end
end
::L161::
end
B = tobit((v_o + 32))
v_A = tobit((tobit((v_e - v_u)) + v_n))
if (U8[bor(0, v_A)] ~= 0) then
I32[7798] = tobit((v_A + 1))
I8[bor(0, v_A)] = tobit(0)
do return v_n end
end
I32[7798] = tobit(0)
end
end
end
do return v_n end
end

F.fH = function(v_A, v_r, v_n)
local v_e, v_o, v_a, v_u = 0, 0, 0, 0
v_a = 0
v_u = 0
v_e = tobit((B - 288))
B = v_e
F.fOA(tobit((v_e + 8)), 0, 280)
I32[arshift((v_A + 4), 2)] = tobit((v_A + 8))
v_o = F.fO(tobit((v_e + 8)), v_r, v_n)
if (not (v_o ~= 0)) then
v_n = I32[arshift((v_e + 8), 2)]
I32[arshift(v_A, 2)] = tobit(v_n)
v_u = I32[arshift((v_e + 12), 2)]
v_a = tobit((v_u + lshift(v_n, 4)))
I32[arshift((v_A + 8), 2)] = tobit(I32[arshift(v_a, 2)])
I32[arshift((v_A + 12), 2)] = tobit(I32[arshift((v_a + 4), 2)])
I32[arshift((v_A + 16), 2)] = tobit(I32[arshift((v_a + 8), 2)])
I32[arshift((v_A + 20), 2)] = tobit(I32[arshift((v_a + 12), 2)])
v_A = tobit((v_A + 24))
v_r = tobit((v_a - 16))
if (bor(0, v_n) < 2) then
v_n = tobit((v_a + 16))
else
do
while true do
v_a = I32[arshift(v_r, 2)]
I32[arshift(v_A, 2)] = tobit(bxor(bxor(bxor(I32[arshift((23744 + lshift(U8[tobit((22464 + band((rshift(v_a, 8) % 4294967296), 255)))], 2)), 2)], I32[arshift((22720 + lshift(U8[tobit((22464 + band(255, v_a)))], 2)), 2)]), I32[arshift((24768 + lshift(U8[tobit((22464 + band((rshift(v_a, 16) % 4294967296), 255)))], 2)), 2)]), I32[arshift((25792 + lshift(U8[tobit((22464 + tobit((rshift(v_a, 24) % 4294967296))))], 2)), 2)]))
v_a = I32[arshift((v_r + 4), 2)]
I32[arshift((v_A + 4), 2)] = tobit(bxor(bxor(bxor(I32[arshift((23744 + lshift(U8[tobit((22464 + band((rshift(v_a, 8) % 4294967296), 255)))], 2)), 2)], I32[arshift((22720 + lshift(U8[tobit((22464 + band(255, v_a)))], 2)), 2)]), I32[arshift((24768 + lshift(U8[tobit((22464 + band((rshift(v_a, 16) % 4294967296), 255)))], 2)), 2)]), I32[arshift((25792 + lshift(U8[tobit((22464 + tobit((rshift(v_a, 24) % 4294967296))))], 2)), 2)]))
v_a = I32[arshift((v_r + 8), 2)]
I32[arshift((v_A + 8), 2)] = tobit(bxor(bxor(bxor(I32[arshift((23744 + lshift(U8[tobit((22464 + band((rshift(v_a, 8) % 4294967296), 255)))], 2)), 2)], I32[arshift((22720 + lshift(U8[tobit((22464 + band(255, v_a)))], 2)), 2)]), I32[arshift((24768 + lshift(U8[tobit((22464 + band((rshift(v_a, 16) % 4294967296), 255)))], 2)), 2)]), I32[arshift((25792 + lshift(U8[tobit((22464 + tobit((rshift(v_a, 24) % 4294967296))))], 2)), 2)]))
v_a = I32[arshift((v_r + 12), 2)]
I32[arshift((v_A + 12), 2)] = tobit(bxor(bxor(bxor(I32[arshift((23744 + lshift(U8[tobit((22464 + band((rshift(v_a, 8) % 4294967296), 255)))], 2)), 2)], I32[arshift((22720 + lshift(U8[tobit((22464 + band(255, v_a)))], 2)), 2)]), I32[arshift((24768 + lshift(U8[tobit((22464 + band((rshift(v_a, 16) % 4294967296), 255)))], 2)), 2)]), I32[arshift((25792 + lshift(U8[tobit((22464 + tobit((rshift(v_a, 24) % 4294967296))))], 2)), 2)]))
v_r = tobit((v_r - 16))
v_A = tobit((v_A + 16))
v_a = ((bor(0, v_n) > 2) and 1 or 0)
v_n = tobit((v_n - 1))
if not (v_a ~= 0) then goto B169 end
do
end
::C169::
end
end
::B169::
v_r = v_u
v_n = tobit((v_r + 32))
end
I32[arshift(v_A, 2)] = tobit(I32[arshift(v_r, 2)])
I32[arshift((v_A + 4), 2)] = tobit(I32[arshift((v_n - 28), 2)])
I32[arshift((v_A + 8), 2)] = tobit(I32[arshift((v_n - 24), 2)])
I32[arshift((v_A + 12), 2)] = tobit(I32[arshift((v_n - 20), 2)])
end
do
v_r = 266
v_A = tobit((v_e + 8))
while true do
I8[bor(0, v_A)] = tobit(0)
I8[tobit((v_A + 1))] = tobit(0)
I8[tobit((v_A + 2))] = tobit(0)
I8[tobit((v_A + 3))] = tobit(0)
I8[tobit((v_A + 4))] = tobit(0)
I8[tobit((v_A + 5))] = tobit(0)
I8[tobit((v_A + 6))] = tobit(0)
I8[tobit((v_A + 7))] = tobit(0)
I8[tobit((v_A + 8))] = tobit(0)
I8[tobit((v_A + 9))] = tobit(0)
I8[tobit((v_A + 10))] = tobit(0)
I8[tobit((v_A + 11))] = tobit(0)
I8[tobit((v_A + 12))] = tobit(0)
I8[tobit((v_A + 13))] = tobit(0)
if not (v_r ~= 0) then goto B170 end
do
v_A = tobit((v_A + 14))
v_r = tobit((v_r - 14))
end
::C170::
end
end
::B170::
B = tobit((v_e + 288))
do return v_o end
end

F.fN = function(v_A, v_r, v_n, v_t)
local v_e, v_o, v_a, v_u, v_c, v_s = 0, 0, 0, 0, 0, 0
v_e = 0
v_o = 0
v_a = 0
v_u = 0
v_c = 0
v_s = 0
do
do
do
v_a = I32[arshift(v_A, 2)]
if (not ((tobit(v_a) % 4294967296) <= U32[arshift((v_A + 4), 2)])) then
do
v_A = I32[arshift((v_A + 8), 2)]
v_c = v_A
if (v_n ~= 0) then
v_s = band(1, v_n)
if (1 ~= bor(0, v_n)) then
do
v_u = band((-2), v_n)
while true do
v_e = bxor(I32[arshift((12064 + lshift(bxor(U8[tobit((v_r + v_o))], band(255, v_e)), 2)), 2)], (rshift(v_e, 8) % 4294967296))
v_e = bxor(I32[arshift((12064 + lshift(bxor(U8[tobit((bor(1, v_o) + v_r))], band(255, v_e)), 2)), 2)], (rshift(v_e, 8) % 4294967296))
v_o = tobit((v_o + 2))
v_u = tobit((v_u - 2))
if not (v_u ~= 0) then goto B172 end
do
end
::C172::
end
end
::B172::
end
if (v_s ~= 0) then
v_e = bxor(I32[arshift((12064 + lshift(bxor(U8[tobit((v_r + v_o))], band(255, v_e)), 2)), 2)], (rshift(v_e, 8) % 4294967296))
end
v_e = imul(v_e, 4097)
else
v_e = 0
end
do
v_e = imul(bxor((rshift(v_e, 22) % 4294967296), v_e), 17)
v_e = imul(bxor((rshift(v_e, 9) % 4294967296), v_e), 1025)
v_e = imul(bxor((rshift(v_e, 2) % 4294967296), v_e), 129)
v_e = tobit(fmod((tobit(imul(bxor((rshift(v_e, 15) % 4294967296), (rshift(v_e, 3) % 4294967296)), (-1640531535))) % 4294967296), (tobit(v_a) % 4294967296)))
v_o = tobit((v_c + lshift(v_e, 4)))
local t201 = I32[arshift((8 + v_o), 2)]
if t201 ~= 0 then
local t202 = ((I32[arshift((v_o + 4), 2)] ~= bor(0, v_n)) and 1 or 0)
if t202 == 0 then
t202 = F.fEA(I32[arshift((v_A + lshift(v_e, 4)), 2)], v_r, v_n)
end
t201 = t202
end
local t203 = t201
if t203 ~= 0 then
local t204 = v_A
v_e = tobit(fmod((tobit((v_e + 1)) % 4294967296), (tobit(v_a) % 4294967296)))
v_o = tobit((t204 + lshift(v_e, 4)))
t203 = I32[arshift((8 + v_o), 2)]
end
local t205 = t203
if t205 ~= 0 then
local t206 = ((I32[arshift((v_o + 4), 2)] ~= bor(0, v_n)) and 1 or 0)
if t206 == 0 then
t206 = F.fEA(I32[arshift((v_A + lshift(v_e, 4)), 2)], v_r, v_n)
end
t205 = t206
end
local t207 = t205
if t207 ~= 0 then
local t208 = v_A
v_e = tobit(fmod((tobit((v_e + 1)) % 4294967296), (tobit(v_a) % 4294967296)))
v_o = tobit((t208 + lshift(v_e, 4)))
t207 = I32[arshift((8 + v_o), 2)]
end
local t209 = t207
if t209 ~= 0 then
local t210 = ((I32[arshift((v_o + 4), 2)] ~= bor(0, v_n)) and 1 or 0)
if t210 == 0 then
t210 = F.fEA(I32[arshift((v_A + lshift(v_e, 4)), 2)], v_r, v_n)
end
t209 = t210
end
local t211 = t209
if t211 ~= 0 then
local t212 = v_A
v_e = tobit(fmod((tobit((v_e + 1)) % 4294967296), (tobit(v_a) % 4294967296)))
v_o = tobit((t212 + lshift(v_e, 4)))
t211 = I32[arshift((8 + v_o), 2)]
end
local t213 = t211
if t213 ~= 0 then
local t214 = ((I32[arshift((v_o + 4), 2)] ~= bor(0, v_n)) and 1 or 0)
if t214 == 0 then
t214 = F.fEA(I32[arshift((v_A + lshift(v_e, 4)), 2)], v_r, v_n)
end
t213 = t214
end
local t215 = t213
if t215 ~= 0 then
local t216 = v_A
v_e = tobit(fmod((tobit((v_e + 1)) % 4294967296), (tobit(v_a) % 4294967296)))
v_o = tobit((t216 + lshift(v_e, 4)))
t215 = I32[arshift((8 + v_o), 2)]
end
local t217 = t215
if t217 ~= 0 then
local t218 = ((I32[arshift((v_o + 4), 2)] ~= bor(0, v_n)) and 1 or 0)
if t218 == 0 then
t218 = F.fEA(I32[arshift((v_A + lshift(v_e, 4)), 2)], v_r, v_n)
end
t217 = t218
end
local t219 = t217
if t219 ~= 0 then
local t220 = v_A
v_e = tobit(fmod((tobit((v_e + 1)) % 4294967296), (tobit(v_a) % 4294967296)))
v_o = tobit((t220 + lshift(v_e, 4)))
t219 = I32[arshift((8 + v_o), 2)]
end
local t221 = t219
if t221 ~= 0 then
local t222 = ((I32[arshift((v_o + 4), 2)] ~= bor(0, v_n)) and 1 or 0)
if t222 == 0 then
t222 = F.fEA(I32[arshift((v_A + lshift(v_e, 4)), 2)], v_r, v_n)
end
t221 = t222
end
local t223 = t221
if t223 ~= 0 then
local t224 = v_A
v_e = tobit(fmod((tobit((v_e + 1)) % 4294967296), (tobit(v_a) % 4294967296)))
v_o = tobit((t224 + lshift(v_e, 4)))
t223 = I32[arshift((8 + v_o), 2)]
end
local t225 = t223
if t225 ~= 0 then
local t226 = ((I32[arshift((v_o + 4), 2)] ~= bor(0, v_n)) and 1 or 0)
if t226 == 0 then
t226 = F.fEA(I32[arshift((v_A + lshift(v_e, 4)), 2)], v_r, v_n)
end
t225 = t226
end
local t227 = t225
if t227 ~= 0 then
local t228 = v_A
v_e = tobit(fmod((tobit((v_e + 1)) % 4294967296), (tobit(v_a) % 4294967296)))
v_a = tobit((t228 + lshift(v_e, 4)))
t227 = I32[arshift((8 + v_a), 2)]
end
if (t227 ~= 0) then
v_o = 0
if (I32[arshift((v_a + 4), 2)] ~= bor(0, v_n)) then
goto L171
end
if (F.fEA(I32[arshift((v_A + lshift(v_e, 4)), 2)], v_r, v_n) ~= 0) then
goto L171
end
end
end
I32[arshift(v_t, 2)] = tobit(v_e)
v_o = 1
end
end
end
end
::L171::
end
do return v_o end
end

F.fV = function(v_A, v_r, v_n)
local v_e, v_o, v_a, v_u, v_c = 0, 0, 0, 0, 0
v_e = 0
v_o = 0
v_a = 0
v_u = 0
v_c = 0
do
do
do
v_e = bor(bor(bor(U8[bor(0, v_r)], lshift(U8[tobit((v_r + 1))], 8)), lshift(U8[tobit((v_r + 2))], 16)), lshift(U8[tobit((v_r + 3))], 24))
v_e = bor(bor(bor(lshift(v_e, 24), band(lshift(v_e, 8), 16711680)), band((rshift(v_e, 8) % 4294967296), 65280)), (rshift(v_e, 24) % 4294967296))
local t230 = v_e
local t229 = (rshift(v_e, 4) % 4294967296)
v_r = bor(bor(bor(U8[tobit((v_r + 4))], lshift(U8[tobit((v_r + 5))], 8)), lshift(U8[tobit((v_r + 6))], 16)), lshift(U8[tobit((v_r + 7))], 24))
v_r = bor(bor(bor(lshift(v_r, 24), band(lshift(v_r, 8), 16711680)), band((rshift(v_r, 8) % 4294967296), 65280)), (rshift(v_r, 24) % 4294967296))
v_o = band(252645135, bxor(t229, v_r))
v_e = bxor(t230, lshift(v_o, 4))
v_o = bxor(v_o, v_r)
local t231 = v_o
v_r = bxor((rshift(v_e, 16) % 4294967296), band(65535, v_o))
v_o = bxor(t231, v_r)
local t233 = v_o
local t232 = (rshift(v_o, 2) % 4294967296)
v_r = bxor(v_e, lshift(v_r, 16))
v_e = band(858993459, bxor(t232, v_r))
v_o = bxor(t233, lshift(v_e, 2))
local t234 = (rshift(v_o, 8) % 4294967296)
v_r = bxor(v_r, v_e)
v_e = band(16711935, bxor(t234, v_r))
v_o = F.fSA(bxor(lshift(v_e, 8), v_o), 1)
v_a = v_o
local t236 = v_a
local t235 = (-1431655766)
v_r = bxor(v_r, v_e)
v_o = band(t235, bxor(v_r, v_o))
v_e = bxor(t236, v_o)
v_r = F.fSA(bxor(v_r, v_o), 1)
v_o = 1
end
while true do
v_a = v_e
v_u = bxor(I32[arshift((v_A + 4), 2)], F.fSA(v_e, 28))
v_c = v_r
v_r = bxor(I32[arshift(v_A, 2)], v_e)
v_r = bxor(bxor(bxor(bxor(bxor(bxor(bxor(bxor(I32[arshift((2912 + lshift(band(63, v_u), 2)), 2)], v_c), I32[arshift((1888 + lshift(band(63, v_r), 2)), 2)]), I32[arshift((2144 + band((rshift(v_r, 6) % 4294967296), 252)), 2)]), I32[arshift((2400 + band((rshift(v_r, 14) % 4294967296), 252)), 2)]), I32[arshift((2656 + band((rshift(v_r, 22) % 4294967296), 252)), 2)]), I32[arshift((3168 + band((rshift(v_u, 6) % 4294967296), 252)), 2)]), I32[arshift((3424 + band((rshift(v_u, 14) % 4294967296), 252)), 2)]), I32[arshift((3680 + band((rshift(v_u, 22) % 4294967296), 252)), 2)])
v_e = bxor(v_r, I32[arshift((v_A + 8), 2)])
v_a = bxor(bxor(bxor(bxor(v_a, I32[arshift((1888 + lshift(band(63, v_e), 2)), 2)]), I32[arshift((2144 + band((rshift(v_e, 6) % 4294967296), 252)), 2)]), I32[arshift((2400 + band((rshift(v_e, 14) % 4294967296), 252)), 2)]), I32[arshift((2656 + band((rshift(v_e, 22) % 4294967296), 252)), 2)])
v_e = bxor(I32[arshift((v_A + 12), 2)], F.fSA(v_r, 28))
v_e = bxor(bxor(bxor(bxor(v_a, I32[arshift((2912 + lshift(band(63, v_e), 2)), 2)]), I32[arshift((3168 + band((rshift(v_e, 6) % 4294967296), 252)), 2)]), I32[arshift((3424 + band((rshift(v_e, 14) % 4294967296), 252)), 2)]), I32[arshift((3680 + band((rshift(v_e, 22) % 4294967296), 252)), 2)])
if not (8 ~= bor(0, v_o)) then goto B173 end
do
v_A = tobit((v_A + 16))
v_o = tobit((v_o + 1))
end
::C173::
end
end
::B173::
end
do
v_a = lshift(v_r, 31)
local t239 = v_a
v_o = v_r
local t238 = v_o
local t237 = (-1431655766)
v_A = F.fSA(v_e, 31)
v_r = band(t237, bxor(v_A, v_r))
v_e = bor(t239, (rshift(bxor(t238, v_r), 1) % 4294967296))
local t241 = v_e
local t240 = (rshift(v_e, 8) % 4294967296)
v_A = bxor(v_A, v_r)
v_r = band(16711935, bxor(t240, v_A))
v_e = bxor(t241, lshift(v_r, 8))
local t243 = v_e
local t242 = (rshift(v_e, 2) % 4294967296)
v_A = bxor(v_A, v_r)
v_r = band(858993459, bxor(t242, v_A))
v_e = bxor(t243, lshift(v_r, 2))
local t244 = band(65535, v_e)
v_A = bxor(v_A, v_r)
v_r = bxor(t244, (rshift(v_A, 16) % 4294967296))
v_o = bxor(lshift(v_r, 16), v_A)
v_A = bxor(v_r, v_e)
local t245 = v_A
v_r = band(252645135, bxor((rshift(v_o, 4) % 4294967296), v_A))
v_A = bxor(t245, v_r)
I8[tobit((v_n + 7))] = tobit(v_A)
I8[tobit((v_n + 6))] = tobit((rshift(v_A, 8) % 4294967296))
I8[tobit((v_n + 5))] = tobit((rshift(v_A, 16) % 4294967296))
I8[tobit((v_n + 4))] = tobit((rshift(v_A, 24) % 4294967296))
v_A = bxor(v_o, lshift(v_r, 4))
I8[tobit((v_n + 3))] = tobit(v_A)
I8[tobit((v_n + 2))] = tobit((rshift(v_A, 8) % 4294967296))
I8[tobit((v_n + 1))] = tobit((rshift(v_A, 16) % 4294967296))
I8[bor(0, v_n)] = tobit((rshift(v_A, 24) % 4294967296))
do return 0 end
end
end

F.fz = function(v_A, v_r, v_n, v_e, v_o, v_i)
local v_a, v_u = 0, 0
v_a = 0
v_u = 0
v_u = (-50)
do
if (not (band(7, v_n) ~= 0)) then
if (1 == bor(0, v_r)) then
v_u = 0
if (v_n ~= 0) then
do
v_r = U8[bor(0, v_e)]
while true do
I8[bor(0, v_i)] = tobit(bxor(U8[bor(0, v_o)], v_r))
I8[tobit((v_i + 1))] = tobit(bxor(U8[tobit((v_e + 1))], U8[tobit((v_o + 1))]))
I8[tobit((v_i + 2))] = tobit(bxor(U8[tobit((v_e + 2))], U8[tobit((v_o + 2))]))
I8[tobit((v_i + 3))] = tobit(bxor(U8[tobit((v_e + 3))], U8[tobit((v_o + 3))]))
I8[tobit((v_i + 4))] = tobit(bxor(U8[tobit((v_e + 4))], U8[tobit((v_o + 4))]))
I8[tobit((v_i + 5))] = tobit(bxor(U8[tobit((v_e + 5))], U8[tobit((v_o + 5))]))
I8[tobit((v_i + 6))] = tobit(bxor(U8[tobit((v_e + 6))], U8[tobit((v_o + 6))]))
I8[tobit((v_i + 7))] = tobit(bxor(U8[tobit((v_e + 7))], U8[tobit((v_o + 7))]))
F.fV(v_A, v_i, v_i)
v_a = bor(bor(bor(U8[tobit((v_i + 4))], lshift(U8[tobit((v_i + 5))], 8)), lshift(U8[tobit((v_i + 6))], 16)), lshift(U8[tobit((v_i + 7))], 24))
v_r = bor(bor(bor(U8[bor(0, v_i)], lshift(U8[tobit((v_i + 1))], 8)), lshift(U8[tobit((v_i + 2))], 16)), lshift(U8[tobit((v_i + 3))], 24))
I8[bor(0, v_e)] = tobit(v_r)
I8[tobit((v_e + 1))] = tobit((rshift(v_r, 8) % 4294967296))
I8[tobit((v_e + 2))] = tobit((rshift(v_r, 16) % 4294967296))
I8[tobit((v_e + 3))] = tobit((rshift(v_r, 24) % 4294967296))
I8[tobit((v_e + 4))] = tobit(v_a)
I8[tobit((v_e + 5))] = tobit((rshift(v_a, 8) % 4294967296))
I8[tobit((v_e + 6))] = tobit((rshift(v_a, 16) % 4294967296))
I8[tobit((v_e + 7))] = tobit((rshift(v_a, 24) % 4294967296))
v_i = tobit((v_i + 8))
v_o = tobit((v_o + 8))
v_n = tobit((v_n - 8))
if not (v_n ~= 0) then goto B175 end
do
end
::C175::
end
end
::B175::
end
else
v_u = 0
if (not (v_n ~= 0)) then
goto L174
end
do
while true do
v_a = bor(bor(bor(U8[tobit((v_o + 4))], lshift(U8[tobit((v_o + 5))], 8)), lshift(U8[tobit((v_o + 6))], 16)), lshift(U8[tobit((v_o + 7))], 24))
v_r = bor(bor(bor(U8[bor(0, v_o)], lshift(U8[tobit((v_o + 1))], 8)), lshift(U8[tobit((v_o + 2))], 16)), lshift(U8[tobit((v_o + 3))], 24))
F.fV(v_A, v_o, v_i)
I8[bor(0, v_i)] = tobit(bxor(U8[bor(0, v_e)], U8[bor(0, v_i)]))
I8[tobit((v_i + 1))] = tobit(bxor(U8[tobit((v_e + 1))], U8[tobit((v_i + 1))]))
I8[tobit((v_i + 2))] = tobit(bxor(U8[tobit((v_e + 2))], U8[tobit((v_i + 2))]))
I8[tobit((v_i + 3))] = tobit(bxor(U8[tobit((v_e + 3))], U8[tobit((v_i + 3))]))
I8[tobit((v_i + 4))] = tobit(bxor(U8[tobit((v_e + 4))], U8[tobit((v_i + 4))]))
I8[tobit((v_i + 5))] = tobit(bxor(U8[tobit((v_e + 5))], U8[tobit((v_i + 5))]))
I8[tobit((v_i + 6))] = tobit(bxor(U8[tobit((v_e + 6))], U8[tobit((v_i + 6))]))
I8[tobit((v_i + 7))] = tobit(bxor(U8[tobit((v_e + 7))], U8[tobit((v_i + 7))]))
I8[bor(0, v_e)] = tobit(v_r)
I8[tobit((v_e + 1))] = tobit((rshift(v_r, 8) % 4294967296))
I8[tobit((v_e + 2))] = tobit((rshift(v_r, 16) % 4294967296))
I8[tobit((v_e + 3))] = tobit((rshift(v_r, 24) % 4294967296))
I8[tobit((v_e + 4))] = tobit(v_a)
I8[tobit((v_e + 5))] = tobit((rshift(v_a, 8) % 4294967296))
I8[tobit((v_e + 6))] = tobit((rshift(v_a, 16) % 4294967296))
I8[tobit((v_e + 7))] = tobit((rshift(v_a, 24) % 4294967296))
v_i = tobit((v_i + 8))
v_o = tobit((v_o + 8))
v_n = tobit((v_n - 8))
if not (v_n ~= 0) then goto B176 end
do
end
::C176::
end
end
::B176::
end
end
end
::L174::
do return v_u end
end

F.fq = function(v_A, v_r, v_n)
local v_t, v_e, v_o, v_i, v_f, v_a, v_u, v_c, v_s = 0, 0, 0, 0, 0, 0, 0, 0, 0
v_t = 0
v_e = 0
v_o = 0
v_i = 0
v_f = 0
v_a = 0
v_u = 0
v_c = 0
v_s = 0
do
do
do
do
do
do
do
do
do
do
do
do
do
do
do
do
v_e = v_r
if (v_r ~= 0) then
v_t = v_n
if (not (v_t ~= 0)) then
goto L186
end
goto L185
end
v_A = tobit(toint(((tobit(v_A) % 4294967296) / (tobit(v_n) % 4294967296))))
Iv = 0
goto L177
end
::L186::
if (not (v_A ~= 0)) then
goto L184
end
goto L183
end
::L185::
if (not (band((v_t - 1), v_t) ~= 0)) then
goto L182
end
v_f = tobit((tobit((clz32(v_t) + 33)) - clz32(v_e)))
v_a = tobit((0 - v_f))
goto L180
end
::L184::
v_A = tobit(toint(((tobit(v_e) % 4294967296) / 0)))
Iv = 0
goto L177
end
::L183::
v_t = tobit((32 - clz32(v_e)))
if ((tobit(v_t) % 4294967296) < 31) then
goto L181
end
goto L179
end
::L182::
if (1 == bor(0, v_t)) then
goto L178
end
v_t = ((v_t ~= 0) and tobit((31 - clz32(bxor((v_t - 1), v_t)))) or 32)
v_n = band(31, v_t)
if ((tobit(band(63, v_t)) % 4294967296) >= 32) then
v_e = 0
v_A = tobit((rshift(v_r, v_n) % 4294967296))
else
v_e = tobit((rshift(v_r, v_n) % 4294967296))
v_A = bor(lshift(band((lshift(1, v_n) - 1), v_r), (32 - v_n)), (rshift(v_A, v_n) % 4294967296))
end
Iv = v_e
goto L177
end
::L181::
v_f = tobit((v_t + 1))
v_a = tobit((63 - v_t))
end
::L180::
do
v_t = v_r
v_e = band(63, v_f)
v_o = band(31, v_e)
if ((tobit(v_e) % 4294967296) >= 32) then
v_e = 0
v_o = tobit((rshift(v_t, v_o) % 4294967296))
else
v_e = tobit((rshift(v_t, v_o) % 4294967296))
v_o = bor(lshift(band((lshift(1, v_o) - 1), v_t), (32 - v_o)), (rshift(v_A, v_o) % 4294967296))
end
v_a = band(v_a, 63)
v_t = band(31, v_a)
if ((tobit(v_a) % 4294967296) >= 32) then
v_r = lshift(v_A, v_t)
v_A = 0
else
v_r = bor(band((lshift(1, v_t) - 1), (rshift(v_A, (32 - v_t)) % 4294967296)), lshift(v_r, v_t))
v_A = lshift(v_A, v_t)
end
if (v_f ~= 0) then
do
do
do
local t246 = (-1)
v_t = tobit((v_n - 1))
v_a = ((t246 ~= bor(0, v_t)) and 0 or (-1))
end
while true do
do
v_i = bor(lshift(v_o, 1), (rshift(v_r, 31) % 4294967296))
v_u = v_i
local t249 = v_u
local t248 = v_n
local t247 = v_a
v_e = bor(lshift(v_e, 1), (rshift(v_o, 31) % 4294967296))
v_i = arshift((t247 - tobit((v_e + (((tobit(v_t) % 4294967296) < (tobit(v_i) % 4294967296)) and 1 or 0)))), 31)
v_c = band(t248, v_i)
v_o = tobit((t249 - v_c))
v_e = tobit((v_e - (((tobit(v_u) % 4294967296) < (tobit(v_c) % 4294967296)) and 1 or 0)))
v_r = bor(lshift(v_r, 1), (rshift(v_A, 31) % 4294967296))
v_A = bor(v_s, lshift(v_A, 1))
v_i = band(v_i, 1)
v_s = v_i
v_f = tobit((v_f - 1))
if not (v_f ~= 0) then goto B187 end
end
do
end
::C187::
end
end
::B187::
end
end
end
Iv = bor(lshift(v_r, 1), (rshift(v_A, 31) % 4294967296))
v_A = bor(v_i, lshift(v_A, 1))
goto L177
end
end
::L179::
end
v_A = 0
v_r = 0
end
end
::L178::
end
Iv = v_r
end
end
::L177::
end
do return v_A end
end

F.fX = function(v_A)
local v_r = 0
v_r = 0
if (v_A ~= 0) then
v_r = I32[arshift((v_A + 60), 2)]
if (v_r ~= 0) then
UA[I32[arshift((I32[arshift((I32[arshift(v_A, 2)] + 28), 2)] + 36), 2)]](v_r)
end
I8[bor(0, v_A)] = tobit(0)
I8[tobit((v_A + 1))] = tobit(0)
I8[tobit((v_A + 2))] = tobit(0)
I8[tobit((v_A + 3))] = tobit(0)
I8[tobit((v_A + 4))] = tobit(0)
I8[tobit((v_A + 5))] = tobit(0)
I8[tobit((v_A + 6))] = tobit(0)
I8[tobit((v_A + 7))] = tobit(0)
I8[tobit((v_A + 8))] = tobit(0)
I8[tobit((v_A + 9))] = tobit(0)
I8[tobit((v_A + 10))] = tobit(0)
I8[tobit((v_A + 11))] = tobit(0)
I8[tobit((v_A + 12))] = tobit(0)
I8[tobit((v_A + 13))] = tobit(0)
I8[tobit((v_A + 14))] = tobit(0)
I8[tobit((v_A + 15))] = tobit(0)
I8[tobit((v_A + 16))] = tobit(0)
I8[tobit((v_A + 17))] = tobit(0)
I8[tobit((v_A + 18))] = tobit(0)
I8[tobit((v_A + 19))] = tobit(0)
I8[tobit((v_A + 20))] = tobit(0)
I8[tobit((v_A + 21))] = tobit(0)
I8[tobit((v_A + 22))] = tobit(0)
I8[tobit((v_A + 23))] = tobit(0)
I8[tobit((v_A + 24))] = tobit(0)
I8[tobit((v_A + 25))] = tobit(0)
I8[tobit((v_A + 26))] = tobit(0)
I8[tobit((v_A + 27))] = tobit(0)
I8[tobit((v_A + 28))] = tobit(0)
I8[tobit((v_A + 29))] = tobit(0)
I8[tobit((v_A + 30))] = tobit(0)
I8[tobit((v_A + 31))] = tobit(0)
I8[tobit((v_A + 32))] = tobit(0)
I8[tobit((v_A + 33))] = tobit(0)
I8[tobit((v_A + 34))] = tobit(0)
I8[tobit((v_A + 35))] = tobit(0)
I8[tobit((v_A + 36))] = tobit(0)
I8[tobit((v_A + 37))] = tobit(0)
I8[tobit((v_A + 38))] = tobit(0)
I8[tobit((v_A + 39))] = tobit(0)
I8[tobit((v_A + 40))] = tobit(0)
I8[tobit((v_A + 41))] = tobit(0)
I8[tobit((v_A + 42))] = tobit(0)
I8[tobit((v_A + 43))] = tobit(0)
I8[tobit((v_A + 44))] = tobit(0)
I8[tobit((v_A + 45))] = tobit(0)
I8[tobit((v_A + 46))] = tobit(0)
I8[tobit((v_A + 47))] = tobit(0)
I8[tobit((v_A + 48))] = tobit(0)
I8[tobit((v_A + 49))] = tobit(0)
I8[tobit((v_A + 50))] = tobit(0)
I8[tobit((v_A + 51))] = tobit(0)
I8[tobit((v_A + 52))] = tobit(0)
I8[tobit((v_A + 53))] = tobit(0)
I8[tobit((v_A + 54))] = tobit(0)
I8[tobit((v_A + 55))] = tobit(0)
I8[tobit((v_A + 56))] = tobit(0)
I8[tobit((v_A + 57))] = tobit(0)
I8[tobit((v_A + 58))] = tobit(0)
I8[tobit((v_A + 59))] = tobit(0)
I8[tobit((v_A + 60))] = tobit(0)
I8[tobit((v_A + 61))] = tobit(0)
I8[tobit((v_A + 62))] = tobit(0)
I8[tobit((v_A + 63))] = tobit(0)
end
end

F.fZ = function(v_A, v_r)
local v_n, v_t = 0, 0
v_n = 0
v_t = 0
F.fJ(v_A, v_r)
v_r = I32[arshift(v_A, 2)]
v_n = I32[arshift((v_A + 4), 2)]
v_t = I32[arshift((v_A + 124), 2)]
I32[arshift(v_A, 2)] = tobit(I32[arshift((v_A + 120), 2)])
I32[arshift((v_A + 4), 2)] = tobit(v_t)
I32[arshift((v_A + 120), 2)] = tobit(v_r)
I32[arshift((v_A + 124), 2)] = tobit(v_n)
v_r = I32[arshift((v_A + 8), 2)]
v_n = I32[arshift((v_A + 12), 2)]
v_t = I32[arshift((v_A + 116), 2)]
I32[arshift((v_A + 8), 2)] = tobit(I32[arshift((v_A + 112), 2)])
I32[arshift((v_A + 12), 2)] = tobit(v_t)
I32[arshift((v_A + 112), 2)] = tobit(v_r)
I32[arshift((v_A + 116), 2)] = tobit(v_n)
v_r = I32[arshift((v_A + 104), 2)]
v_n = I32[arshift((v_A + 108), 2)]
v_t = I32[arshift((v_A + 20), 2)]
I32[arshift((v_A + 104), 2)] = tobit(I32[arshift((v_A + 16), 2)])
I32[arshift((v_A + 108), 2)] = tobit(v_t)
I32[arshift((v_A + 16), 2)] = tobit(v_r)
I32[arshift((v_A + 20), 2)] = tobit(v_n)
v_r = I32[arshift((v_A + 24), 2)]
I32[arshift((v_A + 24), 2)] = tobit(I32[arshift((v_A + 96), 2)])
I32[arshift((v_A + 96), 2)] = tobit(v_r)
v_r = I32[arshift((v_A + 100), 2)]
I32[arshift((v_A + 100), 2)] = tobit(I32[arshift((v_A + 28), 2)])
I32[arshift((v_A + 28), 2)] = tobit(v_r)
v_r = I32[arshift((v_A + 88), 2)]
I32[arshift((v_A + 88), 2)] = tobit(I32[arshift((v_A + 32), 2)])
I32[arshift((v_A + 32), 2)] = tobit(v_r)
v_r = I32[arshift((v_A + 92), 2)]
I32[arshift((v_A + 92), 2)] = tobit(I32[arshift((v_A + 36), 2)])
I32[arshift((v_A + 36), 2)] = tobit(v_r)
v_r = I32[arshift((v_A + 80), 2)]
I32[arshift((v_A + 80), 2)] = tobit(I32[arshift((v_A + 40), 2)])
I32[arshift((v_A + 40), 2)] = tobit(v_r)
v_r = I32[arshift((v_A + 84), 2)]
I32[arshift((v_A + 84), 2)] = tobit(I32[arshift((v_A + 44), 2)])
I32[arshift((v_A + 44), 2)] = tobit(v_r)
v_r = I32[arshift((v_A + 72), 2)]
I32[arshift((v_A + 72), 2)] = tobit(I32[arshift((v_A + 48), 2)])
I32[arshift((v_A + 48), 2)] = tobit(v_r)
v_r = I32[arshift((v_A + 76), 2)]
I32[arshift((v_A + 76), 2)] = tobit(I32[arshift((v_A + 52), 2)])
I32[arshift((v_A + 52), 2)] = tobit(v_r)
v_r = I32[arshift((v_A + 64), 2)]
I32[arshift((v_A + 64), 2)] = tobit(I32[arshift((v_A + 56), 2)])
I32[arshift((v_A + 56), 2)] = tobit(v_r)
v_r = I32[arshift((v_A + 68), 2)]
I32[arshift((v_A + 68), 2)] = tobit(I32[arshift((v_A + 60), 2)])
I32[arshift((v_A + 60), 2)] = tobit(v_r)
do return 0 end
end

F.f_ = function(v_A, v_r, v_n, v_e)
local v_o, v_a, v_u, v_c = 0, 0, 0, 0
v_o = 0
v_a = 0
v_u = 0
v_c = 0
v_a = bor(bor(bor(U8[tobit((v_n + 4))], lshift(U8[tobit((v_n + 5))], 8)), lshift(U8[tobit((v_n + 6))], 16)), lshift(U8[tobit((v_n + 7))], 24))
v_a = bor(bor(bor(lshift(v_a, 24), band(lshift(v_a, 8), 16711680)), band((rshift(v_a, 8) % 4294967296), 65280)), (rshift(v_a, 24) % 4294967296))
v_n = bor(bor(bor(U8[bor(0, v_n)], lshift(U8[tobit((v_n + 1))], 8)), lshift(U8[tobit((v_n + 2))], 16)), lshift(U8[tobit((v_n + 3))], 24))
v_u = bor(bor(bor(lshift(v_n, 24), band(lshift(v_n, 8), 16711680)), band((rshift(v_n, 8) % 4294967296), 65280)), (rshift(v_n, 24) % 4294967296))
if (v_r ~= 0) then
do
v_r = 0
v_n = tobit((v_A + 72))
while true do
v_o = bxor(I32[arshift((lshift(v_r, 2) + v_A), 2)], v_u)
v_u = bxor((bxor((I32[arshift((1024 + tobit((v_n + band((rshift(v_o, 14) % 4294967296), 1020)))), 2)] + I32[arshift((v_n + band((rshift(v_o, 22) % 4294967296), 1020)), 2)]), I32[arshift((2048 + tobit((v_n + band((rshift(v_o, 6) % 4294967296), 1020)))), 2)]) + I32[arshift((3072 + tobit((v_n + lshift(band(255, v_o), 2)))), 2)]), v_a)
v_a = v_o
v_r = tobit((v_r + 1))
if not (16 ~= bor(0, v_r)) then goto B188 end
do
end
::C188::
end
end
::B188::
v_n = bxor(I32[arshift((v_A + 64), 2)], v_u)
v_A = tobit((v_A + 68))
else
do
v_n = 17
v_c = tobit((v_A + 72))
while true do
v_o = bxor(I32[arshift((lshift(v_n, 2) + v_A), 2)], v_u)
v_u = bxor((bxor((I32[arshift((1024 + tobit((band((rshift(v_o, 14) % 4294967296), 1020) + v_c))), 2)] + I32[arshift((band((rshift(v_o, 22) % 4294967296), 1020) + v_c), 2)]), I32[arshift((2048 + tobit((band((rshift(v_o, 6) % 4294967296), 1020) + v_c))), 2)]) + I32[arshift((3072 + tobit((lshift(band(255, v_o), 2) + v_c))), 2)]), v_a)
v_r = (((tobit(v_n) % 4294967296) > 2) and 1 or 0)
v_n = tobit((v_n - 1))
v_a = v_o
if not (v_r ~= 0) then goto B189 end
do
end
::C189::
end
end
::B189::
v_n = bxor(I32[arshift((v_A + 4), 2)], v_u)
end
v_A = I32[arshift(v_A, 2)]
I8[tobit((v_e + 7))] = tobit(v_n)
I8[tobit((v_e + 6))] = tobit((rshift(v_n, 8) % 4294967296))
I8[tobit((v_e + 5))] = tobit((rshift(v_n, 16) % 4294967296))
I8[tobit((v_e + 4))] = tobit((rshift(v_n, 24) % 4294967296))
v_A = bxor(v_A, v_o)
I8[tobit((v_e + 3))] = tobit(v_A)
I8[tobit((v_e + 2))] = tobit((rshift(v_A, 8) % 4294967296))
I8[tobit((v_e + 1))] = tobit((rshift(v_A, 16) % 4294967296))
I8[bor(0, v_e)] = tobit((rshift(v_A, 24) % 4294967296))
do return 0 end
end

F.fS_ = function(v_A, v_r, v_n, v_e)
local v_o, v_a, v_u, v_c, v_s, v_l = 0, 0, 0, 0, 0, 0
v_l = 0
v_o = tobit((B - 400))
B = v_o
v_l = tobit((v_r + 1))
v_s = F.fOA(F.fI(v_l), 0, v_l)
F.fTA(tobit((v_o + 8)))
F.fU(tobit((v_o + 8)), 2, v_e, 256)
v_a = tobit((B - 16))
B = v_a
I32[arshift((v_a + 12), 2)] = tobit(0)
v_l = tobit((v_o + 8))
v_e = v_l
I32[arshift((352 + v_e), 2)] = tobit(0)
I32[arshift((v_e + 356), 2)] = tobit(0)
I32[arshift((v_e + 384), 2)] = tobit(0)
I32[arshift((v_e + 320), 2)] = tobit(0)
I32[arshift((v_e + 324), 2)] = tobit(0)
I32[arshift((v_e + 376), 2)] = tobit(0)
I32[arshift((v_e + 380), 2)] = tobit(0)
I32[arshift((v_e + 368), 2)] = tobit(0)
I32[arshift((v_e + 372), 2)] = tobit(0)
I32[arshift((v_e + 360), 2)] = tobit(0)
I32[arshift((v_e + 364), 2)] = tobit(0)
I32[arshift((v_e + 328), 2)] = tobit(0)
I32[arshift((v_e + 332), 2)] = tobit(0)
v_u = bor(bor(bor(U8[tobit((v_n + 4))], lshift(U8[tobit((v_n + 5))], 8)), lshift(U8[tobit((v_n + 6))], 16)), lshift(U8[tobit((v_n + 7))], 24))
v_e = tobit((v_e + 352))
v_c = bor(bor(bor(U8[bor(0, v_n)], lshift(U8[tobit((v_n + 1))], 8)), lshift(U8[tobit((v_n + 2))], 16)), lshift(U8[tobit((v_n + 3))], 24))
I8[bor(0, v_e)] = tobit(v_c)
I8[tobit((v_e + 1))] = tobit((rshift(v_c, 8) % 4294967296))
I8[tobit((v_e + 2))] = tobit((rshift(v_c, 16) % 4294967296))
I8[tobit((v_e + 3))] = tobit((rshift(v_c, 24) % 4294967296))
I8[tobit((v_e + 4))] = tobit(v_u)
I8[tobit((v_e + 5))] = tobit((rshift(v_u, 8) % 4294967296))
I8[tobit((v_e + 6))] = tobit((rshift(v_u, 16) % 4294967296))
I8[tobit((v_e + 7))] = tobit((rshift(v_u, 24) % 4294967296))
v_n = bor(bor(bor(U8[tobit((v_n + 8))], lshift(U8[tobit((v_n + 9))], 8)), lshift(U8[tobit((v_n + 10))], 16)), lshift(U8[tobit((v_n + 11))], 24))
I8[tobit((v_e + 8))] = tobit(v_n)
I8[tobit((v_e + 9))] = tobit((rshift(v_n, 8) % 4294967296))
I8[tobit((v_e + 10))] = tobit((rshift(v_n, 16) % 4294967296))
I8[tobit((v_e + 11))] = tobit((rshift(v_n, 24) % 4294967296))
I8[tobit((v_l + 367))] = tobit(1)
if not (F.fK(v_l, v_e, tobit((v_l + 336)), tobit((v_a + 12))) ~= 0) then
I32[arshift((v_l + 328), 2)] = tobit(0)
I32[arshift((v_l + 332), 2)] = tobit(0)
end
B = tobit((v_a + 16))
F.fF(tobit((v_o + 8)), v_r, v_A, v_s)
F.fpA(tobit((v_o + 8)))
B = tobit((v_o + 400))
do return v_s end
end

F.fAA = function(v_A)
local v_r, v_n, v_t, v_e, v_o, v_f, v_a = 0, 0, 0, 0, 0, 0, 0
v_n = 0
v_t = 0
v_e = 0
v_o = 0
v_f = 0
v_a = 0
do
v_r = tobit((B - 16))
B = v_r
v_o = 1
v_e = I32[arshift(v_A, 2)]
v_a = lshift(v_e, 1)
v_t = v_a
while true do
v_f = v_n
if not (v_t ~= 0) then goto B190 end
do
v_t = band(v_t, (v_t - 1))
v_n = tobit((v_n + 1))
end
::C190::
end
end
::B190::
do
do
do
local t250 = (1 == bor(0, v_f))
if t250 then
v_n = F.fBA(v_a, 16)
I32[arshift((v_r + 8), 2)] = tobit(v_n)
t250 = (v_n ~= 0)
end
if t250 then
v_f = 0
I32[arshift((v_r + 4), 2)] = tobit(0)
I32[arshift(v_r, 2)] = tobit(v_a)
if (v_e ~= 0) then
do
while true do
do
v_n = tobit((I32[arshift((v_A + 8), 2)] + lshift(v_f, 4)))
if (I32[arshift((v_n + 8), 2)] ~= 0) then
v_a = I32[arshift((v_n + 12), 2)]
v_o = I32[arshift((v_n + 4), 2)]
v_e = I32[arshift(v_n, 2)]
do
do
while true do
do
if (F.fN(v_r, v_e, v_o, tobit((v_r + 12))) ~= 0) then
goto L193
end
if (F.fAA(v_r) ~= 0) then
goto B194
end
end
::C194::
end
end
::B194::
v_o = 1
goto L191
end
::L193::
v_t = tobit((I32[arshift((v_r + 8), 2)] + lshift(I32[arshift((v_r + 12), 2)], 4)))
I32[arshift((v_t + 8), 2)] = tobit(1)
I32[arshift((v_t + 4), 2)] = tobit(v_o)
I32[arshift(v_t, 2)] = tobit(v_e)
I32[arshift((v_t + 12), 2)] = tobit(v_a)
I32[arshift((v_r + 4), 2)] = tobit((I32[arshift((v_r + 4), 2)] + 1))
I32[arshift((v_n + 8), 2)] = tobit(0)
I32[arshift((v_n + 12), 2)] = tobit(0)
I32[arshift(v_n, 2)] = tobit(0)
I32[arshift((v_n + 4), 2)] = tobit(0)
I32[arshift((v_A + 4), 2)] = tobit((I32[arshift((v_A + 4), 2)] - 1))
v_e = I32[arshift(v_A, 2)]
end
v_f = tobit((v_f + 1))
if (not ((tobit(v_f) % 4294967296) < (tobit(v_e) % 4294967296))) then
goto B192
end
end
::C192::
end
end
::B192::
end
F.fR(I32[arshift((v_A + 8), 2)])
I32[arshift((v_A + 8), 2)] = tobit(I32[arshift((v_r + 8), 2)])
v_n = I32[arshift((v_r + 4), 2)]
I32[arshift(v_A, 2)] = tobit(I32[arshift(v_r, 2)])
I32[arshift((v_A + 4), 2)] = tobit(v_n)
v_o = 0
end
end
end
::L191::
end
B = tobit((v_r + 16))
do return v_o end
end

F.frA = function(v_A, v_r, v_n, v_e)

do
if (not ((tobit(v_r) % 4294967296) > 20)) then
do
local sw196 = tobit((v_r - 9))
if sw196 == 0 then goto K196_0
elseif sw196 == 1 then goto K196_1
elseif sw196 == 2 then goto K196_2
elseif sw196 == 3 then goto K196_3
elseif sw196 == 4 then goto K196_4
elseif sw196 == 5 then goto K196_5
elseif sw196 == 6 then goto K196_6
elseif sw196 == 7 then goto K196_7
elseif sw196 == 8 then goto K196_8
elseif sw196 == 9 then goto K196_9
else goto K196_10 end
::K196_0::
do
v_r = I32[arshift(v_n, 2)]
I32[arshift(v_n, 2)] = tobit((v_r + 4))
I32[arshift(v_A, 2)] = tobit(I32[arshift(v_r, 2)])
do return end
end
::K196_1::
do
v_r = I32[arshift(v_n, 2)]
I32[arshift(v_n, 2)] = tobit((v_r + 4))
v_r = I32[arshift(v_r, 2)]
I32[arshift(v_A, 2)] = tobit(v_r)
I32[arshift((v_A + 4), 2)] = tobit(arshift(v_r, 31))
do return end
end
::K196_2::
do
v_r = I32[arshift(v_n, 2)]
I32[arshift(v_n, 2)] = tobit((v_r + 4))
I32[arshift(v_A, 2)] = tobit(I32[arshift(v_r, 2)])
I32[arshift((v_A + 4), 2)] = tobit(0)
do return end
end
::K196_3::
do
v_r = band((I32[arshift(v_n, 2)] + 7), (-8))
I32[arshift(v_n, 2)] = tobit((v_r + 8))
v_n = I32[arshift((v_r + 4), 2)]
I32[arshift(v_A, 2)] = tobit(I32[arshift(v_r, 2)])
I32[arshift((v_A + 4), 2)] = tobit(v_n)
do return end
end
::K196_4::
do
v_r = I32[arshift(v_n, 2)]
I32[arshift(v_n, 2)] = tobit((v_r + 4))
v_r = I16[arshift(v_r, 1)]
I32[arshift(v_A, 2)] = tobit(v_r)
I32[arshift((v_A + 4), 2)] = tobit(arshift(v_r, 31))
do return end
end
::K196_5::
do
v_r = I32[arshift(v_n, 2)]
I32[arshift(v_n, 2)] = tobit((v_r + 4))
I32[arshift(v_A, 2)] = tobit(U16[arshift(v_r, 1)])
I32[arshift((v_A + 4), 2)] = tobit(0)
do return end
end
::K196_6::
do
v_r = I32[arshift(v_n, 2)]
I32[arshift(v_n, 2)] = tobit((v_r + 4))
v_r = I8[bor(0, v_r)]
I32[arshift(v_A, 2)] = tobit(v_r)
I32[arshift((v_A + 4), 2)] = tobit(arshift(v_r, 31))
do return end
end
::K196_7::
do
v_r = I32[arshift(v_n, 2)]
I32[arshift(v_n, 2)] = tobit((v_r + 4))
I32[arshift(v_A, 2)] = tobit(U8[bor(0, v_r)])
I32[arshift((v_A + 4), 2)] = tobit(0)
do return end
end
::K196_8::
do
v_r = band((I32[arshift(v_n, 2)] + 7), (-8))
I32[arshift(v_n, 2)] = tobit((v_r + 8))
F64[arshift(v_A, 3)] = F64[arshift(v_r, 3)]
do return end
end
::K196_9::
do
goto S196
end
::K196_10::
do
goto L195
end
end
::S196::
UA[bor(0, v_e)](v_A, v_n)
end
end
::L195::
end

F.fnA = function(v_A, v_r, v_n)
local v_e, v_o, v_a, v_u = 0, 0, 0, 0
v_e = 0
v_o = 0
v_a = 0
v_u = 0
do
if (not (band(32, U8[bor(0, v_A)]) ~= 0)) then
do
do
do
v_o = v_r
v_r = v_n
do
do
do
v_e = v_A
v_A = I32[arshift((v_e + 16), 2)]
if (not (v_A ~= 0)) then
v_A = U8[tobit((v_e + 74))]
I8[tobit((v_e + 74))] = tobit(bor((v_A - 1), v_A))
v_A = I32[arshift(v_e, 2)]
if (band(8, v_A) ~= 0) then
I32[arshift(v_e, 2)] = tobit(bor(32, v_A))
v_A = (-1)
else
I32[arshift((v_e + 4), 2)] = tobit(0)
I32[arshift((v_e + 8), 2)] = tobit(0)
v_A = I32[arshift((v_e + 44), 2)]
I32[arshift((v_e + 28), 2)] = tobit(v_A)
I32[arshift((v_e + 20), 2)] = tobit(v_A)
I32[arshift((v_e + 16), 2)] = tobit((v_A + I32[arshift((v_e + 48), 2)]))
v_A = 0
end
if (v_A ~= 0) then
goto L198
end
v_A = I32[arshift((v_e + 16), 2)]
end
do
local t251 = v_A
v_u = I32[arshift((v_e + 20), 2)]
if ((tobit((t251 - v_u)) % 4294967296) < (tobit(v_r) % 4294967296)) then
UA[I32[arshift((v_e + 36), 2)]](v_e, v_o, v_n)
goto L197
end
end
do
do
do
if (I8[tobit((v_e + 75))] > (-1)) then
do
do
do
v_A = v_n
while true do
do
do
v_r = v_A
v_a = v_n
if (not (v_A ~= 0)) then
goto L199
end
do
local t252 = v_o
v_A = tobit((v_r - 1))
if (10 == U8[tobit((t252 + v_A))]) then
goto B200
end
end
end
end
::C200::
end
end
::B200::
end
if ((tobit(UA[I32[arshift((v_e + 36), 2)]](v_e, v_o, v_r)) % 4294967296) < (tobit(v_r) % 4294967296)) then
goto L198
end
v_o = tobit((v_r + v_o))
v_u = I32[arshift((v_e + 20), 2)]
v_a = tobit((v_n - v_r))
end
else
v_a = v_n
end
end
end
::L199::
end
do
local t253 = v_u
local t254 = v_o
v_r = v_a
F.fQA(t253, t254, v_r)
I32[arshift((v_e + 20), 2)] = tobit((v_r + I32[arshift((v_e + 20), 2)]))
end
end
end
::L198::
end
end
end
::L197::
end
end
end
end

F.ftA = function(v_A, v_r, v_n, v_e, v_o)
local v_f, v_a = 0, 0
v_a = 0
v_f = tobit((B - 208))
B = v_f
I32[arshift((v_f + 204), 2)] = tobit(v_n)
F.fOA(tobit((v_f + 160)), 0, 40)
I32[arshift((v_f + 200), 2)] = tobit(I32[arshift((v_f + 204), 2)])
if not (bor(0, F.fQ(0, v_r, tobit((v_f + 200)), tobit((v_f + 80)), tobit((v_f + 160)), v_e, v_o)) < 0) then
v_n = I32[arshift(v_A, 2)]
if (I8[tobit((v_A + 74))] <= 0) then
I32[arshift(v_A, 2)] = tobit(band((-33), v_n))
end
v_a = band(32, v_n)
if (I32[arshift((v_A + 48), 2)] ~= 0) then
F.fQ(v_A, v_r, tobit((v_f + 200)), tobit((v_f + 80)), tobit((v_f + 160)), v_e, v_o)
else
I32[arshift((v_A + 48), 2)] = tobit(80)
I32[arshift((v_A + 16), 2)] = tobit((v_f + 80))
I32[arshift((v_A + 28), 2)] = tobit(v_f)
I32[arshift((v_A + 20), 2)] = tobit(v_f)
v_n = I32[arshift((v_A + 44), 2)]
I32[arshift((v_A + 44), 2)] = tobit(v_f)
F.fQ(v_A, v_r, tobit((v_f + 200)), tobit((v_f + 80)), tobit((v_f + 160)), v_e, v_o)
if (v_n ~= 0) then
UA[I32[arshift((v_A + 36), 2)]](v_A, 0, 0)
I32[arshift((v_A + 48), 2)] = tobit(0)
I32[arshift((v_A + 44), 2)] = tobit(v_n)
I32[arshift((v_A + 28), 2)] = tobit(0)
I32[arshift((v_A + 16), 2)] = tobit(0)
I32[arshift((v_A + 20), 2)] = tobit(0)
end
end
I32[arshift(v_A, 2)] = tobit(bor(I32[arshift(v_A, 2)], v_a))
end
B = tobit((v_f + 208))
end

F.feA = function(v_A, v_r)

if (not (v_A ~= 0)) then
do return 0 end
end
do
do
do
do
do
do
do
if (v_A ~= 0) then
do
if ((tobit(v_r) % 4294967296) <= 127) then
goto L202
end
do
if (I32[arshift(I32[3441], 2)] ~= 0) then
do
if ((tobit(v_r) % 4294967296) <= 2047) then
I8[tobit((v_A + 1))] = tobit(bor(band(63, v_r), 128))
I8[bor(0, v_A)] = tobit(bor((rshift(v_r, 6) % 4294967296), 192))
v_A = 2
goto L201
end
do
local t255 = ((57344 ~= band((-8192), v_r)) and 1 or 0)
if t255 ~= 0 then
t255 = (((tobit(v_r) % 4294967296) >= 55296) and 1 or 0)
end
if (not (t255 ~= 0)) then
I8[tobit((v_A + 2))] = tobit(bor(band(63, v_r), 128))
I8[bor(0, v_A)] = tobit(bor((rshift(v_r, 12) % 4294967296), 224))
I8[tobit((v_A + 1))] = tobit(bor(band((rshift(v_r, 6) % 4294967296), 63), 128))
v_A = 3
goto L201
end
end
if ((tobit((v_r - 65536)) % 4294967296) <= 1048575) then
I8[tobit((v_A + 3))] = tobit(bor(band(63, v_r), 128))
I8[bor(0, v_A)] = tobit(bor((rshift(v_r, 18) % 4294967296), 240))
I8[tobit((v_A + 2))] = tobit(bor(band((rshift(v_r, 6) % 4294967296), 63), 128))
I8[tobit((v_A + 1))] = tobit(bor(band((rshift(v_r, 12) % 4294967296), 63), 128))
v_A = 4
goto L201
end
end
else
if (57216 == band((-128), v_r)) then
goto L202
end
end
end
I32[5460] = tobit(25)
v_A = (-1)
end
else
v_A = 1
end
end
goto L201
end
end
::L202::
end
I8[bor(0, v_A)] = tobit(v_r)
v_A = 1
end
end
::L201::
end
do return v_A end
end

F.foA = function(v_A, v_r, v_n, v_t, v_e)
local v_o, v_a, v_u = 0, 0, 0
v_a = 0
v_u = 0
v_o = tobit((B - 288))
B = v_o
v_a = tobit((v_r + 1))
v_a = F.fOA(F.fI(v_a), 0, v_a)
F.fMA(tobit((v_o + 8)))
F.fH(tobit((v_o + 8)), v_t, 256)
F.fM(tobit((v_o + 8)), 0, v_r, v_n, v_A, v_a)
F.fvA(tobit((v_o + 8)))
do
do
do
if (not (bor(band(15, v_r), (((tobit(v_r) % 4294967296) < 16) and 1 or 0)) ~= 0)) then
do
local t256 = v_a
v_A = tobit((v_r - 1))
v_n = U8[tobit((t256 + v_A))]
if ((tobit(band((v_n - 1), 255)) % 4294967296) > 15) then
v_u = v_r
else
do
if (not ((tobit(v_r) % 4294967296) <= (tobit(v_n) % 4294967296))) then
do
v_r = 2
if ((tobit(v_n) % 4294967296) < 2) then
v_u = v_A
else
do
do
do
while true do
do
do
do
local t258 = bor(0, v_n)
local t257 = v_a
v_A = tobit((v_A - 1))
if (t258 ~= U8[tobit((t257 + v_A))]) then
goto L203
end
end
if (not ((tobit(band(255, v_r)) % 4294967296) < (tobit(v_n) % 4294967296))) then
goto B204
end
v_r = tobit((v_r + 1))
end
end
::C204::
end
end
::B204::
end
v_u = v_A
end
end
end
end
end
end
end
end
end
end
::L203::
end
if (v_e ~= 0) then
I32[arshift(v_e, 2)] = tobit(v_u)
end
v_A = F.fI(tobit((v_u + 1)))
F.fOA(tobit((v_A + v_u)), 0, (((-1) ~= bor(0, v_u)) and 1 or 0))
v_A = F.fQA(v_A, v_a, v_u)
F.fR(v_a)
B = tobit((v_o + 288))
do return v_A end
end

F.fiA = function(v_A, v_r, v_n, v_t, v_e)
local v_o, v_a, v_u = 0, 0, 0
v_a = 0
v_u = 0
v_o = tobit((B - 128))
B = v_o
v_a = tobit((v_r + 1))
v_a = F.fOA(F.fI(v_a), 0, v_a)
F.fRA(v_o)
F.fZ(v_o, v_t)
F.fz(v_o, 0, v_r, v_n, v_A, v_a)
F.fL(v_o)
do
do
do
if (not (bor(band(7, v_r), (((tobit(v_r) % 4294967296) < 8) and 1 or 0)) ~= 0)) then
do
local t259 = v_a
v_A = tobit((v_r - 1))
v_n = U8[tobit((t259 + v_A))]
if ((tobit(band((v_n - 1), 255)) % 4294967296) > 7) then
v_u = v_r
else
do
if (not ((tobit(v_r) % 4294967296) <= (tobit(v_n) % 4294967296))) then
do
v_r = 2
if ((tobit(v_n) % 4294967296) < 2) then
v_u = v_A
else
do
do
do
while true do
do
do
do
local t261 = bor(0, v_n)
local t260 = v_a
v_A = tobit((v_A - 1))
if (t261 ~= U8[tobit((t260 + v_A))]) then
goto L205
end
end
if (not ((tobit(band(255, v_r)) % 4294967296) < (tobit(v_n) % 4294967296))) then
goto B206
end
v_r = tobit((v_r + 1))
end
end
::C206::
end
end
::B206::
end
v_u = v_A
end
end
end
end
end
end
end
end
end
end
::L205::
end
if (v_e ~= 0) then
I32[arshift(v_e, 2)] = tobit(v_u)
end
v_A = F.fI(tobit((v_u + 1)))
F.fOA(tobit((v_A + v_u)), 0, (((-1) ~= bor(0, v_u)) and 1 or 0))
v_A = F.fQA(v_A, v_a, v_u)
F.fR(v_a)
B = tobit((v_o + 128))
do return v_A end
end

F.ffA = function(v_A, v_r)
local v_n, v_e = 0, 0
v_n = 0
v_e = 0
do
do
do
do
v_e = v_A
if (not (band(3, bxor(v_e, v_r)) ~= 0)) then
do
if (band(3, v_r) ~= 0) then
do
while true do
do
v_n = U8[bor(0, v_r)]
I8[bor(0, v_e)] = tobit(v_n)
if (not (v_n ~= 0)) then
goto L207
end
v_e = tobit((v_e + 1))
v_r = tobit((v_r + 1))
if (not (band(3, v_r) ~= 0)) then
goto B208
end
end
::C208::
end
end
::B208::
end
do
local t262 = (-1)
v_n = I32[arshift(v_r, 2)]
if (not (band(band(bxor(t262, v_n), (v_n - 16843009)), (-2139062144)) ~= 0)) then
do
while true do
I32[arshift(v_e, 2)] = tobit(v_n)
v_n = I32[arshift((v_r + 4), 2)]
v_e = tobit((v_e + 4))
v_r = tobit((v_r + 4))
if not (not (band(band((v_n - 16843009), bxor((-1), v_n)), (-2139062144)) ~= 0)) then goto B209 end
do
end
::C209::
end
end
::B209::
end
end
end
end
end
v_n = U8[bor(0, v_r)]
I8[bor(0, v_e)] = tobit(v_n)
if (v_n ~= 0) then
do
while true do
v_n = U8[tobit((v_r + 1))]
I8[tobit((v_e + 1))] = tobit(v_n)
v_e = tobit((v_e + 1))
v_r = tobit((v_r + 1))
if not (v_n ~= 0) then goto B210 end
do
end
::C210::
end
end
::B210::
end
end
end
::L207::
end
do return v_A end
end

F.faA = function(v_A, v_r)
local v_n = 0
v_n = 0
v_n = (-24832)
if (not (bor(((not (v_r ~= 0)) and 1 or 0), ((not (v_A ~= 0)) and 1 or 0)) ~= 0)) then
v_n = v_A
I32[arshift(v_n, 2)] = tobit(0)
I32[arshift((v_n + 4), 2)] = tobit(0)
I32[arshift((v_n + 56), 2)] = tobit(0)
I32[arshift((v_n + 60), 2)] = tobit(0)
I32[arshift((v_n + 48), 2)] = tobit(0)
I32[arshift((v_n + 52), 2)] = tobit(0)
I32[arshift((v_n + 40), 2)] = tobit(0)
I32[arshift((v_n + 44), 2)] = tobit(0)
I32[arshift((v_n + 32), 2)] = tobit(0)
I32[arshift((v_n + 36), 2)] = tobit(0)
I32[arshift((v_n + 24), 2)] = tobit(0)
I32[arshift((v_n + 28), 2)] = tobit(0)
I32[arshift((v_n + 16), 2)] = tobit(0)
I32[arshift((v_n + 20), 2)] = tobit(0)
I32[arshift((v_n + 8), 2)] = tobit(0)
I32[arshift((v_n + 12), 2)] = tobit(0)
v_n = bor(0, UA[I32[arshift((I32[arshift((v_r + 28), 2)] + 32), 2)]]())
I32[arshift((v_A + 60), 2)] = tobit(v_n)
if (not (v_n ~= 0)) then
do return (-24960) end
end
I32[arshift(v_A, 2)] = tobit(v_r)
v_n = 0
if (2 == I32[arshift((v_r + 4), 2)]) then
I32[arshift((v_A + 16), 2)] = tobit(53)
I32[arshift((v_A + 12), 2)] = tobit(54)
end
end
do return v_n end
end

F.fuA = function(v_A)
local v_r, v_n, v_e, v_o, v_i = 0, 0, 0, 0, 0
do
v_r = 0
v_n = 0
v_e = 0
v_o = 0
v_i = 0
while true do
v_r = v_A
v_A = tobit((v_r + 1))
v_n = I8[bor(0, v_r)]
if not (bor(((32 == bor(0, v_n)) and 1 or 0), (((tobit((v_n - 9)) % 4294967296) < 5) and 1 or 0)) ~= 0) then goto B211 end
do
end
::C211::
end
end
::B211::
do
do
v_n = I8[bor(0, v_r)]
do
local sw214 = tobit((v_n - 43))
if sw214 == 0 then goto K214_0
elseif sw214 == 2 then goto K214_1
else goto K214_2 end
::K214_0::
do
goto L213
end
::K214_1::
do
goto S214
end
::K214_2::
do
goto L212
end
end
::S214::
v_o = 1
end
::L213::
v_n = I8[bor(0, v_A)]
v_r = v_A
v_i = v_o
end
::L212::
do
if (F.fPA(v_n) ~= 0) then
do
v_A = 0
while true do
do
v_e = tobit((48 + tobit((v_A - I8[bor(0, v_r)]))))
if (not (F.fPA(I8[tobit((v_r + 1))]) ~= 0)) then
goto L215
end
v_r = tobit((v_r + 1))
v_A = imul(v_e, 10)
end
::C216::
end
end
::B216::
end
end
::L215::
do return ((v_i ~= 0) and v_e or tobit((0 - v_e))) end
end

F.fcA = function(v_A, v_r, v_n)
local v_t, v_e = 0, 0
v_t = 0
v_e = 0
do
F.fJ(v_A, v_n)
F.fJ(tobit((v_r + 128)), tobit((v_n + 8)))
F.fJ(tobit((v_A + 256)), tobit((v_n + 16)))
v_n = 0
while true do
v_t = lshift(v_n, 2)
v_e = tobit((v_t + v_r))
I32[arshift(v_e, 2)] = tobit(I32[arshift((lshift((94 - v_n), 2) + v_A), 2)])
I32[arshift((bor(4, v_t) + v_r), 2)] = tobit(I32[arshift((lshift((95 - v_n), 2) + v_A), 2)])
v_t = tobit((v_A + v_t))
I32[arshift((128 + v_t), 2)] = tobit(I32[arshift((lshift((62 - v_n), 2) + v_r), 2)])
I32[arshift((v_t + 132), 2)] = tobit(I32[arshift((lshift((63 - v_n), 2) + v_r), 2)])
I32[arshift((v_e + 256), 2)] = tobit(I32[arshift((lshift((30 - v_n), 2) + v_A), 2)])
I32[arshift((v_e + 260), 2)] = tobit(I32[arshift((lshift((31 - v_n), 2) + v_A), 2)])
v_t = (((tobit(v_n) % 4294967296) < 30) and 1 or 0)
v_n = tobit((v_n + 2))
if not (v_t ~= 0) then goto B217 end
do
end
::C217::
end
end
::B217::
end

F.fsA = function(v_A, v_r)
local v_n, v_e, v_o = 0, 0, 0
v_o = 0
v_e = tobit((B - 16))
B = v_e
I32[arshift((v_e + 12), 2)] = tobit(v_r)
v_n = tobit((B - 160))
B = v_n
F.fQA(tobit((v_n + 8)), 1616, 144)
I32[arshift((v_n + 52), 2)] = tobit(v_A)
I32[arshift((v_n + 28), 2)] = tobit(v_A)
v_o = tobit(((-2) - v_A))
v_o = (((tobit(v_o) % 4294967296) < 2147483647) and v_o or 2147483647)
I32[arshift((v_n + 56), 2)] = tobit(v_o)
v_A = tobit((v_A + v_o))
I32[arshift((v_n + 36), 2)] = tobit(v_A)
I32[arshift((v_n + 24), 2)] = tobit(v_A)
F.ftA(tobit((v_n + 8)), 1058, v_r, 0, 0)
if (v_o ~= 0) then
v_A = I32[arshift((v_n + 28), 2)]
I8[tobit((v_A - ((bor(0, v_A) == I32[arshift((v_n + 24), 2)]) and 1 or 0)))] = tobit(0)
end
B = tobit((v_n + 160))
B = tobit((v_e + 16))
end

F.flA = function(v_A)
local v_r, v_n, v_t = 0, 0, 0
v_r = 0
v_n = 0
v_t = 0
do
do
do
v_r = v_A
if (band(3, v_r) ~= 0) then
do
while true do
do
if (not (U8[bor(0, v_r)] ~= 0)) then
goto L218
end
v_r = tobit((v_r + 1))
if (not (band(3, v_r) ~= 0)) then
goto B219
end
end
::C219::
end
end
::B219::
end
do
do
while true do
do
v_n = v_r
v_r = tobit((v_r + 4))
local t263 = (-1)
v_t = I32[arshift(v_n, 2)]
if not (not (band(band(bxor(t263, v_t), (v_t - 16843009)), (-2139062144)) ~= 0)) then goto B220 end
end
do
end
::C220::
end
end
::B220::
end
if (not (band(255, v_t) ~= 0)) then
do return tobit((v_n - v_A)) end
end
do
while true do
v_t = U8[tobit((v_n + 1))]
v_r = tobit((v_n + 1))
v_n = v_r
if not (v_t ~= 0) then goto B221 end
do
end
::C221::
end
end
::B221::
end
end
::L218::
end
do return tobit((v_r - v_A)) end
end

F.fbA = function(v_A, v_r, v_n)
local v_e, v_o, v_i = 0, 0, 0
v_e = 0
v_o = 0
v_i = 0
if ((tobit(v_r) % 4294967296) < 1) then
v_e = v_A
else
do
while true do
v_e = F.fq(v_A, v_r, 10)
v_o = Iv
v_i = v_o
v_o = F.fhA(v_e, v_o, 10, 0)
v_n = tobit((v_n - 1))
I8[bor(0, v_n)] = tobit(bor((v_A - v_o), 48))
v_o = (((tobit(v_r) % 4294967296) > 9) and 1 or 0)
v_A = v_e
v_r = v_i
if not (v_o ~= 0) then goto B222 end
do
end
::C222::
end
end
::B222::
end
if (v_e ~= 0) then
do
while true do
v_A = tobit(toint(((tobit(v_e) % 4294967296) / 10)))
v_n = tobit((v_n - 1))
I8[bor(0, v_n)] = tobit(bor((v_e - imul(v_A, 10)), 48))
v_r = (((tobit(v_e) % 4294967296) > 9) and 1 or 0)
v_e = v_A
if not (v_r ~= 0) then goto B223 end
do
end
::C223::
end
end
::B223::
end
do return v_n end
end

F.fvA = function(v_A)
local v_r = 0
v_r = 0
do
if (v_A ~= 0) then
do
v_r = 266
while true do
do
I8[bor(0, v_A)] = tobit(0)
I8[tobit((v_A + 1))] = tobit(0)
I8[tobit((v_A + 2))] = tobit(0)
I8[tobit((v_A + 3))] = tobit(0)
I8[tobit((v_A + 4))] = tobit(0)
I8[tobit((v_A + 5))] = tobit(0)
I8[tobit((v_A + 6))] = tobit(0)
I8[tobit((v_A + 7))] = tobit(0)
I8[tobit((v_A + 8))] = tobit(0)
I8[tobit((v_A + 9))] = tobit(0)
I8[tobit((v_A + 10))] = tobit(0)
I8[tobit((v_A + 11))] = tobit(0)
I8[tobit((v_A + 12))] = tobit(0)
I8[tobit((v_A + 13))] = tobit(0)
if (not (v_r ~= 0)) then
goto L224
end
v_A = tobit((v_A + 14))
v_r = tobit((v_r - 14))
end
::C225::
end
end
::B225::
end
end
::L224::
end

F.fgA = function(v_A, v_r)
local v_n, v_t, v_e = 0, 0, 0
v_e = 0
rf_s(v_A)
v_e = bor(0, rf_a(1))
v_n = bor(0, rf_a(0))
v_t = v_e
v_e = band((rshift(v_e, 20) % 4294967296), 2047)
if (2047 ~= bor(0, v_e)) then
if (not (v_e ~= 0)) then
v_e = v_r
if (0 == v_A) then
v_r = 0
else
v_A = F.fgA((18446744073709552000 * v_A), v_r)
v_r = tobit((I32[arshift(v_r, 2)] + (-64)))
end
I32[arshift(v_e, 2)] = tobit(v_r)
do return v_A end
end
I32[arshift(v_r, 2)] = tobit((v_e - 1022))
rf_u(0, bor(0, v_n))
rf_u(1, bor(band((-2146435073), v_t), 1071644672))
v_A = rf_c()
end
do return v_A end
end

F.fpA = function(v_A)
local v_r = 0
v_r = 0
do
F.fX(v_A)
v_r = 378
while true do
I8[bor(0, v_A)] = tobit(0)
I8[tobit((v_A + 1))] = tobit(0)
I8[tobit((v_A + 2))] = tobit(0)
I8[tobit((v_A + 3))] = tobit(0)
I8[tobit((v_A + 4))] = tobit(0)
I8[tobit((v_A + 5))] = tobit(0)
I8[tobit((v_A + 6))] = tobit(0)
I8[tobit((v_A + 7))] = tobit(0)
I8[tobit((v_A + 8))] = tobit(0)
I8[tobit((v_A + 9))] = tobit(0)
I8[tobit((v_A + 10))] = tobit(0)
I8[tobit((v_A + 11))] = tobit(0)
I8[tobit((v_A + 12))] = tobit(0)
I8[tobit((v_A + 13))] = tobit(0)
if not (v_r ~= 0) then goto B226 end
do
v_A = tobit((v_A + 14))
v_r = tobit((v_r - 14))
end
::C226::
end
end
::B226::
end

F.fhA = function(v_A, v_r, v_n, v_t)
local v_e, v_o, v_i, v_f, v_a, v_u = 0, 0, 0, 0, 0, 0
v_a = 0
v_u = 0
do
v_a = tobit((rshift(v_n, 16) % 4294967296))
local t264 = v_a
v_u = tobit((rshift(v_A, 16) % 4294967296))
v_f = imul(t264, v_u)
v_e = band(65535, v_n)
local t265 = v_e
v_o = band(65535, v_A)
v_i = imul(t265, v_o)
v_u = tobit((tobit((rshift(v_i, 16) % 4294967296)) + imul(v_u, v_e)))
v_a = tobit((band(65535, v_u) + imul(v_a, v_o)))
Iv = tobit((((tobit((imul(v_r, v_n) + v_f)) + imul(v_A, v_t)) + (rshift(v_u, 16) % 4294967296)) + (rshift(v_a, 16) % 4294967296)))
do return bor(band(65535, v_i), lshift(v_a, 16)) end
end
end

F.fdA = function(v_A, v_r, v_n, v_t, v_e)
local v_o = 0
do
v_o = tobit((B - 256))
B = v_o
if (not (bor(band(73728, v_e), ((bor(0, v_n) <= bor(0, v_t)) and 1 or 0)) ~= 0)) then
do
do
local t266 = v_o
local t267 = band(255, v_r)
v_n = tobit((v_n - v_t))
v_t = (((tobit(v_n) % 4294967296) < 256) and 1 or 0)
F.fOA(t266, t267, ((v_t ~= 0) and v_n or 256))
if (not (v_t ~= 0)) then
do
while true do
F.fnA(v_A, v_o, 256)
v_n = tobit((v_n - 256))
if not ((tobit(v_n) % 4294967296) > 255) then goto B227 end
do
end
::C227::
end
end
::B227::
end
end
F.fnA(v_A, v_o, v_n)
end
end
end
B = tobit((v_o + 256))
end

F.fkA = function(v_A, v_r)
local v_n, v_t, v_e = 0, 0, 0
v_n = 0
v_t = 0
v_e = 0
v_t = 10848
do
do
do
do
v_n = I32[2713]
if (v_n ~= 0) then
do
do
while true do
do
do
do
v_e = v_t
local t268 = ((1 ~= I32[arshift((v_n + 4), 2)]) and 1 or 0)
if t268 == 0 then
t268 = bor(((I32[arshift(I32[arshift((v_n + 28), 2)], 2)] ~= bor(0, v_A)) and 1 or 0), ((I32[arshift((v_n + 8), 2)] ~= bor(0, v_r)) and 1 or 0))
end
if (not (t268 ~= 0)) then
goto L228
end
end
v_t = tobit((v_e + 8))
v_n = I32[arshift((v_e + 12), 2)]
if (not (v_n ~= 0)) then
goto B229
end
end
end
::C229::
end
end
::B229::
end
end
end
v_n = 0
end
end
::L228::
end
do return v_n end
end

F.fyA = function(v_A, v_r, v_n)
local v_t, v_e = 0, 0
v_t = 0
v_e = 0
do
v_e = (-24832)
if (v_A ~= 0) then
v_t = I32[arshift(v_A, 2)]
local t270 = (not (v_t ~= 0))
local t269 = ((I32[arshift((v_t + 8), 2)] == bor(0, v_n)) and 1 or 0)
if t269 == 0 then
t269 = band(2, U8[tobit((v_t + 20))])
end
if not (bor((t270 and 1 or 0), ((not (t269 ~= 0)) and 1 or 0)) ~= 0) then
I32[arshift((v_A + 8), 2)] = tobit(1)
I32[arshift((v_A + 4), 2)] = tobit(v_n)
v_e = bor(0, UA[I32[arshift((I32[arshift((v_t + 28), 2)] + 24), 2)]](I32[arshift((v_A + 60), 2)], v_r, v_n))
end
end
do return v_e end
end
end

F.fwA = function(v_A)
local v_r, v_t = 0, 0
do
v_r = I32[3397]
local t271 = v_r
v_t = band((v_A + 3), (-4))
v_A = tobit((t271 + v_t))
local t272
if ((((tobit(v_A) % 4294967296) <= (tobit(v_r) % 4294967296)) and (v_t ~= 0)) or (((tobit(v_A) % 4294967296) > (tobit(lshift(tobit(toint((16777216 / 65536))), 16)) % 4294967296)) and (not (bor(0, imp_e(bor(0, v_A))) ~= 0)))) then
I32[5460] = tobit(48)
t272 = (-1)
else
I32[3397] = tobit(v_A)
t272 = v_r
end
do return t272 end
end
end

F.fCA = function(v_A)
local v_r, v_n, v_e = 0, 0, 0
v_r = 0
v_n = 0
v_e = 0
do
if (F.fPA(I8[I32[arshift(v_A, 2)]]) ~= 0) then
do
while true do
do
v_n = I32[arshift(v_A, 2)]
v_e = I8[bor(0, v_n)]
I32[arshift(v_A, 2)] = tobit((v_n + 1))
v_r = tobit((tobit((v_r + v_e)) - 48))
if (not (F.fPA(I8[tobit((v_n + 1))]) ~= 0)) then
goto L230
end
v_r = imul(v_r, 10)
end
::C231::
end
end
::B231::
end
end
::L230::
do return v_r end
end

F.fBA = function(v_A, v_r)
local v_n, v_t = 0, 0
v_n = 0
v_t = 0
v_n = 0
if (v_A ~= 0) then
v_t = F.fhA(v_A, 0, v_r, 0)
v_n = v_t
if not ((tobit(bor(v_A, v_r)) % 4294967296) < 65536) then
v_n = ((Iv ~= 0) and (-1) or v_t)
end
end
v_r = v_n
v_A = F.fI(v_r)
if not (bor(((not (v_A ~= 0)) and 1 or 0), ((not (band(3, U8[tobit((v_A - 4))]) ~= 0)) and 1 or 0)) ~= 0) then
F.fOA(v_A, 0, v_r)
end
do return v_A end
end

F.fEA = function(v_A, v_r, v_n)
local v_t, v_e, v_o = 0, 0, 0
v_t = 0
v_e = 0
v_o = 0
do
do
do
if (v_n ~= 0) then
do
do
do
while true do
do
do
do
v_t = U8[bor(0, v_A)]
local t273 = bor(0, v_t)
v_e = U8[bor(0, v_r)]
if (t273 == bor(0, v_e)) then
v_r = tobit((v_r + 1))
v_A = tobit((v_A + 1))
v_n = tobit((v_n - 1))
if (v_n ~= 0) then
goto C233
end
goto L232
end
end
goto B233
end
end
::C233::
end
end
::B233::
end
v_o = tobit((v_t - v_e))
end
end
end
end
::L232::
end
do return v_o end
end

F.fIA = function()
local v_A, v_r = 0, 0
v_r = 0
v_A = tobit((F.fhA(I32[7796], I32[7797], 1284865837, 1481765933) + 1))
v_r = Iv
v_r = (((tobit(v_A) % 4294967296) < 1) and tobit((v_r + 1)) or v_r)
I32[7796] = tobit(v_A)
I32[7797] = tobit(v_r)
do return tobit((rshift(v_r, 1) % 4294967296)) end
end

F.fmA = function(v_A, v_r, v_n, v_t)
local v_e = 0
v_e = 0
v_e = (-13)
v_r = F.fkA(v_r, v_t)
if not (bor(((not (v_r ~= 0)) and 1 or 0), ((16 ~= I32[arshift((v_r + 24), 2)]) and 1 or 0)) ~= 0) then
F.fX(v_A)
v_e = F.faA(v_A, v_r)
if not (v_e ~= 0) then
v_e = F.fyA(v_A, v_n, v_t)
end
end
do return v_e end
end

F.fQA = function(v_A, v_r, v_n)
local v_e = 0
v_e = 0
if (v_n ~= 0) then
do
v_e = v_A
while true do
I8[bor(0, v_e)] = tobit(U8[bor(0, v_r)])
v_e = tobit((v_e + 1))
v_r = tobit((v_r + 1))
v_n = tobit((v_n - 1))
if not (v_n ~= 0) then goto B234 end
do
end
::C234::
end
end
::B234::
end
do return v_A end
end

F.fOA = function(v_A, v_r, v_n)
local v_e = 0
v_e = 0
if (v_n ~= 0) then
do
v_e = v_A
while true do
I8[bor(0, v_e)] = tobit(v_r)
v_e = tobit((v_e + 1))
v_n = tobit((v_n - 1))
if not (v_n ~= 0) then goto B235 end
do
end
::C235::
end
end
::B235::
end
do return v_A end
end

F.fSA = function(v_A, v_r)
local v_n = 0
v_n = 0
do
local t274 = (-1)
v_n = band(31, v_r)
local t277 = lshift(band((rshift(t274, v_n) % 4294967296), v_A), v_n)
v_n = v_A
local t276 = v_n
local t275 = (-1)
v_A = band((0 - v_r), 31)
do return bor(t277, (rshift(band(t276, lshift(t275, v_A)), v_A) % 4294967296)) end
end
end

F.fjA = function(v_A, v_r)

F.ffA(tobit((F.flA(v_A) + v_A)), v_r)
do return v_A end
end

F.fxA = function(v_A)

I32[7796] = tobit((v_A - 1))
I32[7797] = tobit(0)
end

F.fPA = function(v_A)

do return (((tobit((v_A - 48)) % 4294967296) < 10) and 1 or 0) end
end

F.fMA = function(v_A)

F.fOA(v_A, 0, 280)
end

F.fTA = function(v_A)

F.fOA(v_A, 0, 392)
end

F.fRA = function(v_A)

F.fOA(v_A, 0, 128)
end

UA[1] = function(v_A, v_r, v_n, v_e, v_o, v_u)
local v_c, v_l, v_b, v_v, v_h, v_d, v_k, v_y, v_w, v_C, v_I, v_m, v_Q, v_O, v_S, v_j, v_x, v_P, v_M, v_T, v_R = 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
v_A = tobit(v_A)
v_r = v_r
v_n = tobit(v_n)
v_e = tobit(v_e)
v_o = tobit(v_o)
v_u = tobit(v_u)
v_l = 0
v_b = 0
v_v = 0
v_h = 0
v_d = 0
v_k = 0
v_y = 0
v_w = 0
v_C = 0
v_I = 0
v_m = 0
v_Q = 0
v_O = 0
v_S = 0
v_j = 0
v_x = 0
v_P = 0
v_M = 0
v_T = 0
v_R = 0
v_c = tobit((B - 560))
B = v_c
I32[arshift((v_c + 44), 2)] = tobit(0)
rf_s(v_r)
v_k = bor(0, rf_a(1))
rf_a(0)
if ((bor(0, v_k) < (-1)) or (bor(0, v_k) <= (-1))) then
v_S = 1
v_j = 1039
v_r = (-v_r)
rf_s(v_r)
v_k = bor(0, rf_a(1))
rf_a(0)
else
if (band(2048, v_o) ~= 0) then
v_S = 1
v_j = 1042
else
v_S = band(1, v_o)
v_j = ((v_S ~= 0) and 1045 or 1040)
v_R = ((not (v_S ~= 0)) and 1 or 0)
end
end
do
do
do
if (2146435072 ~= band(2146435072, v_k)) then
do
v_Q = tobit((v_c + 16))
do
do
do
do
do
v_r = F.fgA(v_r, tobit((v_c + 44)))
v_r = (v_r + v_r)
if (0 ~= v_r) then
v_l = I32[arshift((v_c + 44), 2)]
I32[arshift((v_c + 44), 2)] = tobit((v_l - 1))
v_x = bor(32, v_u)
if (97 ~= bor(0, v_x)) then
goto L239
end
goto L237
end
v_x = bor(32, v_u)
if (97 == bor(0, v_x)) then
goto L237
end
v_w = I32[arshift((v_c + 44), 2)]
v_d = ((bor(0, v_e) < 0) and 6 or v_e)
goto L238
end
::L239::
v_w = tobit((v_l - 29))
I32[arshift((v_c + 44), 2)] = tobit(v_w)
v_r = (v_r * 268435456)
v_d = ((bor(0, v_e) < 0) and 6 or v_e)
end
::L238::
do
v_I = ((bor(0, v_w) < 0) and tobit((v_c + 48)) or tobit((v_c + 336)))
v_b = v_I
while true do
v_l = ((band(((v_r < 4294967296) and 1 or 0), ((v_r >= 0) and 1 or 0)) ~= 0) and (tobit(bnot(bnot(v_r))) % 4294967296) or 0)
v_e = v_b
I32[arshift(v_e, 2)] = tobit(v_l)
v_b = tobit((v_b + 4))
v_r = (1000000000 * (v_r - (tobit(v_l) % 4294967296)))
if not (0 ~= v_r) then goto B240 end
do
end
::C240::
end
end
::B240::
do
if (bor(0, v_w) < 1) then
v_e = v_w
v_l = v_b
v_v = v_I
else
do
do
v_v = v_I
v_e = v_w
while true do
do
do
do
v_y = ((bor(0, v_e) < 29) and v_e or 29)
local t278 = (tobit(v_v) % 4294967296)
v_l = tobit((v_b - 4))
if (not (t278 > (tobit(v_l) % 4294967296))) then
do
do
do
v_h = v_y
v_e = 0
v_k = 0
while true do
do
v_m = v_l
v_T = I32[arshift(v_l, 2)]
v_C = band(31, v_h)
if ((tobit(band(63, v_h)) % 4294967296) >= 32) then
v_M = lshift(v_T, v_C)
v_C = 0
else
v_M = band((lshift(1, v_C) - 1), (rshift(v_T, (32 - v_C)) % 4294967296))
v_C = lshift(v_T, v_C)
end
v_M = tobit((v_k + v_M))
v_C = tobit((v_C + v_e))
v_k = v_C
v_e = F.fq(v_k, (((tobit(v_e) % 4294967296) > (tobit(v_k) % 4294967296)) and tobit((v_M + 1)) or v_M), 1000000000)
v_C = F.fhA(v_e, Iv, 1000000000, 0)
I32[arshift(v_m, 2)] = tobit((v_k - v_C))
local t279 = (tobit(v_v) % 4294967296)
v_l = tobit((v_l - 4))
if not (t279 <= (tobit(v_l) % 4294967296)) then goto B242 end
end
do
v_k = 0
end
::C242::
end
end
::B242::
end
if (v_e ~= 0) then
v_v = tobit((v_v - 4))
I32[arshift(v_v, 2)] = tobit(v_e)
end
end
end
end
do
do
while true do
do
local t280 = (tobit(v_v) % 4294967296)
v_l = v_b
local t281 = (t280 < (tobit(v_l) % 4294967296))
if t281 then
v_b = tobit((v_l - 4))
t281 = (not (I32[arshift(v_b, 2)] ~= 0))
end
if not t281 then goto B243 end
end
do
end
::C243::
end
end
::B243::
end
v_e = tobit((I32[arshift((v_c + 44), 2)] - v_y))
I32[arshift((v_c + 44), 2)] = tobit(v_e)
v_b = v_l
if (not (bor(0, v_e) > 0)) then
goto B241
end
end
end
::C241::
end
end
::B241::
end
end
end
do
v_b = tobit(toint((tobit((v_d + 25)) / 9)))
if (bor(0, v_e) <= (-1)) then
do
do
v_C = tobit((v_b + 1))
v_P = ((102 == bor(0, v_x)) and 1 or 0)
while true do
do
do
v_m = ((bor(0, v_e) < (-9)) and 9 or tobit((0 - v_e)))
do
if ((tobit(v_l) % 4294967296) > (tobit(v_v) % 4294967296)) then
do
v_k = tobit((rshift(1000000000, v_m) % 4294967296))
v_h = bxor(lshift((-1), v_m), (-1))
v_e = 0
v_b = v_v
while true do
v_y = v_e
v_e = I32[arshift(v_b, 2)]
I32[arshift(v_b, 2)] = tobit((v_y + tobit((rshift(v_e, v_m) % 4294967296))))
v_e = imul(v_k, band(v_e, v_h))
v_b = tobit((v_b + 4))
if not ((tobit(v_b) % 4294967296) < (tobit(v_l) % 4294967296)) then goto B246 end
do
end
::C246::
end
end
::B246::
v_v = ((I32[arshift(v_v, 2)] ~= 0) and v_v or tobit((v_v + 4)))
if (not (v_e ~= 0)) then
goto L245
end
I32[arshift(v_l, 2)] = tobit(v_e)
v_l = tobit((v_l + 4))
else
v_v = ((I32[arshift(v_v, 2)] ~= 0) and v_v or tobit((v_v + 4)))
end
end
::L245::
do
v_e = tobit((I32[arshift((v_c + 44), 2)] + v_m))
I32[arshift((v_c + 44), 2)] = tobit(v_e)
local t283 = bor(0, v_C)
local t282 = v_l
v_b = ((v_P ~= 0) and v_I or v_v)
v_l = ((t283 < arshift((t282 - v_b), 2)) and tobit((v_b + lshift(v_C, 2))) or v_l)
if (not (bor(0, v_e) < 0)) then
goto B244
end
end
end
end
::C244::
end
end
::B244::
end
end
end
v_b = 0
do
do
do
local t284 = (((tobit(v_l) % 4294967296) <= (tobit(v_v) % 4294967296)) and 1 or 0)
if t284 == 0 then
v_b = imul(arshift((v_I - v_v), 2), 9)
v_h = I32[arshift(v_v, 2)]
t284 = (((tobit(v_h) % 4294967296) < 10) and 1 or 0)
end
if (not (t284 ~= 0)) then
do
v_e = 100
while true do
do
v_b = tobit((v_b + 1))
if ((tobit(v_e) % 4294967296) > (tobit(v_h) % 4294967296)) then
goto L247
end
v_e = imul(v_e, 10)
end
::C248::
end
end
::B248::
end
end
end
::L247::
end
do
v_e = tobit((tobit((v_d - ((102 == bor(0, v_x)) and 0 or v_b))) - band(((103 == bor(0, v_x)) and 1 or 0), ((0 ~= bor(0, v_d)) and 1 or 0))))
if (bor(0, v_e) < tobit((imul(arshift((v_l - v_I), 2), 9) - 9))) then
do
v_k = tobit((v_e + 9216))
v_h = tobit(toint((bor(0, v_k) / 9)))
v_y = tobit((tobit((lshift(v_h, 2) + ((bor(0, v_w) < 0) and bor((v_c + 48), 4) or tobit((v_c + 340))))) - 4096))
v_e = 10
do
v_h = tobit((v_k - imul(v_h, 9)))
if (not (bor(0, v_h) > 7)) then
do
v_e = 100
while true do
do
v_h = tobit((v_h + 1))
if (8 == bor(0, v_h)) then
goto L249
end
v_e = imul(v_e, 10)
end
::C250::
end
end
::B250::
end
end
::L249::
do
do
do
v_k = I32[arshift(v_y, 2)]
local t286 = v_k
local t285 = v_e
v_w = tobit(toint(((tobit(v_k) % 4294967296) / (tobit(v_e) % 4294967296))))
v_C = tobit((t286 - imul(t285, v_w)))
v_h = tobit((v_y + 4))
local t287 = ((bor(0, v_h) ~= bor(0, v_l)) and 1 or 0)
if t287 == 0 then
t287 = v_C
end
local t288 = t287
if t288 ~= 0 then
v_r = ((bor(0, v_l) == bor(0, v_h)) and 1 or 1.5)
v_h = tobit((rshift(v_e, 1) % 4294967296))
v_O = (((tobit(v_h) % 4294967296) > (tobit(v_C) % 4294967296)) and 0.5 or ((bor(0, v_h) == bor(0, v_C)) and v_r or 1.5))
v_r = ((band(1, v_w) ~= 0) and 9007199254740994 or 9007199254740992)
if not (bor(((45 ~= U8[bor(0, v_j)]) and 1 or 0), v_R) ~= 0) then
v_O = (-v_O)
v_r = (-v_r)
end
v_h = tobit((v_k - v_C))
I32[arshift(v_y, 2)] = tobit(v_h)
t288 = (((v_r + v_O) ~= v_r) and 1 or 0)
end
if (t288 ~= 0) then
v_e = tobit((v_e + v_h))
I32[arshift(v_y, 2)] = tobit(v_e)
if ((tobit(v_e) % 4294967296) >= 1000000000) then
do
while true do
I32[arshift(v_y, 2)] = tobit(0)
v_y = tobit((v_y - 4))
if ((tobit(v_y) % 4294967296) < (tobit(v_v) % 4294967296)) then
v_v = tobit((v_v - 4))
I32[arshift(v_v, 2)] = tobit(0)
end
v_e = tobit((I32[arshift(v_y, 2)] + 1))
I32[arshift(v_y, 2)] = tobit(v_e)
if not ((tobit(v_e) % 4294967296) > 999999999) then goto B252 end
do
end
::C252::
end
end
::B252::
end
v_b = imul(arshift((v_I - v_v), 2), 9)
v_h = I32[arshift(v_v, 2)]
if (not ((tobit(v_h) % 4294967296) < 10)) then
do
v_e = 100
while true do
do
v_b = tobit((v_b + 1))
if ((tobit(v_e) % 4294967296) > (tobit(v_h) % 4294967296)) then
goto L251
end
v_e = imul(v_e, 10)
end
::C253::
end
end
::B253::
end
end
end
end
::L251::
end
v_e = tobit((v_y + 4))
v_l = (((tobit(v_e) % 4294967296) < (tobit(v_l) % 4294967296)) and v_e or v_l)
end
end
end
do
do
while true do
do
v_w = v_l
v_h = (((tobit(v_l) % 4294967296) <= (tobit(v_v) % 4294967296)) and 1 or 0)
local t289 = ((not (v_h ~= 0)) and 1 or 0)
if t289 ~= 0 then
v_l = tobit((v_w - 4))
t289 = ((not (I32[arshift(v_l, 2)] ~= 0)) and 1 or 0)
end
if not (t289 ~= 0) then goto B254 end
end
do
end
::C254::
end
end
::B254::
end
do
if (103 == bor(0, v_x)) then
do
do
local t290 = v_d
if t290 == 0 then
t290 = 1
end
v_l = t290
v_e = band(((bor(0, v_l) > bor(0, v_b)) and 1 or 0), ((bor(0, v_b) > (-5)) and 1 or 0))
v_d = tobit((((v_e ~= 0) and bxor((-1), v_b) or (-1)) + v_l))
v_u = tobit((((v_e ~= 0) and (-1) or (-2)) + v_u))
v_m = band(8, v_o)
if (not (v_m ~= 0)) then
do
do
v_l = (-9)
local t291 = ((not (v_h ~= 0)) and 1 or 0)
if t291 ~= 0 then
v_e = I32[arshift((v_w - 4), 2)]
t291 = v_e
end
local t292 = t291
if t292 ~= 0 then
v_l = 0
t292 = ((not (tobit(fmod((tobit(v_e) % 4294967296), 10)) ~= 0)) and 1 or 0)
end
if (t292 ~= 0) then
do
v_h = 0
v_l = 100
while true do
if not (not (tobit(fmod((tobit(v_e) % 4294967296), (tobit(v_l) % 4294967296))) ~= 0)) then goto B255 end
do
v_h = tobit((v_h + 1))
v_l = imul(v_l, 10)
end
::C255::
end
end
::B255::
v_l = bxor((-1), v_h)
end
end
v_e = imul(arshift((v_w - v_I), 2), 9)
if (70 ~= band((-33), v_u)) then
v_m = 0
v_e = tobit((tobit((tobit((v_e + v_b)) + v_l)) - 9))
v_e = ((bor(0, v_e) > 0) and v_e or 0)
v_d = ((bor(0, v_e) > bor(0, v_d)) and v_d or v_e)
else
v_m = 0
v_e = tobit((tobit((v_e + v_l)) - 9))
v_e = ((bor(0, v_e) > 0) and v_e or 0)
v_d = ((bor(0, v_e) > bor(0, v_d)) and v_d or v_e)
end
end
end
end
end
else
v_m = band(8, v_o)
end
end
do
v_C = ((0 ~= bor(v_d, v_m)) and 1 or 0)
v_e = v_A
v_h = v_n
v_k = band((-33), v_u)
if (70 == bor(0, v_k)) then
v_u = ((bor(0, v_b) > 0) and v_b or 0)
else
do
do
local t293 = v_Q
v_l = arshift(v_b, 31)
v_l = F.fbA(bxor((v_l + v_b), v_l), 0, v_Q)
if (tobit((t293 - v_l)) <= 1) then
do
while true do
v_l = tobit((v_l - 1))
I8[bor(0, v_l)] = tobit(48)
if not (tobit((v_Q - v_l)) < 2) then goto B256 end
do
end
::C256::
end
end
::B256::
end
end
v_P = tobit((v_l - 2))
I8[bor(0, v_P)] = tobit(v_u)
I8[tobit((v_l - 1))] = tobit(((bor(0, v_b) < 0) and 45 or 43))
v_u = tobit((v_Q - v_P))
end
end
end
do
local t294 = v_e
local t295 = v_h
v_y = tobit((1 + tobit((v_u + tobit((v_C + tobit((v_d + v_S))))))))
F.fdA(t294, 32, t295, v_y, v_o)
F.fnA(v_A, v_j, v_S)
F.fdA(v_A, 48, v_n, v_y, bxor(65536, v_o))
end
do
do
do
do
do
do
do
do
do
do
if (70 == bor(0, v_k)) then
do
do
do
v_e = bor((v_c + 16), 8)
v_b = bor((v_c + 16), 9)
v_u = (((tobit(v_v) % 4294967296) > (tobit(v_I) % 4294967296)) and v_I or v_v)
v_v = v_u
while true do
do
do
v_l = F.fbA(I32[arshift(v_v, 2)], 0, v_b)
do
if (bor(0, v_u) == bor(0, v_v)) then
if (bor(0, v_l) == bor(0, v_b)) then
I8[tobit((v_c + 24))] = tobit(48)
v_l = v_e
end
else
if ((tobit((v_c + 16)) % 4294967296) >= (tobit(v_l) % 4294967296)) then
goto L261
end
do
while true do
v_l = tobit((v_l - 1))
I8[bor(0, v_l)] = tobit(48)
if not ((tobit((v_c + 16)) % 4294967296) < (tobit(v_l) % 4294967296)) then goto B262 end
do
end
::C262::
end
end
::B262::
end
end
::L261::
do
F.fnA(v_A, v_l, tobit((v_b - v_l)))
local t296 = (tobit(v_I) % 4294967296)
v_v = tobit((v_v + 4))
if (not (t296 >= (tobit(v_v) % 4294967296))) then
goto B260
end
end
end
end
::C260::
end
end
::B260::
end
v_l = 0
if (not (v_C ~= 0)) then
goto L258
end
F.fnA(v_A, 1125, 1)
if (bor(((bor(0, v_d) < 1) and 1 or 0), (((tobit(v_v) % 4294967296) >= (tobit(v_w) % 4294967296)) and 1 or 0)) ~= 0) then
goto L259
end
do
do
while true do
do
do
v_l = F.fbA(I32[arshift(v_v, 2)], 0, v_b)
if ((tobit(v_l) % 4294967296) > (tobit((v_c + 16)) % 4294967296)) then
do
while true do
v_l = tobit((v_l - 1))
I8[bor(0, v_l)] = tobit(48)
if not ((tobit((v_c + 16)) % 4294967296) < (tobit(v_l) % 4294967296)) then goto B264 end
do
end
::C264::
end
end
::B264::
end
do
F.fnA(v_A, v_l, ((bor(0, v_d) < 9) and v_d or 9))
v_l = tobit((v_d - 9))
local t297 = (tobit(v_w) % 4294967296)
v_v = tobit((v_v + 4))
if (t297 <= (tobit(v_v) % 4294967296)) then
goto L258
end
end
v_e = ((bor(0, v_d) > 9) and 1 or 0)
v_d = v_l
if (not (v_e ~= 0)) then
goto B263
end
end
end
::C263::
end
end
::B263::
end
goto L258
end
end
end
do
do
do
if (not (bor(0, v_d) < 0)) then
do
do
v_u = (((tobit(v_v) % 4294967296) < (tobit(v_w) % 4294967296)) and v_w or tobit((v_v + 4)))
v_h = bor((v_c + 16), 9)
v_e = bor((v_c + 16), 8)
v_b = v_v
while true do
do
do
do
local t298 = bor(0, v_h)
v_l = F.fbA(I32[arshift(v_b, 2)], 0, v_h)
if (t298 == bor(0, v_l)) then
I8[tobit((v_c + 24))] = tobit(48)
v_l = v_e
end
end
do
if (bor(0, v_b) == bor(0, v_v)) then
F.fnA(v_A, v_l, 1)
v_l = tobit((v_l + 1))
if not ((not (v_m ~= 0)) and (bor(0, v_d) <= 0)) then
F.fnA(v_A, 1125, 1)
end
else
if ((tobit((v_c + 16)) % 4294967296) >= (tobit(v_l) % 4294967296)) then
goto L267
end
do
while true do
v_l = tobit((v_l - 1))
I8[bor(0, v_l)] = tobit(48)
if not ((tobit((v_c + 16)) % 4294967296) < (tobit(v_l) % 4294967296)) then goto B268 end
do
end
::C268::
end
end
::B268::
end
end
::L267::
do
local t299 = v_A
v_w = v_l
local t300 = v_w
v_l = tobit((v_h - v_l))
F.fnA(t299, t300, ((bor(0, v_l) < bor(0, v_d)) and v_l or v_d))
v_d = tobit((v_d - v_l))
local t301 = (tobit(v_u) % 4294967296)
v_b = tobit((v_b + 4))
if (t301 <= (tobit(v_b) % 4294967296)) then
goto L265
end
end
if (not (bor(0, v_d) > (-1))) then
goto B266
end
end
end
::C266::
end
end
::B266::
end
end
end
end
::L265::
end
F.fdA(v_A, 48, tobit((v_d + 18)), 18, 0)
F.fnA(v_A, v_P, tobit((v_Q - v_P)))
goto L257
end
end
::L259::
end
v_l = v_d
end
end
::L258::
end
F.fdA(v_A, 48, tobit((v_l + 9)), 9, 0)
end
end
::L257::
end
goto L236
end
end
::L237::
end
do
v_d = band(32, v_u)
v_w = ((v_d ~= 0) and tobit((v_j + 9)) or v_j)
local t302 = ((not ((tobit(v_e) % 4294967296) > 11)) and 1 or 0)
if t302 ~= 0 then
v_l = tobit((12 - v_e))
t302 = v_l
end
if (t302 ~= 0) then
do
v_O = 8
while true do
v_O = (v_O * 16)
v_l = tobit((v_l - 1))
if not (v_l ~= 0) then goto B269 end
do
end
::C269::
end
end
::B269::
v_r = ((45 ~= U8[bor(0, v_w)]) and ((v_r + v_O) - v_O) or (-(v_O + ((-v_r) - v_O))))
end
end
do
do
do
local t303 = bor(0, v_Q)
v_l = I32[arshift((v_c + 44), 2)]
v_b = arshift(v_l, 31)
v_l = F.fbA(bxor(v_b, (v_l + v_b)), 0, v_Q)
if (t303 == bor(0, v_l)) then
I8[tobit((v_c + 15))] = tobit(48)
v_l = tobit((v_c + 15))
end
v_h = bor(2, v_S)
v_b = I32[arshift((v_c + 44), 2)]
v_k = tobit((v_l - 2))
I8[bor(0, v_k)] = tobit((v_u + 15))
I8[tobit((v_l - 1))] = tobit(((bor(0, v_b) < 0) and 45 or 43))
v_l = band(8, v_o)
v_v = tobit((v_c + 16))
end
while true do
do
v_u = v_v
v_I = v_d
v_b = ((math.abs(v_r) < 2147483648) and bnot(bnot(v_r)) or (-2147483648))
I8[bor(0, v_v)] = tobit(bor(v_I, U8[tobit((v_b + 1600))]))
v_r = (16 * (v_r - bor(0, v_b)))
local t304 = v_l
if t304 == 0 then
t304 = bor(((bor(0, v_e) > 0) and 1 or 0), ((0 ~= v_r) and 1 or 0))
end
local t305 = (not (t304 ~= 0))
v_v = tobit((v_u + 1))
if not (bor((t305 and 1 or 0), ((1 ~= tobit((v_v - tobit((v_c + 16))))) and 1 or 0)) ~= 0) then
I8[tobit((v_u + 1))] = tobit(46)
v_v = tobit((v_u + 2))
end
if not (0 ~= v_r) then goto B270 end
end
do
end
::C270::
end
end
::B270::
end
do
local t306 = v_A
local t307 = v_n
v_u = ((bor(((not (v_e ~= 0)) and 1 or 0), ((tobit((tobit((v_v - v_c)) - 18)) >= bor(0, v_e)) and 1 or 0)) ~= 0) and tobit((tobit((v_Q - tobit((v_k + tobit((v_c + 16)))))) + v_v)) or tobit((2 + tobit((tobit((v_e + v_Q)) - v_k)))))
v_y = tobit((v_u + v_h))
F.fdA(t306, 32, t307, v_y, v_o)
F.fnA(v_A, v_w, v_h)
F.fdA(v_A, 48, v_n, v_y, bxor(65536, v_o))
local t308 = v_A
local t309 = tobit((v_c + 16))
v_e = tobit((v_v - tobit((v_c + 16))))
F.fnA(t308, t309, v_e)
local t312 = v_A
local t311 = v_u
v_l = v_e
local t310 = v_l
v_e = tobit((v_Q - v_k))
F.fdA(t312, 48, tobit((t311 - tobit((t310 + v_e)))), 0, 0)
F.fnA(v_A, v_k, v_e)
end
end
else
do
local t313 = v_A
local t314 = v_n
v_y = tobit((v_S + 3))
F.fdA(t313, 32, t314, v_y, band((-65537), v_o))
F.fnA(v_A, v_j, v_S)
v_e = band(32, v_u)
F.fnA(v_A, ((v_r ~= v_r) and ((v_e ~= 0) and 1089 or 1117) or ((v_e ~= 0) and 1105 or 1121)), 3)
end
end
end
end
::L236::
end
F.fdA(v_A, 32, v_n, v_y, bxor(8192, v_o))
B = tobit((v_c + 560))
do return bor(0, ((bor(0, v_n) > bor(0, v_y)) and v_n or v_y)) end
end
UA[2] = function(v_A, v_r)
local v_n, v_t, v_e, v_o, v_f, v_a, v_s, v_l, v_b, v_g, v_p, v_h, v_d, v_k, v_y = 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
v_A = tobit(v_A)
v_o = 0
v_f = 0
v_a = 0
v_s = 0
v_l = 0
v_b = 0
v_g = 0
v_p = 0
v_h = 0
v_d = 0
v_k = 0
v_y = 0
v_r = tobit(v_r)
v_o = v_r
v_r = band((I32[arshift(v_r, 2)] + 15), (-16))
I32[arshift(v_o, 2)] = tobit((v_r + 16))
v_e = v_A
v_A = v_r
v_p = I32[arshift(v_A, 2)]
v_r = I32[arshift((v_A + 4), 2)]
v_s = I32[arshift((v_A + 12), 2)]
v_t = v_s
v_n = tobit((B - 32))
B = v_n
v_o = band(2147483647, v_s)
v_s = v_o
v_a = tobit((v_o - 1006698496))
v_f = tobit((v_o - 1140785152))
v_o = I32[arshift((v_A + 8), 2)]
v_g = v_o
do
do
do
if (bor(band(((bor(0, v_a) == bor(0, v_f)) and 1 or 0), (((tobit(v_o) % 4294967296) < (tobit(v_o) % 4294967296)) and 1 or 0)), (((tobit(v_a) % 4294967296) < (tobit(v_f) % 4294967296)) and 1 or 0)) ~= 0) then
do
do
v_s = v_o
v_o = bor(lshift(v_t, 4), (rshift(v_o, 28) % 4294967296))
local t315 = lshift(v_s, 4)
v_A = v_r
v_s = bor(t315, (rshift(v_A, 28) % 4294967296))
v_A = band(v_A, 268435455)
v_r = v_A
if (bor(band(((134217728 == bor(0, v_A)) and 1 or 0), (((tobit(v_p) % 4294967296) >= 1) and 1 or 0)), (((tobit(v_A) % 4294967296) > 134217728) and 1 or 0)) ~= 0) then
v_A = tobit((v_o + 1073741824))
v_r = tobit((v_s + 1))
v_A = (((tobit(v_r) % 4294967296) < 1) and tobit((v_A + 1)) or v_A)
v_a = v_r
goto L271
end
end
v_a = v_s
v_A = tobit((v_o + 1073741824))
if (bor(v_p, bxor(134217728, v_r)) ~= 0) then
goto L271
end
do
v_o = v_A
v_r = band(1, v_s)
local t316 = (tobit(v_r) % 4294967296)
v_s = tobit((v_r + v_a))
v_a = v_s
v_A = ((t316 > (tobit(v_a) % 4294967296)) and tobit((v_o + 1)) or v_o)
end
end
else
do
if (((band(((not (v_g ~= 0)) and 1 or 0), ((2147418112 == bor(0, v_s)) and 1 or 0)) ~= 0) and ((not (bor(v_r, v_p) ~= 0)) and 1 or 0) or (((tobit(v_s) % 4294967296) < 2147418112) and 1 or 0)) ~= 0) then
v_a = 0
v_A = 2146435072
if not ((tobit(v_s) % 4294967296) > 1140785151) then
v_A = 0
v_k = tobit((rshift(v_s, 16) % 4294967296))
if not ((tobit(v_k) % 4294967296) < 15249) then
v_a = v_p
v_A = v_r
v_f = bor(band(65535, v_t), 65536)
v_s = v_f
v_h = v_o
v_l = v_o
v_b = tobit((v_k - 15233))
if (band(64, v_b) ~= 0) then
v_f = v_a
v_o = tobit((v_b + (-64)))
v_a = band(31, v_o)
if ((tobit(band(63, v_o)) % 4294967296) >= 32) then
v_A = lshift(v_f, v_a)
v_l = 0
else
v_A = bor(band((lshift(1, v_a) - 1), (rshift(v_f, (32 - v_a)) % 4294967296)), lshift(v_A, v_a))
v_l = lshift(v_f, v_a)
end
v_f = v_A
v_a = 0
v_A = 0
else
if (v_b ~= 0) then
v_g = v_b
v_o = v_b
v_d = band(31, v_o)
if ((tobit(band(63, v_o)) % 4294967296) >= 32) then
v_o = lshift(v_l, v_d)
v_l = 0
else
v_o = bor(band((lshift(1, v_d) - 1), (rshift(v_l, (32 - v_d)) % 4294967296)), lshift(v_f, v_d))
v_l = lshift(v_l, v_d)
end
v_f = v_o
v_y = v_l
v_l = v_A
v_d = v_a
v_o = tobit((64 - v_b))
v_b = band(31, v_o)
if ((tobit(band(63, v_o)) % 4294967296) >= 32) then
v_o = 0
v_l = tobit((rshift(v_l, v_b) % 4294967296))
else
v_o = tobit((rshift(v_l, v_b) % 4294967296))
v_l = bor(lshift(band((lshift(1, v_b) - 1), v_l), (32 - v_b)), (rshift(v_d, v_b) % 4294967296))
end
v_l = bor(v_l, v_y)
v_f = bor(v_f, v_o)
v_b = band(31, v_g)
if ((tobit(band(63, v_g)) % 4294967296) >= 32) then
v_o = lshift(v_a, v_b)
v_a = 0
else
v_o = bor(band((lshift(1, v_b) - 1), (rshift(v_a, (32 - v_b)) % 4294967296)), lshift(v_A, v_b))
v_a = lshift(v_a, v_b)
end
v_A = v_o
end
end
I32[arshift((v_n + 16), 2)] = tobit(v_a)
I32[arshift((v_n + 20), 2)] = tobit(v_A)
I32[arshift((v_n + 24), 2)] = tobit(v_l)
I32[arshift((v_n + 28), 2)] = tobit(v_f)
v_o = tobit((15361 - v_k))
if (band(64, v_o) ~= 0) then
v_r = v_h
v_A = tobit((v_o + (-64)))
v_f = band(31, v_A)
if ((tobit(band(63, v_A)) % 4294967296) >= 32) then
v_o = 0
v_p = tobit((rshift(v_s, v_f) % 4294967296))
else
v_o = tobit((rshift(v_s, v_f) % 4294967296))
v_p = bor(lshift(band((lshift(1, v_f) - 1), v_s), (32 - v_f)), (rshift(v_r, v_f) % 4294967296))
end
v_r = v_o
v_h = 0
v_s = 0
else
if (v_o ~= 0) then
v_A = v_s
v_a = v_h
v_f = tobit((64 - v_o))
v_g = band(31, v_f)
if ((tobit(band(63, v_f)) % 4294967296) >= 32) then
v_A = lshift(v_a, v_g)
v_a = 0
else
v_A = bor(band((lshift(1, v_g) - 1), (rshift(v_a, (32 - v_g)) % 4294967296)), lshift(v_A, v_g))
v_a = lshift(v_a, v_g)
end
v_f = v_A
v_l = v_a
v_a = v_p
v_A = v_o
v_g = band(31, v_o)
if ((tobit(band(63, v_o)) % 4294967296) >= 32) then
v_o = 0
v_r = tobit((rshift(v_r, v_g) % 4294967296))
else
v_o = tobit((rshift(v_r, v_g) % 4294967296))
v_r = bor(lshift(band((lshift(1, v_g) - 1), v_r), (32 - v_g)), (rshift(v_a, v_g) % 4294967296))
end
v_p = bor(v_l, v_r)
v_r = bor(v_o, v_f)
v_o = v_h
v_f = band(31, v_A)
if ((tobit(band(63, v_A)) % 4294967296) >= 32) then
v_A = 0
v_h = tobit((rshift(v_s, v_f) % 4294967296))
else
v_A = tobit((rshift(v_s, v_f) % 4294967296))
v_h = bor(lshift(band((lshift(1, v_f) - 1), v_s), (32 - v_f)), (rshift(v_o, v_f) % 4294967296))
end
v_s = v_A
end
end
I32[arshift(v_n, 2)] = tobit(v_p)
I32[arshift((v_n + 4), 2)] = tobit(v_r)
I32[arshift((v_n + 8), 2)] = tobit(v_h)
I32[arshift((v_n + 12), 2)] = tobit(v_s)
v_f = I32[arshift((v_n + 4), 2)]
v_r = I32[arshift((v_n + 8), 2)]
v_a = bor(lshift(v_r, 4), (rshift(v_f, 28) % 4294967296))
v_A = bor(lshift(I32[arshift((v_n + 12), 2)], 4), (rshift(v_r, 28) % 4294967296))
v_f = band(v_f, 268435455)
v_s = v_f
local t317 = (134217728 == bor(0, v_f))
v_r = bor(bor(I32[arshift(v_n, 2)], ((0 ~= bor(I32[arshift((v_n + 16), 2)], I32[arshift((v_n + 24), 2)])) and 1 or 0)), ((0 ~= bor(I32[arshift((v_n + 20), 2)], I32[arshift((v_n + 28), 2)])) and 1 or 0))
if (bor(band((t317 and 1 or 0), (((tobit(v_r) % 4294967296) >= 1) and 1 or 0)), (((tobit(v_f) % 4294967296) > 134217728) and 1 or 0)) ~= 0) then
v_r = tobit((v_a + 1))
v_A = (((tobit(v_r) % 4294967296) < 1) and tobit((v_A + 1)) or v_A)
v_a = v_r
else
if not (bor(v_r, bxor(134217728, v_s)) ~= 0) then
v_f = v_A
v_r = tobit((v_a + band(1, v_a)))
v_f = (((tobit(v_r) % 4294967296) < (tobit(v_a) % 4294967296)) and tobit((v_f + 1)) or v_f)
v_a = v_r
v_A = v_f
end
end
end
end
else
v_s = v_o
v_a = bor(lshift(v_s, 4), (rshift(v_r, 28) % 4294967296))
v_o = bor(lshift(v_t, 4), (rshift(v_o, 28) % 4294967296))
v_A = bor(band(524287, v_o), 2146959360)
end
end
end
end
end
::L271::
end
B = tobit((v_n + 32))
rf_u(0, bor(0, v_a))
rf_u(1, bor(band((-2147483648), v_t), v_A))
F64[arshift(v_e, 3)] = rf_c()
end
UA[3] = function(v_A, v_r, v_n)
local v_t, v_e = 0, 0
v_r = tobit(v_r)
v_n = tobit(v_n)
v_e = 0
do
v_A = tobit(v_A)
v_t = I32[arshift((20 + v_A), 2)]
local t319 = v_t
local t320 = v_r
local t318 = (tobit(v_n) % 4294967296)
v_e = tobit((I32[arshift((v_A + 16), 2)] - v_t))
v_e = ((t318 < (tobit(v_e) % 4294967296)) and v_n or v_e)
F.fQA(t319, t320, v_e)
I32[arshift((v_A + 20), 2)] = tobit((v_e + I32[arshift((v_A + 20), 2)]))
do return bor(0, v_n) end
end
end
UA[4] = function(v_A, v_r, v_n, v_t)

v_A = tobit(v_A)
v_n = tobit(v_n)
v_t = tobit(v_t)
v_r = tobit(v_r)
if (1 ~= bor(0, v_r)) then
F.fS(v_A, v_n, v_t)
else
F.fj(v_A, v_n, v_t)
end
do return 0 end
end
UA[5] = function(v_A, v_r, v_n, v_t, v_e, v_o)

do
v_A = tobit(v_A)
local t321 = v_A
v_r = tobit(v_r)
local t322 = v_r
v_n = tobit(v_n)
local t323 = v_n
v_t = tobit(v_t)
local t324 = v_t
v_e = tobit(v_e)
local t325 = v_e
v_o = tobit(v_o)
do return bor(0, F.fM(t321, t322, t323, t324, t325, v_o)) end
end
end
UA[6] = function(v_A, v_r, v_n, v_e, v_o, v_a, v_u)
local v_c, v_s = 0, 0
v_A = tobit(v_A)
v_r = tobit(v_r)
v_n = tobit(v_n)
v_o = tobit(v_o)
v_a = tobit(v_a)
v_u = tobit(v_u)
v_c = 0
v_s = 0
v_e = tobit(v_e)
v_c = I32[arshift(v_e, 2)]
do
if (v_r ~= 0) then
if (not (v_n ~= 0)) then
goto L272
end
do
while true do
v_n = tobit((v_n - 1))
if not (v_c ~= 0) then
F.fj(v_A, v_o, v_o)
end
v_r = tobit((v_o + v_c))
v_s = bxor(U8[bor(0, v_a)], U8[bor(0, v_r)])
I8[bor(0, v_u)] = tobit(v_s)
I8[bor(0, v_r)] = tobit(v_s)
v_u = tobit((v_u + 1))
v_a = tobit((v_a + 1))
v_c = band((v_c + 1), 15)
if not (v_n ~= 0) then goto B273 end
do
end
::C273::
end
end
::B273::
else
if (v_n ~= 0) then
do
while true do
v_n = tobit((v_n - 1))
if not (v_c ~= 0) then
F.fj(v_A, v_o, v_o)
end
v_s = U8[bor(0, v_a)]
v_r = tobit((v_o + v_c))
I8[bor(0, v_u)] = tobit(bxor(v_s, U8[bor(0, v_r)]))
I8[bor(0, v_r)] = tobit(v_s)
v_u = tobit((v_u + 1))
v_a = tobit((v_a + 1))
v_c = band((v_c + 1), 15)
if not (v_n ~= 0) then goto B274 end
do
end
::C274::
end
end
::B274::
end
end
end
::L272::
I32[arshift(v_e, 2)] = tobit(v_c)
do return 0 end
end
UA[7] = function(v_A, v_r, v_n, v_e, v_o, v_a, v_u)
local v_c, v_s, v_l, v_b = 0, 0, 0, 0
v_A = tobit(v_A)
v_r = tobit(v_r)
v_e = tobit(v_e)
v_o = tobit(v_o)
v_a = tobit(v_a)
v_u = tobit(v_u)
v_c = 0
v_s = 0
v_l = 0
v_b = 0
v_n = tobit(v_n)
v_c = I32[arshift(v_n, 2)]
if (v_r ~= 0) then
do
while true do
do
v_r = tobit((v_r - 1))
do
if (not (v_c ~= 0)) then
do
F.fj(v_A, v_e, v_o)
v_s = 16
while true do
do
if (not (v_s ~= 0)) then
goto L276
end
v_s = tobit((v_s - 1))
v_b = tobit((v_s + v_e))
v_l = tobit((U8[bor(0, v_b)] + 1))
I8[bor(0, v_b)] = tobit(v_l)
if (bor(0, v_l) == band(255, v_l)) then
goto B277
end
end
::C277::
end
end
::B277::
end
end
::L276::
I8[bor(0, v_u)] = tobit(bxor(U8[tobit((v_o + v_c))], U8[bor(0, v_a)]))
v_u = tobit((v_u + 1))
v_a = tobit((v_a + 1))
v_c = band((v_c + 1), 15)
if (not (v_r ~= 0)) then
goto B275
end
end
::C275::
end
end
::B275::
end
I32[arshift(v_n, 2)] = tobit(v_c)
do return 0 end
end
UA[8] = function(v_A, v_r, v_n)

do
v_A = tobit(v_A)
local t326 = v_A
v_r = tobit(v_r)
local t327 = v_r
v_n = tobit(v_n)
do return bor(0, F.fO(t326, t327, v_n)) end
end
end
UA[9] = function(v_A, v_r, v_n)

do
v_A = tobit(v_A)
local t328 = v_A
v_r = tobit(v_r)
local t329 = v_r
v_n = tobit(v_n)
do return bor(0, F.fH(t328, t329, v_n)) end
end
end
UA[10] = function()
local v_A = 0
v_A = F.fBA(1, 280)
if (v_A ~= 0) then
F.fMA(v_A)
end
do return bor(0, v_A) end
end
UA[11] = function(v_A)

v_A = tobit(v_A)
F.fvA(v_A)
F.fR(v_A)
end
UA[12] = function(v_A, v_r, v_n)

do
v_A = tobit(v_A)
local t330 = v_A
v_r = tobit(v_r)
local t331 = v_r
v_n = tobit(v_n)
do return bor(0, F.fU(t330, 2, t331, v_n)) end
end
end
UA[13] = function()
local v_A = 0
v_A = F.fBA(1, 392)
if (v_A ~= 0) then
F.fTA(v_A)
end
do return bor(0, v_A) end
end
UA[14] = function(v_A)

v_A = tobit(v_A)
F.fpA(v_A)
F.fR(v_A)
end
UA[15] = function(v_A, v_r, v_n)

do
v_A = tobit(v_A)
local t332 = v_A
v_r = tobit(v_r)
local t333 = v_r
v_n = tobit(v_n)
do return bor(0, F.fmA(t332, 2, t333, v_n)) end
end
end
UA[16] = function()
local v_A, v_r = 0, 0
v_r = 0
v_A = F.fBA(1, 64)
if (v_A ~= 0) then
v_r = v_A
I32[arshift(v_r, 2)] = tobit(0)
I32[arshift((v_r + 4), 2)] = tobit(0)
I32[arshift((v_r + 56), 2)] = tobit(0)
I32[arshift((v_r + 60), 2)] = tobit(0)
I32[arshift((v_r + 48), 2)] = tobit(0)
I32[arshift((v_r + 52), 2)] = tobit(0)
I32[arshift((v_r + 40), 2)] = tobit(0)
I32[arshift((v_r + 44), 2)] = tobit(0)
I32[arshift((v_r + 32), 2)] = tobit(0)
I32[arshift((v_r + 36), 2)] = tobit(0)
I32[arshift((v_r + 24), 2)] = tobit(0)
I32[arshift((v_r + 28), 2)] = tobit(0)
I32[arshift((v_r + 16), 2)] = tobit(0)
I32[arshift((v_r + 20), 2)] = tobit(0)
I32[arshift((v_r + 8), 2)] = tobit(0)
I32[arshift((v_r + 12), 2)] = tobit(0)
end
do return bor(0, v_A) end
end
UA[17] = function(v_A)

v_A = tobit(v_A)
F.fX(v_A)
I8[bor(0, v_A)] = tobit(0)
I8[tobit((v_A + 1))] = tobit(0)
I8[tobit((v_A + 2))] = tobit(0)
I8[tobit((v_A + 3))] = tobit(0)
I8[tobit((v_A + 4))] = tobit(0)
I8[tobit((v_A + 5))] = tobit(0)
I8[tobit((v_A + 6))] = tobit(0)
I8[tobit((v_A + 7))] = tobit(0)
I8[tobit((v_A + 8))] = tobit(0)
I8[tobit((v_A + 9))] = tobit(0)
I8[tobit((v_A + 10))] = tobit(0)
I8[tobit((v_A + 11))] = tobit(0)
I8[tobit((v_A + 12))] = tobit(0)
I8[tobit((v_A + 13))] = tobit(0)
I8[tobit((v_A + 14))] = tobit(0)
I8[tobit((v_A + 15))] = tobit(0)
I8[tobit((v_A + 16))] = tobit(0)
I8[tobit((v_A + 17))] = tobit(0)
I8[tobit((v_A + 18))] = tobit(0)
I8[tobit((v_A + 19))] = tobit(0)
I8[tobit((v_A + 20))] = tobit(0)
I8[tobit((v_A + 21))] = tobit(0)
I8[tobit((v_A + 22))] = tobit(0)
I8[tobit((v_A + 23))] = tobit(0)
I8[tobit((v_A + 24))] = tobit(0)
I8[tobit((v_A + 25))] = tobit(0)
I8[tobit((v_A + 26))] = tobit(0)
I8[tobit((v_A + 27))] = tobit(0)
I8[tobit((v_A + 28))] = tobit(0)
I8[tobit((v_A + 29))] = tobit(0)
I8[tobit((v_A + 30))] = tobit(0)
I8[tobit((v_A + 31))] = tobit(0)
I8[tobit((v_A + 32))] = tobit(0)
I8[tobit((v_A + 33))] = tobit(0)
I8[tobit((v_A + 34))] = tobit(0)
I8[tobit((v_A + 35))] = tobit(0)
I8[tobit((v_A + 36))] = tobit(0)
I8[tobit((v_A + 37))] = tobit(0)
I8[tobit((v_A + 38))] = tobit(0)
I8[tobit((v_A + 39))] = tobit(0)
I8[tobit((v_A + 40))] = tobit(0)
I8[tobit((v_A + 41))] = tobit(0)
I8[tobit((v_A + 42))] = tobit(0)
I8[tobit((v_A + 43))] = tobit(0)
I8[tobit((v_A + 44))] = tobit(0)
I8[tobit((v_A + 45))] = tobit(0)
I8[tobit((v_A + 46))] = tobit(0)
I8[tobit((v_A + 47))] = tobit(0)
I8[tobit((v_A + 48))] = tobit(0)
I8[tobit((v_A + 49))] = tobit(0)
I8[tobit((v_A + 50))] = tobit(0)
I8[tobit((v_A + 51))] = tobit(0)
I8[tobit((v_A + 52))] = tobit(0)
I8[tobit((v_A + 53))] = tobit(0)
I8[tobit((v_A + 54))] = tobit(0)
I8[tobit((v_A + 55))] = tobit(0)
I8[tobit((v_A + 56))] = tobit(0)
I8[tobit((v_A + 57))] = tobit(0)
I8[tobit((v_A + 58))] = tobit(0)
I8[tobit((v_A + 59))] = tobit(0)
I8[tobit((v_A + 60))] = tobit(0)
I8[tobit((v_A + 61))] = tobit(0)
I8[tobit((v_A + 62))] = tobit(0)
I8[tobit((v_A + 63))] = tobit(0)
F.fR(v_A)
end
UA[18] = function(v_A, v_r, v_n, v_e)
local v_o, v_a, v_u, v_c, v_s, v_l, v_b, v_v = 0, 0, 0, 0, 0, 0, 0, 0
v_r = tobit(v_r)
v_n = tobit(v_n)
v_e = tobit(v_e)
v_o = 0
v_a = 0
v_u = 0
v_c = 0
v_s = 0
v_l = 0
v_b = 0
v_v = 0
do
v_A = tobit(v_A)
v_o = I32[arshift((4 + v_A), 2)]
v_a = I32[arshift(v_A, 2)]
if (v_r ~= 0) then
do
do
v_c = tobit((v_A + 8))
while true do
do
local t334 = v_c
v_a = band((v_a + 1), 255)
v_l = tobit((t334 + v_a))
v_s = U8[bor(0, v_l)]
local t335 = v_c
v_o = band((v_s + v_o), 255)
v_b = tobit((t335 + v_o))
v_v = U8[bor(0, v_b)]
I8[bor(0, v_l)] = tobit(v_v)
I8[bor(0, v_b)] = tobit(v_s)
I8[tobit((v_e + v_u))] = tobit(bxor(U8[tobit((band((v_s + v_v), 255) + v_c))], U8[tobit((v_n + v_u))]))
v_u = tobit((v_u + 1))
if not (bor(0, v_u) ~= bor(0, v_r)) then goto B278 end
end
do
end
::C278::
end
end
::B278::
end
end
end
I32[arshift((v_A + 4), 2)] = tobit(v_o)
I32[arshift(v_A, 2)] = tobit(v_a)
do return 0 end
end
UA[19] = function(v_A, v_r, v_n)
local v_e, v_o, v_a, v_u, v_c, v_s = 0, 0, 0, 0, 0, 0
v_A = tobit(v_A)
v_r = tobit(v_r)
v_e = 0
v_o = 0
v_a = 0
v_u = 0
v_c = 0
v_s = 0
do
v_n = tobit(v_n)
if (band(7, v_n) ~= 0) then
v_A = (-24832)
else
do
do
do
v_s = tobit((rshift(v_n, 3) % 4294967296))
v_n = 0
I32[arshift(v_A, 2)] = tobit(0)
I32[arshift((v_A + 4), 2)] = tobit(0)
while true do
do
v_o = tobit((v_A + 8))
I8[tobit((v_o + v_n))] = tobit(v_n)
v_e = bor(1, v_n)
I8[tobit((v_e + v_o))] = tobit(v_e)
v_e = bor(2, v_n)
I8[tobit((v_e + v_o))] = tobit(v_e)
v_e = bor(3, v_n)
I8[tobit((v_e + v_o))] = tobit(v_e)
v_e = bor(4, v_n)
I8[tobit((v_e + v_o))] = tobit(v_e)
v_e = bor(5, v_n)
I8[tobit((v_e + v_o))] = tobit(v_e)
v_e = bor(6, v_n)
I8[tobit((v_e + v_o))] = tobit(v_e)
v_e = v_o
local t336 = v_e
v_o = bor(7, v_n)
I8[tobit((t336 + v_o))] = tobit(v_o)
v_n = tobit((v_n + 8))
if not (256 ~= bor(0, v_n)) then goto B279 end
end
do
end
::C279::
end
end
::B279::
end
do
do
v_A = tobit((v_A + 8))
v_n = 0
v_o = 0
while true do
do
v_e = (((tobit(v_n) % 4294967296) < (tobit(v_s) % 4294967296)) and v_n or 0)
v_u = tobit((v_A + v_a))
v_c = U8[bor(0, v_u)]
local t337 = v_A
v_o = band((U8[tobit((v_e + v_r))] + tobit((v_c + v_o))), 255)
v_n = tobit((t337 + v_o))
I8[bor(0, v_u)] = tobit(U8[bor(0, v_n)])
I8[bor(0, v_n)] = tobit(v_c)
v_n = tobit((v_e + 1))
v_a = tobit((v_a + 1))
if not (256 ~= bor(0, v_a)) then goto B280 end
end
do
end
::C280::
end
end
::B280::
end
v_A = 0
end
end
end
do return bor(0, v_A) end
end
UA[20] = function()
local v_A = 0
v_A = F.fBA(1, 264)
if (v_A ~= 0) then
F.fOA(v_A, 0, 264)
end
do return bor(0, v_A) end
end
UA[21] = function(v_A)
local v_r, v_n = 0, 0
v_r = 0
v_n = 0
do
v_A = tobit(v_A)
v_r = v_A
if (v_r ~= 0) then
do
v_n = 252
while true do
do
I8[bor(0, v_r)] = tobit(0)
I8[tobit((v_r + 1))] = tobit(0)
I8[tobit((v_r + 2))] = tobit(0)
I8[tobit((v_r + 3))] = tobit(0)
I8[tobit((v_r + 4))] = tobit(0)
I8[tobit((v_r + 5))] = tobit(0)
I8[tobit((v_r + 6))] = tobit(0)
I8[tobit((v_r + 7))] = tobit(0)
I8[tobit((v_r + 8))] = tobit(0)
I8[tobit((v_r + 9))] = tobit(0)
I8[tobit((v_r + 10))] = tobit(0)
I8[tobit((v_r + 11))] = tobit(0)
if (not (v_n ~= 0)) then
goto L281
end
v_r = tobit((v_r + 12))
v_n = tobit((v_n - 12))
end
::C282::
end
end
::B282::
end
end
::L281::
F.fR(v_A)
end
UA[22] = function(v_A, v_r, v_n, v_t)

do
v_A = tobit(v_A)
local t338 = v_A
v_r = tobit(v_r)
local t339 = v_r
v_n = tobit(v_n)
local t340 = v_n
v_t = tobit(v_t)
do return bor(0, F.f_(t338, t339, t340, v_t)) end
end
end
UA[23] = function(v_A, v_r, v_n, v_e, v_o, v_i)
local v_a, v_u, v_c = 0, 0, 0
v_A = tobit(v_A)
v_r = tobit(v_r)
v_e = tobit(v_e)
v_o = tobit(v_o)
v_i = tobit(v_i)
v_a = 0
v_u = 0
v_c = 0
v_c = (-24)
do
v_n = tobit(v_n)
if (not (band(7, v_n) ~= 0)) then
if (v_r ~= 0) then
v_c = 0
if (not (v_n ~= 0)) then
goto L283
end
do
v_a = U8[bor(0, v_e)]
while true do
I8[bor(0, v_i)] = tobit(bxor(U8[bor(0, v_o)], v_a))
I8[tobit((v_i + 1))] = tobit(bxor(U8[tobit((v_e + 1))], U8[tobit((v_o + 1))]))
I8[tobit((v_i + 2))] = tobit(bxor(U8[tobit((v_e + 2))], U8[tobit((v_o + 2))]))
I8[tobit((v_i + 3))] = tobit(bxor(U8[tobit((v_e + 3))], U8[tobit((v_o + 3))]))
I8[tobit((v_i + 4))] = tobit(bxor(U8[tobit((v_e + 4))], U8[tobit((v_o + 4))]))
I8[tobit((v_i + 5))] = tobit(bxor(U8[tobit((v_e + 5))], U8[tobit((v_o + 5))]))
I8[tobit((v_i + 6))] = tobit(bxor(U8[tobit((v_e + 6))], U8[tobit((v_o + 6))]))
I8[tobit((v_i + 7))] = tobit(bxor(U8[tobit((v_e + 7))], U8[tobit((v_o + 7))]))
F.f_(v_A, v_r, v_i, v_i)
v_u = bor(bor(bor(U8[tobit((v_i + 4))], lshift(U8[tobit((v_i + 5))], 8)), lshift(U8[tobit((v_i + 6))], 16)), lshift(U8[tobit((v_i + 7))], 24))
v_a = bor(bor(bor(U8[bor(0, v_i)], lshift(U8[tobit((v_i + 1))], 8)), lshift(U8[tobit((v_i + 2))], 16)), lshift(U8[tobit((v_i + 3))], 24))
I8[bor(0, v_e)] = tobit(v_a)
I8[tobit((v_e + 1))] = tobit((rshift(v_a, 8) % 4294967296))
I8[tobit((v_e + 2))] = tobit((rshift(v_a, 16) % 4294967296))
I8[tobit((v_e + 3))] = tobit((rshift(v_a, 24) % 4294967296))
I8[tobit((v_e + 4))] = tobit(v_u)
I8[tobit((v_e + 5))] = tobit((rshift(v_u, 8) % 4294967296))
I8[tobit((v_e + 6))] = tobit((rshift(v_u, 16) % 4294967296))
I8[tobit((v_e + 7))] = tobit((rshift(v_u, 24) % 4294967296))
v_i = tobit((v_i + 8))
v_o = tobit((v_o + 8))
v_n = tobit((v_n - 8))
if not (v_n ~= 0) then goto B284 end
do
end
::C284::
end
end
::B284::
else
v_c = 0
if (v_n ~= 0) then
do
while true do
v_a = bor(bor(bor(U8[tobit((v_o + 4))], lshift(U8[tobit((v_o + 5))], 8)), lshift(U8[tobit((v_o + 6))], 16)), lshift(U8[tobit((v_o + 7))], 24))
v_r = bor(bor(bor(U8[bor(0, v_o)], lshift(U8[tobit((v_o + 1))], 8)), lshift(U8[tobit((v_o + 2))], 16)), lshift(U8[tobit((v_o + 3))], 24))
F.f_(v_A, 0, v_o, v_i)
I8[bor(0, v_i)] = tobit(bxor(U8[bor(0, v_e)], U8[bor(0, v_i)]))
I8[tobit((v_i + 1))] = tobit(bxor(U8[tobit((v_e + 1))], U8[tobit((v_i + 1))]))
I8[tobit((v_i + 2))] = tobit(bxor(U8[tobit((v_e + 2))], U8[tobit((v_i + 2))]))
I8[tobit((v_i + 3))] = tobit(bxor(U8[tobit((v_e + 3))], U8[tobit((v_i + 3))]))
I8[tobit((v_i + 4))] = tobit(bxor(U8[tobit((v_e + 4))], U8[tobit((v_i + 4))]))
I8[tobit((v_i + 5))] = tobit(bxor(U8[tobit((v_e + 5))], U8[tobit((v_i + 5))]))
I8[tobit((v_i + 6))] = tobit(bxor(U8[tobit((v_e + 6))], U8[tobit((v_i + 6))]))
I8[tobit((v_i + 7))] = tobit(bxor(U8[tobit((v_e + 7))], U8[tobit((v_i + 7))]))
I8[bor(0, v_e)] = tobit(v_r)
I8[tobit((v_e + 1))] = tobit((rshift(v_r, 8) % 4294967296))
I8[tobit((v_e + 2))] = tobit((rshift(v_r, 16) % 4294967296))
I8[tobit((v_e + 3))] = tobit((rshift(v_r, 24) % 4294967296))
I8[tobit((v_e + 4))] = tobit(v_a)
I8[tobit((v_e + 5))] = tobit((rshift(v_a, 8) % 4294967296))
I8[tobit((v_e + 6))] = tobit((rshift(v_a, 16) % 4294967296))
I8[tobit((v_e + 7))] = tobit((rshift(v_a, 24) % 4294967296))
v_i = tobit((v_i + 8))
v_o = tobit((v_o + 8))
v_n = tobit((v_n - 8))
if not (v_n ~= 0) then goto B285 end
do
end
::C285::
end
end
::B285::
end
end
end
end
::L283::
do return bor(0, v_c) end
end
UA[24] = function(v_A, v_r, v_n, v_e, v_o, v_a, v_u)
local v_c, v_s = 0, 0
v_A = tobit(v_A)
v_r = tobit(v_r)
v_n = tobit(v_n)
v_o = tobit(v_o)
v_a = tobit(v_a)
v_u = tobit(v_u)
v_c = 0
v_s = 0
v_e = tobit(v_e)
v_c = I32[arshift(v_e, 2)]
do
if (v_r ~= 0) then
if (not (v_n ~= 0)) then
goto L286
end
do
while true do
v_n = tobit((v_n - 1))
if not (v_c ~= 0) then
F.f_(v_A, 1, v_o, v_o)
end
v_r = tobit((v_o + v_c))
v_s = bxor(U8[bor(0, v_a)], U8[bor(0, v_r)])
I8[bor(0, v_u)] = tobit(v_s)
I8[bor(0, v_r)] = tobit(v_s)
v_u = tobit((v_u + 1))
v_a = tobit((v_a + 1))
v_c = band((v_c + 1), 7)
if not (v_n ~= 0) then goto B287 end
do
end
::C287::
end
end
::B287::
else
if (v_n ~= 0) then
do
while true do
v_n = tobit((v_n - 1))
if not (v_c ~= 0) then
F.f_(v_A, 1, v_o, v_o)
end
v_s = U8[bor(0, v_a)]
v_r = tobit((v_o + v_c))
I8[bor(0, v_u)] = tobit(bxor(v_s, U8[bor(0, v_r)]))
I8[bor(0, v_r)] = tobit(v_s)
v_u = tobit((v_u + 1))
v_a = tobit((v_a + 1))
v_c = band((v_c + 1), 7)
if not (v_n ~= 0) then goto B288 end
do
end
::C288::
end
end
::B288::
end
end
end
::L286::
I32[arshift(v_e, 2)] = tobit(v_c)
do return 0 end
end
UA[25] = function(v_A, v_r, v_n, v_e, v_o, v_a, v_u)
local v_c, v_s, v_l, v_b = 0, 0, 0, 0
v_A = tobit(v_A)
v_r = tobit(v_r)
v_e = tobit(v_e)
v_o = tobit(v_o)
v_a = tobit(v_a)
v_u = tobit(v_u)
v_c = 0
v_s = 0
v_l = 0
v_b = 0
v_n = tobit(v_n)
v_c = I32[arshift(v_n, 2)]
if (v_r ~= 0) then
do
while true do
do
v_r = tobit((v_r - 1))
do
if (not (v_c ~= 0)) then
do
F.f_(v_A, 1, v_e, v_o)
v_s = 8
while true do
do
if (not (v_s ~= 0)) then
goto L290
end
v_s = tobit((v_s - 1))
v_b = tobit((v_s + v_e))
v_l = tobit((U8[bor(0, v_b)] + 1))
I8[bor(0, v_b)] = tobit(v_l)
if (bor(0, v_l) == band(255, v_l)) then
goto B291
end
end
::C291::
end
end
::B291::
end
end
::L290::
I8[bor(0, v_u)] = tobit(bxor(U8[tobit((v_o + v_c))], U8[bor(0, v_a)]))
v_u = tobit((v_u + 1))
v_a = tobit((v_a + 1))
v_c = band((v_c + 1), 7)
if (not (v_r ~= 0)) then
goto B289
end
end
::C289::
end
end
::B289::
end
I32[arshift(v_n, 2)] = tobit(v_c)
do return 0 end
end
UA[26] = function(v_A, v_r, v_n)
local v_t, v_e, v_o, v_a, v_u, v_c, v_s = 0, 0, 0, 0, 0, 0, 0
v_e = 0
v_o = 0
v_a = 0
v_u = 0
v_c = 0
v_s = 0
do
v_A = tobit(v_A)
v_t = v_A
v_r = tobit(v_r)
v_A = v_r
v_n = tobit(v_n)
if (bor(band(7, v_n), (((tobit((v_n - 32)) % 4294967296) > 416) and 1 or 0)) ~= 0) then
v_A = (-22)
else
do
do
do
F.fQA(tobit((v_t + 72)), 3936, 4096)
v_n = tobit((rshift(v_n, 3) % 4294967296))
v_r = 0
while true do
do
local t343 = (tobit(v_n) % 4294967296)
local t342 = (tobit(v_n) % 4294967296)
local t341 = (tobit(v_n) % 4294967296)
v_e = tobit((v_r + 1))
v_a = ((t341 > (tobit(v_e) % 4294967296)) and v_e or 0)
v_e = tobit((v_a + 1))
v_u = ((t342 > (tobit(v_e) % 4294967296)) and v_e or 0)
v_e = tobit((v_u + 1))
v_e = ((t343 > (tobit(v_e) % 4294967296)) and v_e or 0)
v_s = lshift(v_o, 2)
I32[arshift((v_s + v_t), 2)] = tobit(bxor(I32[arshift((v_s + 8032), 2)], bor(U8[tobit((v_A + v_e))], lshift(bor(bor(U8[tobit((v_A + v_u))], lshift(U8[tobit((v_A + v_r))], 16)), lshift(U8[tobit((v_A + v_a))], 8)), 8))))
v_r = tobit((v_e + 1))
v_r = (((tobit(v_r) % 4294967296) < (tobit(v_n) % 4294967296)) and v_r or 0)
v_o = tobit((v_o + 1))
if not (18 ~= bor(0, v_o)) then goto B292 end
end
do
end
::C292::
end
end
::B292::
end
do
v_n = 0
v_a = tobit((v_t + 72))
v_e = 0
v_A = 0
while true do
do
do
v_o = 0
while true do
v_r = v_e
v_e = bxor(I32[arshift((lshift(v_o, 2) + v_t), 2)], v_A)
v_A = bxor(v_r, (bxor((I32[arshift((1024 + tobit((v_a + band((rshift(v_e, 14) % 4294967296), 1020)))), 2)] + I32[arshift((v_a + band((rshift(v_e, 22) % 4294967296), 1020)), 2)]), I32[arshift((2048 + tobit((v_a + band((rshift(v_e, 6) % 4294967296), 1020)))), 2)]) + I32[arshift((3072 + tobit((v_a + lshift(band(255, v_e), 2)))), 2)]))
v_o = tobit((v_o + 1))
if not (16 ~= bor(0, v_o)) then goto B294 end
do
end
::C294::
end
end
::B294::
v_o = I32[arshift((v_t + 64), 2)]
v_u = lshift(v_n, 2)
v_r = bxor(I32[arshift((v_t + 68), 2)], v_e)
I32[arshift((v_u + v_t), 2)] = tobit(v_r)
v_e = bxor(v_A, v_o)
I32[arshift((bor(4, v_u) + v_t), 2)] = tobit(v_e)
v_o = (((tobit(v_n) % 4294967296) < 16) and 1 or 0)
v_n = tobit((v_n + 2))
v_A = v_r
if (not (v_o ~= 0)) then
goto B293
end
end
::C293::
end
end
::B293::
do
v_u = I32[arshift((v_t + 68), 2)]
v_s = I32[arshift((v_t + 64), 2)]
v_n = 0
v_a = tobit((v_t + 72))
while true do
do
do
v_o = 0
while true do
v_A = v_e
v_e = bxor(I32[arshift((lshift(v_o, 2) + v_t), 2)], v_r)
v_r = bxor(v_A, (bxor((I32[arshift((1024 + tobit((v_a + band((rshift(v_e, 14) % 4294967296), 1020)))), 2)] + I32[arshift((v_a + band((rshift(v_e, 22) % 4294967296), 1020)), 2)]), I32[arshift((2048 + tobit((v_a + band((rshift(v_e, 6) % 4294967296), 1020)))), 2)]) + I32[arshift((3072 + tobit((v_a + lshift(band(255, v_e), 2)))), 2)]))
v_o = tobit((v_o + 1))
if not (16 ~= bor(0, v_o)) then goto B296 end
do
end
::C296::
end
end
::B296::
v_A = bxor(v_e, v_u)
v_o = lshift(v_n, 2)
I32[arshift((v_o + v_a), 2)] = tobit(v_A)
v_e = bxor(v_r, v_s)
I32[arshift((v_a + bor(4, v_o)), 2)] = tobit(v_e)
v_o = (((tobit(v_n) % 4294967296) < 254) and 1 or 0)
v_n = tobit((v_n + 2))
v_r = v_A
if (not (v_o ~= 0)) then
goto B295
end
end
::C295::
end
end
::B295::
do
v_n = 0
v_a = tobit((v_t + 72))
v_c = tobit((v_t + 1096))
while true do
do
do
v_o = 0
while true do
v_r = v_e
v_e = bxor(I32[arshift((lshift(v_o, 2) + v_t), 2)], v_A)
v_A = bxor(v_r, (bxor((I32[arshift((1024 + tobit((v_a + band((rshift(v_e, 14) % 4294967296), 1020)))), 2)] + I32[arshift((v_a + band((rshift(v_e, 22) % 4294967296), 1020)), 2)]), I32[arshift((2048 + tobit((v_a + band((rshift(v_e, 6) % 4294967296), 1020)))), 2)]) + I32[arshift((3072 + tobit((v_a + lshift(band(255, v_e), 2)))), 2)]))
v_o = tobit((v_o + 1))
if not (16 ~= bor(0, v_o)) then goto B298 end
do
end
::C298::
end
end
::B298::
v_r = bxor(v_e, v_u)
v_o = lshift(v_n, 2)
I32[arshift((v_o + v_c), 2)] = tobit(v_r)
v_e = bxor(v_A, v_s)
I32[arshift((v_c + bor(4, v_o)), 2)] = tobit(v_e)
v_o = (((tobit(v_n) % 4294967296) < 254) and 1 or 0)
v_n = tobit((v_n + 2))
v_A = v_r
if (not (v_o ~= 0)) then
goto B297
end
end
::C297::
end
end
::B297::
do
v_n = 0
v_a = tobit((v_t + 72))
v_c = tobit((v_t + 2120))
while true do
do
do
v_o = 0
while true do
v_A = v_e
v_e = bxor(I32[arshift((lshift(v_o, 2) + v_t), 2)], v_r)
v_r = bxor(v_A, (bxor((I32[arshift((1024 + tobit((v_a + band((rshift(v_e, 14) % 4294967296), 1020)))), 2)] + I32[arshift((v_a + band((rshift(v_e, 22) % 4294967296), 1020)), 2)]), I32[arshift((2048 + tobit((v_a + band((rshift(v_e, 6) % 4294967296), 1020)))), 2)]) + I32[arshift((3072 + tobit((v_a + lshift(band(255, v_e), 2)))), 2)]))
v_o = tobit((v_o + 1))
if not (16 ~= bor(0, v_o)) then goto B300 end
do
end
::C300::
end
end
::B300::
v_A = bxor(v_e, v_u)
v_o = lshift(v_n, 2)
I32[arshift((v_o + v_c), 2)] = tobit(v_A)
v_e = bxor(v_r, v_s)
I32[arshift((v_c + bor(4, v_o)), 2)] = tobit(v_e)
v_o = (((tobit(v_n) % 4294967296) < 254) and 1 or 0)
v_n = tobit((v_n + 2))
v_r = v_A
if (not (v_o ~= 0)) then
goto B299
end
end
::C299::
end
end
::B299::
do
v_r = 0
v_a = tobit((v_t + 72))
v_c = tobit((v_t + 3144))
while true do
do
do
v_o = 0
while true do
v_n = v_e
v_e = bxor(I32[arshift((lshift(v_o, 2) + v_t), 2)], v_A)
v_A = bxor(v_n, (bxor((I32[arshift((1024 + tobit((v_a + band((rshift(v_e, 14) % 4294967296), 1020)))), 2)] + I32[arshift((v_a + band((rshift(v_e, 22) % 4294967296), 1020)), 2)]), I32[arshift((2048 + tobit((v_a + band((rshift(v_e, 6) % 4294967296), 1020)))), 2)]) + I32[arshift((3072 + tobit((v_a + lshift(band(255, v_e), 2)))), 2)]))
v_o = tobit((v_o + 1))
if not (16 ~= bor(0, v_o)) then goto B302 end
do
end
::C302::
end
end
::B302::
v_n = bxor(v_e, v_u)
v_o = lshift(v_r, 2)
I32[arshift((v_o + v_c), 2)] = tobit(v_n)
v_e = bxor(v_A, v_s)
I32[arshift((v_c + bor(4, v_o)), 2)] = tobit(v_e)
v_o = (((tobit(v_r) % 4294967296) < 254) and 1 or 0)
v_r = tobit((v_r + 2))
v_A = v_n
if (not (v_o ~= 0)) then
goto B301
end
end
::C301::
end
end
::B301::
v_A = 0
end
end
end
do return bor(0, v_A) end
end
UA[27] = function()
local v_A = 0
v_A = F.fBA(1, 4168)
if (v_A ~= 0) then
F.fOA(v_A, 0, 4168)
end
do return bor(0, v_A) end
end
UA[28] = function(v_A)
local v_r, v_n = 0, 0
v_r = 0
v_n = 0
do
v_A = tobit(v_A)
v_r = v_A
if (v_r ~= 0) then
do
v_n = 4160
while true do
do
I8[bor(0, v_r)] = tobit(0)
I8[tobit((v_r + 1))] = tobit(0)
I8[tobit((v_r + 2))] = tobit(0)
I8[tobit((v_r + 3))] = tobit(0)
I8[tobit((v_r + 4))] = tobit(0)
I8[tobit((v_r + 5))] = tobit(0)
I8[tobit((v_r + 6))] = tobit(0)
I8[tobit((v_r + 7))] = tobit(0)
if (not (v_n ~= 0)) then
goto L303
end
v_r = tobit((v_r + 8))
v_n = tobit((v_n - 8))
end
::C304::
end
end
::B304::
end
end
::L303::
F.fR(v_A)
end
UA[29] = function(v_A, v_r, v_n, v_t)

do
v_A = tobit(v_A)
local t344 = v_A
v_n = tobit(v_n)
local t345 = v_n
v_t = tobit(v_t)
do return bor(0, F.fD(t344, t345, v_t)) end
end
end
UA[30] = function(v_A, v_r, v_n, v_e, v_o, v_a)
local v_u, v_c, v_s = 0, 0, 0
v_A = tobit(v_A)
v_r = tobit(v_r)
v_e = tobit(v_e)
v_o = tobit(v_o)
v_a = tobit(v_a)
v_c = 0
v_s = 0
v_u = tobit((B - 16))
B = v_u
v_s = (-38)
do
v_n = tobit(v_n)
if (not (band(15, v_n) ~= 0)) then
if (v_r ~= 0) then
v_s = 0
if (not (v_n ~= 0)) then
goto L305
end
do
while true do
I8[bor(0, v_a)] = tobit(bxor(U8[bor(0, v_e)], U8[bor(0, v_o)]))
I8[tobit((v_a + 1))] = tobit(bxor(U8[tobit((v_e + 1))], U8[tobit((v_o + 1))]))
I8[tobit((v_a + 2))] = tobit(bxor(U8[tobit((v_e + 2))], U8[tobit((v_o + 2))]))
I8[tobit((v_a + 3))] = tobit(bxor(U8[tobit((v_e + 3))], U8[tobit((v_o + 3))]))
I8[tobit((v_a + 4))] = tobit(bxor(U8[tobit((v_e + 4))], U8[tobit((v_o + 4))]))
I8[tobit((v_a + 5))] = tobit(bxor(U8[tobit((v_e + 5))], U8[tobit((v_o + 5))]))
I8[tobit((v_a + 6))] = tobit(bxor(U8[tobit((v_e + 6))], U8[tobit((v_o + 6))]))
I8[tobit((v_a + 7))] = tobit(bxor(U8[tobit((v_e + 7))], U8[tobit((v_o + 7))]))
I8[tobit((v_a + 8))] = tobit(bxor(U8[tobit((v_e + 8))], U8[tobit((v_o + 8))]))
I8[tobit((v_a + 9))] = tobit(bxor(U8[tobit((v_e + 9))], U8[tobit((v_o + 9))]))
I8[tobit((v_a + 10))] = tobit(bxor(U8[tobit((v_e + 10))], U8[tobit((v_o + 10))]))
I8[tobit((v_a + 11))] = tobit(bxor(U8[tobit((v_e + 11))], U8[tobit((v_o + 11))]))
I8[tobit((v_a + 12))] = tobit(bxor(U8[tobit((v_e + 12))], U8[tobit((v_o + 12))]))
I8[tobit((v_a + 13))] = tobit(bxor(U8[tobit((v_e + 13))], U8[tobit((v_o + 13))]))
I8[tobit((v_a + 14))] = tobit(bxor(U8[tobit((v_e + 14))], U8[tobit((v_o + 14))]))
I8[tobit((v_a + 15))] = tobit(bxor(U8[tobit((v_e + 15))], U8[tobit((v_o + 15))]))
F.fD(v_A, v_a, v_a)
v_r = bor(bor(bor(U8[tobit((v_a + 12))], lshift(U8[tobit((v_a + 13))], 8)), lshift(U8[tobit((v_a + 14))], 16)), lshift(U8[tobit((v_a + 15))], 24))
v_c = bor(bor(bor(U8[tobit((v_a + 8))], lshift(U8[tobit((v_a + 9))], 8)), lshift(U8[tobit((v_a + 10))], 16)), lshift(U8[tobit((v_a + 11))], 24))
I8[tobit((v_e + 8))] = tobit(v_c)
I8[tobit((v_e + 9))] = tobit((rshift(v_c, 8) % 4294967296))
I8[tobit((v_e + 10))] = tobit((rshift(v_c, 16) % 4294967296))
I8[tobit((v_e + 11))] = tobit((rshift(v_c, 24) % 4294967296))
I8[tobit((v_e + 12))] = tobit(v_r)
I8[tobit((v_e + 13))] = tobit((rshift(v_r, 8) % 4294967296))
I8[tobit((v_e + 14))] = tobit((rshift(v_r, 16) % 4294967296))
I8[tobit((v_e + 15))] = tobit((rshift(v_r, 24) % 4294967296))
v_r = bor(bor(bor(U8[tobit((v_a + 4))], lshift(U8[tobit((v_a + 5))], 8)), lshift(U8[tobit((v_a + 6))], 16)), lshift(U8[tobit((v_a + 7))], 24))
v_c = bor(bor(bor(U8[bor(0, v_a)], lshift(U8[tobit((v_a + 1))], 8)), lshift(U8[tobit((v_a + 2))], 16)), lshift(U8[tobit((v_a + 3))], 24))
I8[bor(0, v_e)] = tobit(v_c)
I8[tobit((v_e + 1))] = tobit((rshift(v_c, 8) % 4294967296))
I8[tobit((v_e + 2))] = tobit((rshift(v_c, 16) % 4294967296))
I8[tobit((v_e + 3))] = tobit((rshift(v_c, 24) % 4294967296))
I8[tobit((v_e + 4))] = tobit(v_r)
I8[tobit((v_e + 5))] = tobit((rshift(v_r, 8) % 4294967296))
I8[tobit((v_e + 6))] = tobit((rshift(v_r, 16) % 4294967296))
I8[tobit((v_e + 7))] = tobit((rshift(v_r, 24) % 4294967296))
v_a = tobit((v_a + 16))
v_o = tobit((v_o + 16))
v_n = tobit((v_n - 16))
if not (v_n ~= 0) then goto B306 end
do
end
::C306::
end
end
::B306::
else
v_s = 0
if (v_n ~= 0) then
do
while true do
v_r = bor(bor(bor(U8[tobit((v_o + 4))], lshift(U8[tobit((v_o + 5))], 8)), lshift(U8[tobit((v_o + 6))], 16)), lshift(U8[tobit((v_o + 7))], 24))
I32[arshift(v_u, 2)] = tobit(bor(bor(bor(U8[bor(0, v_o)], lshift(U8[tobit((v_o + 1))], 8)), lshift(U8[tobit((v_o + 2))], 16)), lshift(U8[tobit((v_o + 3))], 24)))
I32[arshift((v_u + 4), 2)] = tobit(v_r)
v_r = bor(bor(bor(U8[tobit((v_o + 12))], lshift(U8[tobit((v_o + 13))], 8)), lshift(U8[tobit((v_o + 14))], 16)), lshift(U8[tobit((v_o + 15))], 24))
I32[arshift((v_u + 8), 2)] = tobit(bor(bor(bor(U8[tobit((v_o + 8))], lshift(U8[tobit((v_o + 9))], 8)), lshift(U8[tobit((v_o + 10))], 16)), lshift(U8[tobit((v_o + 11))], 24)))
I32[arshift((v_u + 12), 2)] = tobit(v_r)
F.fD(v_A, v_o, v_a)
I8[bor(0, v_a)] = tobit(bxor(U8[bor(0, v_e)], U8[bor(0, v_a)]))
I8[tobit((v_a + 1))] = tobit(bxor(U8[tobit((v_e + 1))], U8[tobit((v_a + 1))]))
I8[tobit((v_a + 2))] = tobit(bxor(U8[tobit((v_e + 2))], U8[tobit((v_a + 2))]))
I8[tobit((v_a + 3))] = tobit(bxor(U8[tobit((v_e + 3))], U8[tobit((v_a + 3))]))
I8[tobit((v_a + 4))] = tobit(bxor(U8[tobit((v_e + 4))], U8[tobit((v_a + 4))]))
I8[tobit((v_a + 5))] = tobit(bxor(U8[tobit((v_e + 5))], U8[tobit((v_a + 5))]))
I8[tobit((v_a + 6))] = tobit(bxor(U8[tobit((v_e + 6))], U8[tobit((v_a + 6))]))
I8[tobit((v_a + 7))] = tobit(bxor(U8[tobit((v_e + 7))], U8[tobit((v_a + 7))]))
I8[tobit((v_a + 8))] = tobit(bxor(U8[tobit((v_e + 8))], U8[tobit((v_a + 8))]))
I8[tobit((v_a + 9))] = tobit(bxor(U8[tobit((v_e + 9))], U8[tobit((v_a + 9))]))
I8[tobit((v_a + 10))] = tobit(bxor(U8[tobit((v_e + 10))], U8[tobit((v_a + 10))]))
I8[tobit((v_a + 11))] = tobit(bxor(U8[tobit((v_e + 11))], U8[tobit((v_a + 11))]))
I8[tobit((v_a + 12))] = tobit(bxor(U8[tobit((v_e + 12))], U8[tobit((v_a + 12))]))
I8[tobit((v_a + 13))] = tobit(bxor(U8[tobit((v_e + 13))], U8[tobit((v_a + 13))]))
I8[tobit((v_a + 14))] = tobit(bxor(U8[tobit((v_e + 14))], U8[tobit((v_a + 14))]))
I8[tobit((v_a + 15))] = tobit(bxor(U8[tobit((v_e + 15))], U8[tobit((v_a + 15))]))
v_r = I32[arshift((v_u + 12), 2)]
v_c = I32[arshift((v_u + 8), 2)]
I8[tobit((v_e + 8))] = tobit(v_c)
I8[tobit((v_e + 9))] = tobit((rshift(v_c, 8) % 4294967296))
I8[tobit((v_e + 10))] = tobit((rshift(v_c, 16) % 4294967296))
I8[tobit((v_e + 11))] = tobit((rshift(v_c, 24) % 4294967296))
I8[tobit((v_e + 12))] = tobit(v_r)
I8[tobit((v_e + 13))] = tobit((rshift(v_r, 8) % 4294967296))
I8[tobit((v_e + 14))] = tobit((rshift(v_r, 16) % 4294967296))
I8[tobit((v_e + 15))] = tobit((rshift(v_r, 24) % 4294967296))
v_r = I32[arshift((v_u + 4), 2)]
v_c = I32[arshift(v_u, 2)]
I8[bor(0, v_e)] = tobit(v_c)
I8[tobit((v_e + 1))] = tobit((rshift(v_c, 8) % 4294967296))
I8[tobit((v_e + 2))] = tobit((rshift(v_c, 16) % 4294967296))
I8[tobit((v_e + 3))] = tobit((rshift(v_c, 24) % 4294967296))
I8[tobit((v_e + 4))] = tobit(v_r)
I8[tobit((v_e + 5))] = tobit((rshift(v_r, 8) % 4294967296))
I8[tobit((v_e + 6))] = tobit((rshift(v_r, 16) % 4294967296))
I8[tobit((v_e + 7))] = tobit((rshift(v_r, 24) % 4294967296))
v_a = tobit((v_a + 16))
v_o = tobit((v_o + 16))
v_n = tobit((v_n - 16))
if not (v_n ~= 0) then goto B307 end
do
end
::C307::
end
end
::B307::
end
end
end
end
::L305::
B = tobit((v_u + 16))
do return bor(0, v_s) end
end
UA[31] = function(v_A, v_r, v_n, v_e, v_o, v_a, v_u)
local v_c, v_s = 0, 0
v_A = tobit(v_A)
v_r = tobit(v_r)
v_n = tobit(v_n)
v_o = tobit(v_o)
v_a = tobit(v_a)
v_u = tobit(v_u)
v_c = 0
v_s = 0
v_e = tobit(v_e)
v_c = I32[arshift(v_e, 2)]
do
if (v_r ~= 0) then
if (not (v_n ~= 0)) then
goto L308
end
do
while true do
v_n = tobit((v_n - 1))
if not (v_c ~= 0) then
F.fD(v_A, v_o, v_o)
end
v_r = tobit((v_o + v_c))
v_s = bxor(U8[bor(0, v_a)], U8[bor(0, v_r)])
I8[bor(0, v_u)] = tobit(v_s)
I8[bor(0, v_r)] = tobit(v_s)
v_u = tobit((v_u + 1))
v_a = tobit((v_a + 1))
v_c = band((v_c + 1), 15)
if not (v_n ~= 0) then goto B309 end
do
end
::C309::
end
end
::B309::
else
if (v_n ~= 0) then
do
while true do
v_n = tobit((v_n - 1))
if not (v_c ~= 0) then
F.fD(v_A, v_o, v_o)
end
v_s = U8[bor(0, v_a)]
v_r = tobit((v_o + v_c))
I8[bor(0, v_u)] = tobit(bxor(v_s, U8[bor(0, v_r)]))
I8[bor(0, v_r)] = tobit(v_s)
v_u = tobit((v_u + 1))
v_a = tobit((v_a + 1))
v_c = band((v_c + 1), 15)
if not (v_n ~= 0) then goto B310 end
do
end
::C310::
end
end
::B310::
end
end
end
::L308::
I32[arshift(v_e, 2)] = tobit(v_c)
do return 0 end
end
UA[32] = function(v_A, v_r, v_n, v_e, v_o, v_a, v_u)
local v_c, v_s, v_l, v_b = 0, 0, 0, 0
v_A = tobit(v_A)
v_r = tobit(v_r)
v_e = tobit(v_e)
v_o = tobit(v_o)
v_a = tobit(v_a)
v_u = tobit(v_u)
v_c = 0
v_s = 0
v_l = 0
v_b = 0
v_n = tobit(v_n)
v_c = I32[arshift(v_n, 2)]
if (v_r ~= 0) then
do
while true do
do
v_r = tobit((v_r - 1))
do
if (not (v_c ~= 0)) then
do
F.fD(v_A, v_e, v_o)
v_s = 16
while true do
do
if (not (v_s ~= 0)) then
goto L312
end
v_s = tobit((v_s - 1))
v_b = tobit((v_s + v_e))
v_l = tobit((U8[bor(0, v_b)] + 1))
I8[bor(0, v_b)] = tobit(v_l)
if (bor(0, v_l) == band(255, v_l)) then
goto B313
end
end
::C313::
end
end
::B313::
end
end
::L312::
I8[bor(0, v_u)] = tobit(bxor(U8[tobit((v_o + v_c))], U8[bor(0, v_a)]))
v_u = tobit((v_u + 1))
v_a = tobit((v_a + 1))
v_c = band((v_c + 1), 15)
if (not (v_r ~= 0)) then
goto B311
end
end
::C311::
end
end
::B311::
end
I32[arshift(v_n, 2)] = tobit(v_c)
do return 0 end
end
UA[33] = function(v_A, v_r, v_n)

do
v_A = tobit(v_A)
local t346 = v_A
v_r = tobit(v_r)
local t347 = v_r
v_n = tobit(v_n)
do return bor(0, F.fm(t346, t347, v_n)) end
end
end
UA[34] = function(v_A, v_r, v_n)
local v_e, v_o, v_f, v_a = 0, 0, 0, 0
v_A = tobit(v_A)
v_r = tobit(v_r)
v_n = tobit(v_n)
v_f = 0
v_a = 0
do
v_e = tobit((B - 288))
B = v_e
F.fOA(tobit((v_e + 8)), 0, 276)
v_o = F.fm(tobit((v_e + 8)), v_r, v_n)
if (not (v_o ~= 0)) then
do
do
do
v_r = I32[arshift((v_e + 8), 2)]
I32[arshift(v_A, 2)] = tobit(v_r)
local t348 = tobit((v_e + 8))
v_f = ((4 == bor(0, v_r)) and 1 or 0)
v_n = tobit((t348 + lshift(v_f, 6)))
I32[arshift((v_A + 4), 2)] = tobit(I32[arshift((v_n + 196), 2)])
I32[arshift((v_A + 8), 2)] = tobit(I32[arshift((v_n + 200), 2)])
I32[arshift((v_A + 12), 2)] = tobit(I32[arshift((v_n + 204), 2)])
I32[arshift((v_A + 16), 2)] = tobit(I32[arshift((v_n + 208), 2)])
v_r = tobit((v_A + 20))
v_f = bor(lshift(v_f, 3), 22)
v_n = tobit((v_n + 188))
v_A = 1
end
while true do
do
I32[arshift(v_r, 2)] = tobit(I32[arshift(v_n, 2)])
I32[arshift((v_r + 4), 2)] = tobit(I32[arshift((v_n + 4), 2)])
v_n = tobit((v_n - 8))
v_f = tobit((v_f - 1))
v_r = tobit((v_r + 8))
if (not (v_A ~= 0)) then
do
while true do
v_A = v_r
I32[arshift(v_A, 2)] = tobit(I32[arshift(v_n, 2)])
I32[arshift((v_A + 4), 2)] = tobit(I32[arshift((v_n + 4), 2)])
I32[arshift((v_A + 8), 2)] = tobit(I32[arshift((v_n - 8), 2)])
I32[arshift((v_A + 12), 2)] = tobit(I32[arshift((v_n - 4), 2)])
I32[arshift((v_A + 16), 2)] = tobit(I32[arshift((v_n - 16), 2)])
I32[arshift((v_A + 20), 2)] = tobit(I32[arshift((v_n - 12), 2)])
v_a = tobit((v_n - 24))
I32[arshift((v_A + 24), 2)] = tobit(I32[arshift(v_a, 2)])
I32[arshift((v_A + 28), 2)] = tobit(I32[arshift((v_n - 20), 2)])
v_n = tobit((v_n - 32))
v_r = tobit((v_A + 32))
v_f = tobit((v_f - 4))
if not (v_f ~= 0) then goto B315 end
do
end
::C315::
end
end
::B315::
I32[arshift((v_A + 32), 2)] = tobit(I32[arshift((v_a - 16), 2)])
I32[arshift((v_A + 36), 2)] = tobit(I32[arshift((v_a - 12), 2)])
I32[arshift((v_A + 40), 2)] = tobit(I32[arshift(v_n, 2)])
I32[arshift((v_A + 44), 2)] = tobit(I32[arshift((v_a - 4), 2)])
goto B314
end
v_A = tobit((v_A - 1))
end
::C314::
end
end
::B314::
end
end
end
do
v_A = 264
v_n = tobit((v_e + 8))
while true do
I8[bor(0, v_n)] = tobit(0)
I8[tobit((v_n + 1))] = tobit(0)
I8[tobit((v_n + 2))] = tobit(0)
I8[tobit((v_n + 3))] = tobit(0)
I8[tobit((v_n + 4))] = tobit(0)
I8[tobit((v_n + 5))] = tobit(0)
I8[tobit((v_n + 6))] = tobit(0)
I8[tobit((v_n + 7))] = tobit(0)
I8[tobit((v_n + 8))] = tobit(0)
I8[tobit((v_n + 9))] = tobit(0)
I8[tobit((v_n + 10))] = tobit(0)
I8[tobit((v_n + 11))] = tobit(0)
if not (v_A ~= 0) then goto B316 end
do
v_n = tobit((v_n + 12))
v_A = tobit((v_A - 12))
end
::C316::
end
end
::B316::
B = tobit((v_e + 288))
do return bor(0, v_o) end
end
UA[35] = function()
local v_A = 0
v_A = F.fBA(1, 276)
if (v_A ~= 0) then
F.fOA(v_A, 0, 276)
end
do return bor(0, v_A) end
end
UA[36] = function(v_A)
local v_r, v_n = 0, 0
v_r = 0
v_n = 0
do
v_A = tobit(v_A)
v_r = v_A
if (v_r ~= 0) then
do
v_n = 264
while true do
do
I8[bor(0, v_r)] = tobit(0)
I8[tobit((v_r + 1))] = tobit(0)
I8[tobit((v_r + 2))] = tobit(0)
I8[tobit((v_r + 3))] = tobit(0)
I8[tobit((v_r + 4))] = tobit(0)
I8[tobit((v_r + 5))] = tobit(0)
I8[tobit((v_r + 6))] = tobit(0)
I8[tobit((v_r + 7))] = tobit(0)
I8[tobit((v_r + 8))] = tobit(0)
I8[tobit((v_r + 9))] = tobit(0)
I8[tobit((v_r + 10))] = tobit(0)
I8[tobit((v_r + 11))] = tobit(0)
if (not (v_n ~= 0)) then
goto L317
end
v_r = tobit((v_r + 12))
v_n = tobit((v_n - 12))
end
::C318::
end
end
::B318::
end
end
::L317::
F.fR(v_A)
end
UA[37] = function(v_A, v_r, v_n)

do
v_A = tobit(v_A)
local t349 = v_A
v_r = tobit(v_r)
local t350 = v_r
v_n = tobit(v_n)
do return bor(0, F.fU(t349, 5, t350, v_n)) end
end
end
UA[38] = function(v_A, v_r, v_n)

do
v_A = tobit(v_A)
local t351 = v_A
v_r = tobit(v_r)
local t352 = v_r
v_n = tobit(v_n)
do return bor(0, F.fmA(t351, 5, t352, v_n)) end
end
end
UA[39] = function(v_A, v_r, v_n, v_t)

do
v_A = tobit(v_A)
local t353 = v_A
v_n = tobit(v_n)
local t354 = v_n
v_t = tobit(v_t)
do return bor(0, F.fV(t353, t354, v_t)) end
end
end
UA[40] = function(v_A, v_r, v_n, v_t, v_e, v_o)

do
v_A = tobit(v_A)
local t355 = v_A
v_r = tobit(v_r)
local t356 = v_r
v_n = tobit(v_n)
local t357 = v_n
v_t = tobit(v_t)
local t358 = v_t
v_e = tobit(v_e)
local t359 = v_e
v_o = tobit(v_o)
do return bor(0, F.fz(t355, t356, t357, t358, t359, v_o)) end
end
end
UA[41] = function(v_A, v_r, v_n)

do
v_A = tobit(v_A)
local t360 = v_A
v_r = tobit(v_r)
F.fJ(t360, v_r)
do return 0 end
end
end
UA[42] = function(v_A, v_r, v_n)

do
v_A = tobit(v_A)
local t361 = v_A
v_r = tobit(v_r)
do return bor(0, F.fZ(t361, v_r)) end
end
end
UA[43] = function()
local v_A = 0
v_A = F.fBA(1, 128)
if (v_A ~= 0) then
F.fRA(v_A)
end
do return bor(0, v_A) end
end
UA[44] = function(v_A)

v_A = tobit(v_A)
F.fL(v_A)
F.fR(v_A)
end
UA[45] = function(v_A, v_r, v_n, v_t)

do
v_A = tobit(v_A)
local t362 = v_A
v_n = tobit(v_n)
local t363 = v_n
v_t = tobit(v_t)
do return bor(0, F.fG(t362, t363, v_t)) end
end
end
UA[46] = function(v_A, v_r, v_n, v_e, v_o, v_i)
local v_a, v_u = 0, 0
v_A = tobit(v_A)
v_r = tobit(v_r)
v_e = tobit(v_e)
v_o = tobit(v_o)
v_i = tobit(v_i)
v_a = 0
v_u = 0
v_u = (-50)
do
v_n = tobit(v_n)
if (not (band(7, v_n) ~= 0)) then
if (1 == bor(0, v_r)) then
v_u = 0
if (v_n ~= 0) then
do
v_r = U8[bor(0, v_e)]
while true do
I8[bor(0, v_i)] = tobit(bxor(U8[bor(0, v_o)], v_r))
I8[tobit((v_i + 1))] = tobit(bxor(U8[tobit((v_e + 1))], U8[tobit((v_o + 1))]))
I8[tobit((v_i + 2))] = tobit(bxor(U8[tobit((v_e + 2))], U8[tobit((v_o + 2))]))
I8[tobit((v_i + 3))] = tobit(bxor(U8[tobit((v_e + 3))], U8[tobit((v_o + 3))]))
I8[tobit((v_i + 4))] = tobit(bxor(U8[tobit((v_e + 4))], U8[tobit((v_o + 4))]))
I8[tobit((v_i + 5))] = tobit(bxor(U8[tobit((v_e + 5))], U8[tobit((v_o + 5))]))
I8[tobit((v_i + 6))] = tobit(bxor(U8[tobit((v_e + 6))], U8[tobit((v_o + 6))]))
I8[tobit((v_i + 7))] = tobit(bxor(U8[tobit((v_e + 7))], U8[tobit((v_o + 7))]))
F.fG(v_A, v_i, v_i)
v_a = bor(bor(bor(U8[tobit((v_i + 4))], lshift(U8[tobit((v_i + 5))], 8)), lshift(U8[tobit((v_i + 6))], 16)), lshift(U8[tobit((v_i + 7))], 24))
v_r = bor(bor(bor(U8[bor(0, v_i)], lshift(U8[tobit((v_i + 1))], 8)), lshift(U8[tobit((v_i + 2))], 16)), lshift(U8[tobit((v_i + 3))], 24))
I8[bor(0, v_e)] = tobit(v_r)
I8[tobit((v_e + 1))] = tobit((rshift(v_r, 8) % 4294967296))
I8[tobit((v_e + 2))] = tobit((rshift(v_r, 16) % 4294967296))
I8[tobit((v_e + 3))] = tobit((rshift(v_r, 24) % 4294967296))
I8[tobit((v_e + 4))] = tobit(v_a)
I8[tobit((v_e + 5))] = tobit((rshift(v_a, 8) % 4294967296))
I8[tobit((v_e + 6))] = tobit((rshift(v_a, 16) % 4294967296))
I8[tobit((v_e + 7))] = tobit((rshift(v_a, 24) % 4294967296))
v_i = tobit((v_i + 8))
v_o = tobit((v_o + 8))
v_n = tobit((v_n - 8))
if not (v_n ~= 0) then goto B320 end
do
end
::C320::
end
end
::B320::
end
else
v_u = 0
if (not (v_n ~= 0)) then
goto L319
end
do
while true do
v_a = bor(bor(bor(U8[tobit((v_o + 4))], lshift(U8[tobit((v_o + 5))], 8)), lshift(U8[tobit((v_o + 6))], 16)), lshift(U8[tobit((v_o + 7))], 24))
v_r = bor(bor(bor(U8[bor(0, v_o)], lshift(U8[tobit((v_o + 1))], 8)), lshift(U8[tobit((v_o + 2))], 16)), lshift(U8[tobit((v_o + 3))], 24))
F.fG(v_A, v_o, v_i)
I8[bor(0, v_i)] = tobit(bxor(U8[bor(0, v_e)], U8[bor(0, v_i)]))
I8[tobit((v_i + 1))] = tobit(bxor(U8[tobit((v_e + 1))], U8[tobit((v_i + 1))]))
I8[tobit((v_i + 2))] = tobit(bxor(U8[tobit((v_e + 2))], U8[tobit((v_i + 2))]))
I8[tobit((v_i + 3))] = tobit(bxor(U8[tobit((v_e + 3))], U8[tobit((v_i + 3))]))
I8[tobit((v_i + 4))] = tobit(bxor(U8[tobit((v_e + 4))], U8[tobit((v_i + 4))]))
I8[tobit((v_i + 5))] = tobit(bxor(U8[tobit((v_e + 5))], U8[tobit((v_i + 5))]))
I8[tobit((v_i + 6))] = tobit(bxor(U8[tobit((v_e + 6))], U8[tobit((v_i + 6))]))
I8[tobit((v_i + 7))] = tobit(bxor(U8[tobit((v_e + 7))], U8[tobit((v_i + 7))]))
I8[bor(0, v_e)] = tobit(v_r)
I8[tobit((v_e + 1))] = tobit((rshift(v_r, 8) % 4294967296))
I8[tobit((v_e + 2))] = tobit((rshift(v_r, 16) % 4294967296))
I8[tobit((v_e + 3))] = tobit((rshift(v_r, 24) % 4294967296))
I8[tobit((v_e + 4))] = tobit(v_a)
I8[tobit((v_e + 5))] = tobit((rshift(v_a, 8) % 4294967296))
I8[tobit((v_e + 6))] = tobit((rshift(v_a, 16) % 4294967296))
I8[tobit((v_e + 7))] = tobit((rshift(v_a, 24) % 4294967296))
v_i = tobit((v_i + 8))
v_o = tobit((v_o + 8))
v_n = tobit((v_n - 8))
if not (v_n ~= 0) then goto B321 end
do
end
::C321::
end
end
::B321::
end
end
end
::L319::
do return bor(0, v_u) end
end
UA[47] = function(v_A, v_r, v_n)
local v_e, v_o, v_f, v_a, v_u, v_c = 0, 0, 0, 0, 0, 0
v_n = tobit(v_n)
v_e = 0
v_o = 0
v_f = 0
v_a = 0
v_u = 0
v_c = 0
do
do
do
v_n = tobit((B - 384))
B = v_n
v_A = tobit(v_A)
local t364 = v_A
v_r = tobit(v_r)
F.fJ(t364, v_r)
F.fJ(tobit((v_n + 128)), tobit((v_r + 8)))
v_r = 0
end
while true do
v_e = lshift(v_r, 2)
v_f = I32[arshift((lshift((30 - v_r), 2) + v_A), 2)]
I32[arshift((v_e + v_n), 2)] = tobit(v_f)
v_a = bor(4, v_e)
v_u = I32[arshift((lshift((31 - v_r), 2) + v_A), 2)]
I32[arshift((v_a + v_n), 2)] = tobit(v_u)
v_o = tobit((v_A + v_e))
I32[arshift((128 + v_o), 2)] = tobit(I32[arshift((lshift((62 - v_r), 2) + v_n), 2)])
I32[arshift((v_o + 132), 2)] = tobit(I32[arshift((lshift((63 - v_r), 2) + v_n), 2)])
v_c = tobit((v_e + 256))
I32[arshift((v_c + v_A), 2)] = tobit(I32[arshift(v_o, 2)])
v_e = tobit((v_e + 260))
I32[arshift((v_e + v_A), 2)] = tobit(I32[arshift((v_A + v_a), 2)])
I32[arshift((v_n + v_e), 2)] = tobit(v_u)
I32[arshift((v_n + v_c), 2)] = tobit(v_f)
v_e = (((tobit(v_r) % 4294967296) < 30) and 1 or 0)
v_r = tobit((v_r + 2))
if not (v_e ~= 0) then goto B322 end
do
end
::C322::
end
end
::B322::
end
do
v_A = 372
v_r = v_n
while true do
I8[bor(0, v_r)] = tobit(0)
I8[tobit((v_r + 1))] = tobit(0)
I8[tobit((v_r + 2))] = tobit(0)
I8[tobit((v_r + 3))] = tobit(0)
I8[tobit((v_r + 4))] = tobit(0)
I8[tobit((v_r + 5))] = tobit(0)
I8[tobit((v_r + 6))] = tobit(0)
I8[tobit((v_r + 7))] = tobit(0)
I8[tobit((v_r + 8))] = tobit(0)
I8[tobit((v_r + 9))] = tobit(0)
I8[tobit((v_r + 10))] = tobit(0)
I8[tobit((v_r + 11))] = tobit(0)
if not (v_A ~= 0) then goto B323 end
do
v_r = tobit((v_r + 12))
v_A = tobit((v_A - 12))
end
::C323::
end
end
::B323::
B = tobit((v_n + 384))
do return 0 end
end
UA[48] = function(v_A, v_r, v_n)
local v_e, v_o, v_f, v_a, v_u, v_c = 0, 0, 0, 0, 0, 0
v_A = tobit(v_A)
v_n = tobit(v_n)
v_e = 0
v_o = 0
v_f = 0
v_a = 0
v_u = 0
v_c = 0
do
do
do
v_n = tobit((B - 384))
B = v_n
local t365 = v_n
v_r = tobit(v_r)
F.fJ(t365, v_r)
F.fJ(tobit((v_A + 128)), tobit((v_r + 8)))
v_r = 0
end
while true do
v_e = lshift(v_r, 2)
v_f = I32[arshift((lshift((30 - v_r), 2) + v_n), 2)]
I32[arshift((v_e + v_A), 2)] = tobit(v_f)
v_a = bor(4, v_e)
v_u = I32[arshift((lshift((31 - v_r), 2) + v_n), 2)]
I32[arshift((v_a + v_A), 2)] = tobit(v_u)
v_o = tobit((v_n + v_e))
I32[arshift((128 + v_o), 2)] = tobit(I32[arshift((lshift((62 - v_r), 2) + v_A), 2)])
I32[arshift((v_o + 132), 2)] = tobit(I32[arshift((lshift((63 - v_r), 2) + v_A), 2)])
v_c = tobit((v_e + 256))
I32[arshift((v_c + v_n), 2)] = tobit(I32[arshift(v_o, 2)])
v_e = tobit((v_e + 260))
I32[arshift((v_e + v_n), 2)] = tobit(I32[arshift((v_n + v_a), 2)])
I32[arshift((v_A + v_e), 2)] = tobit(v_u)
I32[arshift((v_A + v_c), 2)] = tobit(v_f)
v_e = (((tobit(v_r) % 4294967296) < 30) and 1 or 0)
v_r = tobit((v_r + 2))
if not (v_e ~= 0) then goto B324 end
do
end
::C324::
end
end
::B324::
end
do
v_A = 372
v_r = v_n
while true do
I8[bor(0, v_r)] = tobit(0)
I8[tobit((v_r + 1))] = tobit(0)
I8[tobit((v_r + 2))] = tobit(0)
I8[tobit((v_r + 3))] = tobit(0)
I8[tobit((v_r + 4))] = tobit(0)
I8[tobit((v_r + 5))] = tobit(0)
I8[tobit((v_r + 6))] = tobit(0)
I8[tobit((v_r + 7))] = tobit(0)
I8[tobit((v_r + 8))] = tobit(0)
I8[tobit((v_r + 9))] = tobit(0)
I8[tobit((v_r + 10))] = tobit(0)
I8[tobit((v_r + 11))] = tobit(0)
if not (v_A ~= 0) then goto B325 end
do
v_r = tobit((v_r + 12))
v_A = tobit((v_A - 12))
end
::C325::
end
end
::B325::
B = tobit((v_n + 384))
do return 0 end
end
UA[49] = function()
local v_A = 0
v_A = F.fBA(1, 384)
if (v_A ~= 0) then
F.fOA(v_A, 0, 384)
end
do return bor(0, v_A) end
end
UA[50] = function(v_A)
local v_r, v_n = 0, 0
v_r = 0
v_n = 0
do
v_A = tobit(v_A)
v_r = v_A
if (v_r ~= 0) then
do
v_n = 372
while true do
do
I8[bor(0, v_r)] = tobit(0)
I8[tobit((v_r + 1))] = tobit(0)
I8[tobit((v_r + 2))] = tobit(0)
I8[tobit((v_r + 3))] = tobit(0)
I8[tobit((v_r + 4))] = tobit(0)
I8[tobit((v_r + 5))] = tobit(0)
I8[tobit((v_r + 6))] = tobit(0)
I8[tobit((v_r + 7))] = tobit(0)
I8[tobit((v_r + 8))] = tobit(0)
I8[tobit((v_r + 9))] = tobit(0)
I8[tobit((v_r + 10))] = tobit(0)
I8[tobit((v_r + 11))] = tobit(0)
if (not (v_n ~= 0)) then
goto L326
end
v_r = tobit((v_r + 12))
v_n = tobit((v_n - 12))
end
::C327::
end
end
::B327::
end
end
::L326::
F.fR(v_A)
end
UA[51] = function(v_A, v_r, v_n)

do
do
do
v_n = tobit(v_n)
v_n = tobit((B - 384))
B = v_n
v_A = tobit(v_A)
local t366 = v_A
local t367 = v_n
v_r = tobit(v_r)
F.fcA(t366, t367, v_r)
v_r = 372
v_A = v_n
end
while true do
I8[bor(0, v_A)] = tobit(0)
I8[tobit((v_A + 1))] = tobit(0)
I8[tobit((v_A + 2))] = tobit(0)
I8[tobit((v_A + 3))] = tobit(0)
I8[tobit((v_A + 4))] = tobit(0)
I8[tobit((v_A + 5))] = tobit(0)
I8[tobit((v_A + 6))] = tobit(0)
I8[tobit((v_A + 7))] = tobit(0)
I8[tobit((v_A + 8))] = tobit(0)
I8[tobit((v_A + 9))] = tobit(0)
I8[tobit((v_A + 10))] = tobit(0)
I8[tobit((v_A + 11))] = tobit(0)
if not (v_r ~= 0) then goto B328 end
do
v_A = tobit((v_A + 12))
v_r = tobit((v_r - 12))
end
::C328::
end
end
::B328::
end
B = tobit((v_n + 384))
do return 0 end
end
UA[52] = function(v_A, v_r, v_n)

do
do
do
v_n = tobit(v_n)
v_n = tobit((B - 384))
B = v_n
local t368 = v_n
v_A = tobit(v_A)
local t369 = v_A
v_r = tobit(v_r)
F.fcA(t368, t369, v_r)
v_r = 372
v_A = v_n
end
while true do
I8[bor(0, v_A)] = tobit(0)
I8[tobit((v_A + 1))] = tobit(0)
I8[tobit((v_A + 2))] = tobit(0)
I8[tobit((v_A + 3))] = tobit(0)
I8[tobit((v_A + 4))] = tobit(0)
I8[tobit((v_A + 5))] = tobit(0)
I8[tobit((v_A + 6))] = tobit(0)
I8[tobit((v_A + 7))] = tobit(0)
I8[tobit((v_A + 8))] = tobit(0)
I8[tobit((v_A + 9))] = tobit(0)
I8[tobit((v_A + 10))] = tobit(0)
I8[tobit((v_A + 11))] = tobit(0)
if not (v_r ~= 0) then goto B329 end
do
v_A = tobit((v_A + 12))
v_r = tobit((v_r - 12))
end
::C329::
end
end
::B329::
end
B = tobit((v_n + 384))
do return 0 end
end
UA[53] = function(v_A, v_r, v_n)
local v_t, v_e, v_o, v_a, v_u = 0, 0, 0, 0, 0
v_r = tobit(v_r)
v_t = 0
v_e = 0
v_o = 0
v_a = 0
v_u = 0
do
v_A = tobit(v_A)
local t370 = (not (v_A ~= 0))
v_n = tobit(v_n)
if (bor((t370 and 1 or 0), ((not (v_n ~= 0)) and 1 or 0)) ~= 0) then
v_A = (-24832)
else
do
do
local t371 = v_r
v_t = U8[tobit((tobit((v_A + v_r)) - 1))]
v_e = tobit((t371 - v_t))
I32[arshift(v_n, 2)] = tobit(v_e)
v_n = bor(((not (v_t ~= 0)) and 1 or 0), (((tobit(v_r) % 4294967296) < (tobit(v_t) % 4294967296)) and 1 or 0))
if (v_r ~= 0) then
do
do
v_a = band(3, v_r)
if ((tobit((v_r - 1)) % 4294967296) < 3) then
v_r = 0
else
do
do
v_u = band((-4), v_r)
v_r = 0
while true do
do
v_o = bor((((tobit(v_r) % 4294967296) < (tobit(v_e) % 4294967296)) and 0 or bxor(v_t, U8[tobit((v_A + v_r))])), v_n)
local t372 = v_o
v_n = bor(1, v_r)
v_o = bor(t372, (((tobit(v_n) % 4294967296) < (tobit(v_e) % 4294967296)) and 0 or bxor(v_t, U8[tobit((v_n + v_A))])))
local t373 = v_o
v_n = bor(2, v_r)
v_o = bor(t373, (((tobit(v_n) % 4294967296) < (tobit(v_e) % 4294967296)) and 0 or bxor(v_t, U8[tobit((v_n + v_A))])))
local t374 = v_o
v_n = bor(3, v_r)
v_n = bor(t374, (((tobit(v_n) % 4294967296) < (tobit(v_e) % 4294967296)) and 0 or bxor(v_t, U8[tobit((v_n + v_A))])))
v_r = tobit((v_r + 4))
v_u = tobit((v_u - 4))
if not (v_u ~= 0) then goto B330 end
end
do
end
::C330::
end
end
::B330::
end
end
end
if (v_a ~= 0) then
do
while true do
v_n = bor((((tobit(v_r) % 4294967296) < (tobit(v_e) % 4294967296)) and 0 or bxor(v_t, U8[tobit((v_A + v_r))])), v_n)
v_r = tobit((v_r + 1))
v_a = tobit((v_a - 1))
if not (v_a ~= 0) then goto B331 end
do
end
::C331::
end
end
::B331::
end
end
end
end
v_A = ((band(255, v_n) ~= 0) and (-25088) or 0)
end
end
end
do return bor(0, v_A) end
end
UA[54] = function(v_A, v_r, v_n)
local v_e, v_o = 0, 0
v_A = tobit(v_A)
v_e = 0
v_o = 0
do
do
do
v_r = tobit(v_r)
local t375 = v_r
v_n = tobit(v_n)
v_o = tobit((t375 - v_n))
if (v_o ~= 0) then
do
v_r = 1
v_e = v_n
while true do
do
I8[tobit((v_A + v_e))] = tobit(v_o)
v_e = band(255, v_r)
if ((tobit(v_e) % 4294967296) >= (tobit(v_o) % 4294967296)) then
goto L332
end
v_r = tobit((v_r + 1))
v_e = tobit((v_n + v_e))
end
::C333::
end
end
::B333::
end
end
end
::L332::
end
end
UA[55] = function(v_A, v_r, v_n, v_e, v_a, v_u)
local v_c, v_s, v_b, v_v, v_p, v_h, v_d, v_k, v_y, v_w, v_C, v_E = 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
v_A = tobit(v_A)
v_r = tobit(v_r)
v_n = tobit(v_n)
v_e = tobit(v_e)
v_a = tobit(v_a)
v_u = tobit(v_u)
v_s = 0
v_b = 0
v_v = 0
v_p = 0
v_h = 0
v_d = 0
v_k = 0
v_y = 0
v_w = 0
v_C = 0
v_E = 0
do
v_c = tobit((B - 528))
B = v_c
v_v = (-3)
v_s = I32[7792]
if (not (bor(((not (v_s ~= 0)) and 1 or 0), ((not (U8[bor(0, v_s)] ~= 0)) and 1 or 0)) ~= 0)) then
do
if (I32[7794] ~= 0) then
do
do
v_v = (-1)
if (not ((tobit(v_r) % 4294967296) < 256)) then
do
I8[tobit((v_c + 480))] = tobit(0)
F.fQA(tobit((v_c + 224)), v_A, 256)
I8[tobit((v_c + 192))] = tobit(0)
v_s = F.fY()
v_b = F.fT(v_s)
F.fR(v_s)
v_s = v_b
v_v = bor(bor(bor(U8[tobit((v_s + 12))], lshift(U8[tobit((v_s + 13))], 8)), lshift(U8[tobit((v_s + 14))], 16)), lshift(U8[tobit((v_s + 15))], 24))
I32[arshift((v_c + 504), 2)] = tobit(bor(bor(bor(U8[tobit((v_s + 8))], lshift(U8[tobit((v_s + 9))], 8)), lshift(U8[tobit((v_s + 10))], 16)), lshift(U8[tobit((v_s + 11))], 24)))
I32[arshift((v_c + 508), 2)] = tobit(v_v)
v_v = bor(bor(bor(U8[tobit((v_s + 4))], lshift(U8[tobit((v_s + 5))], 8)), lshift(U8[tobit((v_s + 6))], 16)), lshift(U8[tobit((v_s + 7))], 24))
I32[arshift((v_c + 496), 2)] = tobit(bor(bor(bor(U8[bor(0, v_s)], lshift(U8[tobit((v_s + 1))], 8)), lshift(U8[tobit((v_s + 2))], 16)), lshift(U8[tobit((v_s + 3))], 24)))
I32[arshift((v_c + 500), 2)] = tobit(v_v)
v_k = tobit((B - 288))
B = v_k
v_v = F.fOA(F.fI(257), 0, 257)
F.fMA(tobit((v_k + 8)))
F.fH(tobit((v_k + 8)), v_s, 256)
F.fM(tobit((v_k + 8)), 0, 256, tobit((v_c + 496)), tobit((v_c + 224)), v_v)
F.fvA(tobit((v_k + 8)))
B = tobit((v_k + 288))
if (v_v ~= 0) then
do
do
v_s = v_v
v_v = bor(bor(bor(U8[tobit((v_s + 8))], lshift(U8[tobit((v_s + 9))], 8)), lshift(U8[tobit((v_s + 10))], 16)), lshift(U8[tobit((v_s + 11))], 24))
v_d = bor(bor(bor(U8[tobit((v_s + 12))], lshift(U8[tobit((v_s + 13))], 8)), lshift(U8[tobit((v_s + 14))], 16)), lshift(U8[tobit((v_s + 15))], 24))
v_k = bor(bor(bor(U8[bor(0, v_s)], lshift(U8[tobit((v_s + 1))], 8)), lshift(U8[tobit((v_s + 2))], 16)), lshift(U8[tobit((v_s + 3))], 24))
v_p = bor(bor(bor(U8[tobit((v_s + 4))], lshift(U8[tobit((v_s + 5))], 8)), lshift(U8[tobit((v_s + 6))], 16)), lshift(U8[tobit((v_s + 7))], 24))
v_y = bor(bor(bor(U8[tobit((v_s + 20))], lshift(U8[tobit((v_s + 21))], 8)), lshift(U8[tobit((v_s + 22))], 16)), lshift(U8[tobit((v_s + 23))], 24))
I32[arshift((v_c + 208), 2)] = tobit(bor(bor(bor(U8[tobit((v_s + 16))], lshift(U8[tobit((v_s + 17))], 8)), lshift(U8[tobit((v_s + 18))], 16)), lshift(U8[tobit((v_s + 19))], 24)))
I32[arshift((v_c + 212), 2)] = tobit(v_y)
I16[arshift((v_c + 216), 1)] = tobit(bor(U8[tobit((v_s + 24))], lshift(U8[tobit((v_s + 25))], 8)))
F.fQA(tobit((v_c - (-64))), tobit((v_s + 128)), 128)
F.fR(v_b)
F.fR(v_s)
I32[arshift((v_c + 48), 2)] = tobit(v_k)
I32[arshift((v_c + 52), 2)] = tobit(v_p)
I8[tobit((v_c + 56))] = tobit(0)
v_k = F.fuA(tobit((v_c + 48)))
I32[arshift((v_c + 48), 2)] = tobit(v_v)
I32[arshift((v_c + 52), 2)] = tobit(v_d)
v_E = F.fuA(tobit((v_c + 48)))
I16[arshift((v_c + 40), 1)] = tobit(U16[arshift((v_c + 216), 1)])
I8[tobit((v_c + 42))] = tobit(0)
v_s = I32[arshift((v_c + 212), 2)]
I32[arshift((v_c + 32), 2)] = tobit(I32[arshift((v_c + 208), 2)])
I32[arshift((v_c + 36), 2)] = tobit(v_s)
I32[arshift(v_c, 2)] = tobit(F.fuA(tobit((v_c + 32))))
v_b = tobit((B - 16))
B = v_b
I32[arshift((v_b + 12), 2)] = tobit(v_c)
v_s = tobit((B - 160))
B = v_s
F.fQA(tobit((v_s + 8)), 1616, 144)
v_v = tobit((v_c + 32))
I32[arshift((v_s + 52), 2)] = tobit(v_v)
I32[arshift((v_s + 28), 2)] = tobit(v_v)
v_d = tobit(((-2) - v_v))
v_d = (((tobit(v_d) % 4294967296) < 11) and v_d or 11)
I32[arshift((v_s + 56), 2)] = tobit(v_d)
v_v = tobit((v_v + v_d))
I32[arshift((v_s + 36), 2)] = tobit(v_v)
I32[arshift((v_s + 24), 2)] = tobit(v_v)
F.ftA(tobit((v_s + 8)), 1114, v_c, 1, 2)
if (v_d ~= 0) then
v_v = I32[arshift((v_s + 28), 2)]
I8[tobit((v_v - ((bor(0, v_v) == I32[arshift((v_s + 24), 2)]) and 1 or 0)))] = tobit(0)
end
B = tobit((v_s + 160))
B = tobit((v_b + 16))
v_v = (-2)
v_b = I32[7794]
v_d = tobit((v_c + 32))
v_s = 0
v_p = 10
while true do
v_h = bxor(I32[arshift((12064 + lshift(bxor(U8[tobit((v_s + v_d))], band(255, v_h)), 2)), 2)], (rshift(v_h, 8) % 4294967296))
v_h = bxor(I32[arshift((12064 + lshift(bxor(U8[tobit((v_d + bor(1, v_s)))], band(255, v_h)), 2)), 2)], (rshift(v_h, 8) % 4294967296))
v_s = tobit((v_s + 2))
v_p = tobit((v_p - 2))
if not (v_p ~= 0) then goto B334 end
do
end
::C334::
end
end
::B334::
v_s = imul(v_h, 4097)
v_s = imul(bxor((rshift(v_s, 22) % 4294967296), v_s), 17)
v_s = imul(bxor((rshift(v_s, 9) % 4294967296), v_s), 1025)
v_s = imul(bxor((rshift(v_s, 2) % 4294967296), v_s), 129)
v_h = I32[arshift(v_b, 2)]
v_s = tobit(fmod((tobit(imul(bxor((rshift(v_s, 15) % 4294967296), (rshift(v_s, 3) % 4294967296)), (-1640531535))) % 4294967296), (tobit(v_h) % 4294967296)))
v_b = I32[arshift((v_b + 8), 2)]
do
do
do
do
v_p = tobit((lshift(v_s, 4) + v_b))
local t378 = ((bor(((not (I32[arshift((8 + v_p), 2)] ~= 0)) and 1 or 0), ((10 ~= I32[arshift((v_p + 4), 2)]) and 1 or 0)) ~= 0) or (F.fEA(I32[arshift((v_b + lshift(v_s, 4)), 2)], v_d, 10) ~= 0))
if t378 then
local t376 = v_b
v_s = tobit(fmod((tobit((v_s + 1)) % 4294967296), (tobit(v_h) % 4294967296)))
local t377 = (not (I32[arshift((8 + tobit((t376 + lshift(v_s, 4)))), 2)] ~= 0))
if not t377 then
v_p = tobit((v_b + lshift(v_s, 4)))
t377 = (10 ~= I32[arshift((4 + v_p), 2)])
end
t378 = (t377 or (F.fEA(I32[arshift(v_p, 2)], v_d, 10) ~= 0))
end
local t380 = t378
if t380 then
local t379 = v_b
v_s = tobit(fmod((tobit((v_s + 1)) % 4294967296), (tobit(v_h) % 4294967296)))
v_p = tobit((t379 + lshift(v_s, 4)))
t380 = ((bor(((not (I32[arshift((8 + v_p), 2)] ~= 0)) and 1 or 0), ((10 ~= I32[arshift((v_p + 4), 2)]) and 1 or 0)) ~= 0) or (F.fEA(I32[arshift((v_b + lshift(v_s, 4)), 2)], v_d, 10) ~= 0))
end
local t383 = t380
if t383 then
local t381 = v_b
v_s = tobit(fmod((tobit((v_s + 1)) % 4294967296), (tobit(v_h) % 4294967296)))
local t382 = (not (I32[arshift((8 + tobit((t381 + lshift(v_s, 4)))), 2)] ~= 0))
if not t382 then
v_p = tobit((v_b + lshift(v_s, 4)))
t382 = (10 ~= I32[arshift((4 + v_p), 2)])
end
t383 = (t382 or (F.fEA(I32[arshift(v_p, 2)], v_d, 10) ~= 0))
end
local t385 = t383
if t385 then
local t384 = v_b
v_s = tobit(fmod((tobit((v_s + 1)) % 4294967296), (tobit(v_h) % 4294967296)))
v_p = tobit((t384 + lshift(v_s, 4)))
t385 = ((bor(((not (I32[arshift((8 + v_p), 2)] ~= 0)) and 1 or 0), ((10 ~= I32[arshift((v_p + 4), 2)]) and 1 or 0)) ~= 0) or (F.fEA(I32[arshift((v_b + lshift(v_s, 4)), 2)], v_d, 10) ~= 0))
end
local t388 = t385
if t388 then
local t386 = v_b
v_s = tobit(fmod((tobit((v_s + 1)) % 4294967296), (tobit(v_h) % 4294967296)))
local t387 = (not (I32[arshift((8 + tobit((t386 + lshift(v_s, 4)))), 2)] ~= 0))
if not t387 then
v_p = tobit((v_b + lshift(v_s, 4)))
t387 = (10 ~= I32[arshift((4 + v_p), 2)])
end
t388 = (t387 or (F.fEA(I32[arshift(v_p, 2)], v_d, 10) ~= 0))
end
local t390 = t388
if t390 then
local t389 = v_b
v_s = tobit(fmod((tobit((v_s + 1)) % 4294967296), (tobit(v_h) % 4294967296)))
v_p = tobit((t389 + lshift(v_s, 4)))
t390 = ((bor(((not (I32[arshift((8 + v_p), 2)] ~= 0)) and 1 or 0), ((10 ~= I32[arshift((v_p + 4), 2)]) and 1 or 0)) ~= 0) or (F.fEA(I32[arshift((v_b + lshift(v_s, 4)), 2)], v_d, 10) ~= 0))
end
if t390 then
do
do
v_p = 0
local t391 = v_b
v_s = tobit(fmod((tobit((v_s + 1)) % 4294967296), (tobit(v_h) % 4294967296)))
if (not (I32[arshift((8 + tobit((t391 + lshift(v_s, 4)))), 2)] ~= 0)) then
goto L335
end
end
v_h = tobit((v_b + lshift(v_s, 4)))
if (10 ~= I32[arshift((4 + v_h), 2)]) then
goto L335
end
if (F.fEA(I32[arshift(v_h, 2)], v_d, 10) ~= 0) then
goto L335
end
end
end
end
v_p = I32[arshift((12 + tobit((v_b + lshift(v_s, 4)))), 2)]
end
end
::L335::
end
if (not (bor(((not (v_p ~= 0)) and 1 or 0), ((not (I32[arshift((v_p + 8), 2)] ~= 0)) and 1 or 0)) ~= 0)) then
v_v = tobit((v_A + 128))
v_s = F.fQA(v_v, tobit((v_c - (-64))), 128)
if (U8[tobit((v_c + 64))] ~= 0) then
v_A = tobit((v_r - 128))
else
v_b = tobit((v_A + 256))
v_A = F.fEA(tobit((v_c - (-64))), bor((v_c - (-64)), 1), 127)
v_v = ((v_A ~= 0) and v_s or v_b)
v_A = tobit((((v_A ~= 0) and (-128) or (-256)) + v_r))
end
v_s = I32[arshift((v_p + 4), 2)]
v_b = I32[arshift((v_p + 8), 2)]
v_d = tobit((B - 48))
B = v_d
v_w = F.fY()
v_C = F.fT(v_w)
v_r = v_C
v_h = bor(bor(bor(U8[tobit((v_r + 12))], lshift(U8[tobit((v_r + 13))], 8)), lshift(U8[tobit((v_r + 14))], 16)), lshift(U8[tobit((v_r + 15))], 24))
I32[arshift((v_d + 24), 2)] = tobit(bor(bor(bor(U8[tobit((v_r + 8))], lshift(U8[tobit((v_r + 9))], 8)), lshift(U8[tobit((v_r + 10))], 16)), lshift(U8[tobit((v_r + 11))], 24)))
I32[arshift((v_d + 28), 2)] = tobit(v_h)
v_h = bor(bor(bor(U8[tobit((v_r + 4))], lshift(U8[tobit((v_r + 5))], 8)), lshift(U8[tobit((v_r + 6))], 16)), lshift(U8[tobit((v_r + 7))], 24))
I32[arshift((v_d + 16), 2)] = tobit(bor(bor(bor(U8[bor(0, v_r)], lshift(U8[tobit((v_r + 1))], 8)), lshift(U8[tobit((v_r + 2))], 16)), lshift(U8[tobit((v_r + 3))], 24)))
I32[arshift((v_d + 20), 2)] = tobit(v_h)
v_y = F.foA(v_s, v_b, tobit((v_d + 16)), v_r, tobit((v_d + 12)))
v_r = tobit((I32[7793] + v_e))
v_s = tobit((v_d - band((v_r + 32), (-16))))
B = v_s
v_s = F.fOA(v_s, 0, tobit((v_r + 17)))
v_r = v_s
v_b = tobit((v_y + imul(v_E, 17)))
v_h = bor(bor(bor(U8[tobit((v_b + 12))], lshift(U8[tobit((v_b + 13))], 8)), lshift(U8[tobit((v_b + 14))], 16)), lshift(U8[tobit((v_b + 15))], 24))
v_p = bor(bor(bor(U8[tobit((v_b + 8))], lshift(U8[tobit((v_b + 9))], 8)), lshift(U8[tobit((v_b + 10))], 16)), lshift(U8[tobit((v_b + 11))], 24))
I8[tobit((v_r + 8))] = tobit(v_p)
I8[tobit((v_r + 9))] = tobit((rshift(v_p, 8) % 4294967296))
I8[tobit((v_r + 10))] = tobit((rshift(v_p, 16) % 4294967296))
I8[tobit((v_r + 11))] = tobit((rshift(v_p, 24) % 4294967296))
I8[tobit((v_r + 12))] = tobit(v_h)
I8[tobit((v_r + 13))] = tobit((rshift(v_h, 8) % 4294967296))
I8[tobit((v_r + 14))] = tobit((rshift(v_h, 16) % 4294967296))
I8[tobit((v_r + 15))] = tobit((rshift(v_h, 24) % 4294967296))
v_h = bor(bor(bor(U8[tobit((v_b + 4))], lshift(U8[tobit((v_b + 5))], 8)), lshift(U8[tobit((v_b + 6))], 16)), lshift(U8[tobit((v_b + 7))], 24))
v_b = bor(bor(bor(U8[bor(0, v_b)], lshift(U8[tobit((v_b + 1))], 8)), lshift(U8[tobit((v_b + 2))], 16)), lshift(U8[tobit((v_b + 3))], 24))
I8[bor(0, v_r)] = tobit(v_b)
I8[tobit((v_r + 1))] = tobit((rshift(v_b, 8) % 4294967296))
I8[tobit((v_r + 2))] = tobit((rshift(v_b, 16) % 4294967296))
I8[tobit((v_r + 3))] = tobit((rshift(v_b, 24) % 4294967296))
I8[tobit((v_r + 4))] = tobit(v_h)
I8[tobit((v_r + 5))] = tobit((rshift(v_h, 8) % 4294967296))
I8[tobit((v_r + 6))] = tobit((rshift(v_h, 16) % 4294967296))
I8[tobit((v_r + 7))] = tobit((rshift(v_h, 24) % 4294967296))
v_b = tobit((v_r + 16))
v_r = I32[7793]
v_b = F.fQA(v_b, I32[7792], v_r)
if (v_e ~= 0) then
F.fQA(tobit((v_r + v_b)), v_n, v_e)
end
v_r = F.fT(v_s)
F.fR(v_w)
F.fR(v_C)
F.fR(v_y)
B = tobit((v_d + 48))
do
do
do
do
do
do
if (bor(0, v_k) <= 31344422) then
if (bor(0, v_k) <= 29344483) then
if (21123123 == bor(0, v_k)) then
goto L341
end
if (21132184 ~= bor(0, v_k)) then
goto L336
end
I8[tobit((v_c + 16))] = tobit(0)
I32[arshift((v_c + 8), 2)] = tobit(0)
I32[arshift((v_c + 12), 2)] = tobit(0)
v_n = bor(bor(bor(U8[tobit((v_r + 4))], lshift(U8[tobit((v_r + 5))], 8)), lshift(U8[tobit((v_r + 6))], 16)), lshift(U8[tobit((v_r + 7))], 24))
I32[arshift((v_c + 8), 2)] = tobit(bor(bor(bor(U8[bor(0, v_r)], lshift(U8[tobit((v_r + 1))], 8)), lshift(U8[tobit((v_r + 2))], 16)), lshift(U8[tobit((v_r + 3))], 24)))
I32[arshift((v_c + 12), 2)] = tobit(v_n)
v_A = F.fiA(v_v, v_A, tobit((v_c + 8)), tobit((v_c + 8)), tobit((v_c + 28)))
I8[tobit((v_c + 512))] = tobit(0)
I32[arshift((v_c + 504), 2)] = tobit(0)
I32[arshift((v_c + 508), 2)] = tobit(0)
I32[arshift((v_c + 496), 2)] = tobit(0)
I32[arshift((v_c + 500), 2)] = tobit(0)
v_n = bor(bor(bor(U8[tobit((v_r + 4))], lshift(U8[tobit((v_r + 5))], 8)), lshift(U8[tobit((v_r + 6))], 16)), lshift(U8[tobit((v_r + 7))], 24))
I32[arshift((v_c + 496), 2)] = tobit(bor(bor(bor(U8[bor(0, v_r)], lshift(U8[tobit((v_r + 1))], 8)), lshift(U8[tobit((v_r + 2))], 16)), lshift(U8[tobit((v_r + 3))], 24)))
I32[arshift((v_c + 500), 2)] = tobit(v_n)
v_n = bor(bor(bor(U8[tobit((v_r + 12))], lshift(U8[tobit((v_r + 13))], 8)), lshift(U8[tobit((v_r + 14))], 16)), lshift(U8[tobit((v_r + 15))], 24))
I32[arshift((v_c + 504), 2)] = tobit(bor(bor(bor(U8[tobit((v_r + 8))], lshift(U8[tobit((v_r + 9))], 8)), lshift(U8[tobit((v_r + 10))], 16)), lshift(U8[tobit((v_r + 11))], 24)))
I32[arshift((v_c + 508), 2)] = tobit(v_n)
I32[arshift(v_a, 2)] = tobit(F.foA(v_A, I32[arshift((v_c + 28), 2)], tobit((v_c + 496)), v_r, v_u))
F.fR(v_A)
goto L336
end
if (29344484 == bor(0, v_k)) then
goto L338
end
if (29859828 ~= bor(0, v_k)) then
goto L336
end
I8[tobit((v_c + 512))] = tobit(0)
I32[arshift((v_c + 504), 2)] = tobit(0)
I32[arshift((v_c + 508), 2)] = tobit(0)
I32[arshift((v_c + 496), 2)] = tobit(0)
I32[arshift((v_c + 500), 2)] = tobit(0)
v_n = bor(bor(bor(U8[tobit((v_r + 4))], lshift(U8[tobit((v_r + 5))], 8)), lshift(U8[tobit((v_r + 6))], 16)), lshift(U8[tobit((v_r + 7))], 24))
I32[arshift((v_c + 496), 2)] = tobit(bor(bor(bor(U8[bor(0, v_r)], lshift(U8[tobit((v_r + 1))], 8)), lshift(U8[tobit((v_r + 2))], 16)), lshift(U8[tobit((v_r + 3))], 24)))
I32[arshift((v_c + 500), 2)] = tobit(v_n)
v_n = bor(bor(bor(U8[tobit((v_r + 12))], lshift(U8[tobit((v_r + 13))], 8)), lshift(U8[tobit((v_r + 14))], 16)), lshift(U8[tobit((v_r + 15))], 24))
I32[arshift((v_c + 504), 2)] = tobit(bor(bor(bor(U8[tobit((v_r + 8))], lshift(U8[tobit((v_r + 9))], 8)), lshift(U8[tobit((v_r + 10))], 16)), lshift(U8[tobit((v_r + 11))], 24)))
I32[arshift((v_c + 508), 2)] = tobit(v_n)
v_A = F.foA(v_v, v_A, tobit((v_c + 496)), v_r, tobit((v_c + 28)))
I8[tobit((v_c + 13))] = tobit(0)
I8[tobit((v_c + 14))] = tobit(0)
I8[tobit((v_c + 15))] = tobit(0)
I8[tobit((v_c + 16))] = tobit(0)
I8[tobit((v_c + 17))] = tobit(0)
I8[tobit((v_c + 18))] = tobit(0)
I8[tobit((v_c + 19))] = tobit(0)
I8[tobit((v_c + 20))] = tobit(0)
I32[arshift((v_c + 8), 2)] = tobit(0)
I32[arshift((v_c + 12), 2)] = tobit(0)
I32[arshift((v_c + 16), 2)] = tobit(bor(bor(bor(U8[tobit((v_r + 8))], lshift(U8[tobit((v_r + 9))], 8)), lshift(U8[tobit((v_r + 10))], 16)), lshift(U8[tobit((v_r + 11))], 24)))
v_n = bor(bor(bor(U8[tobit((v_r + 4))], lshift(U8[tobit((v_r + 5))], 8)), lshift(U8[tobit((v_r + 6))], 16)), lshift(U8[tobit((v_r + 7))], 24))
I32[arshift((v_c + 8), 2)] = tobit(bor(bor(bor(U8[bor(0, v_r)], lshift(U8[tobit((v_r + 1))], 8)), lshift(U8[tobit((v_r + 2))], 16)), lshift(U8[tobit((v_r + 3))], 24)))
I32[arshift((v_c + 12), 2)] = tobit(v_n)
I32[arshift(v_a, 2)] = tobit(F.fS_(v_A, I32[arshift((v_c + 28), 2)], tobit((v_c + 8)), v_r))
if (v_u ~= 0) then
I32[arshift(v_u, 2)] = tobit(I32[arshift((v_c + 28), 2)])
end
F.fR(v_A)
goto L336
end
if (bor(0, v_k) <= 34232880) then
if (31344423 == bor(0, v_k)) then
goto L337
end
if (31932881 ~= bor(0, v_k)) then
goto L336
end
I8[tobit((v_c + 512))] = tobit(0)
I32[arshift((v_c + 504), 2)] = tobit(0)
I32[arshift((v_c + 508), 2)] = tobit(0)
I32[arshift((v_c + 496), 2)] = tobit(0)
I32[arshift((v_c + 500), 2)] = tobit(0)
v_n = bor(bor(bor(U8[tobit((v_r + 4))], lshift(U8[tobit((v_r + 5))], 8)), lshift(U8[tobit((v_r + 6))], 16)), lshift(U8[tobit((v_r + 7))], 24))
I32[arshift((v_c + 496), 2)] = tobit(bor(bor(bor(U8[bor(0, v_r)], lshift(U8[tobit((v_r + 1))], 8)), lshift(U8[tobit((v_r + 2))], 16)), lshift(U8[tobit((v_r + 3))], 24)))
I32[arshift((v_c + 500), 2)] = tobit(v_n)
v_n = bor(bor(bor(U8[tobit((v_r + 12))], lshift(U8[tobit((v_r + 13))], 8)), lshift(U8[tobit((v_r + 14))], 16)), lshift(U8[tobit((v_r + 15))], 24))
I32[arshift((v_c + 504), 2)] = tobit(bor(bor(bor(U8[tobit((v_r + 8))], lshift(U8[tobit((v_r + 9))], 8)), lshift(U8[tobit((v_r + 10))], 16)), lshift(U8[tobit((v_r + 11))], 24)))
I32[arshift((v_c + 508), 2)] = tobit(v_n)
v_A = F.foA(v_v, v_A, tobit((v_c + 496)), v_r, tobit((v_c + 28)))
I8[tobit((v_c + 16))] = tobit(0)
I32[arshift((v_c + 8), 2)] = tobit(0)
I32[arshift((v_c + 12), 2)] = tobit(0)
v_n = bor(bor(bor(U8[tobit((v_r + 4))], lshift(U8[tobit((v_r + 5))], 8)), lshift(U8[tobit((v_r + 6))], 16)), lshift(U8[tobit((v_r + 7))], 24))
I32[arshift((v_c + 8), 2)] = tobit(bor(bor(bor(U8[bor(0, v_r)], lshift(U8[tobit((v_r + 1))], 8)), lshift(U8[tobit((v_r + 2))], 16)), lshift(U8[tobit((v_r + 3))], 24)))
I32[arshift((v_c + 12), 2)] = tobit(v_n)
I32[arshift(v_a, 2)] = tobit(F.fiA(v_A, I32[arshift((v_c + 28), 2)], tobit((v_c + 8)), tobit((v_c + 8)), v_u))
F.fR(v_A)
goto L336
end
if (34232881 == bor(0, v_k)) then
goto L339
end
if (34941028 == bor(0, v_k)) then
goto L340
end
if (94859123 ~= bor(0, v_k)) then
goto L336
end
I8[tobit((v_c + 13))] = tobit(0)
I8[tobit((v_c + 14))] = tobit(0)
I8[tobit((v_c + 15))] = tobit(0)
I8[tobit((v_c + 16))] = tobit(0)
I8[tobit((v_c + 17))] = tobit(0)
I8[tobit((v_c + 18))] = tobit(0)
I8[tobit((v_c + 19))] = tobit(0)
I8[tobit((v_c + 20))] = tobit(0)
I32[arshift((v_c + 8), 2)] = tobit(0)
I32[arshift((v_c + 12), 2)] = tobit(0)
I32[arshift((v_c + 16), 2)] = tobit(bor(bor(bor(U8[tobit((v_r + 8))], lshift(U8[tobit((v_r + 9))], 8)), lshift(U8[tobit((v_r + 10))], 16)), lshift(U8[tobit((v_r + 11))], 24)))
v_n = bor(bor(bor(U8[tobit((v_r + 4))], lshift(U8[tobit((v_r + 5))], 8)), lshift(U8[tobit((v_r + 6))], 16)), lshift(U8[tobit((v_r + 7))], 24))
I32[arshift((v_c + 8), 2)] = tobit(bor(bor(bor(U8[bor(0, v_r)], lshift(U8[tobit((v_r + 1))], 8)), lshift(U8[tobit((v_r + 2))], 16)), lshift(U8[tobit((v_r + 3))], 24)))
I32[arshift((v_c + 12), 2)] = tobit(v_n)
v_n = F.fS_(v_v, v_A, tobit((v_c + 8)), v_r)
I8[tobit((v_c + 512))] = tobit(0)
I32[arshift((v_c + 504), 2)] = tobit(0)
I32[arshift((v_c + 508), 2)] = tobit(0)
I32[arshift((v_c + 496), 2)] = tobit(0)
I32[arshift((v_c + 500), 2)] = tobit(0)
v_e = bor(bor(bor(U8[tobit((v_r + 4))], lshift(U8[tobit((v_r + 5))], 8)), lshift(U8[tobit((v_r + 6))], 16)), lshift(U8[tobit((v_r + 7))], 24))
I32[arshift((v_c + 496), 2)] = tobit(bor(bor(bor(U8[bor(0, v_r)], lshift(U8[tobit((v_r + 1))], 8)), lshift(U8[tobit((v_r + 2))], 16)), lshift(U8[tobit((v_r + 3))], 24)))
I32[arshift((v_c + 500), 2)] = tobit(v_e)
v_e = bor(bor(bor(U8[tobit((v_r + 12))], lshift(U8[tobit((v_r + 13))], 8)), lshift(U8[tobit((v_r + 14))], 16)), lshift(U8[tobit((v_r + 15))], 24))
I32[arshift((v_c + 504), 2)] = tobit(bor(bor(bor(U8[tobit((v_r + 8))], lshift(U8[tobit((v_r + 9))], 8)), lshift(U8[tobit((v_r + 10))], 16)), lshift(U8[tobit((v_r + 11))], 24)))
I32[arshift((v_c + 508), 2)] = tobit(v_e)
I32[arshift(v_a, 2)] = tobit(F.foA(v_n, v_A, tobit((v_c + 496)), v_r, v_u))
F.fR(v_n)
goto L336
end
::L341::
I8[tobit((v_c + 512))] = tobit(0)
I32[arshift((v_c + 504), 2)] = tobit(0)
I32[arshift((v_c + 508), 2)] = tobit(0)
I32[arshift((v_c + 496), 2)] = tobit(0)
I32[arshift((v_c + 500), 2)] = tobit(0)
v_n = bor(bor(bor(U8[tobit((v_r + 4))], lshift(U8[tobit((v_r + 5))], 8)), lshift(U8[tobit((v_r + 6))], 16)), lshift(U8[tobit((v_r + 7))], 24))
I32[arshift((v_c + 496), 2)] = tobit(bor(bor(bor(U8[bor(0, v_r)], lshift(U8[tobit((v_r + 1))], 8)), lshift(U8[tobit((v_r + 2))], 16)), lshift(U8[tobit((v_r + 3))], 24)))
I32[arshift((v_c + 500), 2)] = tobit(v_n)
v_n = bor(bor(bor(U8[tobit((v_r + 12))], lshift(U8[tobit((v_r + 13))], 8)), lshift(U8[tobit((v_r + 14))], 16)), lshift(U8[tobit((v_r + 15))], 24))
I32[arshift((v_c + 504), 2)] = tobit(bor(bor(bor(U8[tobit((v_r + 8))], lshift(U8[tobit((v_r + 9))], 8)), lshift(U8[tobit((v_r + 10))], 16)), lshift(U8[tobit((v_r + 11))], 24)))
I32[arshift((v_c + 508), 2)] = tobit(v_n)
v_A = F.foA(v_v, v_A, tobit((v_c + 496)), v_r, tobit((v_c + 8)))
I8[tobit((v_c + 512))] = tobit(0)
I32[arshift((v_c + 504), 2)] = tobit(0)
I32[arshift((v_c + 508), 2)] = tobit(0)
I32[arshift((v_c + 496), 2)] = tobit(0)
I32[arshift((v_c + 500), 2)] = tobit(0)
v_n = bor(bor(bor(U8[tobit((v_r + 4))], lshift(U8[tobit((v_r + 5))], 8)), lshift(U8[tobit((v_r + 6))], 16)), lshift(U8[tobit((v_r + 7))], 24))
I32[arshift((v_c + 496), 2)] = tobit(bor(bor(bor(U8[bor(0, v_r)], lshift(U8[tobit((v_r + 1))], 8)), lshift(U8[tobit((v_r + 2))], 16)), lshift(U8[tobit((v_r + 3))], 24)))
I32[arshift((v_c + 500), 2)] = tobit(v_n)
v_n = bor(bor(bor(U8[tobit((v_r + 12))], lshift(U8[tobit((v_r + 13))], 8)), lshift(U8[tobit((v_r + 14))], 16)), lshift(U8[tobit((v_r + 15))], 24))
I32[arshift((v_c + 504), 2)] = tobit(bor(bor(bor(U8[tobit((v_r + 8))], lshift(U8[tobit((v_r + 9))], 8)), lshift(U8[tobit((v_r + 10))], 16)), lshift(U8[tobit((v_r + 11))], 24)))
I32[arshift((v_c + 508), 2)] = tobit(v_n)
I32[arshift(v_a, 2)] = tobit(F.foA(v_A, I32[arshift((v_c + 8), 2)], tobit((v_c + 496)), v_r, v_u))
F.fR(v_A)
goto L336
end
::L340::
I8[tobit((v_c + 504))] = tobit(0)
I32[arshift((v_c + 496), 2)] = tobit(0)
I32[arshift((v_c + 500), 2)] = tobit(0)
v_n = bor(bor(bor(U8[tobit((v_r + 4))], lshift(U8[tobit((v_r + 5))], 8)), lshift(U8[tobit((v_r + 6))], 16)), lshift(U8[tobit((v_r + 7))], 24))
v_e = bor(bor(bor(U8[bor(0, v_r)], lshift(U8[tobit((v_r + 1))], 8)), lshift(U8[tobit((v_r + 2))], 16)), lshift(U8[tobit((v_r + 3))], 24))
I32[arshift((v_c + 496), 2)] = tobit(v_e)
I32[arshift((v_c + 500), 2)] = tobit(v_n)
I32[arshift((v_c + 8), 2)] = tobit(v_e)
I32[arshift((v_c + 12), 2)] = tobit(v_n)
I8[tobit((v_c + 16))] = tobit(0)
v_A = F.fiA(v_v, v_A, tobit((v_c + 8)), tobit((v_c + 496)), tobit((v_c + 28)))
I8[tobit((v_c + 16))] = tobit(0)
v_n = I32[arshift((v_c + 500), 2)]
I32[arshift((v_c + 8), 2)] = tobit(I32[arshift((v_c + 496), 2)])
I32[arshift((v_c + 12), 2)] = tobit(v_n)
I32[arshift(v_a, 2)] = tobit(F.fiA(v_A, I32[arshift((v_c + 28), 2)], tobit((v_c + 8)), tobit((v_c + 496)), v_u))
F.fR(v_A)
goto L336
end
::L339::
I8[tobit((v_c + 501))] = tobit(0)
I8[tobit((v_c + 502))] = tobit(0)
I8[tobit((v_c + 503))] = tobit(0)
I8[tobit((v_c + 504))] = tobit(0)
I8[tobit((v_c + 505))] = tobit(0)
I8[tobit((v_c + 506))] = tobit(0)
I8[tobit((v_c + 507))] = tobit(0)
I8[tobit((v_c + 508))] = tobit(0)
I32[arshift((v_c + 496), 2)] = tobit(0)
I32[arshift((v_c + 500), 2)] = tobit(0)
I32[arshift((v_c + 504), 2)] = tobit(bor(bor(bor(U8[tobit((v_r + 8))], lshift(U8[tobit((v_r + 9))], 8)), lshift(U8[tobit((v_r + 10))], 16)), lshift(U8[tobit((v_r + 11))], 24)))
v_n = bor(bor(bor(U8[tobit((v_r + 4))], lshift(U8[tobit((v_r + 5))], 8)), lshift(U8[tobit((v_r + 6))], 16)), lshift(U8[tobit((v_r + 7))], 24))
I32[arshift((v_c + 496), 2)] = tobit(bor(bor(bor(U8[bor(0, v_r)], lshift(U8[tobit((v_r + 1))], 8)), lshift(U8[tobit((v_r + 2))], 16)), lshift(U8[tobit((v_r + 3))], 24)))
I32[arshift((v_c + 500), 2)] = tobit(v_n)
v_n = F.fS_(v_v, v_A, tobit((v_c + 496)), v_r)
I8[tobit((v_c + 501))] = tobit(0)
I8[tobit((v_c + 502))] = tobit(0)
I8[tobit((v_c + 503))] = tobit(0)
I8[tobit((v_c + 504))] = tobit(0)
I8[tobit((v_c + 505))] = tobit(0)
I8[tobit((v_c + 506))] = tobit(0)
I8[tobit((v_c + 507))] = tobit(0)
I8[tobit((v_c + 508))] = tobit(0)
I32[arshift((v_c + 496), 2)] = tobit(0)
I32[arshift((v_c + 500), 2)] = tobit(0)
I32[arshift((v_c + 504), 2)] = tobit(bor(bor(bor(U8[tobit((v_r + 8))], lshift(U8[tobit((v_r + 9))], 8)), lshift(U8[tobit((v_r + 10))], 16)), lshift(U8[tobit((v_r + 11))], 24)))
v_e = bor(bor(bor(U8[tobit((v_r + 4))], lshift(U8[tobit((v_r + 5))], 8)), lshift(U8[tobit((v_r + 6))], 16)), lshift(U8[tobit((v_r + 7))], 24))
I32[arshift((v_c + 496), 2)] = tobit(bor(bor(bor(U8[bor(0, v_r)], lshift(U8[tobit((v_r + 1))], 8)), lshift(U8[tobit((v_r + 2))], 16)), lshift(U8[tobit((v_r + 3))], 24)))
I32[arshift((v_c + 500), 2)] = tobit(v_e)
I32[arshift(v_a, 2)] = tobit(F.fS_(v_n, v_A, tobit((v_c + 496)), v_r))
if (v_u ~= 0) then
I32[arshift(v_u, 2)] = tobit(v_A)
end
F.fR(v_n)
goto L336
end
::L338::
I8[tobit((v_c + 501))] = tobit(0)
I8[tobit((v_c + 502))] = tobit(0)
I8[tobit((v_c + 503))] = tobit(0)
I8[tobit((v_c + 504))] = tobit(0)
I8[tobit((v_c + 505))] = tobit(0)
I8[tobit((v_c + 506))] = tobit(0)
I8[tobit((v_c + 507))] = tobit(0)
I8[tobit((v_c + 508))] = tobit(0)
I32[arshift((v_c + 496), 2)] = tobit(0)
I32[arshift((v_c + 500), 2)] = tobit(0)
I32[arshift((v_c + 504), 2)] = tobit(bor(bor(bor(U8[tobit((v_r + 8))], lshift(U8[tobit((v_r + 9))], 8)), lshift(U8[tobit((v_r + 10))], 16)), lshift(U8[tobit((v_r + 11))], 24)))
v_n = bor(bor(bor(U8[tobit((v_r + 4))], lshift(U8[tobit((v_r + 5))], 8)), lshift(U8[tobit((v_r + 6))], 16)), lshift(U8[tobit((v_r + 7))], 24))
I32[arshift((v_c + 496), 2)] = tobit(bor(bor(bor(U8[bor(0, v_r)], lshift(U8[tobit((v_r + 1))], 8)), lshift(U8[tobit((v_r + 2))], 16)), lshift(U8[tobit((v_r + 3))], 24)))
I32[arshift((v_c + 500), 2)] = tobit(v_n)
v_n = F.fS_(v_v, v_A, tobit((v_c + 496)), v_r)
I8[tobit((v_c + 16))] = tobit(0)
I32[arshift((v_c + 8), 2)] = tobit(0)
I32[arshift((v_c + 12), 2)] = tobit(0)
v_e = bor(bor(bor(U8[tobit((v_r + 4))], lshift(U8[tobit((v_r + 5))], 8)), lshift(U8[tobit((v_r + 6))], 16)), lshift(U8[tobit((v_r + 7))], 24))
I32[arshift((v_c + 8), 2)] = tobit(bor(bor(bor(U8[bor(0, v_r)], lshift(U8[tobit((v_r + 1))], 8)), lshift(U8[tobit((v_r + 2))], 16)), lshift(U8[tobit((v_r + 3))], 24)))
I32[arshift((v_c + 12), 2)] = tobit(v_e)
I32[arshift(v_a, 2)] = tobit(F.fiA(v_n, v_A, tobit((v_c + 8)), tobit((v_c + 8)), v_u))
F.fR(v_n)
goto L336
end
::L337::
I8[tobit((v_c + 16))] = tobit(0)
I32[arshift((v_c + 8), 2)] = tobit(0)
I32[arshift((v_c + 12), 2)] = tobit(0)
v_n = bor(bor(bor(U8[tobit((v_r + 4))], lshift(U8[tobit((v_r + 5))], 8)), lshift(U8[tobit((v_r + 6))], 16)), lshift(U8[tobit((v_r + 7))], 24))
I32[arshift((v_c + 8), 2)] = tobit(bor(bor(bor(U8[bor(0, v_r)], lshift(U8[tobit((v_r + 1))], 8)), lshift(U8[tobit((v_r + 2))], 16)), lshift(U8[tobit((v_r + 3))], 24)))
I32[arshift((v_c + 12), 2)] = tobit(v_n)
v_A = F.fiA(v_v, v_A, tobit((v_c + 8)), tobit((v_c + 8)), tobit((v_c + 28)))
I8[tobit((v_c + 501))] = tobit(0)
I8[tobit((v_c + 502))] = tobit(0)
I8[tobit((v_c + 503))] = tobit(0)
I8[tobit((v_c + 504))] = tobit(0)
I8[tobit((v_c + 505))] = tobit(0)
I8[tobit((v_c + 506))] = tobit(0)
I8[tobit((v_c + 507))] = tobit(0)
I8[tobit((v_c + 508))] = tobit(0)
I32[arshift((v_c + 496), 2)] = tobit(0)
I32[arshift((v_c + 500), 2)] = tobit(0)
I32[arshift((v_c + 504), 2)] = tobit(bor(bor(bor(U8[tobit((v_r + 8))], lshift(U8[tobit((v_r + 9))], 8)), lshift(U8[tobit((v_r + 10))], 16)), lshift(U8[tobit((v_r + 11))], 24)))
v_n = bor(bor(bor(U8[tobit((v_r + 4))], lshift(U8[tobit((v_r + 5))], 8)), lshift(U8[tobit((v_r + 6))], 16)), lshift(U8[tobit((v_r + 7))], 24))
I32[arshift((v_c + 496), 2)] = tobit(bor(bor(bor(U8[bor(0, v_r)], lshift(U8[tobit((v_r + 1))], 8)), lshift(U8[tobit((v_r + 2))], 16)), lshift(U8[tobit((v_r + 3))], 24)))
I32[arshift((v_c + 500), 2)] = tobit(v_n)
I32[arshift(v_a, 2)] = tobit(F.fS_(v_A, I32[arshift((v_c + 28), 2)], tobit((v_c + 496)), v_r))
if (v_u ~= 0) then
I32[arshift(v_u, 2)] = tobit(I32[arshift((v_c + 28), 2)])
end
F.fR(v_A)
end
::L336::
F.fR(v_r)
v_v = ((I32[arshift(v_a, 2)] ~= 0) and 0 or (-1))
end
end
else
v_v = (-1)
end
end
end
end
end
else
v_v = (-2)
end
end
end
end
B = tobit((v_c + 528))
do return bor(0, v_v) end
end
UA[56] = function()
local v_A, v_r, v_n, v_e, v_a, v_u, v_c = 0, 0, 0, 0, 0, 0, 0
v_r = 0
v_n = 0
v_e = 0
v_a = 0
v_u = 0
v_c = 0
do
v_A = tobit((B - 752))
B = v_A
if (not (I32[7800] ~= 0)) then
do
F.fMA(tobit((v_A + 472)))
I8[tobit((v_A + 464))] = tobit(57)
I8[tobit((v_A + 465))] = tobit(111)
I8[tobit((v_A + 466))] = tobit(54)
I8[tobit((v_A + 467))] = tobit(52)
I8[tobit((v_A + 468))] = tobit(120)
I8[tobit((v_A + 469))] = tobit(56)
I8[tobit((v_A + 470))] = tobit(98)
I8[tobit((v_A + 471))] = tobit(104)
I8[tobit((v_A + 456))] = tobit(118)
I8[tobit((v_A + 457))] = tobit(49)
I8[tobit((v_A + 458))] = tobit(102)
I8[tobit((v_A + 459))] = tobit(114)
I8[tobit((v_A + 460))] = tobit(107)
I8[tobit((v_A + 461))] = tobit(51)
I8[tobit((v_A + 462))] = tobit(55)
I8[tobit((v_A + 463))] = tobit(99)
F.fH(tobit((v_A + 472)), tobit((v_A + 456)), 128)
v_r = bor(bor(bor(U8[13132], lshift(U8[13133], 8)), lshift(U8[13134], 16)), lshift(U8[13135], 24))
I32[arshift((v_A + 416), 2)] = tobit(bor(bor(bor(U8[13128], lshift(U8[13129], 8)), lshift(U8[13130], 16)), lshift(U8[13131], 24)))
I32[arshift((v_A + 420), 2)] = tobit(v_r)
v_r = bor(bor(bor(U8[13140], lshift(U8[13141], 8)), lshift(U8[13142], 16)), lshift(U8[13143], 24))
I32[arshift((v_A + 424), 2)] = tobit(bor(bor(bor(U8[13136], lshift(U8[13137], 8)), lshift(U8[13138], 16)), lshift(U8[13139], 24)))
I32[arshift((v_A + 428), 2)] = tobit(v_r)
v_r = bor(bor(bor(U8[13148], lshift(U8[13149], 8)), lshift(U8[13150], 16)), lshift(U8[13151], 24))
I32[arshift((v_A + 432), 2)] = tobit(bor(bor(bor(U8[13144], lshift(U8[13145], 8)), lshift(U8[13146], 16)), lshift(U8[13147], 24)))
I32[arshift((v_A + 436), 2)] = tobit(v_r)
I8[tobit((v_A + 448))] = tobit(49)
I8[tobit((v_A + 449))] = tobit(48)
I8[tobit((v_A + 450))] = tobit(115)
I8[tobit((v_A + 451))] = tobit(112)
I8[tobit((v_A + 452))] = tobit(122)
I8[tobit((v_A + 453))] = tobit(121)
I8[tobit((v_A + 454))] = tobit(120)
I8[tobit((v_A + 455))] = tobit(108)
I8[tobit((v_A + 440))] = tobit(109)
I8[tobit((v_A + 441))] = tobit(55)
I8[tobit((v_A + 442))] = tobit(56)
I8[tobit((v_A + 443))] = tobit(54)
I8[tobit((v_A + 444))] = tobit(52)
I8[tobit((v_A + 445))] = tobit(51)
I8[tobit((v_A + 446))] = tobit(117)
I8[tobit((v_A + 447))] = tobit(116)
v_r = bor(bor(bor(U8[13124], lshift(U8[13125], 8)), lshift(U8[13126], 16)), lshift(U8[13127], 24))
I32[arshift((v_A + 408), 2)] = tobit(bor(bor(bor(U8[13120], lshift(U8[13121], 8)), lshift(U8[13122], 16)), lshift(U8[13123], 24)))
I32[arshift((v_A + 412), 2)] = tobit(v_r)
v_n = 32
F.fM(tobit((v_A + 472)), 0, 32, tobit((v_A + 440)), tobit((v_A + 408)), tobit((v_A + 336)))
F.fvA(tobit((v_A + 472)))
do
do
do
v_r = U8[tobit((v_A + 367))]
local t392 = (((tobit(band((v_r - 1), 255)) % 4294967296) > 15) and 1 or 0)
if t392 == 0 then
v_e = 2
v_n = 31
t392 = (((tobit(v_r) % 4294967296) < 2) and 1 or 0)
end
if (not (t392 ~= 0)) then
do
v_n = 30
while true do
do
if (bor(((bor(0, v_r) ~= U8[tobit((tobit((v_A + 336)) + v_n))]) and 1 or 0), (((tobit(v_r) % 4294967296) <= (tobit(band(255, v_e)) % 4294967296)) and 1 or 0)) ~= 0) then
goto L342
end
v_e = tobit((v_e + 1))
v_n = tobit((v_n - 1))
end
::C343::
end
end
::B343::
end
end
end
::L342::
end
v_r = F.fI(tobit((v_n + 1)))
F.fOA(tobit((v_r + v_n)), 0, (((-1) ~= bor(0, v_n)) and 1 or 0))
I32[7800] = tobit(F.fQA(v_r, tobit((v_A + 336)), v_n))
end
end
end
do
if (not (I32[7801] ~= 0)) then
do
F.fMA(tobit((v_A + 472)))
I8[tobit((v_A + 328))] = tobit(115)
I8[tobit((v_A + 329))] = tobit(50)
I8[tobit((v_A + 330))] = tobit(101)
I8[tobit((v_A + 331))] = tobit(56)
I8[tobit((v_A + 332))] = tobit(100)
I8[tobit((v_A + 333))] = tobit(110)
I8[tobit((v_A + 334))] = tobit(114)
I8[tobit((v_A + 335))] = tobit(111)
I8[tobit((v_A + 320))] = tobit(105)
I8[tobit((v_A + 321))] = tobit(54)
I8[tobit((v_A + 322))] = tobit(48)
I8[tobit((v_A + 323))] = tobit(119)
I8[tobit((v_A + 324))] = tobit(98)
I8[tobit((v_A + 325))] = tobit(102)
I8[tobit((v_A + 326))] = tobit(99)
I8[tobit((v_A + 327))] = tobit(109)
F.fH(tobit((v_A + 472)), tobit((v_A + 320)), 128)
v_r = bor(bor(bor(U8[13164], lshift(U8[13165], 8)), lshift(U8[13166], 16)), lshift(U8[13167], 24))
I32[arshift((v_A + 248), 2)] = tobit(bor(bor(bor(U8[13160], lshift(U8[13161], 8)), lshift(U8[13162], 16)), lshift(U8[13163], 24)))
I32[arshift((v_A + 252), 2)] = tobit(v_r)
v_r = bor(bor(bor(U8[13172], lshift(U8[13173], 8)), lshift(U8[13174], 16)), lshift(U8[13175], 24))
I32[arshift((v_A + 256), 2)] = tobit(bor(bor(bor(U8[13168], lshift(U8[13169], 8)), lshift(U8[13170], 16)), lshift(U8[13171], 24)))
I32[arshift((v_A + 260), 2)] = tobit(v_r)
v_r = bor(bor(bor(U8[13180], lshift(U8[13181], 8)), lshift(U8[13182], 16)), lshift(U8[13183], 24))
I32[arshift((v_A + 264), 2)] = tobit(bor(bor(bor(U8[13176], lshift(U8[13177], 8)), lshift(U8[13178], 16)), lshift(U8[13179], 24)))
I32[arshift((v_A + 268), 2)] = tobit(v_r)
v_r = bor(bor(bor(U8[13188], lshift(U8[13189], 8)), lshift(U8[13190], 16)), lshift(U8[13191], 24))
I32[arshift((v_A + 272), 2)] = tobit(bor(bor(bor(U8[13184], lshift(U8[13185], 8)), lshift(U8[13186], 16)), lshift(U8[13187], 24)))
I32[arshift((v_A + 276), 2)] = tobit(v_r)
v_r = bor(bor(bor(U8[13196], lshift(U8[13197], 8)), lshift(U8[13198], 16)), lshift(U8[13199], 24))
I32[arshift((v_A + 280), 2)] = tobit(bor(bor(bor(U8[13192], lshift(U8[13193], 8)), lshift(U8[13194], 16)), lshift(U8[13195], 24)))
I32[arshift((v_A + 284), 2)] = tobit(v_r)
v_r = bor(bor(bor(U8[13204], lshift(U8[13205], 8)), lshift(U8[13206], 16)), lshift(U8[13207], 24))
I32[arshift((v_A + 288), 2)] = tobit(bor(bor(bor(U8[13200], lshift(U8[13201], 8)), lshift(U8[13202], 16)), lshift(U8[13203], 24)))
I32[arshift((v_A + 292), 2)] = tobit(v_r)
v_r = bor(bor(bor(U8[13212], lshift(U8[13213], 8)), lshift(U8[13214], 16)), lshift(U8[13215], 24))
I32[arshift((v_A + 296), 2)] = tobit(bor(bor(bor(U8[13208], lshift(U8[13209], 8)), lshift(U8[13210], 16)), lshift(U8[13211], 24)))
I32[arshift((v_A + 300), 2)] = tobit(v_r)
I8[tobit((v_A + 312))] = tobit(119)
I8[tobit((v_A + 313))] = tobit(111)
I8[tobit((v_A + 314))] = tobit(104)
I8[tobit((v_A + 315))] = tobit(114)
I8[tobit((v_A + 316))] = tobit(113)
I8[tobit((v_A + 317))] = tobit(53)
I8[tobit((v_A + 318))] = tobit(56)
I8[tobit((v_A + 319))] = tobit(106)
I8[tobit((v_A + 304))] = tobit(116)
I8[tobit((v_A + 305))] = tobit(50)
I8[tobit((v_A + 306))] = tobit(110)
I8[tobit((v_A + 307))] = tobit(57)
I8[tobit((v_A + 308))] = tobit(100)
I8[tobit((v_A + 309))] = tobit(51)
I8[tobit((v_A + 310))] = tobit(54)
I8[tobit((v_A + 311))] = tobit(97)
v_r = bor(bor(bor(U8[13156], lshift(U8[13157], 8)), lshift(U8[13158], 16)), lshift(U8[13159], 24))
I32[arshift((v_A + 240), 2)] = tobit(bor(bor(bor(U8[13152], lshift(U8[13153], 8)), lshift(U8[13154], 16)), lshift(U8[13155], 24)))
I32[arshift((v_A + 244), 2)] = tobit(v_r)
v_n = 64
F.fM(tobit((v_A + 472)), 0, 64, tobit((v_A + 304)), tobit((v_A + 240)), tobit((v_A + 336)))
F.fvA(tobit((v_A + 472)))
do
do
do
v_r = U8[tobit((v_A + 399))]
local t393 = (((tobit(band((v_r - 1), 255)) % 4294967296) > 15) and 1 or 0)
if t393 == 0 then
v_e = 2
v_n = 63
t393 = (((tobit(v_r) % 4294967296) < 2) and 1 or 0)
end
if (not (t393 ~= 0)) then
do
v_n = 62
while true do
do
if (bor(((bor(0, v_r) ~= U8[tobit((tobit((v_A + 336)) + v_n))]) and 1 or 0), (((tobit(v_r) % 4294967296) <= (tobit(band(255, v_e)) % 4294967296)) and 1 or 0)) ~= 0) then
goto L344
end
v_e = tobit((v_e + 1))
v_n = tobit((v_n - 1))
end
::C345::
end
end
::B345::
end
end
end
::L344::
end
v_r = F.fI(tobit((v_n + 1)))
F.fOA(tobit((v_r + v_n)), 0, (((-1) ~= bor(0, v_n)) and 1 or 0))
I32[7801] = tobit(F.fQA(v_r, tobit((v_A + 336)), v_n))
end
end
end
do
if (not (I32[7802] ~= 0)) then
do
F.fMA(tobit((v_A + 472)))
I8[tobit((v_A + 232))] = tobit(118)
I8[tobit((v_A + 233))] = tobit(56)
I8[tobit((v_A + 234))] = tobit(48)
I8[tobit((v_A + 235))] = tobit(107)
I8[tobit((v_A + 236))] = tobit(103)
I8[tobit((v_A + 237))] = tobit(50)
I8[tobit((v_A + 238))] = tobit(104)
I8[tobit((v_A + 239))] = tobit(54)
I8[tobit((v_A + 224))] = tobit(120)
I8[tobit((v_A + 225))] = tobit(119)
I8[tobit((v_A + 226))] = tobit(110)
I8[tobit((v_A + 227))] = tobit(101)
I8[tobit((v_A + 228))] = tobit(49)
I8[tobit((v_A + 229))] = tobit(53)
I8[tobit((v_A + 230))] = tobit(116)
I8[tobit((v_A + 231))] = tobit(105)
F.fH(tobit((v_A + 472)), tobit((v_A + 224)), 128)
I8[tobit((v_A + 216))] = tobit(111)
I8[tobit((v_A + 217))] = tobit(100)
I8[tobit((v_A + 218))] = tobit(114)
I8[tobit((v_A + 219))] = tobit(104)
I8[tobit((v_A + 220))] = tobit(54)
I8[tobit((v_A + 221))] = tobit(115)
I8[tobit((v_A + 222))] = tobit(99)
I8[tobit((v_A + 223))] = tobit(101)
I8[tobit((v_A + 208))] = tobit(98)
I8[tobit((v_A + 209))] = tobit(106)
I8[tobit((v_A + 210))] = tobit(49)
I8[tobit((v_A + 211))] = tobit(113)
I8[tobit((v_A + 212))] = tobit(103)
I8[tobit((v_A + 213))] = tobit(121)
I8[tobit((v_A + 214))] = tobit(97)
I8[tobit((v_A + 215))] = tobit(50)
I8[tobit((v_A + 200))] = tobit(203)
I8[tobit((v_A + 201))] = tobit(57)
I8[tobit((v_A + 202))] = tobit(201)
I8[tobit((v_A + 203))] = tobit(73)
I8[tobit((v_A + 204))] = tobit(31)
I8[tobit((v_A + 205))] = tobit(230)
I8[tobit((v_A + 206))] = tobit(245)
I8[tobit((v_A + 207))] = tobit(193)
I8[tobit((v_A + 192))] = tobit(6)
I8[tobit((v_A + 193))] = tobit(118)
I8[tobit((v_A + 194))] = tobit(195)
I8[tobit((v_A + 195))] = tobit(164)
I8[tobit((v_A + 196))] = tobit(197)
I8[tobit((v_A + 197))] = tobit(116)
I8[tobit((v_A + 198))] = tobit(203)
I8[tobit((v_A + 199))] = tobit(88)
v_n = 16
F.fM(tobit((v_A + 472)), 0, 16, tobit((v_A + 208)), tobit((v_A + 192)), tobit((v_A + 336)))
F.fvA(tobit((v_A + 472)))
do
do
do
v_r = U8[tobit((v_A + 351))]
local t394 = bor(bor((((tobit(v_r) % 4294967296) > 16) and 1 or 0), ((not (v_r ~= 0)) and 1 or 0)), ((16 == bor(0, v_r)) and 1 or 0))
if t394 == 0 then
v_e = 2
v_n = 15
t394 = (((tobit(v_r) % 4294967296) < 2) and 1 or 0)
end
if (not (t394 ~= 0)) then
do
v_n = 14
while true do
do
if (bor(((bor(0, v_r) ~= U8[tobit((tobit((v_A + 336)) + v_n))]) and 1 or 0), (((tobit(v_r) % 4294967296) <= (tobit(band(255, v_e)) % 4294967296)) and 1 or 0)) ~= 0) then
goto L346
end
v_e = tobit((v_e + 1))
v_n = tobit((v_n - 1))
end
::C347::
end
end
::B347::
end
end
end
::L346::
end
v_r = F.fI(tobit((v_n + 1)))
F.fOA(tobit((v_r + v_n)), 0, (((-1) ~= bor(0, v_n)) and 1 or 0))
I32[7802] = tobit(F.fQA(v_r, tobit((v_A + 336)), v_n))
end
end
end
do
if (not (I32[7803] ~= 0)) then
do
F.fMA(tobit((v_A + 472)))
I8[tobit((v_A + 184))] = tobit(115)
I8[tobit((v_A + 185))] = tobit(99)
I8[tobit((v_A + 186))] = tobit(114)
I8[tobit((v_A + 187))] = tobit(52)
I8[tobit((v_A + 188))] = tobit(119)
I8[tobit((v_A + 189))] = tobit(110)
I8[tobit((v_A + 190))] = tobit(97)
I8[tobit((v_A + 191))] = tobit(122)
I8[tobit((v_A + 176))] = tobit(107)
I8[tobit((v_A + 177))] = tobit(53)
I8[tobit((v_A + 178))] = tobit(57)
I8[tobit((v_A + 179))] = tobit(106)
I8[tobit((v_A + 180))] = tobit(50)
I8[tobit((v_A + 181))] = tobit(98)
I8[tobit((v_A + 182))] = tobit(120)
I8[tobit((v_A + 183))] = tobit(104)
F.fH(tobit((v_A + 472)), tobit((v_A + 176)), 128)
I8[tobit((v_A + 168))] = tobit(52)
I8[tobit((v_A + 169))] = tobit(120)
I8[tobit((v_A + 170))] = tobit(101)
I8[tobit((v_A + 171))] = tobit(105)
I8[tobit((v_A + 172))] = tobit(57)
I8[tobit((v_A + 173))] = tobit(56)
I8[tobit((v_A + 174))] = tobit(116)
I8[tobit((v_A + 175))] = tobit(54)
I8[tobit((v_A + 160))] = tobit(99)
I8[tobit((v_A + 161))] = tobit(113)
I8[tobit((v_A + 162))] = tobit(98)
I8[tobit((v_A + 163))] = tobit(110)
I8[tobit((v_A + 164))] = tobit(53)
I8[tobit((v_A + 165))] = tobit(121)
I8[tobit((v_A + 166))] = tobit(97)
I8[tobit((v_A + 167))] = tobit(55)
I8[tobit((v_A + 152))] = tobit(247)
I8[tobit((v_A + 153))] = tobit(211)
I8[tobit((v_A + 154))] = tobit(145)
I8[tobit((v_A + 155))] = tobit(121)
I8[tobit((v_A + 156))] = tobit(20)
I8[tobit((v_A + 157))] = tobit(91)
I8[tobit((v_A + 158))] = tobit(180)
I8[tobit((v_A + 159))] = tobit(3)
I8[tobit((v_A + 144))] = tobit(183)
I8[tobit((v_A + 145))] = tobit(71)
I8[tobit((v_A + 146))] = tobit(228)
I8[tobit((v_A + 147))] = tobit(180)
I8[tobit((v_A + 148))] = tobit(145)
I8[tobit((v_A + 149))] = tobit(104)
I8[tobit((v_A + 150))] = tobit(243)
I8[tobit((v_A + 151))] = tobit(111)
v_n = 16
F.fM(tobit((v_A + 472)), 0, 16, tobit((v_A + 160)), tobit((v_A + 144)), tobit((v_A + 336)))
F.fvA(tobit((v_A + 472)))
do
do
do
v_r = U8[tobit((v_A + 351))]
local t395 = bor(bor((((tobit(v_r) % 4294967296) > 16) and 1 or 0), ((not (v_r ~= 0)) and 1 or 0)), ((16 == bor(0, v_r)) and 1 or 0))
if t395 == 0 then
v_e = 2
v_n = 15
t395 = (((tobit(v_r) % 4294967296) < 2) and 1 or 0)
end
if (not (t395 ~= 0)) then
do
v_n = 14
while true do
do
if (bor(((bor(0, v_r) ~= U8[tobit((tobit((v_A + 336)) + v_n))]) and 1 or 0), (((tobit(v_r) % 4294967296) <= (tobit(band(255, v_e)) % 4294967296)) and 1 or 0)) ~= 0) then
goto L348
end
v_e = tobit((v_e + 1))
v_n = tobit((v_n - 1))
end
::C349::
end
end
::B349::
end
end
end
::L348::
end
v_r = F.fI(tobit((v_n + 1)))
F.fOA(tobit((v_r + v_n)), 0, (((-1) ~= bor(0, v_n)) and 1 or 0))
I32[7803] = tobit(F.fQA(v_r, tobit((v_A + 336)), v_n))
end
end
end
do
if (not (I32[7804] ~= 0)) then
do
F.fMA(tobit((v_A + 472)))
I8[tobit((v_A + 136))] = tobit(97)
I8[tobit((v_A + 137))] = tobit(52)
I8[tobit((v_A + 138))] = tobit(107)
I8[tobit((v_A + 139))] = tobit(103)
I8[tobit((v_A + 140))] = tobit(57)
I8[tobit((v_A + 141))] = tobit(53)
I8[tobit((v_A + 142))] = tobit(114)
I8[tobit((v_A + 143))] = tobit(106)
I8[tobit((v_A + 128))] = tobit(105)
I8[tobit((v_A + 129))] = tobit(100)
I8[tobit((v_A + 130))] = tobit(101)
I8[tobit((v_A + 131))] = tobit(119)
I8[tobit((v_A + 132))] = tobit(122)
I8[tobit((v_A + 133))] = tobit(120)
I8[tobit((v_A + 134))] = tobit(54)
I8[tobit((v_A + 135))] = tobit(50)
F.fH(tobit((v_A + 472)), tobit((v_A + 128)), 128)
v_r = bor(bor(bor(U8[13228], lshift(U8[13229], 8)), lshift(U8[13230], 16)), lshift(U8[13231], 24))
I32[arshift((v_A + 88), 2)] = tobit(bor(bor(bor(U8[13224], lshift(U8[13225], 8)), lshift(U8[13226], 16)), lshift(U8[13227], 24)))
I32[arshift((v_A + 92), 2)] = tobit(v_r)
v_r = bor(bor(bor(U8[13236], lshift(U8[13237], 8)), lshift(U8[13238], 16)), lshift(U8[13239], 24))
I32[arshift((v_A + 96), 2)] = tobit(bor(bor(bor(U8[13232], lshift(U8[13233], 8)), lshift(U8[13234], 16)), lshift(U8[13235], 24)))
I32[arshift((v_A + 100), 2)] = tobit(v_r)
v_r = bor(bor(bor(U8[13244], lshift(U8[13245], 8)), lshift(U8[13246], 16)), lshift(U8[13247], 24))
I32[arshift((v_A + 104), 2)] = tobit(bor(bor(bor(U8[13240], lshift(U8[13241], 8)), lshift(U8[13242], 16)), lshift(U8[13243], 24)))
I32[arshift((v_A + 108), 2)] = tobit(v_r)
I8[tobit((v_A + 120))] = tobit(56)
I8[tobit((v_A + 121))] = tobit(102)
I8[tobit((v_A + 122))] = tobit(52)
I8[tobit((v_A + 123))] = tobit(115)
I8[tobit((v_A + 124))] = tobit(53)
I8[tobit((v_A + 125))] = tobit(101)
I8[tobit((v_A + 126))] = tobit(103)
I8[tobit((v_A + 127))] = tobit(106)
I8[tobit((v_A + 112))] = tobit(120)
I8[tobit((v_A + 113))] = tobit(113)
I8[tobit((v_A + 114))] = tobit(114)
I8[tobit((v_A + 115))] = tobit(98)
I8[tobit((v_A + 116))] = tobit(100)
I8[tobit((v_A + 117))] = tobit(110)
I8[tobit((v_A + 118))] = tobit(109)
I8[tobit((v_A + 119))] = tobit(104)
v_r = bor(bor(bor(U8[13220], lshift(U8[13221], 8)), lshift(U8[13222], 16)), lshift(U8[13223], 24))
I32[arshift((v_A + 80), 2)] = tobit(bor(bor(bor(U8[13216], lshift(U8[13217], 8)), lshift(U8[13218], 16)), lshift(U8[13219], 24)))
I32[arshift((v_A + 84), 2)] = tobit(v_r)
v_n = 32
F.fM(tobit((v_A + 472)), 0, 32, tobit((v_A + 112)), tobit((v_A + 80)), tobit((v_A + 336)))
F.fvA(tobit((v_A + 472)))
do
do
do
v_r = U8[tobit((v_A + 367))]
local t396 = (((tobit(band((v_r - 1), 255)) % 4294967296) > 15) and 1 or 0)
if t396 == 0 then
v_e = 2
v_n = 31
t396 = (((tobit(v_r) % 4294967296) < 2) and 1 or 0)
end
if (not (t396 ~= 0)) then
do
v_n = 30
while true do
do
if (bor(((bor(0, v_r) ~= U8[tobit((tobit((v_A + 336)) + v_n))]) and 1 or 0), (((tobit(v_r) % 4294967296) <= (tobit(band(255, v_e)) % 4294967296)) and 1 or 0)) ~= 0) then
goto L350
end
v_e = tobit((v_e + 1))
v_n = tobit((v_n - 1))
end
::C351::
end
end
::B351::
end
end
end
::L350::
end
v_r = F.fI(tobit((v_n + 1)))
F.fOA(tobit((v_r + v_n)), 0, (((-1) ~= bor(0, v_n)) and 1 or 0))
I32[7804] = tobit(F.fQA(v_r, tobit((v_A + 336)), v_n))
end
end
end
do
v_e = I32[7805]
if (not (v_e ~= 0)) then
do
F.fMA(tobit((v_A + 472)))
I8[tobit((v_A + 72))] = tobit(102)
I8[tobit((v_A + 73))] = tobit(50)
I8[tobit((v_A + 74))] = tobit(117)
I8[tobit((v_A + 75))] = tobit(108)
I8[tobit((v_A + 76))] = tobit(114)
I8[tobit((v_A + 77))] = tobit(103)
I8[tobit((v_A + 78))] = tobit(101)
I8[tobit((v_A + 79))] = tobit(110)
I8[tobit((v_A + 64))] = tobit(107)
I8[tobit((v_A + 65))] = tobit(119)
I8[tobit((v_A + 66))] = tobit(98)
I8[tobit((v_A + 67))] = tobit(57)
I8[tobit((v_A + 68))] = tobit(115)
I8[tobit((v_A + 69))] = tobit(56)
I8[tobit((v_A + 70))] = tobit(118)
I8[tobit((v_A + 71))] = tobit(55)
F.fH(tobit((v_A + 472)), tobit((v_A - (-64))), 128)
I8[tobit((v_A + 56))] = tobit(116)
I8[tobit((v_A + 57))] = tobit(110)
I8[tobit((v_A + 58))] = tobit(105)
I8[tobit((v_A + 59))] = tobit(104)
I8[tobit((v_A + 60))] = tobit(117)
I8[tobit((v_A + 61))] = tobit(97)
I8[tobit((v_A + 62))] = tobit(103)
I8[tobit((v_A + 63))] = tobit(102)
I8[tobit((v_A + 48))] = tobit(99)
I8[tobit((v_A + 49))] = tobit(108)
I8[tobit((v_A + 50))] = tobit(49)
I8[tobit((v_A + 51))] = tobit(48)
I8[tobit((v_A + 52))] = tobit(101)
I8[tobit((v_A + 53))] = tobit(54)
I8[tobit((v_A + 54))] = tobit(115)
I8[tobit((v_A + 55))] = tobit(114)
I8[tobit((v_A + 40))] = tobit(15)
I8[tobit((v_A + 41))] = tobit(171)
I8[tobit((v_A + 42))] = tobit(232)
I8[tobit((v_A + 43))] = tobit(189)
I8[tobit((v_A + 44))] = tobit(174)
I8[tobit((v_A + 45))] = tobit(30)
I8[tobit((v_A + 46))] = tobit(115)
I8[tobit((v_A + 47))] = tobit(7)
I8[tobit((v_A + 32))] = tobit(13)
I8[tobit((v_A + 33))] = tobit(152)
I8[tobit((v_A + 34))] = tobit(55)
I8[tobit((v_A + 35))] = tobit(16)
I8[tobit((v_A + 36))] = tobit(1)
I8[tobit((v_A + 37))] = tobit(102)
I8[tobit((v_A + 38))] = tobit(234)
I8[tobit((v_A + 39))] = tobit(74)
v_n = 16
F.fM(tobit((v_A + 472)), 0, 16, tobit((v_A + 48)), tobit((v_A + 32)), tobit((v_A + 336)))
F.fvA(tobit((v_A + 472)))
do
do
do
v_r = U8[tobit((v_A + 351))]
local t397 = bor(bor((((tobit(v_r) % 4294967296) > 16) and 1 or 0), ((not (v_r ~= 0)) and 1 or 0)), ((16 == bor(0, v_r)) and 1 or 0))
if t397 == 0 then
v_e = 2
v_n = 15
t397 = (((tobit(v_r) % 4294967296) < 2) and 1 or 0)
end
if (not (t397 ~= 0)) then
do
v_n = 14
while true do
do
if (bor(((bor(0, v_r) ~= U8[tobit((tobit((v_A + 336)) + v_n))]) and 1 or 0), (((tobit(v_r) % 4294967296) <= (tobit(band(255, v_e)) % 4294967296)) and 1 or 0)) ~= 0) then
goto L352
end
v_n = tobit((v_n - 1))
v_e = tobit((v_e + 1))
end
::C353::
end
end
::B353::
end
end
end
::L352::
end
v_e = F.fI(tobit((v_n + 1)))
F.fOA(tobit((v_e + v_n)), 0, (((-1) ~= bor(0, v_n)) and 1 or 0))
I32[7805] = tobit(F.fQA(v_e, tobit((v_A + 336)), v_n))
end
end
end
I16[arshift((v_A + 28), 1)] = tobit(105)
I32[arshift((v_A + 16), 2)] = tobit(v_e)
I32[arshift((v_A + 24), 2)] = tobit(1768515945)
I32[arshift(v_A, 2)] = tobit(1071)
I32[arshift((v_A + 4), 2)] = tobit(1024)
v_n = 0
I32[arshift((v_A + 8), 2)] = tobit(I32[7799])
I32[arshift((v_A + 12), 2)] = tobit(I32[7800])
do
do
do
if (not (bor(0, imp_b(13820, tobit((v_A + 24)), bor(0, v_A))) ~= 0)) then
do
v_a = bor(0, imp_c(I32[7801]))
v_e = U8[bor(0, v_a)]
v_r = I32[7802]
do
do
do
local t398 = (not (v_e ~= 0))
v_u = U8[bor(0, v_r)]
if (not (bor((t398 and 1 or 0), ((bor(0, v_u) ~= bor(0, v_e)) and 1 or 0)) ~= 0)) then
do
while true do
do
v_u = U8[tobit((v_r + 1))]
v_e = U8[tobit((v_a + 1))]
if (not (v_e ~= 0)) then
goto L355
end
v_r = tobit((v_r + 1))
v_a = tobit((v_a + 1))
if (bor(0, v_e) ~= bor(0, v_u)) then
goto B356
end
end
::C356::
end
end
::B356::
end
end
end
::L355::
end
do
local t399 = (not (tobit((v_e - v_u)) ~= 0))
if t399 then
v_u = bor(0, imp_c(I32[7804]))
v_e = F.fW(I32[7803])
t399 = (v_e ~= 0)
end
if t399 then
do
if (not (v_u ~= 0)) then
do
while true do
do
if (not (F.fW(0) ~= 0)) then
goto L354
end
end
::C357::
end
end
::B357::
end
do
do
while true do
do
do
do
v_r = F.flA(v_u)
local t400 = (tobit(v_r) % 4294967296)
v_n = F.flA(v_e)
if (not (t400 < (tobit(v_n) % 4294967296))) then
v_a = tobit((tobit((v_r + v_u)) - v_n))
v_r = 0
if (v_n ~= 0) then
do
v_r = U8[bor(0, v_a)]
if (v_r ~= 0) then
do
while true do
do
v_c = U8[bor(0, v_e)]
if (not (v_c ~= 0)) then
goto L359
end
v_n = tobit((v_n - 1))
if (not (v_n ~= 0)) then
goto L359
end
if (bor(0, v_r) ~= bor(0, v_c)) then
goto L359
end
v_e = tobit((v_e + 1))
v_r = U8[tobit((v_a + 1))]
v_a = tobit((v_a + 1))
if (not (v_r ~= 0)) then
goto B360
end
end
::C360::
end
end
::B360::
end
v_r = 0
end
::L359::
v_r = tobit((v_r - U8[bor(0, v_e)]))
end
if (not (v_r ~= 0)) then
v_n = 1
goto L354
end
end
end
v_n = 0
v_e = F.fW(0)
if (not (v_e ~= 0)) then
goto B358
end
end
end
::C358::
end
end
::B358::
end
end
end
end
end
end
end
end
::L354::
end
B = tobit((v_A + 752))
do return bor(0, v_n) end
end
UA[57] = function(v_A, v_r, v_n, v_e)
local v_o = 0
v_A = tobit(v_A)
v_r = tobit(v_r)
v_n = tobit(v_n)
v_e = tobit(v_e)
v_o = tobit((B - 32))
B = v_o
v_A = bor(0, UA[bxor(31180, I32[7795])](v_A, v_r, v_n, v_e, tobit((v_o + 28)), tobit((v_o + 24))))
I8[tobit((v_o + 20))] = tobit(105)
I8[tobit((v_o + 21))] = tobit(105)
I8[tobit((v_o + 22))] = tobit(105)
I8[tobit((v_o + 23))] = tobit(0)
I32[arshift(v_o, 2)] = tobit(v_A)
I32[arshift((v_o + 4), 2)] = tobit(I32[arshift((v_o + 28), 2)])
I32[arshift((v_o + 8), 2)] = tobit(I32[arshift((v_o + 24), 2)])
imp_b(21795, tobit((v_o + 20)), bor(0, v_o))
if not (v_A ~= 0) then
F.fR(I32[arshift((v_o + 28), 2)])
end
B = tobit((v_o + 32))
end

local DATA = {
    { 1024, "Ym9keQAtKyAgIDBYMHgALTBYKzBYIDBYLTB4KzB4IDB4AF8weCV4AHdpbmRvdwBkb2N1bWVudABmdW5jdGlvbgBuYW4Ac2V0SW50ZXJ2YWwAaW5mAG5vbmUAJWQATkFOAElORgAuACwAKG51bGwpABEACgAREREAAAAABQAAAAAAAAkAAAAACwAAAAAAAAAAEQAPChEREQMKBwABAAkLCwAACQYLAAALAAYRAAAAERER" },
    { 1217, "CwAAAAAAAAAAEQAKChEREQAKAAACAAkLAAAACQALAAAL" },
    { 1275, "DA==" },
    { 1287, "DAAAAAAMAAAAAAkMAAAAAAAMAAAM" },
    { 1333, "Dg==" },
    { 1345, "DQAAAAQNAAAAAAkOAAAAAAAOAAAO" },
    { 1391, "EA==" },
    { 1403, "DwAAAAAPAAAAAAkQAAAAAAAQAAAQAAASAAAAEhIS" },
    { 1458, "EgAAABISEgAAAAAAAAk=" },
    { 1507, "Cw==" },
    { 1519, "CgAAAAAKAAAAAAkLAAAAAAALAAAL" },
    { 1565, "DA==" },
    { 1577, "DAAAAAAMAAAAAAkMAAAAAAAMAAAMAAAwMTIzNDU2Nzg5QUJDREVG" },
    { 1652, "Aw==" },
    { 1691, "//////8=" },
    { 1764, "AQAAAAABAAABAQAAAAABAAEAAQAAAQEAAQEBAAAAAAEBAAABAAEAAQEBAAEAAAEBAQABAQABAQEBAQEBAAAAAAAAAAEAAAEAAAABAQABAAAAAQABAAEBAAABAQEBAAAAAQAAAQEAAQABAAEBAQEAAAEBAAEBAQEAAQEBAUAQABAAEAAAAAAEAEAQBBAAAAAQQBAAEEAAAAAAAAAQQAAEAAAABBBAEAQQABAEAAAQBBBAEAQAABAAAEAAAAAAAAQQQAAAEAAQABBAEAAAABAEAEAABABAAAQQABAEEEAQ" },
    { 1996, "QAAEEEAAABAAEAAQQBAEAAAABABAEAQAAAAEAAAQBBAAEAAAQAAAAEAABBAAEAAAQBAEAAAQABBAAAAAQAAAEAAABBBAAAQQAAAAEAAABABAEAAQAAAAAEAQBBBAAAQAQAAAEAAABBAAEAAQQBAAEAAAAABAEAQQABAEAAAQBABAEAAAQBAAAEAABAAAAAAQABAEEBAAACAAAEAgAEAAABBAQCAAAEAgEAAAABBAQCAAAEAAAEAAIBBAQAAAAEAAEAAAIBAAQAAAQAAgAAAAIBBAAAAAAAAAEABAABBAACAAQAAAAEBAABBAACAQAAAAEABAIBAAQCAAAAAAEEBAAABAQCAQQAAAAEBAAABAQCAAAAAgAEAAIBAAAAAQAEAgAEBAABBAQCAAAEAAEEAAABAAACAAAEAAAEAAIAAAACAQQAAAEAAAIBBAQCAAQEAAAABAIBBAQAAAQEAgAAAAABAAQCAQAAAAAEAAAAAAQCAQQEAAAEAAABAAQAAQQAAgAAAAAABAQCAAAAAgEABAABBAACABIIAAgSAAAIEgAACAAAAAgCCAAIEAgAABAIAAASAAAAAAAAAAIIAAACCAAIEggACBAAAAAAAAAIAAgAABAIAAAQAAAAAgAAAAAIAAASCAAIAAAAAAAIAAASAAAIAgAACBAIAAAQAAAIAgAACAAIAAACAAAIAggACBIIAAgQAAAIAAgAABAIAAACCAAIEggACB" },
    { 2557, "IIAAgCAAAIAAgACBAIAAAQAAAAEggACBIAAAgSAAAIAAAACBIIAAgQAAAAEAAAAAIAAAAQCAAAEgAACAIIAAgQCAAAEgAACAIAAAAACAAAEggACAAAAAAACAAAAgAACAIIAAIIAQgACAAIAAgAAAIIAQAAAAEAAgAAAAIAAQgCCAAIAgAACAIIAQgACAEIAAAACAAIAAgAAAEAAgAAAAIAAQgACAEAAgABAAIIAAgAAAAAAAAACAAIAAACCAEAAAABCAIAAQACAAAIAAAAAAAIAQACCAAAAAgBCAAAAQgCCAAAAAAAAAIIAQACAAEIAAABAAIIAAgAAAEIAAgBCAAIAAAAAAEIAAgACAIAAAACCAEIAggBAAIAAAAACAAAAAAACAIIAAAACAEIAAABAAIAAAgCAAEAAggACAIAAAgCAAEAAAgBAAAAAAAACAAIAggAAAAAAAgCAAEIAggBCAAIAQAAAAIAACACAEAggABAAAAAAACAAAAggABAIIIAAACCAEAgggBAAAIAAAAAAAAgAABAIAAAAAAAAEAgAgBAIIAAAACAAEAgggAAIAIAAACAAEAgAABAAAIAQACCAEAgAgAAAAIAQACAAAAggAAAIIIAQACCAAAgAAAAAAAAQACCAAAAAABAAIIAAAACAAAggABAIIAAQCACAEAgAgBAIAAAACACAAAAAABAAIAAQAACAAAAggBAIIAAACCCAAAAggBAIIAAACAAAEAgggBAAAIAQACCAAAAAAAAIAAAACCCAEAAAAAAIIIAAAACAEAAgAAAIAAAQACAAEAAgAAAIAIAAAAQAAAAEIAgAACAIAAQBCAAAIAAABAAAAAABAAAAIAgABCEAAAAgAAAEAAgABCEAAAQBCAAAIQgABCAAAAABAAAAAAgAACEAAAAhAAAAAAAABAEAAAQhCAAEIQgABAAIAAAhCAAEAQAAAAAAAAABCAAEIAgAAAAIAAABCAAEIAAAACAAAAQBCAAEAAAAAAAIAAABAAAAIAgABAEIAAQhAAAEAAgAAAEAAAAhCAAEIAgABCEAAAQAAAAAAAgAACEIAAQhCAAEIAAAAAEIAAQhCAAAIAgAAAAAAAAhAAAAAQgABCAAAAQACAAEAQAAACAAAAAAAAAAIQAABCAIAAQBACAIAAAACAggAAAAACAACCAACAAgAAAAACAICAAACAAgIAAIACAAACAgAAAgAAAIACAICCAgAAgAAAAIICAIAAAAAAAgIAAAAAAICCAACAAAAAgIAAAACCAgAAggIAgIACAIACAACAgAAAAIACAIACAgAAAAIAgIIAAIAAAAAAAgAAgIIAAAACAgAAgAIAgAAAAACAAACAggAAgAIAAAAAAACAAAIAAIACAICCAACAAgIAAAIAAIAAAAAAAAIAAIICAIACAAAAgAAAAAICAICCAgAAAAIAgIAAAICAAgAAAgAAAIICAIACAgCAAAAAAIICAICAAgAAAAIAAIIAAICAAAEAQEAAAAAAAABAAQEAQEEAAEBBAQBAAQAAAAAAAEAAAQAAAAEAQEEBAEBAAQAAAQEAAEEAAEBAAAAAQQAAAAEBAAAAAQAAQAEAAEABAEAAAQBAAAAAQEAAAEBBAQAAQQAAQAEAAABBAAAAQQAAQAAAAAABAQAAAQEAQAAAAABAAABAAQEAQEEAAAAAAABAQAEAQEAAAABAAAAAQAEAAAEAAEBAAABAAAEAQAEAAABAAQAAAQAAAAEBAABBAQBAAQEAQEEAAEAAAABAQQEAAEEAAABBAQAAAQEAQAABAEBBAQAAAAEAAEABAABAAAAAAQAAQAABAEAAAAAAAQAAQGmCzHRrLXfmNty/S+33xrQ7a/huJZ+JmpFkHy6mX8s8UeZoST3bJGz4vIBCBb8joXYIGljaU5XcaP+WKR+PZP0j3SVDVi2jnJYzYtx7koVgh2kVHu1WVrCOdUwnBNg8iojsNHF8IVgKBh5QcrvONu4sNx5jg4YOmCLDp5sPooesMF3FdcnSzG92i+veGBcYFXzJVXmlKtVqmKYSFdAFOhjajnKVbYQqyo0XMy0zuhBEa+GVKGT6XJ8ERTusyq8b2Ndxakr9jEYdBY+XM4ek4ebM7rWr1zPJGyBUzJ6d4aVKJhIjzuvuUtrG+i/xJMhKGbMCdhhkakh+2CsfEgygOxdXV2E77F1hekCIybciBtl64E+iSPFrJbT829tDzlC9IOCRAsuBCCEpErwyGlemx+eQmjGIZps6fZhnAxn8IjTq9KgUWpoL1TYKKcPlqMzUatsC+9u5Dt6E1DwO7qYKvt+HWXxoXYBrzk+WcpmiA5DghmG7oy0n29Fw6WEfb5eizvYdW/gcyDBhZ9EGkCmasFWYqrTTgZ3PzZy3/4bPQKbQiTX0DdIEgrQ0+oP25vA8UnJclMHexuZgNh51CX33uj2GlD+4ztMeba94GyXugbABLZPqcHEYJ9Awp5cXmMkahmvb/totVNsPuuyORNv7FI7H1H8bSyVMJtERYHMCb1erwTQ4779SjPeBygPZrNLLhlXqMvAD3TIRTlfC9Lb+9O5vcB5VQoyYBrGAKHWeXIsQP4ln2fMox/7+OmljvgiMtvfFnU8FWth/cgeUC+rUgWt+rU9MmCHI/1IezFTgt8APrtXXJ6gjG/KLlaHGttpF9/2qELVw/9+KMYyZ6xzVU+MsCdbachYyrtdo//hoBHwuJg9+hC4gyH9bLX8SlvT0S155FOaZUX4trxJjtKQl/tL2vLd4TN+y6RBE/ti6MbkztrKIO8BTHc2/p5+0LQf8StN2tuVmJGQrnGOreqg1ZNr0NGO0OAlx68vWzyOt5R1jvvi9o9kKxLyEriIiBzwDZCgXq1PHMOPaJHxz9GtwaizGCIvL3cXDr7+LXXqoR8Ciw/MoOXodG+11vOsGJniic7gT6i0t+AT/YE7xHzZqK3SZqJfFgV3lYAUc8yTdxQaIWUgreaG+rV39UJUx881nfsMr83roIk+e9MbQdZJfh6uLQ4lAF6zcSC7AGgir+C4V5s2ZCQeuQnwHZFjVaqm31mJQ8F4f1Na2aJbfSDFueUCdgMmg6nPlWJoGcgRQUpzTsotR7NKqRR7UgBRGxUpU5o/Vw/W5MabvHakYCsAdOaBtW+6CB/pG1dr7JbyFdkNKiFlY7a2+bnnLgU0/2RWhcVdLbBToY+fqZlHughqB4Vu6XB6S0Qps7UuCXXbIyYZxLCmbq1936dJuGDunGay7Y9xjKrs/xeaaWxSZFbhnrHCpQI2GSlMCXVAE1mgPjoY5JqYVD9lnUJb1uSPa9Y/95kHnNKh9TDo7+Y4LU3BXSXwhiDdTCbrcITG6YJjXsweAj9raAnJ77o+FBiXPKFwamuENX9ohuKgUgVTnLc3B1CqHIQHPlyu3n/sRH2OuPIWVzfaOrANDFDwBB8c8P+zAAIa9QyusnS1PFh6gyW9IQnc+ROR0fYvqXxzRzKUAUf1IoHl5Trc2sI3NHa1yKfd85pGYUSpDgPQDz7HyOxBHnWkmc044i8O6juhu4AyMbM+GDiLVE4IuW1PAw1Cb78ECvaQErgseXyXJHKweVavia+8H3ea3hAIk9kSrouzLj/P3B9yElUkcWsu5t0aUIfNhJ8YR1h6F9oIdLyan7yMfUvpOux67PodhdtmQwlj0sNkxEcYHO8I2RUyNztD3Ra6wiRDTaESUcRlKgIAlFDd5DoTnvjfcVVOMRDWd6yBmxkRX/FWNQRrx6PXOxgRPAmlJFnt5o/y+vvxlyy/up5uPBUecEXjhrFv6eoKXg6Gsyo+WhznH3f6Bj1OudxlKQ8d55nWiT6AJchmUnjJTC5qsxCcug4Vxnjq4pRTPPyl9C0KHqdO9/I9Kx02DyY5GWB5whkIpyNSthIT927+retmH8PqlUW844PIe6bRN3+xKP+MAe/dMsOlWmy+hSFYZQKYq2gPpc7uO5Uv26197yqEL25bKLYhFXBhByl1R93sEBWfYTCozBOWvWHrHv40A89jA6qQXHO1OaJwTAuentUU3qrLvIbM7qcsYmCrXKucboTzsq8ei2TK8L0ZuWkjoFC7WmUyWmhAs7QqPNXpnjH3uCHAGQtUm5mgX4d+mfeVqH09YpqIN/h3LeOXX5PtEYESaBYpiDUO1h/mx6Hf3paZulh4pYT1V2NyIhv/w4OblkbCGusKs81UMC5T5EjZjygxvG3v8utY6v/GNGHtKP5zPHzu2RRKXeO3ZOgUXRBC4BM+ILbi7kXqq6qjFU9s29BPy/pC9ELHtbtq7x07T2UFIc1Bnnke2MdNhYZqR0vkUGKBPfKhYs9GJo1boIOI/KO2x8HDJBV/knTLaQuKhEeFspJWAL9bCZ1IGa10sWIUAA6CIyqNQljq9VUMPvStHWFwPyOS8HIzQX6TjfHsX9bbOyJsWTfefGB07sun8oVAbjJ3zoSAB6aeUPgZVdjv6DWX2WGqp2mpwgYMxfyrBFrcyguALnpEnoQ0RcMFZ9X9yZ4eDtPbc9vNiFUQedpfZ0BDZ+NlNMTF2Dg+cZ74KD0g/23x5yE+FUo9sI8rn+Pm962D22haPen3QIGUHCZM9jQpaZT3IBVB99QCdi5r9LxoAKLUcSQI1Gr0IDO31LdDr2EAUC72OR5GRSSXdE8hFECIi78d/JVNr5G1ltPd9HBFL6Bm7Am8v4WXvQPQbax/BIXLMbMn65ZBOf1V5kcl2poKyqsleFAo9CkEU9qGLAr7bbbpYhTcaABpSNekwA5o7o2hJ6L+P0+MrYfoBuCMtbbW9Hp8Hs6q7F8305mjeM5CKmtANZ7+ILmF89mr1znui04SO/f6yR1WGG1LMWajJrKX4+p0+m46MkNb3ffnQWj7IHjKTvUK+5ez/tisVkBFJ5VIujo6U1WHjYMgt6lr/kuVltC8Z6hVWJoVoWMpqcwz2+GZVkoqpvklMT8cfvRefDEpkALo+P1wLycEXBW7gOMsKAVIFcGVIm3G5D8TwUjchg/H7sn5Bw8fBEGkeUdAF26IXetRXzLRwJvVj8G88mQ1EUE0eHslYJwqYKPo+N8bbGMfwrQSDp4y4QLRT2avFYHRyuCVI2vhkj4zYgskOyK5vu4OorKFmQ265owMct4o96ItRXgS0P2Ut5ViCH1k8PXM52+jSVT6SH2HJ/2dwx6NPvNBY0cKdP8umatubzo3/fj0YNwSqPjd66FM4RuZDWtu2xBVe8Y3LGdtO9RlJwTo0NzHDSnxo/8AzJIPObUL7Q9p+597Zpx9284Lz5Ggo14V2YgvE7skrVtRv3mUe+vWO3azLjk3eVkRzJfiJoAtMS70p61CaDsrasbMTHUSHPEueDdCEmrnUZK35ruhBlBj+0sYEGsa+u3KEdi9JT3Jw+HiWRZCRIYTEgpu7AzZKuqr1U5nr2RfqIbaiOm/vv7D5GRXgLydhsD38Ph7eGBNYANgRoP90bAfOPYErkV3zPw21zNrQoNxqx7wh0GAsF9eADy+V6B3JK7ovZlCRlVhLli/j/RYTqL93fI473T0wr2Jh8P5ZlN0jrPIVfJ1tLnZ/EZhJut6hN8di3kOaoTilV+RjlluRnBXtCCRVdWMTN4CyeGsC7nQBYK7SGKoEZ6pdHW2GX+3Cdyp4KEJLWYzRjLEAh9a6Iy+8AkloJlKEP5uHR09uRrfpKULD/KGoWnxaCiD2rfc/gY5V5vO4qFSf81PAV4RUPqDBqfEtQKgJ9DmDSeM+JpBhj93Bkxgw7UGqGEoehfw4Ib1wKpYYABifdww157mEWPqOCOU3cJTNBbCwlbuy7vetryQoX3863YdWc4J5AVviAF8Sz0KcjkkfJJ8X3LjhrmdTXK0W8Ea/Lie03hVVO21pfwI03w92MQPrU1e71Ae+OZhsdkUhaI8E1Fs58fVb8RO4VbOvyo2N8jG3TQymtcSgmOSjvoOZ+AAYEA3zjk6z/X60zd3wqsbLcVanmewXEI3o09AJ4LTvpu8mZ2OEdUVcw+/fhwt1nvEAMdrG4y3RZChIb6xbrK0bjZqL6tIV3lulLzSdqPGyMJJZe74D1N93o1GHQpz1cZN0EzbuzkpUEa6qegmlawE416+8NX6oZpRLWrijO9jIu6GmrjCicD2LiRDqgMepaTQ8py6YcCDTWrpm1AV5Y/WW2S6+aImKOE6OqeGlalL6WJV79PvL8fa91L3aW8EP1kK+ncVqeSAAYawh63mCZuT5T47Wv2Q6ZfXNJ7Zt/AsUYsrAjqs1ZZ9pn0B1j7P0SgtfXzPJZ8fm7jyrXK01lpM9Yhacawp4OalGeD9rLBHm/qT7Y3E0+jMVzsoKWbV+CguE3mRAV94VWB17UQOlveMXtPj1G0FFbpt9IglYaEDvfBkBRWe68OiV5A87BonlyoHOqmbbT8b9SFjHvtmnPUZ89wmKNkzdfX9VbGCNFYDuzy6ihF3USj42QrCZ1HMq1+SrcxRF+hNjtwwOGJYnTeR+SCTwpB66s57PvtkziFRMr5Pd37jtqhGPSnDaVPeSIDmE2QQCK6iJLJt3f0thWlmIQcJCkaas93ARWTP3mxYrsggHN33vltAjVgbfwHSzLvjtGt+aqLdRf9ZOkQKNT7VzbS8qM7qcruEZPquEmaNR288v2Pkm9KeXS9UG3fCrnBjTvaNDQ50VxNb53EWcvhdfVOvCMtAQMzitE5qRtI0hK8VASgEsOEdOpiVtJ+4Bkigbs6COz9vgqsgNUsdGgH4J3InsWAVYdw/k+creTq7vSVFNOE5iKBLec5Rt8kyL8m6H6B+yBzg9tHHvMMRAc/HquihSYeQGpq9T9TL3trQONoK1SrDOQNnNpHGfDH5jU8rseC3WZ73Orv1Q/8Z1fKcRdknLCKXvyr85hVx/JEPJRWUm2GT5frrnLbOWWSowtGouhJeB8G2DGoF42VQ0hBCpAPLDm7s4DvbmBa+oJhMZOl4MjKVH5/fktPgKzSg0x7ycYlBdAobjDSjSyBxvsXYMnbDjZ813y4vmZtHbwvmHfHjD1TaTOWR2Noez3lizm9+Ps1msRgWBR0s/cXSj4SZIvv2V/Mj9SN2MqYxNaiTAs3MVmKB8Ky163ValzYWbsxz0oiSYpbe0Em5gRuQUEwUVsZxvcfG5goUejIG0OFFmnvyw/1TqskAD6hi4r8lu/bSvTUFaRJxIgIEsnzPy7YrnHbNwD4RU9PjQBZgvas48K1HJZwgOLp2zkb3xaGvd2BgdSBO/suF2I3oirD5qnp+qvlMXMJIGYyK+wLkasMB+eHr1mn41JCg3lymLSUJP5/mCMIyYU63W+J3zuPfj1fmcsM6iGo/JNMIo4UuihkTRHNwAyI4CaTQMZ8pmPouCIlsTuzmIShFdxPQOM9mVL5sDOk0tymswN1QfMm11YQ/FwlHtdnVFpIb+3mJ" },
    { 8113, "AQIDCAkKCyYnJCUXFBUWG///Gv//////////////////////////BAUGBwwNDg8QERIT/xgZ/x8cHR7//////////////////////////wABAgM9Pj88/////xsYGRojICEi/////wgJCgsQERIT/////yckJSb/////DA0ODzo7ODkfHB0e/////wQFBgdBQkNAFBUWF/////8rKCkqFRYXFP////8SExARCwgJCg8MDQ4ZGhsYHR4fHBITEBH//////////wAAAAAAAAAAcIIs7LMnwOXkhVc16gyuQSPva5NFGaUh7Q5PTh1lkr2GuK+PfOsfzj4w3F9exQsapuE5ytVHXT3ZAVrWUVZsTYsNmmb7zLAtdBIrIPCxhJnfTMvCNH52BW23qTHRFwTXFFg6Yd4bERwyD5wWUxjyIv5Ez7LDtXqRJAjoqGD8aVCq0KB9oYlil1RbHpXg/2TSEMQASKP3dduKA+baCT/dlIdcgwLNSpAzc2f2851/v+JSm9gmyDfGO4GWb0sTvmMu6XmnjJ9uvI4p9fm2L/20WXiYBmrnRnG61CWrQoiijfpyB7lV+O6sCjZJKmg8OPGkQCjTe7vJQ8EV4630d8eAnuAFWNlnToHLyQuuatUYXYJG39YnijJLQtscnpw6yiV7DXFfH/jXPp18YLm+vIsWNE3DcpWrjrp6swK0raKs2JoXGjXM95lhWugkVkDhYwkzv5iXhWj87Arab1Nioy4IryiwdMK9NiI4ZB45LKYw5UT9iJ9lh2v0I0gQ0VHA+dKgVaFB+kMTxC+otjwrwf/IpSCJAJBH7+q3FQbNtRJ+uykPuAcEm5QhZubO7ec7/n/FpDexTJFujXYDLd6WJn3GXNPyTxk/3HkdUuvzbV77abLwMQzUz4zidalKV4QRRRv15A5zqvHdWRRsklTQeHDjSYBQp/Z3k4aDKsdb6e6PAT04QRZ22ZNg8nLCq5p1Blegkfe1yaKM0pD2B6cnjrJJ3kNc18c+9Y9nHxhury/ihQ1T8Jxl6qOunuyALWuoKzamxYZNM/1mWJY6CZUQeNhCzO8m5WEaPzuCttvUmOiLAusKLB2wb42IDhmHTgupDHkRfyLnWeHaPcgSBHRUMH60KFVoUL7QxDHLKq0PynD/MmkIYgAk0fu67UWBc22En+5Kwy7BAeYlSJm5s3v5zr/fcSnNbBNkm2OdwEu3pYlfsRf0vNNGzzdeR5T6/FuX/lqsPEwDNfMjuF1qktUhRFHGfTmD3Kp8d1YFG6QVNB4c+FIgFOm93eSh4Irx1nq740BPcCyzwORX6q4ja0Wl7U8dkoavfB8+3F4LpjnVXdlaUWyLmvuwdCvwhN/LNHZtqdEEFDreETKcU/L+z8N6JOhgaaqgoWJUHuBkEACjdYrmCd2Hg82Qc/adv1LYyMaBbxNj6aefvCn5L7R4Budx1KuIjXK5+Kw2KjzxQNO7QxWtd4CC7CflhTUMQe+TGSEOTmW9uI/rzjBfxRrhykc9AdZWTQ1mzC0SILGZTMJ+BbcxF9dYYRscDxYYIkSytZEIqPxQ0H2Jl1uV/9LESPfbA9o/lFwCSjNn83/imyY3O5ZLvi55jG6O9bb9WZhqRrolQqL6B1XuCkloOKQoe8nB4/THngIAAAABAAAAgAAAAG8E" },
    { 9368, "EAAAAOArAAADAAAAAQAAAMAAAABvBA==" },
    { 9400, "EAAAAOArAAAEAAAAAQAAAAABAABvBA==" },
    { 9432, "EAAAAOArAAAFAAAAAgAAAIAAAABvBAAAEAAAAAAAAAAQAAAA4CsAAAYAAAACAAAAwAAAAG8EAAAQAAAAAAAAABAAAADgKwAABwAAAAIAAAAAAQAAbwQAABAAAAAAAAAAEAAAAOArAAAIAAAAAwAAAIAAAABvBAAAEAAAAAAAAAAQAAAA4CsAAAkAAAADAAAAwAAAAG8EAAAQAAAAAAAAABAAAADgKwAACgAAAAMAAAAAAQAAbwQAABAAAAAAAAAAEAAAAOArAAALAAAABQAAAIAAAABvBAAAEAAAAAAAAAAQAAAA4CsAAAwAAAAFAAAAwAAAAG8EAAAQAAAAAAAAABAAAADgKwAADQAAAAUAAAAAAQAAbwQAABAAAAAAAAAAEAAAAOArAAAOAAAABgAAAIAAAABvBAAADAAAAAEAAAAQAAAACCwAAA8AAAAGAAAAwAAAAG8EAAAMAAAAAQAAABAAAAAILAAAEAAAAAYAAAAAAQAAbwQAAAwAAAABAAAAEAAAAAgsAAArAAAACAAAAIAAAABvBAAADAAAAAEAAAAQAAAAMCwAACwAAAAIAAAAwAAAAG8EAAAMAAAAAQAAABAAAAAwLAAALQAAAAgAAAAAAQAAbwQAAAwAAAABAAAAEAAAADAsAAAqAAAABwAAAIAAAABvBA==" },
    { 9944, "AQAAAFgsAAAmAAAAAQAAAIAAAABvBAAACAAAAAIAAAAIAAAAgCwAACcAAAACAAAAgAAAAG8EAAAIAAAAAgAAAAgAAACALAAAKAAAAAMAAACAAAAAbwQAAAgAAAACAAAACAAAAIAsAAApAAAABQAAAIAAAABvBAAACAAAAAIAAAAIAAAAgCwAABEAAAABAAAAgAAAAG8EAAAQAAAAAAAAABAAAACoLAAAEgAAAAEAAADAAAAAbwQAABAAAAAAAAAAEAAAAKgsAAATAAAAAQAAAAABAABvBAAAEAAAAAAAAAAQAAAAqCwAABQAAAACAAAAgAAAAG8EAAAQAAAAAAAAABAAAACoLAAAFQAAAAIAAADAAAAAbwQAABAAAAAAAAAAEAAAAKgsAAAWAAAAAgAAAAABAABvBAAAEAAAAAAAAAAQAAAAqCwAABcAAAADAAAAgAAAAG8EAAAQAAAAAAAAABAAAACoLAAAGAAAAAMAAADAAAAAbwQAABAAAAAAAAAAEAAAAKgsAAAZAAAAAwAAAAABAABvBAAAEAAAAAAAAAAQAAAAqCwAABoAAAAFAAAAgAAAAG8EAAAQAAAAAAAAABAAAACoLAAAGwAAAAUAAADAAAAAbwQAABAAAAAAAAAAEAAAAKgsAAAcAAAABQAAAAABAABvBAAAEAAAAAAAAAAQAAAAqCwAAB0AAAAGAAAAgAAAAG8EAAAMAAAAAQAAABAAAADQLAAAHgAAAAYAAADAAAAAbwQAAAwAAAABAAAAEAAAANAsAAAfAAAABgAAAAABAABvBAAADAAAAAEAAAAQAAAA0CwAAC4AAAAIAAAAgAAAAG8EAAAMAAAAAQAAABAAAAD4LAAALwAAAAgAAADAAAAAbwQAAAwAAAABAAAAEAAAAPgsAAAwAAAACAAAAAABAABvBAAADAAAAAEAAAAQAAAA+CwAACAAAAABAAAAQAAAAG8EAAAIAAAAAAAAAAgAAAAgLQAAIgAAAAEAAACAAAAAbwQAAAgAAAAAAAAACAAAAEgtAAAkAAAAAQAAAMAAAABvBAAACAAAAAAAAAAIAAAAcC0AACEAAAACAAAAQAAAAG8EAAAIAAAAAAAAAAgAAAAgLQAAIwAAAAIAAACAAAAAbwQAAAgAAAAAAAAACAAAAEgtAAAlAAAAAgAAAMAAAABvBAAACAAAAAAAAAAIAAAAcC0AAAIAAACAJAAAAwAAAKAkAAAEAAAAwCQAAAUAAADgJAAABgAAAAAlAAAHAAAAICUAAAgAAABAJQAACQAAAGAlAAAKAAAAgCUAAAsAAACgJQAADAAAAMAlAAANAAAA4CUAAA4AAAAAJgAADwAAACAmAAAQAAAAQCYAACsAAABgJgAALAAAAIAmAAAtAAAAoCYAACoAAADAJgAAJgAAAOAmAAAnAAAAACcAACgAAAAgJwAAKQAAAEAnAAARAAAAYCcAABIAAACAJwAAEwAAAKAnAAAUAAAAwCcAABUAAADgJwAAFgAAAAAoAAAXAAAAICgAABgAAABAKAAAGQAAAGAoAAAaAAAAgCgAABsAAACgKAAAHAAAAMAoAAAdAAAA4CgAAB4AAAAAKQAAHwAAACApAAAuAAAAQCkAAC8AAABgKQAAMAAAAIApAAAgAAAAoCkAACIAAADAKQAAJAAAAOApAAAhAAAAACoAACMAAAAgKgAAJQAAAEAq" },
    { 11232, "AgAAAAQAAAAFAAAABgAAAAcAAAAAAAAACAAAAAkAAAAKAAAACwAAAAI=" },
    { 11296, "DAAAAAwAAAANAAAADgAAAAI=" },
    { 11336, "DwAAAA8AAAAQAAAAEQAAAAc=" },
    { 11372, "EgAAABMAAAATAAAAFAAAABUAAAAGAAAAFgAAABcAAAAYAAAAGQAAAAAAAAAaAAAAGgAAABsAAAAcAAAABQAAAB0AAAAeAAAAHwAAACAAAAAAAAAAIQAAACIAAAAjAAAAJAAAAAU=" },
    { 11496, "JQAAACUAAAANAAAADgAAAAU=" },
    { 11536, "JgAAACYAAAAQAAAAEQAAAAMAAAAnAAAAKA==" },
    { 11576, "KQAAACoAAAArAAAALAAAAAMAAAAtAAAALg==" },
    { 11616, "LwAAADAAAAAxAAAAMgAAAAQAAAAtAAAALg==" },
    { 11656, "MwAAADQAAAAxAAAAMg==" },
    { 11688, "IBwAAAAAAABAOAAAAAAAAGAkAAAAAAAAgHAAAAAAAACgbAAAAAAAAMBIAAAAAAAA4FQAAAAAAAAA4QAAAAAAACD9AAAAAAAAQNkAAAAAAABgxQAAAAAAAICRAAAAAAAAoI0AAAAAAADAqQAAAAAAAOC1AAAAAAAAmC+KQpFEN3HP+8C1pdu16VvCVjnxEfFZpII/ktVeHKuYqgfYAVuDEr6FMSTDfQxVdF2+cv6x3oCnBtybdPGbwcFpm+SGR77vxp3BD8yhDCRvLOktqoR0StypsFzaiPl2UlE+mG3GMajIJwOwx39Zv/ML4MZHkafVUWPKBmcpKRSFCrcnOCEbLvxtLE0TDThTVHMKZbsKanYuycKBhSxykqHov6JLZhqocItLwqNRbMcZ6JLRJAaZ1oU1DvRwoGoQFsGkGQhsNx5Md0gntbywNLMMHDlKqthOT8qcW/NvLmjugo90b2OleBR4yIQIAseM+v++kOtsUKT3o/m+8nhxxgAAAAADg2vy93A74fTzUBMfl5rHHBTxNejnoSbrZMrUz1jZiszbsng4KOJrO6uJmdDPQ03TTCi/J794rCQ8E15vx14QbEQ14pi3ZfGbNA4DcFDE13PTryWHIP82hKOUxKCfh5qjHOxoV++8e1Rs14m/CB1dvIt2r0h4JrxL+01O3o69IN0N1tIp/obBKn3tM8EZJ+fCmkwVNmkcBjXqd/QR1mSqElUPWOamX0vlJTS5DkH+bQ3ClZ/5McWM+rKufrFJ4zCyyojCRjnY0UW6syOu3nn3rV0SBVmuQhZaLSnkfhE6un2SUUiJYQFbiuJqqWGGoH1iBcuPlvabnJV18G68HXtBv54Qs0ttQKBI7itSo4rhhqAJinRU+tpnV3mxlXNFostwxsk5hDWZKoe28ths0jgMb1FT/puiA+2YIWgf09olUdBZTqMkqh6wJyl1QsxNv5bPztRkOz2Edzi+74UcgvzbHwGXKevyxzrocazIAxVmHACWDe70ZV399+Y2D2KTxmFhEK2TleP9gJZglnJ9BFymfoc3VIp0Z0eJ9wy1rcsf665IdBlauyQKWThP+LJchSyx3+7eRSy+zUav1T8NVJhxDtfzg/oko5D5p8hiEsMCthFAaUTlszlX5jBSpcIMQfvBjyoJNXx6Gjb/Eejdm9s83hiwzirr4N0paIsveDv2gnu4nXCPS81jjMimkWesbEVkLwe3kNxXpJNfPFa3Yy8ItOBE+kATFOlDkH8bqPS1z6t33j1fhI4uXAfl3Bf8qJIUf8Ng4IyTc+MP+IEIazJVC+hZp/8bCbT8mGJG2KRxGNsnGuov1Er5LFchC8cz69/EsIAtMEPQPjPAu8ymtUuipTYgUFHFcENSRhuxuSLRZbqhupdOUuqETdGBdmntkihqbvnanp2pyZ0ewjt2egjvdfljHYEKMw6CiVj8yXIVssrxfkA+Ai5TPYFFodblj3XVZuSHIZW0lCIW32YGKsw4BamnyvFa99ny2ZwrGb1W/xo+PQ3uzW0e7U4G7MQmjcPHpeYxM1a2IjDV3dDbsRcE2DJ89izBLOUvQkcXC35USQj9P7v8Dm+o/40EWhTpzo4XaqV845n1b+Aanp2r4dPTqGK4IVyR6DJfEoPAtHZJFLf1IuZDBnL1QIUZB2S5CllnOmGrk8kxuJBKWkp7LpCeeK37bIxeq3+P3cCNGqgw4xkrWxHt2AsC7ltg8AU/qiQGvMHW8k+RxfHM+jfV8Olp1nOCmyKA0oghA7l6ymdzrsnkGFw9F0hPPpQjvXVvbvN27AUBgh9VEoGcPuBq+PQ0aXufxp2Iz9WeC6Qnuje3ebm03ItNR4yYTsTnaqWgLb6mI0ZMUtAWX1FTfa2kqHIsRNTx6XlcCzD+uXVKa3tr8xOEPH9aPNhY284Wj3eh54oDgHPLV6jXvszPJFLOPC3it8oLvtNelchjxnrEzacdW7VG9aRz7Brv6ibNLwfMnIF2rtnAh+UIomezM14qPdd7n/adeocovmCSYC/Bp1VJU0/w17jf82vque4I3Buh012r8sxq0L5dvAI9tVCNmdnwfIXm0UrbHftctFFRY29sbG9xdXkAAAAAAAAAY29sb25pemUAAAAAAAAAY29sdW1iaWMAAAAAAAAAY29sb3JpemUAAAAAAAAAY29sZW1pY2UAAAAAAAAAY29saWZvcm0AAAAAAAAAY29sbHV2aWEAAAAAAAAAY29sb2JvbWEAAAAAAAAAY29sb3Bob24AAAAAAAAAY29sdW1uYWwAAAAAAAAAY29sdW1uZWQAAAAAAAAAY29sb3J3YXkAAAAAAAAAY29sb3RvbXkAAAAAAAAAY29sdWJyaWQAAAAAAAAAY29sdW1uYXI=" },
    { 13488, "dXBkYXRlAAAAAHJlbG9hZAAAAAB2aXNpdAAAAAAAY2xpY2sAAAAAAHRvdWNodXAAAAB0b3VjaGRvd24Ad2hlZWxkb3duAGxvYWQAAAAAAABob3ZlcgAAAAAAcGF1c2U=" },
    { 13589, "elA=" },
    { 13764, "bFc=" },
}

local exports = {}
exports.f = function()


end
exports.g = function(v_A, v_r)
local v_n, v_t = 0, 0
v_A = tobit(v_A)
v_r = tobit(v_r)
v_n = 0
v_t = 0
if not (I32[7794] ~= 0) then
v_n = F.fI(12)
I32[7794] = tobit(v_n)
v_t = F.fBA(64, 16)
I32[arshift((v_n + 8), 2)] = tobit(v_t)
if (v_t ~= 0) then
I32[arshift(v_n, 2)] = tobit(64)
I32[arshift((v_n + 4), 2)] = tobit(0)
end
end
v_n = I32[7792]
if (v_n ~= 0) then
F.fR(v_n)
end
I32[7793] = tobit(v_r)
v_n = F.fI(tobit((v_r + 1)))
I32[7792] = tobit(v_n)
F.fOA(tobit((v_r + v_n)), 0, (((-1) ~= bor(0, v_r)) and 1 or 0))
F.fQA(v_n, v_A, v_r)
I32[7795] = tobit(31227)
do return 0 end
end
exports.h = function(v_A, v_r, v_n)
local v_t, v_e, v_o, v_f = 0, 0, 0, 0
v_A = tobit(v_A)
v_r = tobit(v_r)
v_n = tobit(v_n)
v_e = 0
v_o = 0
v_f = 0
v_t = tobit((B - 16))
B = v_t
v_e = I32[7794]
if not (v_e ~= 0) then
v_e = F.fI(12)
I32[7794] = tobit(v_e)
v_o = F.fBA(64, 16)
I32[arshift((v_e + 8), 2)] = tobit(v_o)
if (v_o ~= 0) then
I32[arshift(v_e, 2)] = tobit(64)
I32[arshift((v_e + 4), 2)] = tobit(0)
end
end
v_o = F.fI(12)
v_f = F.fI(11)
I32[arshift(v_o, 2)] = tobit(v_f)
v_n = F.ffA(v_f, v_n)
v_f = F.fI(v_r)
I32[arshift((v_o + 4), 2)] = tobit(v_f)
F.fQA(v_f, v_A, v_r)
I32[arshift((v_o + 8), 2)] = tobit(v_r)
do
do
while true do
do
if (not (F.fN(v_e, v_n, 10, tobit((v_t + 12))) ~= 0)) then
if (not (F.fAA(v_e) ~= 0)) then
goto C362
end
goto L361
end
goto B362
end
::C362::
end
end
::B362::
v_A = tobit((I32[arshift((v_e + 8), 2)] + lshift(I32[arshift((v_t + 12), 2)], 4)))
I32[arshift((v_A + 4), 2)] = tobit(10)
I32[arshift((v_A + 8), 2)] = tobit(1)
I32[arshift(v_A, 2)] = tobit(v_n)
I32[arshift((v_A + 12), 2)] = tobit(v_o)
I32[arshift((v_e + 4), 2)] = tobit((I32[arshift((v_e + 4), 2)] + 1))
end
::L361::
B = tobit((v_t + 16))
end
exports.i = function(v_A, v_r, v_n, v_t)

v_A = tobit(v_A)
v_r = tobit(v_r)
v_n = tobit(v_n)
v_t = tobit(v_t)
UA[bor(0, imul(bxor(31228, I32[7807]), bor(0, UA[bxor(31224, I32[7806])]())))](v_A, v_r, v_n, v_t)
end
exports.j = function(v_A, v_r)
local v_n, v_e, v_o, v_a, v_u = 0, 0, 0, 0, 0
v_A = tobit(v_A)
v_r = tobit(v_r)
v_e = 0
v_o = 0
v_a = 0
v_u = 0
v_A = tobit((B - 848))
B = v_A
I8[tobit((v_A + 847))] = tobit(0)
imp_b(21110, tobit((v_A + 847)), 0)
F.fQA(tobit((v_A + 608)), 13248, 225)
F.fQA(tobit((v_A + 496)), 13488, 100)
F.fxA(bor(0, imp_d(0)))
v_r = F.fIA()
v_e = F.fIA()
v_o = tobit((tobit((v_A + 608)) + imul(tobit(fmod(bor(0, v_r), 14)), 15)))
v_e = tobit((tobit((v_A + 496)) + imul(tobit(fmod(bor(0, v_e), 9)), 10)))
v_a = tobit((F.flA(v_o) + F.flA(v_e)))
v_u = tobit((3 + v_a))
v_r = F.fI(v_u)
F.fOA(tobit((v_r + 3)), 0, (((tobit(v_u) % 4294967296) < 4) and 0 or v_a))
I8[tobit((v_r + 2))] = tobit(U8[1088])
v_a = bor(U8[1086], lshift(U8[1087], 8))
I8[bor(0, v_r)] = tobit(v_a)
I8[tobit((v_r + 1))] = tobit((rshift(v_a, 8) % 4294967296))
v_u = F.fjA(F.fjA(v_r, v_o), v_e)
I32[7799] = tobit(v_u)
F.fP()
F.fMA(tobit((v_A + 216)))
I8[tobit((v_A + 184))] = tobit(113)
I8[tobit((v_A + 185))] = tobit(101)
I8[tobit((v_A + 186))] = tobit(122)
I8[tobit((v_A + 187))] = tobit(100)
I8[tobit((v_A + 188))] = tobit(107)
I8[tobit((v_A + 189))] = tobit(119)
I8[tobit((v_A + 190))] = tobit(108)
I8[tobit((v_A + 191))] = tobit(52)
I8[tobit((v_A + 176))] = tobit(115)
I8[tobit((v_A + 177))] = tobit(111)
I8[tobit((v_A + 178))] = tobit(109)
I8[tobit((v_A + 179))] = tobit(106)
I8[tobit((v_A + 180))] = tobit(97)
I8[tobit((v_A + 181))] = tobit(116)
I8[tobit((v_A + 182))] = tobit(112)
I8[tobit((v_A + 183))] = tobit(105)
F.fH(tobit((v_A + 216)), tobit((v_A + 176)), 128)
I8[tobit((v_A + 168))] = tobit(97)
I8[tobit((v_A + 169))] = tobit(50)
I8[tobit((v_A + 170))] = tobit(54)
I8[tobit((v_A + 171))] = tobit(106)
I8[tobit((v_A + 172))] = tobit(116)
I8[tobit((v_A + 173))] = tobit(103)
I8[tobit((v_A + 174))] = tobit(48)
I8[tobit((v_A + 175))] = tobit(118)
I8[tobit((v_A + 160))] = tobit(113)
I8[tobit((v_A + 161))] = tobit(111)
I8[tobit((v_A + 162))] = tobit(53)
I8[tobit((v_A + 163))] = tobit(109)
I8[tobit((v_A + 164))] = tobit(122)
I8[tobit((v_A + 165))] = tobit(101)
I8[tobit((v_A + 166))] = tobit(115)
I8[tobit((v_A + 167))] = tobit(102)
I8[tobit((v_A + 152))] = tobit(77)
I8[tobit((v_A + 153))] = tobit(212)
I8[tobit((v_A + 154))] = tobit(157)
I8[tobit((v_A + 155))] = tobit(221)
I8[tobit((v_A + 156))] = tobit(19)
I8[tobit((v_A + 157))] = tobit(107)
I8[tobit((v_A + 158))] = tobit(158)
I8[tobit((v_A + 159))] = tobit(123)
I8[tobit((v_A + 144))] = tobit(87)
I8[tobit((v_A + 145))] = tobit(242)
I8[tobit((v_A + 146))] = tobit(122)
I8[tobit((v_A + 147))] = tobit(182)
I8[tobit((v_A + 148))] = tobit(154)
I8[tobit((v_A + 149))] = tobit(134)
I8[tobit((v_A + 150))] = tobit(216)
I8[tobit((v_A + 151))] = tobit(222)
v_o = 16
F.fM(tobit((v_A + 216)), 0, 16, tobit((v_A + 160)), tobit((v_A + 144)), tobit((v_A + 192)))
F.fvA(tobit((v_A + 216)))
v_r = 16
do
do
do
v_a = U8[tobit((v_A + 207))]
local t401 = bor(bor((((tobit(v_a) % 4294967296) > 16) and 1 or 0), ((not (v_a ~= 0)) and 1 or 0)), ((16 == bor(0, v_a)) and 1 or 0))
if t401 == 0 then
v_e = 2
v_r = 15
t401 = (((tobit(v_a) % 4294967296) < 2) and 1 or 0)
end
if (not (t401 ~= 0)) then
do
v_r = 14
while true do
do
if (bor(((bor(0, v_a) ~= U8[tobit((tobit((v_A + 192)) + v_r))]) and 1 or 0), (((tobit(v_a) % 4294967296) <= (tobit(band(255, v_e)) % 4294967296)) and 1 or 0)) ~= 0) then
goto L363
end
v_e = tobit((v_e + 1))
v_r = tobit((v_r - 1))
end
::C364::
end
end
::B364::
end
end
end
::L363::
end
v_e = F.fI(tobit((v_r + 1)))
F.fOA(tobit((v_e + v_r)), 0, (((-1) ~= bor(0, v_r)) and 1 or 0))
v_a = F.fQA(v_e, tobit((v_A + 192)), v_r)
F.fMA(tobit((v_A + 216)))
I8[tobit((v_A + 136))] = tobit(112)
I8[tobit((v_A + 137))] = tobit(56)
I8[tobit((v_A + 138))] = tobit(110)
I8[tobit((v_A + 139))] = tobit(108)
I8[tobit((v_A + 140))] = tobit(52)
I8[tobit((v_A + 141))] = tobit(114)
I8[tobit((v_A + 142))] = tobit(97)
I8[tobit((v_A + 143))] = tobit(109)
I8[tobit((v_A + 128))] = tobit(102)
I8[tobit((v_A + 129))] = tobit(99)
I8[tobit((v_A + 130))] = tobit(48)
I8[tobit((v_A + 131))] = tobit(113)
I8[tobit((v_A + 132))] = tobit(55)
I8[tobit((v_A + 133))] = tobit(104)
I8[tobit((v_A + 134))] = tobit(117)
I8[tobit((v_A + 135))] = tobit(57)
F.fH(tobit((v_A + 216)), tobit((v_A + 128)), 128)
I8[tobit((v_A + 120))] = tobit(114)
I8[tobit((v_A + 121))] = tobit(122)
I8[tobit((v_A + 122))] = tobit(119)
I8[tobit((v_A + 123))] = tobit(111)
I8[tobit((v_A + 124))] = tobit(50)
I8[tobit((v_A + 125))] = tobit(105)
I8[tobit((v_A + 126))] = tobit(55)
I8[tobit((v_A + 127))] = tobit(120)
I8[tobit((v_A + 112))] = tobit(106)
I8[tobit((v_A + 113))] = tobit(103)
I8[tobit((v_A + 114))] = tobit(48)
I8[tobit((v_A + 115))] = tobit(117)
I8[tobit((v_A + 116))] = tobit(112)
I8[tobit((v_A + 117))] = tobit(121)
I8[tobit((v_A + 118))] = tobit(113)
I8[tobit((v_A + 119))] = tobit(109)
I8[tobit((v_A + 104))] = tobit(106)
I8[tobit((v_A + 105))] = tobit(11)
I8[tobit((v_A + 106))] = tobit(86)
I8[tobit((v_A + 107))] = tobit(137)
I8[tobit((v_A + 108))] = tobit(2)
I8[tobit((v_A + 109))] = tobit(115)
I8[tobit((v_A + 110))] = tobit(250)
I8[tobit((v_A + 111))] = tobit(221)
I8[tobit((v_A + 96))] = tobit(239)
I8[tobit((v_A + 97))] = tobit(197)
I8[tobit((v_A + 98))] = tobit(55)
I8[tobit((v_A + 99))] = tobit(95)
I8[tobit((v_A + 100))] = tobit(6)
I8[tobit((v_A + 101))] = tobit(33)
I8[tobit((v_A + 102))] = tobit(136)
I8[tobit((v_A + 103))] = tobit(177)
F.fM(tobit((v_A + 216)), 0, 16, tobit((v_A + 112)), tobit((v_A + 96)), tobit((v_A + 192)))
F.fvA(tobit((v_A + 216)))
do
do
do
v_r = U8[tobit((v_A + 207))]
local t402 = bor(bor((((tobit(v_r) % 4294967296) > 16) and 1 or 0), ((not (v_r ~= 0)) and 1 or 0)), ((16 == bor(0, v_r)) and 1 or 0))
if t402 == 0 then
v_e = 2
v_o = 15
t402 = (((tobit(v_r) % 4294967296) < 2) and 1 or 0)
end
if (not (t402 ~= 0)) then
do
v_o = 14
while true do
do
if (bor(((bor(0, v_r) ~= U8[tobit((tobit((v_A + 192)) + v_o))]) and 1 or 0), (((tobit(v_r) % 4294967296) <= (tobit(band(255, v_e)) % 4294967296)) and 1 or 0)) ~= 0) then
goto L365
end
v_e = tobit((v_e + 1))
v_o = tobit((v_o - 1))
end
::C366::
end
end
::B366::
end
end
end
::L365::
end
v_r = F.fI(tobit((v_o + 1)))
F.fOA(tobit((v_r + v_o)), 0, (((-1) ~= bor(0, v_o)) and 1 or 0))
v_n = F.fQA(v_r, tobit((v_A + 192)), v_o)
F.fMA(tobit((v_A + 216)))
I8[tobit((v_A + 88))] = tobit(102)
I8[tobit((v_A + 89))] = tobit(50)
I8[tobit((v_A + 90))] = tobit(117)
I8[tobit((v_A + 91))] = tobit(108)
I8[tobit((v_A + 92))] = tobit(114)
I8[tobit((v_A + 93))] = tobit(103)
I8[tobit((v_A + 94))] = tobit(101)
I8[tobit((v_A + 95))] = tobit(110)
I8[tobit((v_A + 80))] = tobit(107)
I8[tobit((v_A + 81))] = tobit(119)
I8[tobit((v_A + 82))] = tobit(98)
I8[tobit((v_A + 83))] = tobit(57)
I8[tobit((v_A + 84))] = tobit(115)
I8[tobit((v_A + 85))] = tobit(56)
I8[tobit((v_A + 86))] = tobit(118)
I8[tobit((v_A + 87))] = tobit(55)
F.fH(tobit((v_A + 216)), tobit((v_A + 80)), 128)
I8[tobit((v_A + 72))] = tobit(116)
I8[tobit((v_A + 73))] = tobit(110)
I8[tobit((v_A + 74))] = tobit(105)
I8[tobit((v_A + 75))] = tobit(104)
I8[tobit((v_A + 76))] = tobit(117)
I8[tobit((v_A + 77))] = tobit(97)
I8[tobit((v_A + 78))] = tobit(103)
I8[tobit((v_A + 79))] = tobit(102)
I8[tobit((v_A + 64))] = tobit(99)
I8[tobit((v_A + 65))] = tobit(108)
I8[tobit((v_A + 66))] = tobit(49)
I8[tobit((v_A + 67))] = tobit(48)
I8[tobit((v_A + 68))] = tobit(101)
I8[tobit((v_A + 69))] = tobit(54)
I8[tobit((v_A + 70))] = tobit(115)
I8[tobit((v_A + 71))] = tobit(114)
I8[tobit((v_A + 56))] = tobit(15)
I8[tobit((v_A + 57))] = tobit(171)
I8[tobit((v_A + 58))] = tobit(232)
I8[tobit((v_A + 59))] = tobit(189)
I8[tobit((v_A + 60))] = tobit(174)
I8[tobit((v_A + 61))] = tobit(30)
I8[tobit((v_A + 62))] = tobit(115)
I8[tobit((v_A + 63))] = tobit(7)
I8[tobit((v_A + 48))] = tobit(13)
I8[tobit((v_A + 49))] = tobit(152)
I8[tobit((v_A + 50))] = tobit(55)
I8[tobit((v_A + 51))] = tobit(16)
I8[tobit((v_A + 52))] = tobit(1)
I8[tobit((v_A + 53))] = tobit(102)
I8[tobit((v_A + 54))] = tobit(234)
I8[tobit((v_A + 55))] = tobit(74)
F.fM(tobit((v_A + 216)), 0, 16, tobit((v_A - (-64))), tobit((v_A + 48)), tobit((v_A + 192)))
F.fvA(tobit((v_A + 216)))
v_r = 16
do
do
do
v_o = U8[tobit((v_A + 207))]
local t403 = bor(bor((((tobit(v_o) % 4294967296) > 16) and 1 or 0), ((not (v_o ~= 0)) and 1 or 0)), ((16 == bor(0, v_o)) and 1 or 0))
if t403 == 0 then
v_e = 2
v_r = 15
t403 = (((tobit(v_o) % 4294967296) < 2) and 1 or 0)
end
if (not (t403 ~= 0)) then
do
v_r = 14
while true do
do
if (bor(((bor(0, v_o) ~= U8[tobit((tobit((v_A + 192)) + v_r))]) and 1 or 0), (((tobit(v_o) % 4294967296) <= (tobit(band(255, v_e)) % 4294967296)) and 1 or 0)) ~= 0) then
goto L367
end
v_r = tobit((v_r - 1))
v_e = tobit((v_e + 1))
end
::C368::
end
end
::B368::
end
end
end
::L367::
end
v_e = F.fI(tobit((v_r + 1)))
F.fOA(tobit((v_e + v_r)), 0, (((-1) ~= bor(0, v_r)) and 1 or 0))
v_r = F.fQA(v_e, tobit((v_A + 192)), v_r)
I32[arshift((v_A + 16), 2)] = tobit(v_u)
I32[arshift((v_A + 20), 2)] = tobit(v_n)
I32[arshift((v_A + 24), 2)] = tobit(1064)
I32[arshift((v_A + 28), 2)] = tobit(v_r)
I8[tobit((v_A + 40))] = tobit(0)
I32[arshift((v_A + 32), 2)] = tobit(1768515945)
I32[arshift((v_A + 36), 2)] = tobit(1768515945)
I32[arshift(v_A, 2)] = tobit(v_a)
I32[arshift((v_A + 4), 2)] = tobit(1109)
I32[arshift((v_A + 8), 2)] = tobit(1071)
I32[arshift((v_A + 12), 2)] = tobit(1024)
imp_b(21525, tobit((v_A + 32)), bor(0, v_A))
F.fP()
I32[7806] = tobit(31168)
I32[7807] = tobit(31173)
B = tobit((v_A + 848))
do return 0 end
end
exports.k = function()

do return bor(0, B) end
end
exports.l = function(v_A)

v_A = tobit(v_A)
B = v_A
end
exports.m = function(v_A)

do
local t404 = B
v_A = tobit(v_A)
v_A = band((t404 - v_A), (-16))
B = v_A
do return bor(0, v_A) end
end
end
exports.n = F.fI
exports.o = F.fR
exports.p = UA
return exports, DATA, function(v) B = v end, function() return B end
end
