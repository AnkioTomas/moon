-- 由 tools/gen_fock.js 从起点 Fock（wasm2js）转译生成，勿手改。
-- 运行环境见 fock.lua；env = { mem = ffi uint8_t*, imp = { b, c, d, e, f, abort } }。
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
local B, Iv = 5274992, 0
local scratch = ffi.new("int32_t[4]")
local scratch_f = ffi.cast("double*", scratch)
local function rf_a(i) return scratch[i] end
local function rf_u(i, v) scratch[i] = v end
local function rf_c() return scratch_f[0] end
local function rf_s(v) scratch_f[0] = v end
local F = {}
local UA = { [0] = false }
local YA = UA

F.fm = function(v_A)
local v_r, v_e, v_n, v_t, v_o, v_a, v_u, v_c, v_s, v_l, v_v, v_g = 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
v_e = 0
v_n = 0
v_t = 0
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
v_a = I32[5681]
local t1 = v_a
v_s = (((tobit(v_A) % 4294967296) < 11) and 16 or band((v_A + 11), (-8)))
v_n = tobit((rshift(v_s, 3) % 4294967296))
v_e = tobit((rshift(t1, v_n) % 4294967296))
if (band(3, v_e) ~= 0) then
do
do
v_t = tobit((v_n + band(1, bxor((-1), v_e))))
v_e = lshift(v_t, 3)
v_o = I32[arshift((22772 + v_e), 2)]
v_A = tobit((v_o + 8))
v_n = I32[arshift((v_o + 8), 2)]
local t2 = bor(0, v_n)
v_e = tobit((v_e + 22764))
if (t2 ~= bor(0, v_e)) then
I32[arshift((v_n + 12), 2)] = tobit(v_e)
I32[arshift((v_e + 8), 2)] = tobit(v_n)
else
I32[5681] = tobit(band(F.fKA((-2), v_t), v_a))
end
v_e = lshift(v_t, 3)
I32[arshift((v_o + 4), 2)] = tobit(bor(3, v_e))
v_e = tobit((v_e + v_o))
I32[arshift((4 + v_e), 2)] = tobit(bor(1, I32[arshift((v_e + 4), 2)]))
end
goto L1
end
end
end
v_v = I32[5683]
if ((tobit(v_v) % 4294967296) >= (tobit(v_s) % 4294967296)) then
goto L12
end
do
if (v_e ~= 0) then
do
do
v_A = lshift(2, v_n)
v_A = band(bor((0 - v_A), v_A), lshift(v_e, v_n))
v_e = tobit((band((0 - v_A), v_A) - 1))
v_A = band((rshift(v_e, 12) % 4294967296), 16)
v_n = v_A
local t3 = v_n
v_e = tobit((rshift(v_e, v_A) % 4294967296))
v_A = band((rshift(v_e, 5) % 4294967296), 8)
v_n = bor(t3, v_A)
local t4 = v_n
v_e = tobit((rshift(v_e, v_A) % 4294967296))
v_A = band((rshift(v_e, 2) % 4294967296), 4)
v_n = bor(t4, v_A)
local t5 = v_n
v_e = tobit((rshift(v_e, v_A) % 4294967296))
v_A = band((rshift(v_e, 1) % 4294967296), 2)
v_n = bor(t5, v_A)
local t6 = v_n
v_e = tobit((rshift(v_e, v_A) % 4294967296))
v_A = band((rshift(v_e, 1) % 4294967296), 1)
v_n = tobit((bor(t6, v_A) + tobit((rshift(v_e, v_A) % 4294967296))))
v_A = lshift(v_n, 3)
v_u = I32[arshift((22772 + v_A), 2)]
v_e = I32[arshift((v_u + 8), 2)]
local t7 = bor(0, v_e)
v_A = tobit((v_A + 22764))
if (t7 ~= bor(0, v_A)) then
I32[arshift((v_e + 12), 2)] = tobit(v_A)
I32[arshift((v_A + 8), 2)] = tobit(v_e)
else
v_a = band(F.fKA((-2), v_n), v_a)
I32[5681] = tobit(v_a)
end
v_A = tobit((v_u + 8))
I32[arshift((v_u + 4), 2)] = tobit(bor(3, v_s))
v_e = lshift(v_n, 3)
v_o = tobit((v_e - v_s))
v_t = tobit((v_u + v_s))
I32[arshift((4 + v_t), 2)] = tobit(bor(1, v_o))
I32[arshift((v_e + v_u), 2)] = tobit(v_o)
if (v_v ~= 0) then
v_e = tobit((rshift(v_v, 3) % 4294967296))
v_n = tobit((22764 + lshift(v_e, 3)))
v_u = I32[5686]
v_e = lshift(1, v_e)
if (band(v_e, v_a) ~= 0) then
v_e = I32[arshift((v_n + 8), 2)]
else
I32[5681] = tobit(bor(v_e, v_a))
v_e = v_n
end
I32[arshift((v_n + 8), 2)] = tobit(v_u)
I32[arshift((v_e + 12), 2)] = tobit(v_u)
I32[arshift((v_u + 12), 2)] = tobit(v_n)
I32[arshift((v_u + 8), 2)] = tobit(v_e)
end
I32[5686] = tobit(v_t)
I32[5683] = tobit(v_o)
end
goto L1
end
end
end
v_c = I32[5682]
if (not (v_c ~= 0)) then
goto L12
end
do
do
do
v_e = tobit((band(v_c, (0 - v_c)) - 1))
v_A = band((rshift(v_e, 12) % 4294967296), 16)
v_n = v_A
local t8 = v_n
v_e = tobit((rshift(v_e, v_A) % 4294967296))
v_A = band((rshift(v_e, 5) % 4294967296), 8)
v_n = bor(t8, v_A)
local t9 = v_n
v_e = tobit((rshift(v_e, v_A) % 4294967296))
v_A = band((rshift(v_e, 2) % 4294967296), 4)
v_n = bor(t9, v_A)
local t10 = v_n
v_e = tobit((rshift(v_e, v_A) % 4294967296))
v_A = band((rshift(v_e, 1) % 4294967296), 2)
v_n = bor(t10, v_A)
local t11 = v_n
v_e = tobit((rshift(v_e, v_A) % 4294967296))
v_A = band((rshift(v_e, 1) % 4294967296), 1)
v_e = I32[arshift((23028 + lshift((bor(t11, v_A) + tobit((rshift(v_e, v_A) % 4294967296))), 2)), 2)]
v_t = tobit((band((-8), I32[arshift((v_e + 4), 2)]) - v_s))
v_n = v_e
end
while true do
do
v_A = I32[arshift((v_n + 16), 2)]
local t12 = (v_A ~= 0)
if not t12 then
v_A = I32[arshift((v_n + 20), 2)]
t12 = (v_A ~= 0)
end
if not t12 then goto B13 end
end
do
v_n = tobit((band((-8), I32[arshift((v_A + 4), 2)]) - v_s))
v_o = (((tobit(v_n) % 4294967296) < (tobit(v_t) % 4294967296)) and 1 or 0)
v_t = ((v_o ~= 0) and v_n or v_t)
v_e = ((v_o ~= 0) and v_A or v_e)
v_n = v_A
end
::C13::
end
end
::B13::
end
v_l = tobit((v_e + v_s))
if ((tobit(v_l) % 4294967296) <= (tobit(v_e) % 4294967296)) then
goto L11
end
v_g = I32[arshift((v_e + 24), 2)]
v_o = I32[arshift((v_e + 12), 2)]
if (bor(0, v_o) ~= bor(0, v_e)) then
v_A = I32[arshift((v_e + 8), 2)]
I32[arshift((v_A + 12), 2)] = tobit(v_o)
I32[arshift((v_o + 8), 2)] = tobit(v_A)
goto L2
end
v_n = tobit((v_e + 20))
v_A = I32[arshift(v_n, 2)]
if (not (v_A ~= 0)) then
v_A = I32[arshift((v_e + 16), 2)]
if (not (v_A ~= 0)) then
goto L10
end
v_n = tobit((v_e + 16))
end
do
do
while true do
do
v_u = v_n
v_o = v_A
v_n = tobit((v_A + 20))
v_A = I32[arshift(v_n, 2)]
local t13 = v_A
if t13 == 0 then
v_n = tobit((v_o + 16))
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
v_l = I32[5682]
t14 = v_l
end
if (t14 ~= 0) then
do
do
v_t = tobit((0 - v_s))
v_a = 0
if not ((tobit(v_s) % 4294967296) < 256) then
v_a = 31
if not ((tobit(v_s) % 4294967296) > 16777215) then
v_A = tobit((rshift(v_A, 8) % 4294967296))
local t16 = v_A
v_u = band((rshift((v_A + 1048320), 16) % 4294967296), 8)
v_A = lshift(t16, v_u)
local t17 = v_A
v_n = band((rshift((v_A + 520192), 16) % 4294967296), 4)
v_A = lshift(t17, v_n)
local t18 = v_A
v_e = band((rshift((v_A + 245760), 16) % 4294967296), 2)
v_A = tobit((tobit((rshift(lshift(t18, v_e), 15) % 4294967296)) - bor(bor(v_e, v_n), v_u)))
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
v_n = I32[arshift((23028 + lshift(v_a, 2)), 2)]
if (v_n ~= 0) then
do
do
v_A = 0
v_e = lshift(v_s, ((31 == bor(0, v_a)) and 0 or tobit((25 - tobit((rshift(v_a, 1) % 4294967296))))))
while true do
do
do
do
v_u = tobit((band((-8), I32[arshift((v_n + 4), 2)]) - v_s))
local t19 = (((tobit(v_u) % 4294967296) >= (tobit(v_t) % 4294967296)) and 1 or 0)
if t19 == 0 then
v_o = v_n
v_t = v_u
t19 = v_t
end
if (not (t19 ~= 0)) then
v_t = 0
v_A = v_n
goto L16
end
end
v_u = I32[arshift((v_n + 20), 2)]
v_n = I32[arshift((16 + tobit((band((rshift(v_e, 29) % 4294967296), 4) + v_n))), 2)]
v_A = ((v_u ~= 0) and ((bor(0, v_u) == bor(0, v_n)) and v_A or v_u) or v_A)
v_e = lshift(v_e, 1)
if (not (v_n ~= 0)) then
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
v_e = tobit((band(v_A, (0 - v_A)) - 1))
v_A = band((rshift(v_e, 12) % 4294967296), 16)
v_n = v_A
local t20 = v_n
v_e = tobit((rshift(v_e, v_A) % 4294967296))
v_A = band((rshift(v_e, 5) % 4294967296), 8)
v_n = bor(t20, v_A)
local t21 = v_n
v_e = tobit((rshift(v_e, v_A) % 4294967296))
v_A = band((rshift(v_e, 2) % 4294967296), 4)
v_n = bor(t21, v_A)
local t22 = v_n
v_e = tobit((rshift(v_e, v_A) % 4294967296))
v_A = band((rshift(v_e, 1) % 4294967296), 2)
v_n = bor(t22, v_A)
local t23 = v_n
v_e = tobit((rshift(v_e, v_A) % 4294967296))
v_A = band((rshift(v_e, 1) % 4294967296), 1)
v_A = I32[arshift((23028 + lshift((bor(t23, v_A) + tobit((rshift(v_e, v_A) % 4294967296))), 2)), 2)]
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
v_e = tobit((band((-8), I32[arshift((v_A + 4), 2)]) - v_s))
v_n = (((tobit(v_e) % 4294967296) < (tobit(v_t) % 4294967296)) and 1 or 0)
v_t = ((v_n ~= 0) and v_e or v_t)
v_o = ((v_n ~= 0) and v_A or v_o)
v_e = I32[arshift((v_A + 16), 2)]
local t24 = v_e
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
if (not (bor(((not (v_o ~= 0)) and 1 or 0), (((tobit((I32[5683] - v_s)) % 4294967296) <= (tobit(v_t) % 4294967296)) and 1 or 0)) ~= 0)) then
do
v_c = tobit((v_o + v_s))
if ((tobit(v_c) % 4294967296) <= (tobit(v_o) % 4294967296)) then
goto L11
end
do
v_a = I32[arshift((v_o + 24), 2)]
local t25 = bor(0, v_o)
v_e = I32[arshift((v_o + 12), 2)]
if (t25 ~= bor(0, v_e)) then
v_A = I32[arshift((v_o + 8), 2)]
I32[arshift((v_A + 12), 2)] = tobit(v_e)
I32[arshift((v_e + 8), 2)] = tobit(v_A)
goto L3
end
end
v_n = tobit((v_o + 20))
v_A = I32[arshift(v_n, 2)]
if (not (v_A ~= 0)) then
v_A = I32[arshift((v_o + 16), 2)]
if (not (v_A ~= 0)) then
goto L9
end
v_n = tobit((v_o + 16))
end
do
do
while true do
do
v_u = v_n
v_e = v_A
v_n = tobit((v_A + 20))
v_A = I32[arshift(v_n, 2)]
local t26 = v_A
if t26 == 0 then
v_n = tobit((v_e + 16))
v_A = I32[arshift((v_e + 16), 2)]
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
v_n = I32[5683]
if ((tobit(v_n) % 4294967296) >= (tobit(v_s) % 4294967296)) then
v_t = I32[5686]
v_e = tobit((v_n - v_s))
if ((tobit(v_e) % 4294967296) >= 16) then
I32[5683] = tobit(v_e)
v_A = tobit((v_t + v_s))
I32[5686] = tobit(v_A)
I32[arshift((v_A + 4), 2)] = tobit(bor(1, v_e))
I32[arshift((v_n + v_t), 2)] = tobit(v_e)
I32[arshift((v_t + 4), 2)] = tobit(bor(3, v_s))
else
I32[5686] = tobit(0)
I32[5683] = tobit(0)
I32[arshift((v_t + 4), 2)] = tobit(bor(3, v_n))
v_A = tobit((v_n + v_t))
I32[arshift((4 + v_A), 2)] = tobit(bor(1, I32[arshift((v_A + 4), 2)]))
end
v_A = tobit((v_t + 8))
goto L1
end
v_c = I32[5684]
if ((tobit(v_c) % 4294967296) > (tobit(v_s) % 4294967296)) then
v_e = tobit((v_c - v_s))
I32[5684] = tobit(v_e)
v_n = I32[5687]
v_A = tobit((v_n + v_s))
I32[5687] = tobit(v_A)
I32[arshift((v_A + 4), 2)] = tobit(bor(1, v_e))
I32[arshift((v_n + 4), 2)] = tobit(bor(3, v_s))
v_A = tobit((v_n + 8))
goto L1
end
do
v_A = 0
v_l = tobit((v_s + 47))
v_e = v_l
if (I32[5799] ~= 0) then
v_n = I32[5801]
else
I32[5802] = tobit((-1))
I32[5803] = tobit((-1))
I32[5800] = tobit(4096)
I32[5801] = tobit(4096)
I32[5799] = tobit(bxor(band((v_r + 12), (-16)), 1431655768))
I32[5804] = tobit(0)
I32[5792] = tobit(0)
v_n = 4096
end
v_u = tobit((v_e + v_n))
local t27 = v_u
v_o = tobit((0 - v_n))
v_n = band(t27, v_o)
if ((tobit(v_n) % 4294967296) <= (tobit(v_s) % 4294967296)) then
goto L1
end
end
do
v_t = I32[5791]
local t29 = (v_t ~= 0)
if t29 then
local t28 = (tobit(v_t) % 4294967296)
v_e = I32[5789]
v_a = tobit((v_e + v_n))
t29 = (bor(((t28 < (tobit(v_a) % 4294967296)) and 1 or 0), (((tobit(v_e) % 4294967296) >= (tobit(v_a) % 4294967296)) and 1 or 0)) ~= 0)
end
if t29 then
goto L1
end
end
if (band(4, U8[23168]) ~= 0) then
goto L6
end
do
do
do
do
do
do
do
v_t = I32[5687]
if (v_t ~= 0) then
do
do
v_A = 23172
while true do
do
do
do
local t30 = (tobit(v_t) % 4294967296)
v_e = I32[arshift(v_A, 2)]
if ((t30 < (tobit((v_e + I32[arshift((v_A + 4), 2)])) % 4294967296)) and ((tobit(v_e) % 4294967296) <= (tobit(v_t) % 4294967296))) then
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
v_e = F.fmA(0)
if (t31 == bor(0, v_e)) then
goto L7
end
end
v_a = v_n
v_t = I32[5800]
v_A = tobit((v_t - 1))
if (band(v_A, v_e) ~= 0) then
v_a = tobit((tobit((v_n - v_e)) + band((v_A + v_e), (0 - v_t))))
end
if (bor((((tobit(v_a) % 4294967296) <= (tobit(v_s) % 4294967296)) and 1 or 0), (((tobit(v_a) % 4294967296) > 2147483646) and 1 or 0)) ~= 0) then
goto L7
end
do
v_t = I32[5791]
local t33 = (v_t ~= 0)
if t33 then
local t32 = (tobit(v_t) % 4294967296)
v_A = I32[5789]
v_o = tobit((v_A + v_a))
t33 = (bor(((t32 < (tobit(v_o) % 4294967296)) and 1 or 0), (((tobit(v_A) % 4294967296) >= (tobit(v_o) % 4294967296)) and 1 or 0)) ~= 0)
end
if t33 then
goto L7
end
end
do
local t34 = bor(0, v_e)
v_A = F.fmA(v_a)
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
v_e = F.fmA(v_a)
if (bor(0, v_e) == tobit((I32[arshift(v_A, 2)] + I32[arshift((v_A + 4), 2)]))) then
goto L8
end
v_A = v_e
end
end
::L20::
end
if (not (bor((((-1) == bor(0, v_A)) and 1 or 0), (((tobit((v_s + 48)) % 4294967296) <= (tobit(v_a) % 4294967296)) and 1 or 0)) ~= 0)) then
v_e = I32[5801]
v_e = band((v_e + tobit((v_l - v_a))), (0 - v_e))
if ((tobit(v_e) % 4294967296) > 2147483646) then
v_e = v_A
goto L5
end
if ((-1) ~= bor(0, F.fmA(v_e))) then
v_a = tobit((v_e + v_a))
v_e = v_A
goto L5
end
F.fmA(tobit((0 - v_a)))
goto L7
end
v_e = v_A
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
v_e = 0
goto L3
end
end
::L8::
end
if ((-1) ~= bor(0, v_e)) then
goto L5
end
end
end
::L7::
end
I32[5792] = tobit(bor(4, I32[5792]))
end
end
::L6::
end
if ((tobit(v_n) % 4294967296) > 2147483646) then
goto L4
end
do
local t35 = (-1)
v_e = F.fmA(v_n)
local t37 = (t35 == bor(0, v_e))
local t36 = (-1)
v_A = F.fmA(0)
if (bor(bor((t37 and 1 or 0), ((t36 == bor(0, v_A)) and 1 or 0)), (((tobit(v_A) % 4294967296) <= (tobit(v_e) % 4294967296)) and 1 or 0)) ~= 0) then
goto L4
end
end
v_a = tobit((v_A - v_e))
if ((tobit(v_a) % 4294967296) <= (tobit((v_s + 40)) % 4294967296)) then
goto L4
end
end
end
::L5::
end
v_A = tobit((I32[5789] + v_a))
I32[5789] = tobit(v_A)
if ((tobit(v_A) % 4294967296) > U32[5790]) then
I32[5790] = tobit(v_A)
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
v_u = I32[5687]
if (v_u ~= 0) then
do
do
do
v_A = 23172
while true do
do
do
do
v_t = I32[arshift(v_A, 2)]
local t38 = v_t
v_n = I32[arshift((v_A + 4), 2)]
if (tobit((t38 + v_n)) == bor(0, v_e)) then
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
v_A = I32[5685]
if not (((tobit(v_A) % 4294967296) <= (tobit(v_e) % 4294967296)) and (v_A ~= 0)) then
I32[5685] = tobit(v_e)
end
v_A = 0
I32[5794] = tobit(v_a)
I32[5793] = tobit(v_e)
I32[5689] = tobit((-1))
I32[5690] = tobit(I32[5799])
I32[5796] = tobit(0)
while true do
v_t = lshift(v_A, 3)
v_n = tobit((22764 + v_t))
I32[arshift((v_t + 22772), 2)] = tobit(v_n)
I32[arshift((v_t + 22776), 2)] = tobit(v_n)
v_A = tobit((v_A + 1))
if not (32 ~= bor(0, v_A)) then goto B27 end
do
end
::C27::
end
end
::B27::
do
v_t = tobit((v_a - 40))
local t39 = v_t
v_A = ((band((v_e + 8), 7) ~= 0) and band(((-8) - v_e), 7) or 0)
v_n = tobit((t39 - v_A))
I32[5684] = tobit(v_n)
v_A = tobit((v_A + v_e))
I32[5687] = tobit(v_A)
I32[arshift((v_A + 4), 2)] = tobit(bor(1, v_n))
I32[arshift((4 + tobit((v_e + v_t))), 2)] = tobit(40)
I32[5688] = tobit(I32[5803])
end
goto L23
end
end
::L25::
end
if (not (bor(bor(band(8, U8[tobit((v_A + 12))]), (((tobit(v_t) % 4294967296) > (tobit(v_u) % 4294967296)) and 1 or 0)), (((tobit(v_e) % 4294967296) <= (tobit(v_u) % 4294967296)) and 1 or 0)) ~= 0)) then
I32[arshift((v_A + 4), 2)] = tobit((v_n + v_a))
v_A = ((band((v_u + 8), 7) ~= 0) and band(((-8) - v_u), 7) or 0)
v_n = tobit((v_A + v_u))
I32[5687] = tobit(v_n)
v_e = tobit((I32[5684] + v_a))
v_A = tobit((v_e - v_A))
I32[5684] = tobit(v_A)
I32[arshift((v_n + 4), 2)] = tobit(bor(1, v_A))
I32[arshift((4 + tobit((v_e + v_u))), 2)] = tobit(40)
I32[5688] = tobit(I32[5803])
goto L23
end
end
end
::L24::
end
if (U32[5685] > (tobit(v_e) % 4294967296)) then
I32[5685] = tobit(v_e)
end
v_n = tobit((v_e + v_a))
v_A = 23172
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
if (bor(0, v_n) ~= I32[arshift(v_A, 2)]) then
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
v_A = 23172
while true do
do
do
do
v_n = I32[arshift(v_A, 2)]
local t40 = ((tobit(v_n) % 4294967296) <= (tobit(v_u) % 4294967296))
if t40 then
v_o = tobit((v_n + I32[arshift((v_A + 4), 2)]))
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
I32[arshift(v_A, 2)] = tobit(v_e)
I32[arshift((v_A + 4), 2)] = tobit((I32[arshift((v_A + 4), 2)] + v_a))
v_l = tobit((((band((v_e + 8), 7) ~= 0) and band(((-8) - v_e), 7) or 0) + v_e))
I32[arshift((4 + v_l), 2)] = tobit(bor(3, v_s))
v_a = tobit((v_n + ((band((v_n + 8), 7) ~= 0) and band(((-8) - v_n), 7) or 0)))
local t41 = v_a
v_c = tobit((v_s + v_l))
v_n = tobit((t41 - v_c))
if (bor(0, v_u) == bor(0, v_a)) then
I32[5687] = tobit(v_c)
v_A = tobit((I32[5684] + v_n))
I32[5684] = tobit(v_A)
I32[arshift((v_c + 4), 2)] = tobit(bor(1, v_A))
goto L29
end
end
if (I32[5686] == bor(0, v_a)) then
I32[5686] = tobit(v_c)
v_A = tobit((I32[5683] + v_n))
I32[5683] = tobit(v_A)
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
v_t = I32[arshift((v_a + 8), 2)]
v_A = tobit((rshift(v_A, 3) % 4294967296))
v_e = I32[arshift((v_a + 12), 2)]
if (bor(0, v_e) == bor(0, v_t)) then
I32[5681] = tobit(band(I32[5681], F.fKA((-2), v_A)))
goto L36
end
I32[arshift((v_t + 12), 2)] = tobit(v_e)
I32[arshift((v_e + 8), 2)] = tobit(v_t)
else
do
do
v_s = I32[arshift((v_a + 24), 2)]
local t42 = bor(0, v_a)
v_e = I32[arshift((v_a + 12), 2)]
if (t42 == bor(0, v_e)) then
do
v_A = tobit((v_a + 20))
v_t = I32[arshift(v_A, 2)]
local t43 = (v_t ~= 0)
if not t43 then
v_A = tobit((v_a + 16))
v_t = I32[arshift(v_A, 2)]
t43 = (v_t ~= 0)
end
if t43 then
do
do
do
while true do
do
v_o = v_A
v_e = v_t
v_A = tobit((v_e + 20))
v_t = I32[arshift(v_A, 2)]
local t44 = v_t
if t44 == 0 then
v_A = tobit((v_e + 16))
v_t = I32[arshift((v_e + 16), 2)]
t44 = v_t
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
v_e = 0
end
end
else
v_A = I32[arshift((v_a + 8), 2)]
I32[arshift((v_A + 12), 2)] = tobit(v_e)
I32[arshift((v_e + 8), 2)] = tobit(v_A)
end
end
if (v_s ~= 0) then
v_t = I32[arshift((v_a + 28), 2)]
do
v_A = tobit((23028 + lshift(v_t, 2)))
if (I32[arshift(v_A, 2)] == bor(0, v_a)) then
I32[arshift(v_A, 2)] = tobit(v_e)
if (v_e ~= 0) then
goto L38
end
I32[5682] = tobit(band(I32[5682], F.fKA((-2), v_t)))
goto L36
end
I32[arshift((v_s + ((I32[arshift((v_s + 16), 2)] == bor(0, v_a)) and 16 or 20)), 2)] = tobit(v_e)
if (not (v_e ~= 0)) then
goto L36
end
end
::L38::
I32[arshift((v_e + 24), 2)] = tobit(v_s)
v_A = I32[arshift((v_a + 16), 2)]
if (v_A ~= 0) then
I32[arshift((v_e + 16), 2)] = tobit(v_A)
I32[arshift((v_A + 24), 2)] = tobit(v_e)
end
v_A = I32[arshift((v_a + 20), 2)]
if (v_A ~= 0) then
I32[arshift((v_e + 20), 2)] = tobit(v_A)
I32[arshift((v_A + 24), 2)] = tobit(v_e)
end
end
end
end
end
end
::L36::
end
v_a = tobit((v_u + v_a))
v_n = tobit((v_n + v_u))
end
end
end
do
I32[arshift((v_a + 4), 2)] = tobit(band((-2), I32[arshift((v_a + 4), 2)]))
I32[arshift((v_c + 4), 2)] = tobit(bor(1, v_n))
I32[arshift((v_n + v_c), 2)] = tobit(v_n)
if ((tobit(v_n) % 4294967296) <= 255) then
do
do
v_A = tobit((rshift(v_n, 3) % 4294967296))
v_e = tobit((22764 + lshift(v_A, 3)))
v_n = I32[5681]
local t45 = v_n
v_A = lshift(1, v_A)
if (band(t45, v_A) ~= 0) then
v_A = I32[arshift((v_e + 8), 2)]
else
I32[5681] = tobit(bor(v_A, v_n))
v_A = v_e
end
I32[arshift((v_e + 8), 2)] = tobit(v_c)
I32[arshift((v_A + 12), 2)] = tobit(v_c)
I32[arshift((v_c + 12), 2)] = tobit(v_e)
I32[arshift((v_c + 8), 2)] = tobit(v_A)
end
goto L29
end
end
end
do
v_A = 31
if ((tobit(v_n) % 4294967296) <= 16777215) then
v_A = tobit((rshift(v_n, 8) % 4294967296))
local t46 = v_A
v_o = band((rshift((v_A + 1048320), 16) % 4294967296), 8)
v_A = lshift(t46, v_o)
local t47 = v_A
v_t = band((rshift((v_A + 520192), 16) % 4294967296), 4)
v_A = lshift(t47, v_t)
local t48 = v_A
v_e = band((rshift((v_A + 245760), 16) % 4294967296), 2)
v_A = tobit((tobit((rshift(lshift(t48, v_e), 15) % 4294967296)) - bor(bor(v_e, v_t), v_o)))
v_A = tobit((28 + bor(lshift(v_A, 1), band((rshift(v_n, (v_A + 21)) % 4294967296), 1))))
end
I32[arshift((v_c + 28), 2)] = tobit(v_A)
I32[arshift((v_c + 16), 2)] = tobit(0)
I32[arshift((v_c + 20), 2)] = tobit(0)
v_o = tobit((23028 + lshift(v_A, 2)))
v_t = I32[5682]
local t49 = v_t
v_e = lshift(1, v_A)
if (band(t49, v_e) ~= 0) then
do
v_A = lshift(v_n, ((31 == bor(0, v_A)) and 0 or tobit((25 - tobit((rshift(v_A, 1) % 4294967296))))))
v_e = I32[arshift(v_o, 2)]
while true do
do
v_t = v_e
if (band((-8), I32[arshift((v_e + 4), 2)]) == bor(0, v_n)) then
goto L30
end
v_e = tobit((rshift(v_A, 29) % 4294967296))
v_A = lshift(v_A, 1)
v_o = tobit((v_t + band(4, v_e)))
v_e = I32[arshift((16 + v_o), 2)]
if (not (v_e ~= 0)) then
goto B39
end
end
::C39::
end
end
::B39::
I32[arshift((v_o + 16), 2)] = tobit(v_c)
I32[arshift((v_c + 24), 2)] = tobit(v_t)
else
I32[5682] = tobit(bor(v_e, v_t))
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
v_t = tobit((v_a - 40))
local t50 = v_t
v_A = ((band((v_e + 8), 7) ~= 0) and band(((-8) - v_e), 7) or 0)
v_n = tobit((t50 - v_A))
I32[5684] = tobit(v_n)
v_A = tobit((v_A + v_e))
I32[5687] = tobit(v_A)
I32[arshift((v_A + 4), 2)] = tobit(bor(1, v_n))
I32[arshift((4 + tobit((v_e + v_t))), 2)] = tobit(40)
I32[5688] = tobit(I32[5803])
v_A = tobit((tobit((v_o + ((band((v_o - 39), 7) ~= 0) and band((39 - v_o), 7) or 0))) - 47))
v_n = (((tobit(v_A) % 4294967296) < (tobit((v_u + 16)) % 4294967296)) and v_u or v_A)
I32[arshift((v_n + 4), 2)] = tobit(27)
v_A = I32[5796]
I32[arshift((v_n + 16), 2)] = tobit(I32[5795])
I32[arshift((v_n + 20), 2)] = tobit(v_A)
v_A = I32[5794]
I32[arshift((v_n + 8), 2)] = tobit(I32[5793])
I32[arshift((v_n + 12), 2)] = tobit(v_A)
I32[5795] = tobit((v_n + 8))
I32[5794] = tobit(v_a)
I32[5793] = tobit(v_e)
I32[5796] = tobit(0)
v_A = tobit((v_n + 24))
end
while true do
I32[arshift((v_A + 4), 2)] = tobit(7)
v_e = tobit((v_A + 8))
v_A = tobit((v_A + 4))
if not ((tobit(v_e) % 4294967296) < (tobit(v_o) % 4294967296)) then goto B40 end
do
end
::C40::
end
end
::B40::
end
if (bor(0, v_n) == bor(0, v_u)) then
goto L23
end
do
I32[arshift((v_n + 4), 2)] = tobit(band((-2), I32[arshift((v_n + 4), 2)]))
v_o = tobit((v_n - v_u))
I32[arshift((v_u + 4), 2)] = tobit(bor(1, v_o))
I32[arshift(v_n, 2)] = tobit(v_o)
if ((tobit(v_o) % 4294967296) <= 255) then
do
do
v_A = tobit((rshift(v_o, 3) % 4294967296))
v_e = tobit((22764 + lshift(v_A, 3)))
v_n = I32[5681]
local t51 = v_n
v_A = lshift(1, v_A)
if (band(t51, v_A) ~= 0) then
v_A = I32[arshift((v_e + 8), 2)]
else
I32[5681] = tobit(bor(v_A, v_n))
v_A = v_e
end
I32[arshift((v_e + 8), 2)] = tobit(v_u)
I32[arshift((v_A + 12), 2)] = tobit(v_u)
I32[arshift((v_u + 12), 2)] = tobit(v_e)
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
v_t = band((rshift((v_A + 1048320), 16) % 4294967296), 8)
v_A = lshift(t52, v_t)
local t53 = v_A
v_n = band((rshift((v_A + 520192), 16) % 4294967296), 4)
v_A = lshift(t53, v_n)
local t54 = v_A
v_e = band((rshift((v_A + 245760), 16) % 4294967296), 2)
v_A = tobit((tobit((rshift(lshift(t54, v_e), 15) % 4294967296)) - bor(bor(v_e, v_n), v_t)))
v_A = tobit((28 + bor(lshift(v_A, 1), band((rshift(v_o, (v_A + 21)) % 4294967296), 1))))
end
I32[arshift((v_u + 28), 2)] = tobit(v_A)
v_t = tobit((23028 + lshift(v_A, 2)))
v_n = I32[5682]
local t55 = v_n
v_e = lshift(1, v_A)
if (band(t55, v_e) ~= 0) then
do
v_A = lshift(v_o, ((31 == bor(0, v_A)) and 0 or tobit((25 - tobit((rshift(v_A, 1) % 4294967296))))))
v_e = I32[arshift(v_t, 2)]
while true do
do
v_n = v_e
if (bor(0, v_o) == band((-8), I32[arshift((v_e + 4), 2)])) then
goto L28
end
v_e = tobit((rshift(v_A, 29) % 4294967296))
v_A = lshift(v_A, 1)
v_t = tobit((v_n + band(4, v_e)))
v_e = I32[arshift((16 + v_t), 2)]
if (not (v_e ~= 0)) then
goto B41
end
end
::C41::
end
end
::B41::
I32[arshift((v_t + 16), 2)] = tobit(v_u)
I32[arshift((v_u + 24), 2)] = tobit(v_n)
else
I32[5682] = tobit(bor(v_e, v_n))
I32[arshift(v_t, 2)] = tobit(v_u)
I32[arshift((v_u + 24), 2)] = tobit(v_t)
end
end
I32[arshift((v_u + 12), 2)] = tobit(v_u)
I32[arshift((v_u + 8), 2)] = tobit(v_u)
goto L23
end
end
::L30::
end
v_A = I32[arshift((v_t + 8), 2)]
I32[arshift((v_A + 12), 2)] = tobit(v_c)
I32[arshift((v_t + 8), 2)] = tobit(v_c)
I32[arshift((v_c + 24), 2)] = tobit(0)
I32[arshift((v_c + 12), 2)] = tobit(v_t)
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
v_A = I32[arshift((v_n + 8), 2)]
I32[arshift((v_A + 12), 2)] = tobit(v_u)
I32[arshift((v_n + 8), 2)] = tobit(v_u)
I32[arshift((v_u + 24), 2)] = tobit(0)
I32[arshift((v_u + 12), 2)] = tobit(v_n)
I32[arshift((v_u + 8), 2)] = tobit(v_A)
end
end
::L23::
end
v_A = I32[5684]
if (not ((tobit(v_A) % 4294967296) <= (tobit(v_s) % 4294967296))) then
v_e = tobit((v_A - v_s))
I32[5684] = tobit(v_e)
v_n = I32[5687]
v_A = tobit((v_n + v_s))
I32[5687] = tobit(v_A)
I32[arshift((v_A + 4), 2)] = tobit(bor(1, v_e))
I32[arshift((v_n + 4), 2)] = tobit(bor(3, v_s))
v_A = tobit((v_n + 8))
goto L1
end
end
end
::L4::
end
I32[5680] = tobit(48)
v_A = 0
goto L1
end
end
::L3::
end
do
if (v_a ~= 0) then
v_n = I32[arshift((v_o + 28), 2)]
do
v_A = tobit((23028 + lshift(v_n, 2)))
if (I32[arshift(v_A, 2)] == bor(0, v_o)) then
I32[arshift(v_A, 2)] = tobit(v_e)
if (v_e ~= 0) then
goto L43
end
v_l = band(F.fKA((-2), v_n), v_l)
I32[5682] = tobit(v_l)
goto L42
end
I32[arshift((v_a + ((I32[arshift((v_a + 16), 2)] == bor(0, v_o)) and 16 or 20)), 2)] = tobit(v_e)
if (not (v_e ~= 0)) then
goto L42
end
end
::L43::
I32[arshift((v_e + 24), 2)] = tobit(v_a)
v_A = I32[arshift((v_o + 16), 2)]
if (v_A ~= 0) then
I32[arshift((v_e + 16), 2)] = tobit(v_A)
I32[arshift((v_A + 24), 2)] = tobit(v_e)
end
v_A = I32[arshift((v_o + 20), 2)]
if (v_A ~= 0) then
I32[arshift((v_e + 20), 2)] = tobit(v_A)
I32[arshift((v_A + 24), 2)] = tobit(v_e)
end
end
end
::L42::
do
do
do
if ((tobit(v_t) % 4294967296) <= 15) then
v_A = tobit((v_t + v_s))
I32[arshift((v_o + 4), 2)] = tobit(bor(3, v_A))
v_A = tobit((v_A + v_o))
I32[arshift((4 + v_A), 2)] = tobit(bor(1, I32[arshift((v_A + 4), 2)]))
else
do
I32[arshift((v_o + 4), 2)] = tobit(bor(3, v_s))
I32[arshift((v_c + 4), 2)] = tobit(bor(1, v_t))
I32[arshift((v_t + v_c), 2)] = tobit(v_t)
if ((tobit(v_t) % 4294967296) <= 255) then
do
v_A = tobit((rshift(v_t, 3) % 4294967296))
v_e = tobit((22764 + lshift(v_A, 3)))
v_n = I32[5681]
local t56 = v_n
v_A = lshift(1, v_A)
if (band(t56, v_A) ~= 0) then
v_A = I32[arshift((v_e + 8), 2)]
else
I32[5681] = tobit(bor(v_A, v_n))
v_A = v_e
end
I32[arshift((v_e + 8), 2)] = tobit(v_c)
I32[arshift((v_A + 12), 2)] = tobit(v_c)
I32[arshift((v_c + 12), 2)] = tobit(v_e)
I32[arshift((v_c + 8), 2)] = tobit(v_A)
end
else
do
do
v_A = 31
if ((tobit(v_t) % 4294967296) <= 16777215) then
v_A = tobit((rshift(v_t, 8) % 4294967296))
local t57 = v_A
v_u = band((rshift((v_A + 1048320), 16) % 4294967296), 8)
v_A = lshift(t57, v_u)
local t58 = v_A
v_n = band((rshift((v_A + 520192), 16) % 4294967296), 4)
v_A = lshift(t58, v_n)
local t59 = v_A
v_e = band((rshift((v_A + 245760), 16) % 4294967296), 2)
v_A = tobit((tobit((rshift(lshift(t59, v_e), 15) % 4294967296)) - bor(bor(v_e, v_n), v_u)))
v_A = tobit((28 + bor(lshift(v_A, 1), band((rshift(v_t, (v_A + 21)) % 4294967296), 1))))
end
I32[arshift((v_c + 28), 2)] = tobit(v_A)
I32[arshift((v_c + 16), 2)] = tobit(0)
I32[arshift((v_c + 20), 2)] = tobit(0)
v_n = tobit((23028 + lshift(v_A, 2)))
end
do
do
do
do
v_e = lshift(1, v_A)
if (band(v_e, v_l) ~= 0) then
do
do
do
v_A = lshift(v_t, ((31 == bor(0, v_A)) and 0 or tobit((25 - tobit((rshift(v_A, 1) % 4294967296))))))
v_s = I32[arshift(v_n, 2)]
while true do
do
do
do
local t60 = (-8)
v_e = v_s
if (band(t60, I32[arshift((v_e + 4), 2)]) == bor(0, v_t)) then
goto L45
end
end
v_n = tobit((rshift(v_A, 29) % 4294967296))
v_A = lshift(v_A, 1)
v_n = tobit((v_e + band(4, v_n)))
v_s = I32[arshift((16 + v_n), 2)]
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
I32[arshift((v_n + 16), 2)] = tobit(v_c)
I32[arshift((v_c + 24), 2)] = tobit(v_e)
end
else
I32[5682] = tobit(bor(v_e, v_l))
I32[arshift(v_n, 2)] = tobit(v_c)
I32[arshift((v_c + 24), 2)] = tobit(v_n)
end
end
I32[arshift((v_c + 12), 2)] = tobit(v_c)
I32[arshift((v_c + 8), 2)] = tobit(v_c)
goto L44
end
end
::L45::
end
v_A = I32[arshift((v_e + 8), 2)]
I32[arshift((v_A + 12), 2)] = tobit(v_c)
I32[arshift((v_e + 8), 2)] = tobit(v_c)
I32[arshift((v_c + 24), 2)] = tobit(0)
I32[arshift((v_c + 12), 2)] = tobit(v_e)
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
v_n = I32[arshift((v_e + 28), 2)]
do
v_A = tobit((23028 + lshift(v_n, 2)))
if (I32[arshift(v_A, 2)] == bor(0, v_e)) then
I32[arshift(v_A, 2)] = tobit(v_o)
if (v_o ~= 0) then
goto L48
end
I32[5682] = tobit(band(F.fKA((-2), v_n), v_c))
goto L47
end
I32[arshift((((I32[arshift((v_g + 16), 2)] == bor(0, v_e)) and 16 or 20) + v_g), 2)] = tobit(v_o)
if (not (v_o ~= 0)) then
goto L47
end
end
::L48::
I32[arshift((v_o + 24), 2)] = tobit(v_g)
v_A = I32[arshift((v_e + 16), 2)]
if (v_A ~= 0) then
I32[arshift((v_o + 16), 2)] = tobit(v_A)
I32[arshift((v_A + 24), 2)] = tobit(v_o)
end
v_A = I32[arshift((v_e + 20), 2)]
if (v_A ~= 0) then
I32[arshift((v_o + 20), 2)] = tobit(v_A)
I32[arshift((v_A + 24), 2)] = tobit(v_o)
end
end
end
::L47::
if ((tobit(v_t) % 4294967296) <= 15) then
v_A = tobit((v_t + v_s))
I32[arshift((v_e + 4), 2)] = tobit(bor(3, v_A))
v_A = tobit((v_A + v_e))
I32[arshift((4 + v_A), 2)] = tobit(bor(1, I32[arshift((v_A + 4), 2)]))
else
I32[arshift((v_e + 4), 2)] = tobit(bor(3, v_s))
I32[arshift((v_l + 4), 2)] = tobit(bor(1, v_t))
I32[arshift((v_t + v_l), 2)] = tobit(v_t)
if (v_v ~= 0) then
v_A = tobit((rshift(v_v, 3) % 4294967296))
v_n = tobit((22764 + lshift(v_A, 3)))
v_o = I32[5686]
v_A = lshift(1, v_A)
if (band(v_A, v_a) ~= 0) then
v_A = I32[arshift((v_n + 8), 2)]
else
I32[5681] = tobit(bor(v_A, v_a))
v_A = v_n
end
I32[arshift((v_n + 8), 2)] = tobit(v_o)
I32[arshift((v_A + 12), 2)] = tobit(v_o)
I32[arshift((v_o + 12), 2)] = tobit(v_n)
I32[arshift((v_o + 8), 2)] = tobit(v_A)
end
I32[5686] = tobit(v_l)
I32[5683] = tobit(v_t)
end
v_A = tobit((v_e + 8))
end
end
::L1::
end
B = tobit((v_r + 16))
do return bor(0, v_A) end
end

F.fQ = function(v_A, v_r, v_e)
local v_t, v_o, v_a, v_u, v_c, v_s, v_l, v_b, v_v, v_p, v_d, v_h, v_k, v_y, v_w, v_C, v_E, v_I, v_m, v_Q, v_O, v_S, v_M, v_x, v_j, v_T, v_P, v_K, v_R, v_D, v_L, v_F, v_H, v_N, v_U, v_Y, v_G, v_J, v_q, v_W, v_V, v_Z, v_z = 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
v_o = 0
v_a = 0
v_u = 0
v_c = 0
v_s = 0
v_l = 0
v_b = 0
v_v = 0
v_p = 0
v_d = 0
v_h = 0
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
v_M = 0
v_x = 0
v_j = 0
v_T = 0
v_P = 0
v_K = 0
v_R = 0
v_D = 0
v_L = 0
v_F = 0
v_H = 0
v_N = 0
v_U = 0
v_Y = 0
v_G = 0
v_J = 0
v_q = 0
v_W = 0
v_V = 0
v_Z = 0
v_z = 0
v_t = tobit((B + (-64)))
B = v_t
I32[arshift((v_t + 56), 2)] = tobit(0)
I32[arshift((v_t + 60), 2)] = tobit(0)
I32[arshift((v_t + 48), 2)] = tobit(0)
I32[arshift((v_t + 52), 2)] = tobit(0)
I32[arshift((v_t + 40), 2)] = tobit(0)
I32[arshift((v_t + 44), 2)] = tobit(0)
I32[arshift((v_t + 32), 2)] = tobit(0)
I32[arshift((v_t + 36), 2)] = tobit(0)
I32[arshift((v_t + 24), 2)] = tobit(0)
I32[arshift((v_t + 28), 2)] = tobit(0)
I32[arshift((v_t + 16), 2)] = tobit(0)
I32[arshift((v_t + 20), 2)] = tobit(0)
I32[arshift((v_t + 8), 2)] = tobit(0)
I32[arshift((v_t + 12), 2)] = tobit(0)
I32[arshift(v_t, 2)] = tobit(0)
I32[arshift((v_t + 4), 2)] = tobit(0)
F.fPA(tobit((v_A + 4)), 0, 272)
do
do
do
do
do
if (bor(((256 == bor(0, v_e)) and 1 or 0), ((192 == bor(0, v_e)) and 1 or 0)) ~= 0) then
I32[arshift(v_A, 2)] = tobit(4)
v_u = F.fTA(v_t, v_r, tobit((rshift(v_e, 3) % 4294967296)))
v_r = 1
if (192 == bor(0, v_e)) then
goto L51
end
else
v_a = (-36)
if (128 ~= bor(0, v_e)) then
goto L49
end
I32[arshift(v_A, 2)] = tobit(3)
F.fTA(v_t, v_r, tobit((rshift(v_e, 3) % 4294967296)))
v_r = 0
v_P = 1
end
v_s = U8[tobit((v_t + 22))]
v_a = U8[tobit((v_t + 21))]
v_c = U8[tobit((v_t + 20))]
v_l = U8[tobit((v_t + 19))]
v_v = U8[tobit((v_t + 18))]
v_y = U8[tobit((v_t + 17))]
v_h = U8[tobit((v_t + 16))]
goto L50
end
::L51::
v_h = U8[tobit((v_u + 16))]
I8[tobit((v_u + 24))] = tobit(bxor((-1), v_h))
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
v_K = U8[tobit((v_t + 23))]
local t61 = v_K
v_R = bor(lshift(band(255, v_a), 16), lshift(v_c, 24))
v_w = bor(bor(t61, v_R), lshift(band(255, v_s), 8))
v_D = U8[tobit((v_t + 7))]
local t62 = v_D
v_Q = bor(lshift(U8[tobit((v_t + 5))], 16), lshift(U8[tobit((v_t + 4))], 24))
v_u = bor(bor(t62, v_Q), lshift(U8[tobit((v_t + 6))], 8))
v_a = bxor(bxor(v_w, v_u), 1003262091)
v_o = U8[tobit((7840 + tobit((rshift(v_a, 24) % 4294967296))))]
v_s = bor(bor(bor(U8[tobit((7584 + band(255, v_a)))], lshift(U8[tobit((8096 + band((rshift(v_a, 16) % 4294967296), 255)))], 16)), lshift(v_o, 24)), lshift(U8[tobit((8352 + band((rshift(v_a, 8) % 4294967296), 255)))], 8))
v_L = band(255, v_l)
local t63 = v_L
v_F = bor(lshift(band(255, v_y), 16), lshift(v_h, 24))
v_S = bor(bor(t63, v_F), lshift(band(255, v_v), 8))
v_O = U8[tobit((v_t + 3))]
local t64 = v_O
v_y = bor(lshift(U8[tobit((v_t + 1))], 16), lshift(U8[bor(0, v_t)], 24))
v_c = bor(bor(t64, v_y), lshift(U8[tobit((v_t + 2))], 8))
local t66 = bor(v_o, lshift(v_s, 8))
local t65 = (-1600231809)
v_l = bxor(v_S, v_c)
v_a = bxor(t65, v_l)
v_a = bxor(t66, bor(bor(bor(lshift(U8[tobit((7840 + band((rshift(v_a, 16) % 4294967296), 255)))], 16), lshift(U8[tobit((7584 + tobit((rshift(v_a, 24) % 4294967296))))], 24)), lshift(U8[tobit((8096 + band((rshift(v_a, 8) % 4294967296), 255)))], 8)), U8[tobit((8352 + band(255, v_a)))]))
v_s = bxor(F.fKA(v_a, 16), v_s)
v_a = bxor(F.fKA(v_s, 24), v_a)
v_H = U8[tobit((v_t + 31))]
local t67 = v_H
v_N = bor(lshift(U8[tobit((v_t + 29))], 16), lshift(U8[tobit((v_t + 28))], 24))
v_M = bor(bor(t67, v_N), lshift(U8[tobit((v_t + 30))], 8))
v_U = U8[tobit((v_t + 15))]
local t68 = v_U
v_x = bor(lshift(U8[tobit((v_t + 13))], 16), lshift(U8[tobit((v_t + 12))], 24))
v_h = bor(bor(t68, v_x), lshift(U8[tobit((v_t + 14))], 8))
v_o = bxor(bxor(bxor(v_a, v_M), v_h), 1286239154)
v_v = U8[tobit((7840 + tobit((rshift(v_o, 24) % 4294967296))))]
local t69 = v_v
v_b = bor(bor(bor(U8[tobit((7584 + band(255, v_o)))], lshift(U8[tobit((8096 + band((rshift(v_o, 16) % 4294967296), 255)))], 16)), lshift(v_v, 24)), lshift(U8[tobit((8352 + band((rshift(v_o, 8) % 4294967296), 255)))], 8))
v_C = bor(t69, lshift(v_b, 8))
local t71 = v_s
v_Y = U8[tobit((v_t + 27))]
local t70 = v_Y
v_G = bor(lshift(U8[tobit((v_t + 25))], 16), lshift(U8[tobit((v_t + 24))], 24))
v_j = bor(bor(t70, v_G), lshift(U8[tobit((v_t + 26))], 8))
local t73 = bxor(t71, v_j)
v_J = U8[tobit((v_t + 11))]
local t72 = v_J
v_T = bor(lshift(U8[tobit((v_t + 9))], 16), lshift(U8[tobit((v_t + 8))], 24))
v_v = bor(bor(t72, v_T), lshift(U8[tobit((v_t + 10))], 8))
v_d = bxor(bxor(t73, v_v), F.fKA(v_a, 24))
local t74 = v_C
v_o = bxor((-1233459112), v_d)
v_o = bxor(t74, bor(bor(bor(lshift(U8[tobit((7840 + band((rshift(v_o, 16) % 4294967296), 255)))], 16), lshift(U8[tobit((7584 + tobit((rshift(v_o, 24) % 4294967296))))], 24)), lshift(U8[tobit((8096 + band((rshift(v_o, 8) % 4294967296), 255)))], 8)), U8[tobit((8352 + band(255, v_o)))]))
v_b = bxor(F.fKA(v_o, 16), v_b)
v_E = bxor(F.fKA(v_b, 24), v_o)
local t75 = (-380665154)
v_q = bxor(v_E, v_w)
v_o = bxor(t75, v_q)
v_s = U8[tobit((7840 + tobit((rshift(v_o, 24) % 4294967296))))]
v_p = bor(bor(bor(U8[tobit((7584 + band(255, v_o)))], lshift(U8[tobit((8096 + band((rshift(v_o, 16) % 4294967296), 255)))], 16)), lshift(v_s, 24)), lshift(U8[tobit((8352 + band((rshift(v_o, 8) % 4294967296), 255)))], 8))
v_l = bxor(bxor(bxor(v_c, F.fKA(v_E, 24)), v_l), v_b)
local t76 = bor(v_s, lshift(v_p, 8))
v_o = bxor((-957401297), v_l)
v_o = bxor(t76, bor(bor(bor(lshift(U8[tobit((7840 + band((rshift(v_o, 16) % 4294967296), 255)))], 16), lshift(U8[tobit((7584 + tobit((rshift(v_o, 24) % 4294967296))))], 24)), lshift(U8[tobit((8096 + band((rshift(v_o, 8) % 4294967296), 255)))], 8)), U8[tobit((8352 + band(255, v_o)))]))
v_b = bxor(F.fKA(v_o, 16), v_p)
v_C = bxor(F.fKA(v_b, 24), v_o)
local t77 = (-237801700)
v_I = bxor(bxor(v_C, v_a), v_M)
v_o = bxor(t77, v_I)
v_s = U8[tobit((7840 + tobit((rshift(v_o, 24) % 4294967296))))]
local t78 = v_s
v_p = bor(bor(bor(U8[tobit((7584 + band(255, v_o)))], lshift(U8[tobit((8096 + band((rshift(v_o, 16) % 4294967296), 255)))], 16)), lshift(v_s, 24)), lshift(U8[tobit((8352 + band((rshift(v_o, 8) % 4294967296), 255)))], 8))
v_k = bor(t78, lshift(v_p, 8))
v_s = bxor(bxor(bxor(F.fKA(v_C, 24), v_b), v_v), v_d)
local t79 = v_k
v_o = bxor(1426019237, v_s)
v_o = bxor(t79, bor(bor(bor(lshift(U8[tobit((7840 + band((rshift(v_o, 16) % 4294967296), 255)))], 16), lshift(U8[tobit((7584 + tobit((rshift(v_o, 24) % 4294967296))))], 24)), lshift(U8[tobit((8096 + band((rshift(v_o, 8) % 4294967296), 255)))], 8)), U8[tobit((8352 + band(255, v_o)))]))
v_b = bxor(F.fKA(v_o, 16), v_p)
v_k = bxor(F.fKA(v_b, 24), v_o)
v_l = bxor(bxor(F.fKA(v_k, 24), v_l), v_b)
v_b = 0
v_d = 0
v_p = 0
if ((tobit(v_e) % 4294967296) >= 129) then
v_C = bxor(v_C, v_a)
local t80 = (-563598051)
v_d = bxor(v_k, v_E)
v_o = bxor(t80, v_d)
v_b = U8[tobit((7840 + tobit((rshift(v_o, 24) % 4294967296))))]
local t81 = v_b
v_o = bor(bor(bor(U8[tobit((7584 + band(255, v_o)))], lshift(U8[tobit((8096 + band((rshift(v_o, 16) % 4294967296), 255)))], 16)), lshift(v_b, 24)), lshift(U8[tobit((8352 + band((rshift(v_o, 8) % 4294967296), 255)))], 8))
v_p = bor(t81, lshift(v_o, 8))
local t82 = v_p
v_b = bxor(v_l, v_S)
v_a = bxor(283453434, v_b)
v_a = bxor(t82, bor(bor(bor(lshift(U8[tobit((7840 + band((rshift(v_a, 16) % 4294967296), 255)))], 16), lshift(U8[tobit((7584 + tobit((rshift(v_a, 24) % 4294967296))))], 24)), lshift(U8[tobit((8096 + band((rshift(v_a, 8) % 4294967296), 255)))], 8)), U8[tobit((8352 + band(255, v_a)))]))
v_p = bxor(F.fKA(v_a, 16), v_o)
v_E = bxor(F.fKA(v_p, 24), v_a)
local t83 = (-1276722691)
v_m = bxor(v_C, v_E)
v_a = bxor(t83, v_m)
v_o = U8[tobit((7840 + tobit((rshift(v_a, 24) % 4294967296))))]
v_C = v_d
v_d = bor(bor(bor(U8[tobit((7584 + band(255, v_a)))], lshift(U8[tobit((8096 + band((rshift(v_a, 16) % 4294967296), 255)))], 16)), lshift(v_o, 24)), lshift(U8[tobit((8352 + band((rshift(v_a, 8) % 4294967296), 255)))], 8))
v_p = bxor(bxor(bxor(F.fKA(v_E, 24), v_p), v_s), v_j)
local t84 = bor(v_o, lshift(v_d, 8))
v_a = bxor((-1336506174), v_p)
v_a = bxor(t84, bor(bor(bor(lshift(U8[tobit((7840 + band((rshift(v_a, 16) % 4294967296), 255)))], 16), lshift(U8[tobit((7584 + tobit((rshift(v_a, 24) % 4294967296))))], 24)), lshift(U8[tobit((8096 + band((rshift(v_a, 8) % 4294967296), 255)))], 8)), U8[tobit((8352 + band(255, v_a)))]))
v_o = bxor(F.fKA(v_a, 16), v_d)
local t85 = v_C
v_a = bxor(F.fKA(v_o, 24), v_a)
v_d = bxor(t85, v_a)
v_b = bxor(bxor(F.fKA(v_a, 24), v_o), v_b)
end
if not (v_r ~= 0) then
v_W = bor(lshift(v_D, 30), (rshift(v_v, 2) % 4294967296))
v_V = bor(lshift(v_O, 30), (rshift(v_u, 2) % 4294967296))
v_Z = bor(lshift(v_U, 30), (rshift(v_c, 2) % 4294967296))
v_z = bor(lshift(v_J, 30), (rshift(v_h, 2) % 4294967296))
end
v_o = tobit((v_A + 4))
v_a = imul(v_r, 80)
I32[arshift((v_o + lshift(I8[tobit((v_a + 7376))], 2)), 2)] = tobit(v_c)
I32[arshift((v_o + lshift(I8[tobit((v_a + 7377))], 2)), 2)] = tobit(v_u)
I32[arshift((v_o + lshift(I8[tobit((v_a + 7378))], 2)), 2)] = tobit(v_v)
I32[arshift((v_o + lshift(I8[tobit((v_a + 7379))], 2)), 2)] = tobit(v_h)
I32[arshift((v_o + lshift(I8[tobit((v_a + 7380))], 2)), 2)] = tobit(bor(lshift(v_c, 15), (rshift(v_Q, 17) % 4294967296)))
I32[arshift((v_o + lshift(I8[tobit((v_a + 7381))], 2)), 2)] = tobit(bor(lshift(v_u, 15), (rshift(v_T, 17) % 4294967296)))
I32[arshift((v_o + lshift(I8[tobit((v_a + 7382))], 2)), 2)] = tobit(bor(lshift(v_v, 15), (rshift(v_x, 17) % 4294967296)))
I32[arshift((v_o + lshift(I8[tobit((v_a + 7383))], 2)), 2)] = tobit(bor(lshift(v_h, 15), (rshift(v_y, 17) % 4294967296)))
v_O = bor(lshift(v_O, 28), (rshift(v_u, 4) % 4294967296))
v_E = bor(lshift(v_h, 13), (rshift(v_y, 19) % 4294967296))
v_x = bor(lshift(v_v, 13), (rshift(v_x, 19) % 4294967296))
v_T = bor(lshift(v_u, 13), (rshift(v_T, 19) % 4294967296))
v_u = bor(lshift(v_c, 13), (rshift(v_Q, 19) % 4294967296))
if not (v_r ~= 0) then
I32[arshift((v_o + lshift(I8[tobit((v_a + 7384))], 2)), 2)] = tobit(v_V)
I32[arshift((v_o + lshift(I8[tobit((v_a + 7385))], 2)), 2)] = tobit(v_W)
I32[arshift((v_o + lshift(I8[tobit((v_a + 7386))], 2)), 2)] = tobit(v_z)
I32[arshift((v_o + lshift(I8[tobit((v_a + 7387))], 2)), 2)] = tobit(v_Z)
end
v_k = bxor(v_k, v_q)
v_y = bor(lshift(v_U, 28), (rshift(v_c, 4) % 4294967296))
v_Q = bor(lshift(v_J, 28), (rshift(v_h, 4) % 4294967296))
v_h = bor(lshift(v_D, 28), (rshift(v_v, 4) % 4294967296))
I32[arshift((v_o + lshift(I8[tobit((v_a + 7388))], 2)), 2)] = tobit(v_u)
I32[arshift((v_o + lshift(I8[tobit((v_a + 7389))], 2)), 2)] = tobit(v_T)
I32[arshift((v_o + lshift(I8[tobit((v_a + 7390))], 2)), 2)] = tobit(v_x)
I32[arshift((v_o + lshift(I8[tobit((v_a + 7391))], 2)), 2)] = tobit(v_E)
I32[arshift((v_o + lshift(I8[tobit((v_a + 7392))], 2)), 2)] = tobit(v_O)
end
do
if (v_P ~= 0) then
v_u = tobit((imul(v_r, 80) + 7395))
else
v_c = tobit((v_A + 4))
v_o = imul(v_r, 80)
I32[arshift((v_c + lshift(I8[tobit((v_o + 7393))], 2)), 2)] = tobit(v_h)
I32[arshift((v_c + lshift(I8[tobit((v_o + 7394))], 2)), 2)] = tobit(v_Q)
I32[arshift((v_c + lshift(I8[tobit((v_o + 7395))], 2)), 2)] = tobit(v_y)
if ((tobit(v_e) % 4294967296) < 129) then
goto L52
end
v_o = bor(v_r, v_P)
if not (v_o ~= 0) then
v_x = bor(lshift(v_j, 13), (rshift(v_N, 19) % 4294967296))
v_T = bor(lshift(v_w, 13), (rshift(v_G, 19) % 4294967296))
v_E = bor(lshift(v_M, 13), (rshift(v_F, 19) % 4294967296))
v_u = bor(lshift(v_S, 13), (rshift(v_R, 19) % 4294967296))
end
if not (v_o ~= 0) then
I32[arshift((4 + tobit((lshift(I8[tobit((imul(v_r, 80) + 7396))], 2) + v_A))), 2)] = tobit(v_S)
end
if not (v_o ~= 0) then
I32[arshift((4 + tobit((lshift(I8[tobit((imul(v_r, 80) + 7397))], 2) + v_A))), 2)] = tobit(v_w)
end
if not (v_o ~= 0) then
I32[arshift((4 + tobit((lshift(I8[tobit((imul(v_r, 80) + 7398))], 2) + v_A))), 2)] = tobit(v_j)
end
if not (v_o ~= 0) then
I32[arshift((4 + tobit((lshift(I8[tobit((imul(v_r, 80) + 7399))], 2) + v_A))), 2)] = tobit(v_M)
end
v_v = tobit((v_A + 4))
v_c = imul(v_r, 80)
I32[arshift((v_v + lshift(I8[tobit((v_c + 7400))], 2)), 2)] = tobit(bor(lshift(v_S, 15), (rshift(v_R, 17) % 4294967296)))
I32[arshift((v_v + lshift(I8[tobit((v_c + 7401))], 2)), 2)] = tobit(bor(lshift(v_w, 15), (rshift(v_G, 17) % 4294967296)))
I32[arshift((v_v + lshift(I8[tobit((v_c + 7402))], 2)), 2)] = tobit(bor(lshift(v_j, 15), (rshift(v_N, 17) % 4294967296)))
I32[arshift((v_v + lshift(I8[tobit((v_c + 7403))], 2)), 2)] = tobit(bor(lshift(v_M, 15), (rshift(v_F, 17) % 4294967296)))
I32[arshift((v_v + lshift(I8[tobit((v_c + 7404))], 2)), 2)] = tobit(bor(lshift(v_L, 30), (rshift(v_w, 2) % 4294967296)))
I32[arshift((v_v + lshift(I8[tobit((v_c + 7405))], 2)), 2)] = tobit(bor(lshift(v_K, 30), (rshift(v_j, 2) % 4294967296)))
I32[arshift((v_v + lshift(I8[tobit((v_c + 7406))], 2)), 2)] = tobit(bor(lshift(v_Y, 30), (rshift(v_M, 2) % 4294967296)))
I32[arshift((v_v + lshift(I8[tobit((v_c + 7407))], 2)), 2)] = tobit(bor(lshift(v_H, 30), (rshift(v_S, 2) % 4294967296)))
if not (v_o ~= 0) then
I32[arshift((4 + tobit((lshift(I8[tobit((v_c + 7408))], 2) + v_A))), 2)] = tobit(v_u)
end
if not (v_o ~= 0) then
I32[arshift((4 + tobit((lshift(I8[tobit((imul(v_r, 80) + 7409))], 2) + v_A))), 2)] = tobit(v_T)
end
if not (v_o ~= 0) then
I32[arshift((4 + tobit((lshift(I8[tobit((imul(v_r, 80) + 7410))], 2) + v_A))), 2)] = tobit(v_x)
end
v_Q = bor(lshift(v_Y, 28), (rshift(v_M, 4) % 4294967296))
v_h = bor(lshift(v_K, 28), (rshift(v_j, 4) % 4294967296))
v_O = bor(lshift(v_L, 28), (rshift(v_w, 4) % 4294967296))
if not (v_o ~= 0) then
I32[arshift((4 + tobit((lshift(I8[tobit((imul(v_r, 80) + 7411))], 2) + v_A))), 2)] = tobit(v_E)
end
v_y = bor(lshift(v_H, 28), (rshift(v_S, 4) % 4294967296))
v_o = tobit((v_A + 4))
v_u = imul(v_r, 80)
I32[arshift((v_o + lshift(I8[tobit((v_u + 7412))], 2)), 2)] = tobit(v_O)
I32[arshift((v_o + lshift(I8[tobit((v_u + 7413))], 2)), 2)] = tobit(v_h)
I32[arshift((v_o + lshift(I8[tobit((v_u + 7414))], 2)), 2)] = tobit(v_Q)
v_u = tobit((v_u + 7415))
end
I32[arshift((4 + tobit((lshift(I8[bor(0, v_u)], 2) + v_A))), 2)] = tobit(v_y)
end
::L52::
do
if not (v_r ~= 0) then
v_u = tobit((v_A + 4))
v_a = imul(v_r, 80)
I32[arshift((v_u + lshift(I8[tobit((v_a + 7416))], 2)), 2)] = tobit(v_l)
I32[arshift((v_u + lshift(I8[tobit((v_a + 7417))], 2)), 2)] = tobit(v_k)
I32[arshift((v_u + lshift(I8[tobit((v_a + 7418))], 2)), 2)] = tobit(v_s)
I32[arshift((v_u + lshift(I8[tobit((v_a + 7419))], 2)), 2)] = tobit(v_I)
v_Q = bor(lshift(v_s, 28), (rshift(v_I, 4) % 4294967296))
v_h = bor(lshift(v_k, 28), (rshift(v_s, 4) % 4294967296))
v_O = bor(lshift(v_l, 28), (rshift(v_k, 4) % 4294967296))
v_y = bor(lshift(v_I, 28), (rshift(v_l, 4) % 4294967296))
end
v_v = bor(lshift(v_I, 13), (rshift(v_l, 19) % 4294967296))
v_a = bor(lshift(v_s, 13), (rshift(v_I, 19) % 4294967296))
v_c = bor(lshift(v_k, 13), (rshift(v_s, 19) % 4294967296))
v_w = bor(lshift(v_l, 13), (rshift(v_k, 19) % 4294967296))
v_o = tobit((v_A + 4))
v_u = imul(v_r, 80)
I32[arshift((v_o + lshift(I8[tobit((v_u + 7420))], 2)), 2)] = tobit(bor(lshift(v_l, 15), (rshift(v_k, 17) % 4294967296)))
I32[arshift((v_o + lshift(I8[tobit((v_u + 7421))], 2)), 2)] = tobit(bor(lshift(v_k, 15), (rshift(v_s, 17) % 4294967296)))
I32[arshift((v_o + lshift(I8[tobit((v_u + 7422))], 2)), 2)] = tobit(bor(lshift(v_s, 15), (rshift(v_I, 17) % 4294967296)))
I32[arshift((v_o + lshift(I8[tobit((v_u + 7423))], 2)), 2)] = tobit(bor(lshift(v_I, 15), (rshift(v_l, 17) % 4294967296)))
I32[arshift((v_o + lshift(I8[tobit((v_u + 7424))], 2)), 2)] = tobit(bor(lshift(v_l, 30), (rshift(v_k, 2) % 4294967296)))
I32[arshift((v_o + lshift(I8[tobit((v_u + 7425))], 2)), 2)] = tobit(bor(lshift(v_k, 30), (rshift(v_s, 2) % 4294967296)))
I32[arshift((v_o + lshift(I8[tobit((v_u + 7426))], 2)), 2)] = tobit(bor(lshift(v_s, 30), (rshift(v_I, 2) % 4294967296)))
I32[arshift((v_o + lshift(I8[tobit((v_u + 7427))], 2)), 2)] = tobit(bor(lshift(v_I, 30), (rshift(v_l, 2) % 4294967296)))
if (v_P ~= 0) then
v_s = tobit((v_u + 7430))
v_l = tobit((v_u + 7429))
v_o = v_a
v_u = v_c
else
I32[arshift((v_o + lshift(I8[tobit((v_u + 7428))], 2)), 2)] = tobit(v_w)
I32[arshift((v_o + lshift(I8[tobit((v_u + 7429))], 2)), 2)] = tobit(v_c)
v_s = tobit((v_u + 7431))
v_l = tobit((v_u + 7430))
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
I32[arshift((v_l + lshift(I8[tobit((v_u + 7432))], 2)), 2)] = tobit(v_O)
I32[arshift((v_l + lshift(I8[tobit((v_u + 7433))], 2)), 2)] = tobit(v_h)
I32[arshift((v_l + lshift(I8[tobit((v_u + 7434))], 2)), 2)] = tobit(v_Q)
I32[arshift((v_l + lshift(I8[tobit((v_u + 7435))], 2)), 2)] = tobit(v_y)
end
if not (bor((((tobit(v_e) % 4294967296) < 129) and 1 or 0), v_P) ~= 0) then
v_o = bor(v_r, v_P)
if not (v_o ~= 0) then
v_v = bor(lshift(v_m, 13), (rshift(v_b, 19) % 4294967296))
v_c = bor(lshift(v_d, 13), (rshift(v_p, 19) % 4294967296))
v_w = bor(lshift(v_b, 13), (rshift(v_d, 19) % 4294967296))
v_a = bor(lshift(v_p, 13), (rshift(v_m, 19) % 4294967296))
end
v_u = tobit((v_A + 4))
v_e = imul(v_r, 80)
I32[arshift((v_u + lshift(I8[tobit((v_e + 7436))], 2)), 2)] = tobit(v_b)
I32[arshift((v_u + lshift(I8[tobit((v_e + 7437))], 2)), 2)] = tobit(v_d)
I32[arshift((v_u + lshift(I8[tobit((v_e + 7438))], 2)), 2)] = tobit(v_p)
I32[arshift((v_u + lshift(I8[tobit((v_e + 7439))], 2)), 2)] = tobit(v_m)
I32[arshift((v_u + lshift(I8[tobit((v_e + 7440))], 2)), 2)] = tobit(bor(lshift(v_b, 15), (rshift(v_d, 17) % 4294967296)))
I32[arshift((v_u + lshift(I8[tobit((v_e + 7441))], 2)), 2)] = tobit(bor(lshift(v_d, 15), (rshift(v_p, 17) % 4294967296)))
I32[arshift((v_u + lshift(I8[tobit((v_e + 7442))], 2)), 2)] = tobit(bor(lshift(v_p, 15), (rshift(v_m, 17) % 4294967296)))
I32[arshift((v_u + lshift(I8[tobit((v_e + 7443))], 2)), 2)] = tobit(bor(lshift(v_m, 15), (rshift(v_b, 17) % 4294967296)))
I32[arshift((v_u + lshift(I8[tobit((v_e + 7444))], 2)), 2)] = tobit(bor(lshift(v_b, 30), (rshift(v_d, 2) % 4294967296)))
I32[arshift((v_u + lshift(I8[tobit((v_e + 7445))], 2)), 2)] = tobit(bor(lshift(v_d, 30), (rshift(v_p, 2) % 4294967296)))
I32[arshift((v_u + lshift(I8[tobit((v_e + 7446))], 2)), 2)] = tobit(bor(lshift(v_p, 30), (rshift(v_m, 2) % 4294967296)))
I32[arshift((v_u + lshift(I8[tobit((v_e + 7447))], 2)), 2)] = tobit(bor(lshift(v_m, 30), (rshift(v_b, 2) % 4294967296)))
if not (v_o ~= 0) then
I32[arshift((4 + tobit((lshift(I8[tobit((v_e + 7448))], 2) + v_A))), 2)] = tobit(v_w)
end
if not (v_o ~= 0) then
I32[arshift((4 + tobit((lshift(I8[tobit((imul(v_r, 80) + 7449))], 2) + v_A))), 2)] = tobit(v_c)
end
if not (v_o ~= 0) then
I32[arshift((4 + tobit((lshift(I8[tobit((imul(v_r, 80) + 7450))], 2) + v_A))), 2)] = tobit(v_a)
end
if not (v_o ~= 0) then
I32[arshift((4 + tobit((lshift(I8[tobit((imul(v_r, 80) + 7451))], 2) + v_A))), 2)] = tobit(v_v)
end
v_a = tobit((v_A + 4))
v_e = imul(v_r, 80)
I32[arshift((v_a + lshift(I8[tobit((v_e + 7452))], 2)), 2)] = tobit(bor(lshift(v_b, 28), (rshift(v_d, 4) % 4294967296)))
I32[arshift((v_a + lshift(I8[tobit((v_e + 7453))], 2)), 2)] = tobit(bor(lshift(v_d, 28), (rshift(v_p, 4) % 4294967296)))
I32[arshift((v_a + lshift(I8[tobit((v_e + 7454))], 2)), 2)] = tobit(bor(lshift(v_p, 28), (rshift(v_m, 4) % 4294967296)))
I32[arshift((v_a + lshift(I8[tobit((v_e + 7455))], 2)), 2)] = tobit(bor(lshift(v_m, 28), (rshift(v_b, 4) % 4294967296)))
end
v_e = tobit((v_A + 4))
v_c = imul(v_r, 12)
v_u = lshift(v_c, 2)
v_a = imul(v_r, 20)
I32[arshift((v_e + bor(128, v_u)), 2)] = tobit(I32[arshift((v_e + lshift(I8[tobit((v_a + 7536))], 2)), 2)])
I32[arshift((v_e + bor(132, v_u)), 2)] = tobit(I32[arshift((v_e + lshift(I8[tobit((v_a + 7537))], 2)), 2)])
I32[arshift((v_e + bor(136, v_u)), 2)] = tobit(I32[arshift((v_e + lshift(I8[tobit((v_a + 7538))], 2)), 2)])
I32[arshift((v_e + bor(140, v_u)), 2)] = tobit(I32[arshift((v_e + lshift(I8[tobit((v_a + 7539))], 2)), 2)])
if not (v_P ~= 0) then
v_o = tobit((v_e + v_u))
I32[arshift((144 + v_o), 2)] = tobit(I32[arshift((v_e + lshift(I8[tobit((v_a + 7540))], 2)), 2)])
I32[arshift((v_o + 148), 2)] = tobit(I32[arshift((v_e + lshift(I8[tobit((v_a + 7541))], 2)), 2)])
I32[arshift((v_o + 152), 2)] = tobit(I32[arshift((v_e + lshift(I8[tobit((v_a + 7542))], 2)), 2)])
I32[arshift((v_o + 156), 2)] = tobit(I32[arshift((v_e + lshift(I8[tobit((v_a + 7543))], 2)), 2)])
end
v_u = tobit((v_e + v_u))
I32[arshift((160 + v_u), 2)] = tobit(I32[arshift((v_e + lshift(I8[tobit((v_a + 7544))], 2)), 2)])
I32[arshift((v_u + 164), 2)] = tobit(I32[arshift((v_e + lshift(I8[tobit((v_a + 7545))], 2)), 2)])
I32[arshift((v_u + 168), 2)] = tobit(I32[arshift((v_e + lshift(I8[tobit((v_a + 7546))], 2)), 2)])
I32[arshift((v_u + 172), 2)] = tobit(I32[arshift((v_e + lshift(I8[tobit((v_a + 7547))], 2)), 2)])
v_a = 0
if not (v_r ~= 0) then
v_A = tobit((v_A + 4))
v_e = tobit((v_A + lshift(v_c, 2)))
v_r = imul(v_r, 20)
I32[arshift((v_e + 176), 2)] = tobit(I32[arshift((v_A + lshift(I8[tobit((v_r + 7548))], 2)), 2)])
I32[arshift((v_e + 180), 2)] = tobit(I32[arshift((v_A + lshift(I8[tobit((v_r + 7549))], 2)), 2)])
I32[arshift((v_e + 184), 2)] = tobit(I32[arshift((v_A + lshift(I8[tobit((v_r + 7550))], 2)), 2)])
I32[arshift((v_e + 188), 2)] = tobit(I32[arshift((v_A + lshift(I8[tobit((v_r + 7551))], 2)), 2)])
I32[arshift((v_e + 192), 2)] = tobit(I32[arshift((v_A + lshift(I8[tobit((v_r + 7552))], 2)), 2)])
I32[arshift((v_e + 196), 2)] = tobit(I32[arshift((v_A + lshift(I8[tobit((v_r + 7553))], 2)), 2)])
I32[arshift((v_e + 200), 2)] = tobit(I32[arshift((v_A + lshift(I8[tobit((v_r + 7554))], 2)), 2)])
I32[arshift((v_e + 204), 2)] = tobit(I32[arshift((v_A + lshift(I8[tobit((v_r + 7555))], 2)), 2)])
end
end
end
end
::L49::
end
B = tobit((v_t - (-64)))
do return v_a end
end

F.fO = function(v_A, v_r, v_e, v_t, v_a, v_u, v_c)
local v_s, v_l, v_b, v_p, v_d, v_h, v_k, v_y, v_w, v_C, v_E, v_I, v_m, v_Q, v_O, v_S, v_M = 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
v_p = 0
v_d = 0
v_h = 0
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
v_M = 0
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
I32[5680] = tobit(61)
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
v_h = v_s
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
v_d = tobit((v_r + 2))
I32[arshift((v_s + 76), 2)] = tobit(v_d)
v_p = tobit((v_p + 1))
v_y = U8[tobit((v_r + 2))]
v_r = v_d
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
F.fiA(v_A, v_w, v_r)
end
if (v_r ~= 0) then
goto C53
end
v_d = ((not (F.fDA(I8[tobit((I32[arshift((v_s + 76), 2)] + 1))]) ~= 0)) and 1 or 0)
v_r = I32[arshift((v_s + 76), 2)]
if (bor(v_d, ((36 ~= U8[tobit((v_r + 2))]) and 1 or 0)) ~= 0) then
goto L63
end
v_m = tobit((I8[tobit((v_r + 1))] - 48))
v_O = 1
v_r = tobit((v_r + 3))
goto L62
end
::L65::
v_d = tobit((v_r + 1))
I32[arshift((v_s + 76), 2)] = tobit(v_d)
v_p = U8[tobit((v_r + 1))]
v_r = v_d
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
F.foA(tobit((lshift(v_r, 3) + v_t)), v_A, v_e, v_c)
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
I32[arshift((v_h + 76), 2)] = tobit(v_r)
v_h = 0
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
v_d = tobit((v_r + 1))
I32[arshift((v_s + 76), 2)] = tobit(v_d)
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
v_r = v_d
end
::C70::
end
end
::B70::
end
v_r = v_d
v_h = v_p
end
end
end
do
do
do
if (42 ~= bor(0, v_k)) then
v_E = F.fQA(tobit((v_s + 76)))
if (bor(0, v_E) < 0) then
goto L56
end
v_r = I32[arshift((v_s + 76), 2)]
else
do
do
v_d = v_s
local t89 = F.fDA(I8[tobit((v_r + 1))])
if t89 ~= 0 then
v_r = I32[arshift((v_s + 76), 2)]
t89 = ((36 == U8[tobit((v_r + 2))]) and 1 or 0)
end
if (t89 ~= 0) then
I32[arshift((tobit((lshift(I8[tobit((v_r + 1))], 2) + v_a)) - 192), 2)] = tobit(10)
v_E = I32[arshift((tobit((lshift(I8[tobit((v_r + 1))], 3) + v_t)) - 384), 2)]
v_O = 1
v_r = tobit((v_r + 3))
else
if (v_O ~= 0) then
goto L56
end
v_O = 0
v_E = 0
if (v_A ~= 0) then
v_r = I32[arshift(v_e, 2)]
I32[arshift(v_e, 2)] = tobit((v_r + 4))
v_E = I32[arshift(v_r, 2)]
end
v_r = tobit((I32[arshift((v_s + 76), 2)] + 1))
end
end
I32[arshift((v_d + 76), 2)] = tobit(v_r)
if (bor(0, v_E) > (-1)) then
goto L71
end
v_E = tobit((0 - v_E))
v_h = bor(v_h, 8192)
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
v_y = F.fQA(tobit((v_s + 76)))
v_r = I32[arshift((v_s + 76), 2)]
else
do
do
local t90 = (F.fDA(I8[tobit((v_r + 2))]) ~= 0)
if t90 then
v_r = I32[arshift((v_s + 76), 2)]
t90 = (36 == U8[tobit((v_r + 3))])
end
if t90 then
I32[arshift((tobit((lshift(I8[tobit((v_r + 2))], 2) + v_a)) - 192), 2)] = tobit(10)
v_y = I32[arshift((tobit((lshift(I8[tobit((v_r + 2))], 3) + v_t)) - 384), 2)]
v_r = tobit((v_r + 4))
I32[arshift((v_s + 76), 2)] = tobit(v_r)
goto L72
end
end
if (v_O ~= 0) then
goto L56
end
if (v_A ~= 0) then
v_r = I32[arshift(v_e, 2)]
I32[arshift(v_e, 2)] = tobit((v_r + 4))
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
v_p = U8[tobit((11759 + tobit((v_p + imul(v_Q, 58)))))]
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
v_r = tobit((lshift(v_m, 3) + v_t))
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
F.foA(tobit((v_s - (-64))), v_p, v_e, v_c)
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
v_d = band((-65537), v_h)
v_p = ((band(8192, v_h) ~= 0) and v_d or v_h)
v_C = 0
v_m = 10501
v_h = v_l
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
v_d = I32[arshift((v_s + 68), 2)]
v_m = 10501
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
v_d = v_Q
local t91 = v_d
v_k = I32[arshift((v_s + 64), 2)]
if (bor(t91, v_k) ~= 0) then
do
while true do
v_w = tobit((v_w - 1))
I8[bor(0, v_w)] = tobit(bor(v_S, U8[tobit((12288 + band(15, v_k)))]))
v_M = bor(band(((not (v_d ~= 0)) and 1 or 0), (((tobit(v_k) % 4294967296) > 15) and 1 or 0)), ((0 ~= bor(0, v_d)) and 1 or 0))
v_Q = v_d
v_d = tobit((rshift(v_d, 4) % 4294967296))
v_k = bor(lshift(band(15, v_Q), 28), (rshift(v_k, 4) % 4294967296))
if not (v_M ~= 0) then goto B92 end
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
v_m = tobit((10501 + tobit((rshift(v_r, 4) % 4294967296))))
v_C = 2
goto L81
end
end
::L84::
end
do
v_r = v_l
v_w = I32[arshift((v_s + 68), 2)]
v_d = v_w
local t92 = v_d
v_k = I32[arshift((v_s + 64), 2)]
if (bor(t92, v_k) ~= 0) then
do
while true do
v_r = tobit((v_r - 1))
I8[bor(0, v_r)] = tobit(bor(band(7, v_k), 48))
v_Q = bor(band(((not (v_d ~= 0)) and 1 or 0), (((tobit(v_k) % 4294967296) > 7) and 1 or 0)), ((0 ~= bor(0, v_d)) and 1 or 0))
v_w = v_d
v_d = tobit((rshift(v_d, 3) % 4294967296))
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
v_d = v_r
v_k = I32[arshift((v_s + 64), 2)]
if ((bor(0, v_r) < (-1)) or (bor(0, v_r) <= (-1))) then
v_d = tobit((0 - tobit((v_d + ((0 ~= bor(0, v_k)) and 1 or 0)))))
v_k = tobit((0 - v_k))
I32[arshift((v_s + 64), 2)] = tobit(v_k)
I32[arshift((v_s + 68), 2)] = tobit(v_d)
v_C = 1
v_m = 10501
else
if (band(2048, v_p) ~= 0) then
v_C = 1
v_m = 10502
else
v_C = band(1, v_p)
v_m = ((v_C ~= 0) and 10503 or 10501)
end
end
end
end
::L82::
end
v_w = F.fdA(v_k, v_d, v_l)
end
end
::L81::
end
v_p = ((bor(0, v_y) > (-1)) and band((-65537), v_p) or v_p)
v_r = I32[arshift((v_s + 68), 2)]
v_d = v_r
v_k = I32[arshift((v_s + 64), 2)]
if (not (bor(bor(((0 ~= bor(0, v_k)) and 1 or 0), ((0 ~= bor(0, v_r)) and 1 or 0)), v_y) ~= 0)) then
v_y = 0
v_w = v_l
goto L54
end
v_r = tobit((((not (bor(v_d, v_k) ~= 0)) and 1 or 0) + tobit((v_l - v_w))))
v_y = ((bor(0, v_r) < bor(0, v_y)) and v_y or v_r)
goto L54
end
end
::L80::
end
v_r = v_y
v_h = ((0 ~= bor(0, v_r)) and 1 or 0)
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
t93 = 10659
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
v_h = ((0 ~= bor(0, v_r)) and 1 or 0)
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
if (not (v_h ~= 0)) then
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
v_h = I32[arshift(v_p, 2)]
if (band(band(bxor(t94, v_h), (v_h - 16843009)), (-2139062144)) ~= 0) then
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
v_h = v_p
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
v_h = 0
end
end
::L94::
end
do
v_r = v_h
local t95 = v_r
if t95 == 0 then
t95 = tobit((v_y + v_w))
end
v_h = t95
v_p = v_d
v_y = ((v_r ~= 0) and tobit((v_r - v_w)) or v_y)
end
goto L54
end
end
::L79::
end
v_h = I32[arshift((v_s + 64), 2)]
if (v_y ~= 0) then
goto L77
end
v_r = 0
F.fEA(v_A, 32, v_E, 0, v_p)
goto L76
end
end
::L78::
end
I32[arshift((v_s + 12), 2)] = tobit(0)
I32[arshift((v_s + 8), 2)] = tobit(I32[arshift((v_s + 64), 2)])
I32[arshift((v_s + 64), 2)] = tobit((v_s + 8))
v_y = (-1)
v_h = tobit((v_s + 8))
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
v_d = I32[arshift(v_h, 2)]
if (not (v_d ~= 0)) then
goto L102
end
do
v_d = F.faA(tobit((v_s + 4)), v_d)
v_w = ((bor(0, v_d) < 0) and 1 or 0)
if (not (bor(v_w, (((tobit(v_d) % 4294967296) > (tobit((v_y - v_r)) % 4294967296)) and 1 or 0)) ~= 0)) then
do
do
v_h = tobit((v_h + 4))
local t96 = (tobit(v_y) % 4294967296)
v_r = tobit((v_r + v_d))
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
F.fEA(v_A, 32, v_E, v_r, v_p)
if (v_r ~= 0) then
do
v_h = 0
v_k = I32[arshift((v_s + 64), 2)]
while true do
do
v_d = I32[arshift(v_k, 2)]
if (not (v_d ~= 0)) then
goto L76
end
v_d = F.faA(tobit((v_s + 4)), v_d)
v_h = tobit((v_d + v_h))
if (bor(0, v_h) > bor(0, v_r)) then
goto L76
end
F.fiA(v_A, tobit((v_s + 4)), v_d)
v_k = tobit((v_k + 4))
if (not ((tobit(v_r) % 4294967296) > (tobit(v_h) % 4294967296))) then
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
F.fEA(v_A, 32, v_E, v_r, bxor(8192, v_p))
v_r = ((bor(0, v_r) < bor(0, v_E)) and v_E or v_r)
goto C53
end
end
::L75::
end
v_r = bor(0, YA[bor(0, v_u)](v_A, F64[arshift((v_s + 64), 3)], v_E, v_y, v_p, v_r))
goto C53
end
end
::L74::
end
I8[tobit((v_s + 55))] = tobit(I32[arshift((v_s + 64), 2)])
v_y = 1
v_w = v_b
v_p = v_d
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
v_h = tobit((v_h - v_w))
v_y = ((t97 < bor(0, v_h)) and v_h or v_y)
v_d = tobit((v_y + v_C))
v_r = ((bor(0, v_d) > bor(0, v_E)) and v_d or v_E)
F.fEA(t98, 32, v_r, v_d, v_p)
F.fiA(v_A, v_m, v_C)
F.fEA(v_A, 48, v_r, v_d, bxor(65536, v_p))
F.fEA(v_A, 48, v_y, v_h, 0)
F.fiA(v_A, v_w, v_h)
F.fEA(v_A, 32, v_r, v_d, bxor(8192, v_p))
end
end
end
::C53::
end
end
::B53::
end
end

F.fS = function(v_A)
local v_r, v_e, v_t, v_o, v_i = 0, 0, 0, 0, 0
v_r = 0
v_e = 0
v_t = 0
v_o = 0
v_i = 0
do
do
v_e = U8[tobit((v_A + 64))]
I8[tobit((v_A + 32))] = tobit(v_e)
I8[tobit((v_A + 48))] = tobit(bxor(v_e, U8[tobit((v_A + 16))]))
v_e = U8[tobit((v_A + 65))]
I8[tobit((v_A + 33))] = tobit(v_e)
v_r = U8[tobit((v_A + 66))]
I8[tobit((v_A + 34))] = tobit(v_r)
v_t = U8[tobit((v_A + 67))]
I8[tobit((v_A + 35))] = tobit(v_t)
v_o = U8[tobit((v_A + 68))]
I8[tobit((v_A + 36))] = tobit(v_o)
I8[tobit((v_A + 49))] = tobit(bxor(v_e, U8[tobit((v_A + 17))]))
I8[tobit((v_A + 50))] = tobit(bxor(v_r, U8[tobit((v_A + 18))]))
I8[tobit((v_A + 51))] = tobit(bxor(v_t, U8[tobit((v_A + 19))]))
I8[tobit((v_A + 52))] = tobit(bxor(v_o, U8[tobit((v_A + 20))]))
v_e = U8[tobit((v_A + 69))]
I8[tobit((v_A + 37))] = tobit(v_e)
v_r = U8[tobit((v_A + 70))]
I8[tobit((v_A + 38))] = tobit(v_r)
v_t = U8[tobit((v_A + 71))]
I8[tobit((v_A + 39))] = tobit(v_t)
v_o = U8[tobit((v_A + 72))]
I8[tobit((v_A + 40))] = tobit(v_o)
v_i = U8[tobit((v_A + 73))]
I8[tobit((v_A + 41))] = tobit(v_i)
I8[tobit((v_A + 53))] = tobit(bxor(v_e, U8[tobit((v_A + 21))]))
I8[tobit((v_A + 54))] = tobit(bxor(v_r, U8[tobit((v_A + 22))]))
I8[tobit((v_A + 55))] = tobit(bxor(v_t, U8[tobit((v_A + 23))]))
I8[tobit((v_A + 56))] = tobit(bxor(v_o, U8[tobit((v_A + 24))]))
v_e = U8[tobit((v_A + 74))]
I8[tobit((v_A + 42))] = tobit(v_e)
v_r = U8[tobit((v_A + 75))]
I8[tobit((v_A + 43))] = tobit(v_r)
v_t = U8[tobit((v_A + 76))]
I8[tobit((v_A + 44))] = tobit(v_t)
v_o = U8[tobit((v_A + 77))]
I8[tobit((v_A + 45))] = tobit(v_o)
I8[tobit((v_A + 57))] = tobit(bxor(v_i, U8[tobit((v_A + 25))]))
I8[tobit((v_A + 58))] = tobit(bxor(v_e, U8[tobit((v_A + 26))]))
I8[tobit((v_A + 59))] = tobit(bxor(v_r, U8[tobit((v_A + 27))]))
I8[tobit((v_A + 60))] = tobit(bxor(v_t, U8[tobit((v_A + 28))]))
I8[tobit((v_A + 61))] = tobit(bxor(v_o, U8[tobit((v_A + 29))]))
v_e = U8[tobit((v_A + 78))]
I8[tobit((v_A + 46))] = tobit(v_e)
I8[tobit((v_A + 62))] = tobit(bxor(v_e, U8[tobit((v_A + 30))]))
v_e = U8[tobit((v_A + 79))]
I8[tobit((v_A + 47))] = tobit(v_e)
I8[tobit((v_A + 63))] = tobit(bxor(v_e, U8[tobit((v_A + 31))]))
v_t = 0
v_e = 0
v_r = 0
while true do
do
do
do
v_i = U8[tobit((v_e + 11504))]
local t99 = v_i
v_e = tobit((v_A + v_r))
v_o = bxor(t99, U8[tobit((16 + v_e))])
I8[tobit((v_e + 16))] = tobit(v_o)
v_o = bxor(U8[tobit((v_o + 11504))], U8[tobit((v_e + 17))])
I8[tobit((v_e + 17))] = tobit(v_o)
v_i = v_e
v_e = bxor(U8[tobit((v_o + 11504))], U8[tobit((v_e + 18))])
I8[tobit((v_i + 18))] = tobit(v_e)
v_r = tobit((v_r + 3))
if (48 == bor(0, v_r)) then
do
while true do
v_r = tobit((v_A + v_t))
v_e = bxor(U8[tobit((11504 + band(255, v_e)))], U8[tobit((v_r + 16))])
I8[tobit((v_r + 16))] = tobit(v_e)
v_e = bxor(U8[tobit((v_e + 11504))], U8[tobit((v_r + 17))])
I8[tobit((v_r + 17))] = tobit(v_e)
v_e = bxor(U8[tobit((v_e + 11504))], U8[tobit((v_r + 18))])
I8[tobit((v_r + 18))] = tobit(v_e)
v_t = tobit((v_t + 3))
if not (48 ~= bor(0, v_t)) then goto B106 end
do
end
::C106::
end
end
::B106::
do
v_r = tobit((v_e + 1))
v_e = 0
while true do
v_t = tobit((v_A + v_e))
v_r = bxor(U8[tobit((11504 + band(255, v_r)))], U8[tobit((v_t + 16))])
I8[tobit((v_t + 16))] = tobit(v_r)
v_r = bxor(U8[tobit((v_r + 11504))], U8[tobit((v_t + 17))])
I8[tobit((v_t + 17))] = tobit(v_r)
v_r = bxor(U8[tobit((v_r + 11504))], U8[tobit((v_t + 18))])
I8[tobit((v_t + 18))] = tobit(v_r)
v_e = tobit((v_e + 3))
if not (48 ~= bor(0, v_e)) then goto B107 end
do
end
::C107::
end
end
::B107::
do
v_r = tobit((v_r + 2))
v_e = 0
while true do
v_t = tobit((v_A + v_e))
v_r = bxor(U8[tobit((11504 + band(255, v_r)))], U8[tobit((v_t + 16))])
I8[tobit((v_t + 16))] = tobit(v_r)
v_r = bxor(U8[tobit((v_r + 11504))], U8[tobit((v_t + 17))])
I8[tobit((v_t + 17))] = tobit(v_r)
v_r = bxor(U8[tobit((v_r + 11504))], U8[tobit((v_t + 18))])
I8[tobit((v_t + 18))] = tobit(v_r)
v_e = tobit((v_e + 3))
if not (48 ~= bor(0, v_e)) then goto B108 end
do
end
::C108::
end
end
::B108::
do
v_r = tobit((v_r + 3))
v_e = 0
while true do
v_t = tobit((v_A + v_e))
v_r = bxor(U8[tobit((11504 + band(255, v_r)))], U8[tobit((v_t + 16))])
I8[tobit((v_t + 16))] = tobit(v_r)
v_r = bxor(U8[tobit((v_r + 11504))], U8[tobit((v_t + 17))])
I8[tobit((v_t + 17))] = tobit(v_r)
v_r = bxor(U8[tobit((v_r + 11504))], U8[tobit((v_t + 18))])
I8[tobit((v_t + 18))] = tobit(v_r)
v_e = tobit((v_e + 3))
if not (48 ~= bor(0, v_e)) then goto B109 end
do
end
::C109::
end
end
::B109::
do
v_r = tobit((v_r + 4))
v_e = 0
while true do
v_t = tobit((v_A + v_e))
v_r = bxor(U8[tobit((11504 + band(255, v_r)))], U8[tobit((v_t + 16))])
I8[tobit((v_t + 16))] = tobit(v_r)
v_r = bxor(U8[tobit((v_r + 11504))], U8[tobit((v_t + 17))])
I8[tobit((v_t + 17))] = tobit(v_r)
v_r = bxor(U8[tobit((v_r + 11504))], U8[tobit((v_t + 18))])
I8[tobit((v_t + 18))] = tobit(v_r)
v_e = tobit((v_e + 3))
if not (48 ~= bor(0, v_e)) then goto B110 end
do
end
::C110::
end
end
::B110::
do
v_r = tobit((v_r + 5))
v_e = 0
while true do
v_t = tobit((v_A + v_e))
v_r = bxor(U8[tobit((11504 + band(255, v_r)))], U8[tobit((v_t + 16))])
I8[tobit((v_t + 16))] = tobit(v_r)
v_r = bxor(U8[tobit((v_r + 11504))], U8[tobit((v_t + 17))])
I8[tobit((v_t + 17))] = tobit(v_r)
v_r = bxor(U8[tobit((v_r + 11504))], U8[tobit((v_t + 18))])
I8[tobit((v_t + 18))] = tobit(v_r)
v_e = tobit((v_e + 3))
if not (48 ~= bor(0, v_e)) then goto B111 end
do
end
::C111::
end
end
::B111::
do
v_r = tobit((v_r + 6))
v_e = 0
while true do
v_t = tobit((v_A + v_e))
v_r = bxor(U8[tobit((11504 + band(255, v_r)))], U8[tobit((v_t + 16))])
I8[tobit((v_t + 16))] = tobit(v_r)
v_r = bxor(U8[tobit((v_r + 11504))], U8[tobit((v_t + 17))])
I8[tobit((v_t + 17))] = tobit(v_r)
v_r = bxor(U8[tobit((v_r + 11504))], U8[tobit((v_t + 18))])
I8[tobit((v_t + 18))] = tobit(v_r)
v_e = tobit((v_e + 3))
if not (48 ~= bor(0, v_e)) then goto B112 end
do
end
::C112::
end
end
::B112::
do
v_r = tobit((v_r + 7))
v_e = 0
while true do
v_t = tobit((v_A + v_e))
v_r = bxor(U8[tobit((11504 + band(255, v_r)))], U8[tobit((v_t + 16))])
I8[tobit((v_t + 16))] = tobit(v_r)
v_r = bxor(U8[tobit((v_r + 11504))], U8[tobit((v_t + 17))])
I8[tobit((v_t + 17))] = tobit(v_r)
v_r = bxor(U8[tobit((v_r + 11504))], U8[tobit((v_t + 18))])
I8[tobit((v_t + 18))] = tobit(v_r)
v_e = tobit((v_e + 3))
if not (48 ~= bor(0, v_e)) then goto B113 end
do
end
::C113::
end
end
::B113::
do
v_r = tobit((v_r + 8))
v_e = 0
while true do
v_t = tobit((v_A + v_e))
v_r = bxor(U8[tobit((11504 + band(255, v_r)))], U8[tobit((v_t + 16))])
I8[tobit((v_t + 16))] = tobit(v_r)
v_r = bxor(U8[tobit((v_r + 11504))], U8[tobit((v_t + 17))])
I8[tobit((v_t + 17))] = tobit(v_r)
v_r = bxor(U8[tobit((v_r + 11504))], U8[tobit((v_t + 18))])
I8[tobit((v_t + 18))] = tobit(v_r)
v_e = tobit((v_e + 3))
if not (48 ~= bor(0, v_e)) then goto B114 end
do
end
::C114::
end
end
::B114::
do
v_r = tobit((v_r + 9))
v_e = 0
while true do
v_t = tobit((v_A + v_e))
v_r = bxor(U8[tobit((11504 + band(255, v_r)))], U8[tobit((v_t + 16))])
I8[tobit((v_t + 16))] = tobit(v_r)
v_r = bxor(U8[tobit((v_r + 11504))], U8[tobit((v_t + 17))])
I8[tobit((v_t + 17))] = tobit(v_r)
v_r = bxor(U8[tobit((v_r + 11504))], U8[tobit((v_t + 18))])
I8[tobit((v_t + 18))] = tobit(v_r)
v_e = tobit((v_e + 3))
if not (48 ~= bor(0, v_e)) then goto B115 end
do
end
::C115::
end
end
::B115::
do
v_r = tobit((v_r + 10))
v_e = 0
while true do
v_t = tobit((v_A + v_e))
v_r = bxor(U8[tobit((11504 + band(255, v_r)))], U8[tobit((v_t + 16))])
I8[tobit((v_t + 16))] = tobit(v_r)
v_r = bxor(U8[tobit((v_r + 11504))], U8[tobit((v_t + 17))])
I8[tobit((v_t + 17))] = tobit(v_r)
v_r = bxor(U8[tobit((v_r + 11504))], U8[tobit((v_t + 18))])
I8[tobit((v_t + 18))] = tobit(v_r)
v_e = tobit((v_e + 3))
if not (48 ~= bor(0, v_e)) then goto B116 end
do
end
::C116::
end
end
::B116::
do
v_r = tobit((v_r + 11))
v_e = 0
while true do
v_t = tobit((v_A + v_e))
v_r = bxor(U8[tobit((11504 + band(255, v_r)))], U8[tobit((v_t + 16))])
I8[tobit((v_t + 16))] = tobit(v_r)
v_r = bxor(U8[tobit((v_r + 11504))], U8[tobit((v_t + 17))])
I8[tobit((v_t + 17))] = tobit(v_r)
v_r = bxor(U8[tobit((v_r + 11504))], U8[tobit((v_t + 18))])
I8[tobit((v_t + 18))] = tobit(v_r)
v_e = tobit((v_e + 3))
if not (48 ~= bor(0, v_e)) then goto B117 end
do
end
::C117::
end
end
::B117::
do
v_r = tobit((v_r + 12))
v_e = 0
while true do
v_t = tobit((v_A + v_e))
v_r = bxor(U8[tobit((11504 + band(255, v_r)))], U8[tobit((v_t + 16))])
I8[tobit((v_t + 16))] = tobit(v_r)
v_r = bxor(U8[tobit((v_r + 11504))], U8[tobit((v_t + 17))])
I8[tobit((v_t + 17))] = tobit(v_r)
v_r = bxor(U8[tobit((v_r + 11504))], U8[tobit((v_t + 18))])
I8[tobit((v_t + 18))] = tobit(v_r)
v_e = tobit((v_e + 3))
if not (48 ~= bor(0, v_e)) then goto B118 end
do
end
::C118::
end
end
::B118::
do
v_r = tobit((v_r + 13))
v_e = 0
while true do
v_t = tobit((v_A + v_e))
v_r = bxor(U8[tobit((11504 + band(255, v_r)))], U8[tobit((v_t + 16))])
I8[tobit((v_t + 16))] = tobit(v_r)
v_r = bxor(U8[tobit((v_r + 11504))], U8[tobit((v_t + 17))])
I8[tobit((v_t + 17))] = tobit(v_r)
v_r = bxor(U8[tobit((v_r + 11504))], U8[tobit((v_t + 18))])
I8[tobit((v_t + 18))] = tobit(v_r)
v_e = tobit((v_e + 3))
if not (48 ~= bor(0, v_e)) then goto B119 end
do
end
::C119::
end
end
::B119::
do
v_r = tobit((v_r + 14))
v_e = 0
while true do
v_t = tobit((v_A + v_e))
v_r = bxor(U8[tobit((11504 + band(255, v_r)))], U8[tobit((v_t + 16))])
I8[tobit((v_t + 16))] = tobit(v_r)
v_r = bxor(U8[tobit((v_r + 11504))], U8[tobit((v_t + 17))])
I8[tobit((v_t + 17))] = tobit(v_r)
v_r = bxor(U8[tobit((v_r + 11504))], U8[tobit((v_t + 18))])
I8[tobit((v_t + 18))] = tobit(v_r)
v_e = tobit((v_e + 3))
if not (48 ~= bor(0, v_e)) then goto B120 end
do
end
::C120::
end
end
::B120::
do
v_r = tobit((v_r + 15))
v_e = 0
while true do
v_t = tobit((v_A + v_e))
v_r = bxor(U8[tobit((11504 + band(255, v_r)))], U8[tobit((v_t + 16))])
I8[tobit((v_t + 16))] = tobit(v_r)
v_r = bxor(U8[tobit((v_r + 11504))], U8[tobit((v_t + 17))])
I8[tobit((v_t + 17))] = tobit(v_r)
v_r = bxor(U8[tobit((v_r + 11504))], U8[tobit((v_t + 18))])
I8[tobit((v_t + 18))] = tobit(v_r)
v_e = tobit((v_e + 3))
if not (48 ~= bor(0, v_e)) then goto B121 end
do
end
::C121::
end
end
::B121::
do
v_r = tobit((v_r + 16))
v_e = 0
while true do
v_t = tobit((v_A + v_e))
v_r = bxor(U8[tobit((11504 + band(255, v_r)))], U8[tobit((v_t + 16))])
I8[tobit((v_t + 16))] = tobit(v_r)
v_r = bxor(U8[tobit((v_r + 11504))], U8[tobit((v_t + 17))])
I8[tobit((v_t + 17))] = tobit(v_r)
v_r = bxor(U8[tobit((v_r + 11504))], U8[tobit((v_t + 18))])
I8[tobit((v_t + 18))] = tobit(v_r)
v_e = tobit((v_e + 3))
if not (48 ~= bor(0, v_e)) then goto B122 end
do
end
::C122::
end
end
::B122::
v_e = bxor(U8[tobit((11504 + bxor(U8[tobit((v_A + 64))], U8[tobit((v_A + 15))])))], U8[bor(0, v_A)])
I8[bor(0, v_A)] = tobit(v_e)
v_e = bxor(U8[tobit((11504 + bxor(v_e, U8[tobit((v_A + 65))])))], U8[tobit((v_A + 1))])
I8[tobit((v_A + 1))] = tobit(v_e)
v_e = bxor(U8[tobit((11504 + bxor(v_e, U8[tobit((v_A + 66))])))], U8[tobit((v_A + 2))])
I8[tobit((v_A + 2))] = tobit(v_e)
v_e = bxor(U8[tobit((11504 + bxor(v_e, U8[tobit((v_A + 67))])))], U8[tobit((v_A + 3))])
I8[tobit((v_A + 3))] = tobit(v_e)
v_e = bxor(U8[tobit((11504 + bxor(v_e, U8[tobit((v_A + 68))])))], U8[tobit((v_A + 4))])
I8[tobit((v_A + 4))] = tobit(v_e)
v_e = bxor(U8[tobit((11504 + bxor(v_e, U8[tobit((v_A + 69))])))], U8[tobit((v_A + 5))])
I8[tobit((v_A + 5))] = tobit(v_e)
v_e = bxor(U8[tobit((11504 + bxor(v_e, U8[tobit((v_A + 70))])))], U8[tobit((v_A + 6))])
I8[tobit((v_A + 6))] = tobit(v_e)
v_e = bxor(U8[tobit((11504 + bxor(v_e, U8[tobit((v_A + 71))])))], U8[tobit((v_A + 7))])
I8[tobit((v_A + 7))] = tobit(v_e)
v_e = bxor(U8[tobit((11504 + bxor(v_e, U8[tobit((v_A + 72))])))], U8[tobit((v_A + 8))])
I8[tobit((v_A + 8))] = tobit(v_e)
v_e = bxor(U8[tobit((11504 + bxor(v_e, U8[tobit((v_A + 73))])))], U8[tobit((v_A + 9))])
I8[tobit((v_A + 9))] = tobit(v_e)
v_e = bxor(U8[tobit((11504 + bxor(v_e, U8[tobit((v_A + 74))])))], U8[tobit((v_A + 10))])
I8[tobit((v_A + 10))] = tobit(v_e)
v_e = bxor(U8[tobit((11504 + bxor(v_e, U8[tobit((v_A + 75))])))], U8[tobit((v_A + 11))])
I8[tobit((v_A + 11))] = tobit(v_e)
v_e = bxor(U8[tobit((11504 + bxor(v_e, U8[tobit((v_A + 76))])))], U8[tobit((v_A + 12))])
I8[tobit((v_A + 12))] = tobit(v_e)
v_e = bxor(U8[tobit((11504 + bxor(v_e, U8[tobit((v_A + 77))])))], U8[tobit((v_A + 13))])
I8[tobit((v_A + 13))] = tobit(v_e)
v_e = bxor(U8[tobit((11504 + bxor(v_e, U8[tobit((v_A + 78))])))], U8[tobit((v_A + 14))])
I8[tobit((v_A + 14))] = tobit(v_e)
I8[tobit((v_A + 15))] = tobit(bxor(U8[tobit((11504 + bxor(v_e, U8[tobit((v_A + 79))])))], U8[tobit((v_A + 15))]))
goto B105
end
end
v_e = band(v_e, 255)
end
end
::C105::
end
end
::B105::
end
end

F.fM = function(v_A, v_r, v_e)
local v_t, v_o, v_a, v_u, v_c, v_s, v_l, v_b, v_v, v_g = 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
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
v_t = tobit((B - 2048))
B = v_t
if (not (U8[23220] ~= 0)) then
do
do
do
v_o = 1
while true do
do
I32[arshift((tobit((v_t + 1024)) + lshift(v_s, 2)), 2)] = tobit(v_o)
I32[arshift((lshift(v_o, 2) + v_t), 2)] = tobit(v_s)
v_u = band(arshift(lshift(v_o, 24), 31), 27)
local t100 = v_u
v_o = bxor(v_o, band(lshift(v_o, 1), 254))
v_u = bxor(t100, v_o)
local t101 = tobit((v_t + 1024))
v_a = bor(1, v_s)
I32[arshift((t101 + lshift(v_a, 2)), 2)] = tobit(v_u)
I32[arshift((lshift(v_u, 2) + v_t), 2)] = tobit(v_a)
v_o = bxor(bxor(band(arshift(lshift(v_o, 24), 31), 27), v_u), band(lshift(v_u, 1), 254))
v_s = tobit((v_s + 2))
if not (256 ~= bor(0, v_s)) then goto B123 end
end
do
end
::C123::
end
end
::B123::
end
do
do
I32[5816] = tobit(27)
I32[5817] = tobit(54)
I32[5814] = tobit(64)
I32[5815] = tobit(128)
I32[5812] = tobit(16)
I32[5813] = tobit(32)
I32[5810] = tobit(4)
I32[5811] = tobit(8)
I32[5808] = tobit(1)
I32[5809] = tobit(2)
I8[23280] = tobit(99)
I8[31827] = tobit(0)
v_o = 1
while true do
do
v_u = I32[arshift((2044 + tobit((lshift((0 - I32[arshift((lshift(v_o, 2) + v_t), 2)]), 2) + v_t))), 2)]
v_s = band(255, bor(lshift(v_u, 1), (rshift(v_u, 7) % 4294967296)))
v_a = band(lshift(v_s, 1), 254)
local t102 = (rshift(v_a, 7) % 4294967296)
v_c = bor(v_a, (rshift(v_s, 7) % 4294967296))
v_l = band(lshift(v_c, 1), 254)
v_a = bor(t102, v_l)
v_u = bxor(bxor(bxor(bxor(bxor(v_a, v_c), v_u), v_s), bor(band(lshift(v_a, 1), 254), (rshift(v_l, 7) % 4294967296))), 99)
I8[tobit((v_o + 23280))] = tobit(v_u)
I8[tobit((v_u + 31728))] = tobit(v_o)
v_o = tobit((v_o + 1))
if not (256 ~= bor(0, v_o)) then goto B124 end
end
do
end
::C124::
end
end
::B124::
end
do
v_a = 0
v_s = 99
v_c = I32[arshift((v_t + 44), 2)]
v_l = I32[arshift((v_t + 52), 2)]
v_v = I32[arshift((v_t + 36), 2)]
v_g = I32[arshift((v_t + 56), 2)]
while true do
v_o = bxor(band(arshift(lshift(v_s, 24), 31), 27), band(lshift(v_s, 1), 254))
v_b = bor(bor(v_o, lshift(v_s, 8)), lshift(v_s, 16))
v_o = bxor(v_o, v_s)
v_u = lshift(v_a, 2)
I32[arshift((27632 + v_u), 2)] = tobit(bor(v_b, lshift(v_o, 24)))
v_o = bor(v_o, lshift(v_b, 8))
I32[arshift((v_u + 28656), 2)] = tobit(v_o)
v_o = bor(lshift(v_o, 8), v_s)
I32[arshift((v_u + 29680), 2)] = tobit(v_o)
I32[arshift((v_u + 30704), 2)] = tobit(bor(lshift(v_o, 8), v_s))
v_o = U8[tobit((v_a + 31728))]
if (v_o ~= 0) then
v_o = I32[arshift((lshift(v_o, 2) + v_t), 2)]
v_s = bxor(bxor(lshift(I32[arshift((tobit((v_t + 1024)) + lshift(fmod(tobit((v_o + v_v)), 255), 2)), 2)], 8), I32[arshift((tobit((v_t + 1024)) + lshift(fmod(tobit((v_o + v_g)), 255), 2)), 2)]), lshift(I32[arshift((tobit((v_t + 1024)) + lshift(fmod(tobit((v_o + v_l)), 255), 2)), 2)], 16))
v_o = lshift(I32[arshift((tobit((v_t + 1024)) + lshift(fmod(tobit((v_o + v_c)), 255), 2)), 2)], 24)
else
v_s = 0
v_o = 0
end
v_o = bxor(v_o, v_s)
I32[arshift((v_u + 23536), 2)] = tobit(v_o)
v_o = bor(lshift(v_s, 8), (rshift(v_o, 24) % 4294967296))
I32[arshift((v_u + 24560), 2)] = tobit(v_o)
I32[arshift((v_u + 25584), 2)] = tobit(F.fKA(v_o, 8))
I32[arshift((v_u + 26608), 2)] = tobit(F.fKA(v_o, 16))
v_a = tobit((v_a + 1))
if not (256 ~= bor(0, v_a)) then goto B125 end
do
v_s = U8[tobit((v_a + 23280))]
end
::C125::
end
end
::B125::
I8[23220] = tobit(1)
end
end
end
v_o = v_A
v_u = 10
do
do
do
if (128 ~= bor(0, v_e)) then
if (256 == bor(0, v_e)) then
v_u = 14
else
v_s = (-32)
if (192 ~= bor(0, v_e)) then
goto L126
end
v_u = 12
end
end
do
do
I32[arshift(v_o, 2)] = tobit(v_u)
v_o = tobit((v_A + 8))
I32[arshift((v_A + 4), 2)] = tobit(v_o)
v_s = tobit((rshift(v_e, 5) % 4294967296))
v_a = 0
while true do
do
v_e = lshift(v_a, 2)
I32[arshift((8 + tobit((v_e + v_A))), 2)] = tobit(bor(bor(bor(U8[tobit((v_r + v_e))], lshift(U8[tobit((bor(1, v_e) + v_r))], 8)), lshift(U8[tobit((bor(2, v_e) + v_r))], 16)), lshift(U8[tobit((bor(3, v_e) + v_r))], 24)))
local t103 = bor(0, v_s)
v_a = tobit((v_a + 1))
if not (t103 ~= bor(0, v_a)) then goto B127 end
end
do
end
::C127::
end
end
::B127::
end
v_s = 0
do
local sw128 = tobit((v_u - 10))
if sw128 == 0 then goto K128_0
elseif sw128 == 2 then goto K128_1
elseif sw128 == 4 then goto K128_2
else goto K128_3 end
::K128_0::
do
do
v_r = I32[arshift(v_o, 2)]
v_a = 0
while true do
v_A = I32[arshift((v_o + 12), 2)]
v_r = bxor(bxor(bxor(bxor(bxor(U8[tobit((23280 + band((rshift(v_A, 8) % 4294967296), 255)))], I32[arshift((23232 + lshift(v_a, 2)), 2)]), v_r), lshift(U8[tobit((23280 + band((rshift(v_A, 16) % 4294967296), 255)))], 8)), lshift(U8[tobit((23280 + tobit((rshift(v_A, 24) % 4294967296))))], 16)), lshift(U8[tobit((23280 + band(255, v_A)))], 24))
I32[arshift((v_o + 16), 2)] = tobit(v_r)
v_e = bxor(I32[arshift((v_o + 4), 2)], v_r)
I32[arshift((v_o + 20), 2)] = tobit(v_e)
v_e = bxor(v_e, I32[arshift((v_o + 8), 2)])
I32[arshift((v_o + 24), 2)] = tobit(v_e)
I32[arshift((v_o + 28), 2)] = tobit(bxor(v_A, v_e))
v_o = tobit((v_o + 16))
v_a = tobit((v_a + 1))
if not (10 ~= bor(0, v_a)) then goto B129 end
do
end
::C129::
end
end
::B129::
goto L126
end
::K128_1::
do
v_r = I32[arshift((v_A + 28), 2)]
v_e = bxor(bxor(bxor(bxor(bxor(U8[tobit((23280 + band((rshift(v_r, 8) % 4294967296), 255)))], I32[5808]), I32[arshift((v_A + 8), 2)]), lshift(U8[tobit((23280 + band((rshift(v_r, 16) % 4294967296), 255)))], 8)), lshift(U8[tobit((23280 + tobit((rshift(v_r, 24) % 4294967296))))], 16)), lshift(U8[tobit((23280 + band(255, v_r)))], 24))
I32[arshift((v_A + 32), 2)] = tobit(v_e)
v_u = bxor(v_e, I32[arshift((v_A + 12), 2)])
I32[arshift((v_A + 36), 2)] = tobit(v_u)
v_o = bxor(v_u, I32[arshift((v_A + 16), 2)])
I32[arshift((v_A + 40), 2)] = tobit(v_o)
v_a = bxor(v_o, I32[arshift((v_A + 20), 2)])
I32[arshift((v_A + 44), 2)] = tobit(v_a)
v_c = bxor(v_a, I32[arshift((v_A + 24), 2)])
I32[arshift((v_A + 48), 2)] = tobit(v_c)
v_r = bxor(v_r, v_c)
I32[arshift((v_A + 52), 2)] = tobit(v_r)
v_e = bxor(bxor(bxor(bxor(bxor(U8[tobit((23280 + band((rshift(v_r, 8) % 4294967296), 255)))], v_e), I32[5809]), lshift(U8[tobit((23280 + band((rshift(v_r, 16) % 4294967296), 255)))], 8)), lshift(U8[tobit((23280 + tobit((rshift(v_r, 24) % 4294967296))))], 16)), lshift(U8[tobit((23280 + band(255, v_r)))], 24))
I32[arshift((v_A + 56), 2)] = tobit(v_e)
v_u = bxor(v_u, v_e)
I32[arshift((v_A + 60), 2)] = tobit(v_u)
v_o = bxor(v_o, v_u)
I32[arshift((v_A - (-64)), 2)] = tobit(v_o)
v_a = bxor(v_a, v_o)
I32[arshift((v_A + 68), 2)] = tobit(v_a)
v_c = bxor(v_c, v_a)
I32[arshift((v_A + 72), 2)] = tobit(v_c)
v_r = bxor(v_r, v_c)
I32[arshift((v_A + 76), 2)] = tobit(v_r)
v_e = bxor(bxor(bxor(bxor(bxor(U8[tobit((23280 + band((rshift(v_r, 8) % 4294967296), 255)))], v_e), I32[5810]), lshift(U8[tobit((23280 + band((rshift(v_r, 16) % 4294967296), 255)))], 8)), lshift(U8[tobit((23280 + tobit((rshift(v_r, 24) % 4294967296))))], 16)), lshift(U8[tobit((23280 + band(255, v_r)))], 24))
I32[arshift((v_A + 80), 2)] = tobit(v_e)
v_u = bxor(v_u, v_e)
I32[arshift((v_A + 84), 2)] = tobit(v_u)
v_o = bxor(v_o, v_u)
I32[arshift((v_A + 88), 2)] = tobit(v_o)
v_a = bxor(v_a, v_o)
I32[arshift((v_A + 92), 2)] = tobit(v_a)
v_c = bxor(v_c, v_a)
I32[arshift((v_A + 96), 2)] = tobit(v_c)
v_r = bxor(v_r, v_c)
I32[arshift((v_A + 100), 2)] = tobit(v_r)
v_e = bxor(bxor(bxor(bxor(bxor(U8[tobit((23280 + band((rshift(v_r, 8) % 4294967296), 255)))], v_e), I32[5811]), lshift(U8[tobit((23280 + band((rshift(v_r, 16) % 4294967296), 255)))], 8)), lshift(U8[tobit((23280 + tobit((rshift(v_r, 24) % 4294967296))))], 16)), lshift(U8[tobit((23280 + band(255, v_r)))], 24))
I32[arshift((v_A + 104), 2)] = tobit(v_e)
v_u = bxor(v_u, v_e)
I32[arshift((v_A + 108), 2)] = tobit(v_u)
v_o = bxor(v_o, v_u)
I32[arshift((v_A + 112), 2)] = tobit(v_o)
v_a = bxor(v_a, v_o)
I32[arshift((v_A + 116), 2)] = tobit(v_a)
v_c = bxor(v_c, v_a)
I32[arshift((v_A + 120), 2)] = tobit(v_c)
v_r = bxor(v_r, v_c)
I32[arshift((v_A + 124), 2)] = tobit(v_r)
v_e = bxor(bxor(bxor(bxor(bxor(U8[tobit((23280 + band((rshift(v_r, 8) % 4294967296), 255)))], v_e), I32[5812]), lshift(U8[tobit((23280 + band((rshift(v_r, 16) % 4294967296), 255)))], 8)), lshift(U8[tobit((23280 + tobit((rshift(v_r, 24) % 4294967296))))], 16)), lshift(U8[tobit((23280 + band(255, v_r)))], 24))
I32[arshift((v_A + 128), 2)] = tobit(v_e)
v_u = bxor(v_u, v_e)
I32[arshift((v_A + 132), 2)] = tobit(v_u)
v_o = bxor(v_o, v_u)
I32[arshift((v_A + 136), 2)] = tobit(v_o)
v_a = bxor(v_a, v_o)
I32[arshift((v_A + 140), 2)] = tobit(v_a)
v_c = bxor(v_c, v_a)
I32[arshift((v_A + 144), 2)] = tobit(v_c)
v_r = bxor(v_r, v_c)
I32[arshift((v_A + 148), 2)] = tobit(v_r)
v_e = bxor(bxor(bxor(bxor(bxor(U8[tobit((23280 + band((rshift(v_r, 8) % 4294967296), 255)))], v_e), I32[5813]), lshift(U8[tobit((23280 + band((rshift(v_r, 16) % 4294967296), 255)))], 8)), lshift(U8[tobit((23280 + tobit((rshift(v_r, 24) % 4294967296))))], 16)), lshift(U8[tobit((23280 + band(255, v_r)))], 24))
I32[arshift((v_A + 152), 2)] = tobit(v_e)
v_u = bxor(v_u, v_e)
I32[arshift((v_A + 156), 2)] = tobit(v_u)
v_o = bxor(v_o, v_u)
I32[arshift((v_A + 160), 2)] = tobit(v_o)
v_a = bxor(v_a, v_o)
I32[arshift((v_A + 164), 2)] = tobit(v_a)
v_c = bxor(v_c, v_a)
I32[arshift((v_A + 168), 2)] = tobit(v_c)
v_r = bxor(v_r, v_c)
I32[arshift((v_A + 172), 2)] = tobit(v_r)
v_e = bxor(bxor(bxor(bxor(bxor(U8[tobit((23280 + band((rshift(v_r, 8) % 4294967296), 255)))], v_e), I32[5814]), lshift(U8[tobit((23280 + band((rshift(v_r, 16) % 4294967296), 255)))], 8)), lshift(U8[tobit((23280 + tobit((rshift(v_r, 24) % 4294967296))))], 16)), lshift(U8[tobit((23280 + band(255, v_r)))], 24))
I32[arshift((v_A + 176), 2)] = tobit(v_e)
v_u = bxor(v_u, v_e)
I32[arshift((v_A + 180), 2)] = tobit(v_u)
v_o = bxor(v_o, v_u)
I32[arshift((v_A + 184), 2)] = tobit(v_o)
v_a = bxor(v_a, v_o)
I32[arshift((v_A + 188), 2)] = tobit(v_a)
v_c = bxor(v_c, v_a)
I32[arshift((v_A + 192), 2)] = tobit(v_c)
v_r = bxor(v_r, v_c)
I32[arshift((v_A + 196), 2)] = tobit(v_r)
v_e = bxor(bxor(bxor(bxor(bxor(U8[tobit((23280 + band((rshift(v_r, 8) % 4294967296), 255)))], v_e), I32[5815]), lshift(U8[tobit((23280 + band((rshift(v_r, 16) % 4294967296), 255)))], 8)), lshift(U8[tobit((23280 + tobit((rshift(v_r, 24) % 4294967296))))], 16)), lshift(U8[tobit((23280 + band(255, v_r)))], 24))
I32[arshift((v_A + 200), 2)] = tobit(v_e)
v_e = bxor(v_e, v_u)
I32[arshift((v_A + 204), 2)] = tobit(v_e)
v_e = bxor(v_e, v_o)
I32[arshift((v_A + 208), 2)] = tobit(v_e)
v_e = bxor(v_e, v_a)
I32[arshift((v_A + 212), 2)] = tobit(v_e)
v_e = bxor(v_e, v_c)
I32[arshift((v_A + 216), 2)] = tobit(v_e)
I32[arshift((v_A + 220), 2)] = tobit(bxor(v_r, v_e))
goto L126
end
::K128_2::
do
goto S128
end
::K128_3::
do
goto L126
end
end
::S128::
do
v_a = I32[arshift(v_o, 2)]
v_e = 0
while true do
v_A = I32[arshift((v_o + 28), 2)]
v_a = bxor(bxor(bxor(bxor(bxor(U8[tobit((23280 + band((rshift(v_A, 8) % 4294967296), 255)))], I32[arshift((23232 + lshift(v_e, 2)), 2)]), v_a), lshift(U8[tobit((23280 + band((rshift(v_A, 16) % 4294967296), 255)))], 8)), lshift(U8[tobit((23280 + tobit((rshift(v_A, 24) % 4294967296))))], 16)), lshift(U8[tobit((23280 + band(255, v_A)))], 24))
I32[arshift((v_o + 32), 2)] = tobit(v_a)
v_r = bxor(I32[arshift((v_o + 4), 2)], v_a)
I32[arshift((v_o + 36), 2)] = tobit(v_r)
v_r = bxor(v_r, I32[arshift((v_o + 8), 2)])
I32[arshift((v_o + 40), 2)] = tobit(v_r)
v_r = bxor(v_r, I32[arshift((v_o + 12), 2)])
I32[arshift((v_o + 44), 2)] = tobit(v_r)
v_r = bxor(bxor(bxor(bxor(I32[arshift((v_o + 16), 2)], U8[tobit((23280 + band(255, v_r)))]), lshift(U8[tobit((23280 + band((rshift(v_r, 8) % 4294967296), 255)))], 8)), lshift(U8[tobit((23280 + band((rshift(v_r, 16) % 4294967296), 255)))], 16)), lshift(U8[tobit((23280 + tobit((rshift(v_r, 24) % 4294967296))))], 24))
I32[arshift((v_o + 48), 2)] = tobit(v_r)
v_r = bxor(v_r, I32[arshift((v_o + 20), 2)])
I32[arshift((v_o + 52), 2)] = tobit(v_r)
v_r = bxor(v_r, I32[arshift((v_o + 24), 2)])
I32[arshift((v_o + 56), 2)] = tobit(v_r)
I32[arshift((v_o + 60), 2)] = tobit(bxor(v_A, v_r))
v_o = tobit((v_o + 32))
v_e = tobit((v_e + 1))
if not (7 ~= bor(0, v_e)) then goto B130 end
do
end
::C130::
end
end
::B130::
end
end
::L126::
end
B = tobit((v_t + 2048))
do return v_s end
end

F.fx = function(v_A, v_r)
local v_e, v_n, v_t, v_o, v_a, v_u, v_c, v_s, v_l, v_b, v_v, v_g, v_p, v_d, v_h, v_k, v_y, v_w, v_C, v_E, v_B, v_I, v_m, v_Q, v_O = 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
v_w = 0
v_C = 0
v_E = 0
v_B = 0
v_I = 0
v_m = 0
v_Q = 0
v_O = 0
do
v_t = bor(bor(bor(U8[tobit((v_r + 16))], lshift(U8[tobit((v_r + 17))], 8)), lshift(U8[tobit((v_r + 18))], 16)), lshift(U8[tobit((v_r + 19))], 24))
v_m = bor(bor(bor(U8[tobit((v_r + 32))], lshift(U8[tobit((v_r + 33))], 8)), lshift(U8[tobit((v_r + 34))], 16)), lshift(U8[tobit((v_r + 35))], 24))
v_o = bor(bor(bor(U8[tobit((v_r + 48))], lshift(U8[tobit((v_r + 49))], 8)), lshift(U8[tobit((v_r + 50))], 16)), lshift(U8[tobit((v_r + 51))], 24))
v_a = bor(bor(bor(U8[tobit((v_r + 36))], lshift(U8[tobit((v_r + 37))], 8)), lshift(U8[tobit((v_r + 38))], 16)), lshift(U8[tobit((v_r + 39))], 24))
v_u = bor(bor(bor(U8[tobit((v_r + 52))], lshift(U8[tobit((v_r + 53))], 8)), lshift(U8[tobit((v_r + 54))], 16)), lshift(U8[tobit((v_r + 55))], 24))
v_c = bor(bor(bor(U8[tobit((v_r + 4))], lshift(U8[tobit((v_r + 5))], 8)), lshift(U8[tobit((v_r + 6))], 16)), lshift(U8[tobit((v_r + 7))], 24))
v_I = bor(bor(bor(U8[tobit((v_r + 20))], lshift(U8[tobit((v_r + 21))], 8)), lshift(U8[tobit((v_r + 22))], 16)), lshift(U8[tobit((v_r + 23))], 24))
v_e = I32[arshift((v_A + 12), 2)]
local t108 = v_e
v_Q = bor(bor(bor(U8[bor(0, v_r)], lshift(U8[tobit((v_r + 1))], 8)), lshift(U8[tobit((v_r + 2))], 16)), lshift(U8[tobit((v_r + 3))], 24))
local t104 = v_Q
v_y = I32[arshift((v_A + 8), 2)]
local t107 = tobit((t104 + v_y))
v_s = I32[arshift((v_A + 20), 2)]
local t106 = v_s
local t105 = v_s
v_n = I32[arshift((v_A + 16), 2)]
v_w = tobit((t108 + F.fKA(tobit((tobit((t107 + bxor(t106, band(bxor(t105, v_n), v_e)))) - 680876936)), 7)))
v_l = bor(bor(bor(U8[tobit((v_r + 12))], lshift(U8[tobit((v_r + 13))], 8)), lshift(U8[tobit((v_r + 14))], 16)), lshift(U8[tobit((v_r + 15))], 24))
v_b = bor(bor(bor(U8[tobit((v_r + 8))], lshift(U8[tobit((v_r + 9))], 8)), lshift(U8[tobit((v_r + 10))], 16)), lshift(U8[tobit((v_r + 11))], 24))
v_E = tobit((F.fKA(tobit((tobit((tobit((v_c + v_s)) + bxor(band(v_w, bxor(v_e, v_n)), v_n))) - 389564586)), 12) + v_w))
v_C = tobit((F.fKA(tobit((606105819 + tobit((tobit((v_b + v_n)) + bxor(band(v_E, bxor(v_w, v_e)), v_e))))), 17) + v_E))
v_B = tobit((F.fKA(tobit((tobit((tobit((v_e + v_l)) + bxor(v_w, band(v_C, bxor(v_w, v_E))))) - 1044525330)), 22) + v_C))
v_w = tobit((F.fKA(tobit((tobit((tobit((v_w + v_t)) + bxor(v_E, band(v_B, bxor(v_C, v_E))))) - 176418897)), 7) + v_B))
v_v = bor(bor(bor(U8[tobit((v_r + 28))], lshift(U8[tobit((v_r + 29))], 8)), lshift(U8[tobit((v_r + 30))], 16)), lshift(U8[tobit((v_r + 31))], 24))
v_g = bor(bor(bor(U8[tobit((v_r + 24))], lshift(U8[tobit((v_r + 25))], 8)), lshift(U8[tobit((v_r + 26))], 16)), lshift(U8[tobit((v_r + 27))], 24))
v_E = tobit((F.fKA(tobit((1200080426 + tobit((tobit((v_E + v_I)) + bxor(v_C, band(v_w, bxor(v_C, v_B))))))), 12) + v_w))
v_C = tobit((F.fKA(tobit((tobit((tobit((v_C + v_g)) + bxor(v_B, band(v_E, bxor(v_w, v_B))))) - 1473231341)), 17) + v_E))
v_B = tobit((F.fKA(tobit((tobit((tobit((v_B + v_v)) + bxor(v_w, band(v_C, bxor(v_w, v_E))))) - 45705983)), 22) + v_C))
v_w = tobit((F.fKA(tobit((1770035416 + tobit((tobit((v_w + v_m)) + bxor(v_E, band(v_B, bxor(v_C, v_E))))))), 7) + v_B))
v_p = bor(bor(bor(U8[tobit((v_r + 44))], lshift(U8[tobit((v_r + 45))], 8)), lshift(U8[tobit((v_r + 46))], 16)), lshift(U8[tobit((v_r + 47))], 24))
v_d = bor(bor(bor(U8[tobit((v_r + 40))], lshift(U8[tobit((v_r + 41))], 8)), lshift(U8[tobit((v_r + 42))], 16)), lshift(U8[tobit((v_r + 43))], 24))
v_E = tobit((F.fKA(tobit((tobit((tobit((v_E + v_a)) + bxor(v_C, band(v_w, bxor(v_C, v_B))))) - 1958414417)), 12) + v_w))
v_C = tobit((F.fKA(tobit((tobit((tobit((v_d + v_C)) + bxor(v_B, band(v_E, bxor(v_w, v_B))))) - 42063)), 17) + v_E))
v_B = tobit((F.fKA(tobit((tobit((tobit((v_B + v_p)) + bxor(v_w, band(v_C, bxor(v_w, v_E))))) - 1990404162)), 22) + v_C))
v_w = tobit((F.fKA(tobit((1804603682 + tobit((tobit((v_w + v_o)) + bxor(v_E, band(v_B, bxor(v_C, v_E))))))), 7) + v_B))
v_h = bor(bor(bor(U8[tobit((v_r + 60))], lshift(U8[tobit((v_r + 61))], 8)), lshift(U8[tobit((v_r + 62))], 16)), lshift(U8[tobit((v_r + 63))], 24))
v_O = tobit((v_w + v_c))
v_k = bor(bor(bor(U8[tobit((v_r + 56))], lshift(U8[tobit((v_r + 57))], 8)), lshift(U8[tobit((v_r + 58))], 16)), lshift(U8[tobit((v_r + 59))], 24))
v_E = tobit((F.fKA(tobit((tobit((tobit((v_E + v_u)) + bxor(v_C, band(v_w, bxor(v_C, v_B))))) - 40341101)), 12) + v_w))
v_r = tobit((F.fKA(tobit((tobit((tobit((v_k + v_C)) + bxor(v_B, band(v_E, bxor(v_w, v_B))))) - 1502002290)), 17) + v_E))
v_w = tobit((F.fKA(tobit((1236535329 + tobit((tobit((v_B + v_h)) + bxor(v_w, band(v_r, bxor(v_w, v_E))))))), 22) + v_r))
v_C = tobit((F.fKA(tobit((tobit((v_O + bxor(band(bxor(v_r, v_w), v_E), v_r))) - 165796510)), 5) + v_w))
v_B = tobit((v_r + v_p))
v_r = tobit((F.fKA(tobit((tobit((tobit((v_E + v_g)) + bxor(v_w, band(v_r, bxor(v_w, v_C))))) - 1069501632)), 9) + v_C))
v_E = tobit((F.fKA(tobit((643717713 + tobit((v_B + bxor(v_C, band(v_w, bxor(v_r, v_C))))))), 14) + v_r))
v_w = tobit((F.fKA(tobit((tobit((tobit((v_w + v_Q)) + bxor(v_r, band(v_C, bxor(v_r, v_E))))) - 373897302)), 20) + v_E))
v_C = tobit((F.fKA(tobit((tobit((tobit((v_C + v_I)) + bxor(band(bxor(v_E, v_w), v_r), v_E))) - 701558691)), 5) + v_w))
v_r = tobit((F.fKA(tobit((38016083 + tobit((tobit((v_r + v_d)) + bxor(v_w, band(v_E, bxor(v_w, v_C))))))), 9) + v_C))
v_E = tobit((F.fKA(tobit((tobit((tobit((v_E + v_h)) + bxor(v_C, band(v_w, bxor(v_r, v_C))))) - 660478335)), 14) + v_r))
v_w = tobit((F.fKA(tobit((tobit((tobit((v_w + v_t)) + bxor(v_r, band(v_C, bxor(v_r, v_E))))) - 405537848)), 20) + v_E))
v_C = tobit((F.fKA(tobit((568446438 + tobit((tobit((v_C + v_a)) + bxor(band(bxor(v_E, v_w), v_r), v_E))))), 5) + v_w))
v_B = tobit((v_E + v_l))
v_E = tobit((F.fKA(tobit((tobit((tobit((v_r + v_k)) + bxor(v_w, band(v_E, bxor(v_w, v_C))))) - 1019803690)), 9) + v_C))
v_B = tobit((F.fKA(tobit((tobit((v_B + bxor(v_C, band(v_w, bxor(v_E, v_C))))) - 187363961)), 14) + v_E))
v_w = tobit((F.fKA(tobit((1163531501 + tobit((tobit((v_w + v_m)) + bxor(v_E, band(v_C, bxor(v_E, v_B))))))), 20) + v_B))
v_r = tobit((F.fKA(tobit((tobit((tobit((v_C + v_u)) + bxor(band(bxor(v_B, v_w), v_E), v_B))) - 1444681467)), 5) + v_w))
v_C = tobit((F.fKA(tobit((tobit((tobit((v_E + v_b)) + bxor(v_w, band(v_B, bxor(v_r, v_w))))) - 51403784)), 9) + v_r))
v_E = tobit((F.fKA(tobit((1735328473 + tobit((tobit((v_B + v_v)) + bxor(v_r, band(v_w, bxor(v_C, v_r))))))), 14) + v_C))
v_O = tobit((v_C + v_m))
local t110 = tobit((v_w + v_o))
local t109 = v_C
v_B = bxor(v_C, v_E)
v_w = tobit((F.fKA(tobit((tobit((t110 + bxor(t109, band(v_B, v_r)))) - 1926607734)), 20) + v_E))
v_C = tobit((F.fKA(tobit((tobit((tobit((v_r + v_I)) + bxor(v_w, v_B))) - 378558)), 4) + v_w))
v_r = tobit((F.fKA(tobit((tobit((v_O + bxor(bxor(v_w, v_E), v_C))) - 2022574463)), 11) + v_C))
v_E = tobit((F.fKA(tobit((1839030562 + tobit((tobit((v_E + v_p)) + bxor(bxor(v_r, v_w), v_C))))), 16) + v_r))
v_w = tobit((F.fKA(tobit((tobit((tobit((v_w + v_k)) + bxor(bxor(v_E, v_r), v_C))) - 35309556)), 23) + v_E))
v_C = tobit((F.fKA(tobit((tobit((tobit((v_C + v_c)) + bxor(bxor(v_w, v_r), v_E))) - 1530992060)), 4) + v_w))
v_r = tobit((F.fKA(tobit((1272893353 + tobit((tobit((v_r + v_t)) + bxor(bxor(v_C, v_w), v_E))))), 11) + v_C))
v_E = tobit((F.fKA(tobit((tobit((tobit((v_E + v_v)) + bxor(bxor(v_r, v_w), v_C))) - 155497632)), 16) + v_r))
v_w = tobit((F.fKA(tobit((tobit((tobit((v_w + v_d)) + bxor(bxor(v_E, v_r), v_C))) - 1094730640)), 23) + v_E))
v_C = tobit((F.fKA(tobit((681279174 + tobit((tobit((v_C + v_u)) + bxor(bxor(v_w, v_r), v_E))))), 4) + v_w))
v_r = tobit((F.fKA(tobit((tobit((tobit((v_r + v_Q)) + bxor(bxor(v_C, v_w), v_E))) - 358537222)), 11) + v_C))
v_E = tobit((F.fKA(tobit((tobit((tobit((v_E + v_l)) + bxor(bxor(v_r, v_w), v_C))) - 722521979)), 16) + v_r))
v_w = tobit((F.fKA(tobit((76029189 + tobit((tobit((v_w + v_g)) + bxor(bxor(v_E, v_r), v_C))))), 23) + v_E))
v_C = tobit((F.fKA(tobit((tobit((tobit((v_C + v_a)) + bxor(bxor(v_w, v_r), v_E))) - 640364487)), 4) + v_w))
v_B = tobit((v_C + v_Q))
v_r = tobit((F.fKA(tobit((tobit((tobit((v_r + v_o)) + bxor(bxor(v_C, v_w), v_E))) - 421815835)), 11) + v_C))
v_Q = bxor(v_r, v_C)
v_C = tobit((F.fKA(tobit((530742520 + tobit((tobit((v_E + v_h)) + bxor(bxor(v_r, v_w), v_C))))), 16) + v_r))
v_E = tobit((F.fKA(tobit((tobit((tobit((v_w + v_b)) + bxor(v_Q, v_C))) - 995338651)), 23) + v_C))
v_w = tobit((F.fKA(tobit((tobit((v_B + bxor(bor(v_E, bxor((-1), v_r)), v_C))) - 198630844)), 6) + v_E))
v_B = tobit((v_E + v_I))
v_I = tobit((v_C + v_k))
v_C = tobit((F.fKA(tobit((1126891415 + tobit((tobit((v_r + v_v)) + bxor(v_E, bor(v_w, bxor((-1), v_C))))))), 10) + v_w))
v_E = tobit((F.fKA(tobit((tobit((v_I + bxor(v_w, bor(v_C, bxor((-1), v_E))))) - 1416354905)), 15) + v_C))
v_r = tobit((F.fKA(tobit((tobit((v_B + bxor(bor(v_E, bxor((-1), v_w)), v_C))) - 57434055)), 21) + v_E))
v_B = tobit((v_E + v_d))
v_I = tobit((v_C + v_l))
v_C = tobit((F.fKA(tobit((1700485571 + tobit((tobit((v_w + v_o)) + bxor(v_E, bor(v_r, bxor((-1), v_C))))))), 6) + v_r))
v_E = tobit((F.fKA(tobit((tobit((v_I + bxor(v_r, bor(v_C, bxor((-1), v_E))))) - 1894986606)), 10) + v_C))
v_w = tobit((F.fKA(tobit((tobit((v_B + bxor(bor(v_E, bxor((-1), v_r)), v_C))) - 1051523)), 15) + v_E))
v_B = tobit((v_E + v_h))
v_m = tobit((v_C + v_m))
v_C = tobit((F.fKA(tobit((tobit((tobit((v_r + v_c)) + bxor(v_E, bor(v_w, bxor((-1), v_C))))) - 2054922799)), 21) + v_w))
v_E = tobit((F.fKA(tobit((1873313359 + tobit((v_m + bxor(v_w, bor(v_C, bxor((-1), v_E))))))), 6) + v_C))
v_r = tobit((F.fKA(tobit((tobit((v_B + bxor(bor(v_E, bxor((-1), v_w)), v_C))) - 30611744)), 10) + v_E))
v_w = tobit((F.fKA(tobit((tobit((tobit((v_w + v_g)) + bxor(v_E, bor(v_r, bxor((-1), v_C))))) - 1560198380)), 15) + v_r))
v_C = tobit((F.fKA(tobit((1309151649 + tobit((tobit((v_C + v_u)) + bxor(v_r, bor(v_w, bxor((-1), v_E))))))), 21) + v_w))
v_E = tobit((F.fKA(tobit((tobit((tobit((v_E + v_t)) + bxor(bor(v_C, bxor((-1), v_r)), v_w))) - 145523070)), 6) + v_C))
I32[arshift((v_A + 8), 2)] = tobit((v_E + v_y))
v_r = tobit((F.fKA(tobit((tobit((tobit((v_r + v_p)) + bxor(v_C, bor(v_E, bxor((-1), v_w))))) - 1120210379)), 10) + v_E))
I32[arshift((v_A + 20), 2)] = tobit((v_r + v_s))
v_w = tobit((F.fKA(tobit((718787259 + tobit((tobit((v_w + v_b)) + bxor(v_E, bor(v_r, bxor((-1), v_C))))))), 15) + v_r))
I32[arshift((v_A + 16), 2)] = tobit((v_w + v_n))
I32[arshift((v_A + 12), 2)] = tobit((F.fKA(tobit((tobit((tobit((v_C + v_a)) + bxor(v_r, bor(v_w, bxor((-1), v_E))))) - 343485551)), 21) + tobit((v_w + v_e))))
end
end

F.fj = function(v_A, v_r, v_e)
local v_t, v_o, v_a, v_u, v_c, v_s, v_l, v_b, v_v, v_g, v_p, v_d, v_h, v_k, v_y, v_w, v_C, v_E, v_I, v_m, v_Q, v_O, v_S, v_M = 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
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
v_d = 0
v_h = 0
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
v_M = 0
v_c = I32[arshift((v_A + 4), 2)]
v_o = U8[tobit((v_r + 3))]
v_a = U8[tobit((v_r + 1))]
v_u = U8[tobit((v_r + 2))]
v_t = tobit((B - 48))
v_s = U8[bor(0, v_r)]
I8[tobit((v_t + 40))] = tobit(v_s)
v_o = bxor(I32[arshift(v_c, 2)], bor(bor(bor(v_s, lshift(v_a, 8)), lshift(v_u, 16)), lshift(v_o, 24)))
I8[tobit((v_t + 40))] = tobit(v_o)
I8[tobit((v_t + 39))] = tobit((rshift(v_o, 8) % 4294967296))
I8[tobit((v_t + 38))] = tobit((rshift(v_o, 16) % 4294967296))
I8[tobit((v_t + 37))] = tobit((rshift(v_o, 24) % 4294967296))
v_o = bxor(I32[arshift((v_c + 4), 2)], bor(bor(bor(U8[tobit((v_r + 4))], lshift(U8[tobit((v_r + 5))], 8)), lshift(U8[tobit((v_r + 6))], 16)), lshift(U8[tobit((v_r + 7))], 24)))
I8[tobit((v_t + 36))] = tobit(v_o)
v_l = tobit((rshift(v_o, 8) % 4294967296))
I8[tobit((v_t + 35))] = tobit(v_l)
v_v = tobit((rshift(v_o, 16) % 4294967296))
I8[tobit((v_t + 34))] = tobit(v_v)
v_g = tobit((rshift(v_o, 24) % 4294967296))
I8[tobit((v_t + 33))] = tobit(v_g)
v_a = bor(bor(bor(U8[tobit((v_r + 8))], lshift(U8[tobit((v_r + 9))], 8)), lshift(U8[tobit((v_r + 10))], 16)), lshift(U8[tobit((v_r + 11))], 24))
I32[arshift((v_t + 44), 2)] = tobit((v_c + 12))
v_a = bxor(v_a, I32[arshift((v_c + 8), 2)])
I8[tobit((v_t + 32))] = tobit(v_a)
v_p = tobit((rshift(v_a, 8) % 4294967296))
I8[tobit((v_t + 31))] = tobit(v_p)
v_d = tobit((rshift(v_a, 16) % 4294967296))
I8[tobit((v_t + 30))] = tobit(v_d)
v_h = tobit((rshift(v_a, 24) % 4294967296))
I8[tobit((v_t + 29))] = tobit(v_h)
v_u = bxor(I32[arshift((v_c + 12), 2)], bor(bor(bor(U8[tobit((v_r + 12))], lshift(U8[tobit((v_r + 13))], 8)), lshift(U8[tobit((v_r + 14))], 16)), lshift(U8[tobit((v_r + 15))], 24)))
I8[tobit((v_t + 28))] = tobit(v_u)
v_k = tobit((rshift(v_u, 8) % 4294967296))
I8[tobit((v_t + 27))] = tobit(v_k)
v_y = tobit((rshift(v_u, 16) % 4294967296))
I8[tobit((v_t + 26))] = tobit(v_y)
v_w = tobit((rshift(v_u, 24) % 4294967296))
I8[tobit((v_t + 25))] = tobit(v_w)
v_r = tobit((v_c + 16))
v_A = I32[arshift(v_A, 2)]
if (bor(0, v_A) <= 3) then
v_C = U8[tobit((v_t + 37))]
v_E = U8[tobit((v_t + 38))]
else
do
v_I = tobit((rshift(v_A, 1) % 4294967296))
v_m = U8[tobit((v_t + 39))]
v_C = U8[tobit((v_t + 37))]
v_E = U8[tobit((v_t + 38))]
while true do
v_A = bxor(bxor(bxor(bxor(I32[arshift((26608 + lshift(v_g, 2)), 2)], I32[arshift((25584 + lshift(band(255, v_d), 2)), 2)]), I32[arshift((24560 + lshift(band(255, v_k), 2)), 2)]), I32[arshift((23536 + lshift(U8[tobit((v_t + 40))], 2)), 2)]), I32[arshift(v_r, 2)])
I8[tobit((v_t + 24))] = tobit(v_A)
v_c = bxor(bxor(bxor(bxor(I32[arshift((26608 + lshift(v_h, 2)), 2)], I32[arshift((25584 + lshift(band(255, v_y), 2)), 2)]), I32[arshift((24560 + lshift(band(255, v_m), 2)), 2)]), I32[arshift((23536 + lshift(band(255, v_o), 2)), 2)]), I32[arshift((v_r + 4), 2)])
I8[tobit((v_t + 20))] = tobit(v_c)
v_s = bxor(bxor(bxor(bxor(I32[arshift((26608 + lshift(v_w, 2)), 2)], I32[arshift((25584 + lshift(band(255, v_E), 2)), 2)]), I32[arshift((24560 + lshift(band(255, v_l), 2)), 2)]), I32[arshift((23536 + lshift(band(255, v_a), 2)), 2)]), I32[arshift((v_r + 8), 2)])
I8[tobit((v_t + 16))] = tobit(v_s)
v_b = bxor(bxor(bxor(bxor(I32[arshift((26608 + lshift(v_C, 2)), 2)], I32[arshift((25584 + lshift(band(255, v_v), 2)), 2)]), I32[arshift((24560 + lshift(band(255, v_p), 2)), 2)]), I32[arshift((23536 + lshift(band(255, v_u), 2)), 2)]), I32[arshift((v_r + 12), 2)])
I8[tobit((v_t + 12))] = tobit(v_b)
v_Q = tobit((rshift(v_c, 24) % 4294967296))
v_l = bxor(bxor(bxor(bxor(I32[arshift((26608 + lshift(v_Q, 2)), 2)], I32[arshift((25584 + band((rshift(v_s, 14) % 4294967296), 1020)), 2)]), I32[arshift((24560 + band((rshift(v_b, 6) % 4294967296), 1020)), 2)]), I32[arshift((23536 + lshift(band(255, v_A), 2)), 2)]), I32[arshift((v_r + 16), 2)])
I8[tobit((v_t + 40))] = tobit(v_l)
v_O = tobit((rshift(v_s, 24) % 4294967296))
v_o = bxor(bxor(bxor(bxor(I32[arshift((26608 + lshift(v_O, 2)), 2)], I32[arshift((25584 + band((rshift(v_b, 14) % 4294967296), 1020)), 2)]), I32[arshift((24560 + band((rshift(v_A, 6) % 4294967296), 1020)), 2)]), I32[arshift((23536 + lshift(band(255, v_c), 2)), 2)]), I32[arshift((v_r + 20), 2)])
I8[tobit((v_t + 36))] = tobit(v_o)
v_a = bxor(bxor(bxor(bxor(I32[arshift((26608 + band((rshift(v_b, 22) % 4294967296), 1020)), 2)], I32[arshift((25584 + band((rshift(v_A, 14) % 4294967296), 1020)), 2)]), I32[arshift((24560 + band((rshift(v_c, 6) % 4294967296), 1020)), 2)]), I32[arshift((23536 + lshift(band(255, v_s), 2)), 2)]), I32[arshift((v_r + 24), 2)])
I8[tobit((v_t + 32))] = tobit(v_a)
v_S = tobit((rshift(v_A, 24) % 4294967296))
v_u = bxor(bxor(bxor(bxor(I32[arshift((26608 + lshift(v_S, 2)), 2)], I32[arshift((25584 + band((rshift(v_c, 14) % 4294967296), 1020)), 2)]), I32[arshift((24560 + band((rshift(v_s, 6) % 4294967296), 1020)), 2)]), I32[arshift((23536 + lshift(band(255, v_b), 2)), 2)]), I32[arshift((v_r + 28), 2)])
I8[tobit((v_t + 28))] = tobit(v_u)
v_C = tobit((rshift(v_l, 24) % 4294967296))
v_E = tobit((rshift(v_l, 16) % 4294967296))
v_m = tobit((rshift(v_l, 8) % 4294967296))
v_g = tobit((rshift(v_o, 24) % 4294967296))
v_v = tobit((rshift(v_o, 16) % 4294967296))
v_l = tobit((rshift(v_o, 8) % 4294967296))
v_h = tobit((rshift(v_a, 24) % 4294967296))
v_d = tobit((rshift(v_a, 16) % 4294967296))
v_p = tobit((rshift(v_a, 8) % 4294967296))
v_w = tobit((rshift(v_u, 24) % 4294967296))
v_y = tobit((rshift(v_u, 16) % 4294967296))
v_k = tobit((rshift(v_u, 8) % 4294967296))
v_r = tobit((v_r + 32))
v_M = ((bor(0, v_I) > 2) and 1 or 0)
v_I = tobit((v_I - 1))
if not (v_M ~= 0) then goto B131 end
do
end
::C131::
end
end
::B131::
I8[tobit((v_t + 23))] = tobit((rshift(v_A, 8) % 4294967296))
I8[tobit((v_t + 39))] = tobit(v_m)
I8[tobit((v_t + 22))] = tobit((rshift(v_A, 16) % 4294967296))
I8[tobit((v_t + 21))] = tobit(v_S)
I8[tobit((v_t + 19))] = tobit((rshift(v_c, 8) % 4294967296))
I8[tobit((v_t + 18))] = tobit((rshift(v_c, 16) % 4294967296))
I8[tobit((v_t + 17))] = tobit(v_Q)
I8[tobit((v_t + 15))] = tobit((rshift(v_s, 8) % 4294967296))
I8[tobit((v_t + 14))] = tobit((rshift(v_s, 16) % 4294967296))
I8[tobit((v_t + 13))] = tobit(v_O)
I8[tobit((v_t + 11))] = tobit((rshift(v_b, 8) % 4294967296))
I8[tobit((v_t + 10))] = tobit((rshift(v_b, 16) % 4294967296))
end
v_u = bxor(bxor(bxor(bxor(I32[arshift((26608 + lshift(v_C, 2)), 2)], I32[arshift((25584 + lshift(band(255, v_v), 2)), 2)]), I32[arshift((24560 + lshift(band(255, v_p), 2)), 2)]), I32[arshift((23536 + lshift(band(255, v_u), 2)), 2)]), I32[arshift((v_r + 12), 2)])
v_c = U8[tobit((31728 + band((rshift(v_u, 8) % 4294967296), 255)))]
v_A = bxor(bxor(bxor(bxor(I32[arshift((26608 + lshift(v_w, 2)), 2)], I32[arshift((25584 + lshift(band(255, v_E), 2)), 2)]), I32[arshift((24560 + lshift(band(255, v_l), 2)), 2)]), I32[arshift((23536 + lshift(band(255, v_a), 2)), 2)]), I32[arshift((v_r + 8), 2)])
v_s = U8[tobit((31728 + band((rshift(v_A, 16) % 4294967296), 255)))]
v_b = U8[tobit((31728 + band((rshift(v_u, 16) % 4294967296), 255)))]
v_o = bxor(bxor(bxor(bxor(I32[arshift((26608 + lshift(v_h, 2)), 2)], I32[arshift((25584 + lshift(band(255, v_y), 2)), 2)]), I32[arshift((24560 + lshift(U8[tobit((v_t + 39))], 2)), 2)]), I32[arshift((23536 + lshift(band(255, v_o), 2)), 2)]), I32[arshift((v_r + 4), 2)])
v_C = U8[tobit((31728 + band((rshift(v_o, 8) % 4294967296), 255)))]
v_E = U8[tobit((31728 + band((rshift(v_A, 8) % 4294967296), 255)))]
v_l = U8[tobit((31728 + band((rshift(v_o, 16) % 4294967296), 255)))]
v_v = U8[tobit((31728 + tobit((rshift(v_o, 24) % 4294967296))))]
v_a = bxor(bxor(bxor(bxor(I32[arshift((26608 + lshift(v_g, 2)), 2)], I32[arshift((25584 + lshift(band(255, v_d), 2)), 2)]), I32[arshift((24560 + lshift(band(255, v_k), 2)), 2)]), I32[arshift((23536 + lshift(U8[tobit((v_t + 40))], 2)), 2)]), I32[arshift(v_r, 2)])
v_g = U8[tobit((31728 + band((rshift(v_a, 8) % 4294967296), 255)))]
v_p = U8[tobit((31728 + tobit((rshift(v_A, 24) % 4294967296))))]
v_d = U8[tobit((31728 + band((rshift(v_a, 16) % 4294967296), 255)))]
v_h = U8[tobit((31728 + tobit((rshift(v_u, 24) % 4294967296))))]
v_k = U8[tobit((31728 + tobit((rshift(v_a, 24) % 4294967296))))]
v_y = U8[tobit((31728 + band(255, v_a)))]
v_w = U8[tobit((31728 + band(255, v_o)))]
v_I = U8[tobit((31728 + band(255, v_A)))]
v_A = I32[arshift((v_r + 16), 2)]
v_o = I32[arshift((v_r + 20), 2)]
v_a = I32[arshift((v_r + 24), 2)]
v_r = I32[arshift((v_r + 28), 2)]
I8[tobit((v_e + 12))] = tobit(bxor(v_r, U8[tobit((31728 + band(255, v_u)))]))
I8[tobit((v_e + 8))] = tobit(bxor(v_a, v_I))
I8[tobit((v_e + 4))] = tobit(bxor(v_o, v_w))
I8[bor(0, v_e)] = tobit(bxor(v_A, v_y))
I8[tobit((v_e + 15))] = tobit((rshift(bxor(v_r, lshift(v_k, 24)), 24) % 4294967296))
I8[tobit((v_e + 11))] = tobit((rshift(bxor(v_a, lshift(v_h, 24)), 24) % 4294967296))
I8[tobit((v_e + 10))] = tobit((rshift(bxor(v_a, lshift(v_d, 16)), 16) % 4294967296))
I8[tobit((v_e + 7))] = tobit((rshift(bxor(v_o, lshift(v_p, 24)), 24) % 4294967296))
I8[tobit((v_e + 5))] = tobit((rshift(bxor(v_o, lshift(v_g, 8)), 8) % 4294967296))
I8[tobit((v_e + 3))] = tobit((rshift(bxor(v_A, lshift(v_v, 24)), 24) % 4294967296))
I8[tobit((v_e + 14))] = tobit((rshift(bxor(v_r, lshift(v_l, 16)), 16) % 4294967296))
I8[tobit((v_e + 13))] = tobit((rshift(bxor(v_r, lshift(v_E, 8)), 8) % 4294967296))
I8[tobit((v_e + 9))] = tobit((rshift(bxor(v_a, lshift(v_C, 8)), 8) % 4294967296))
I8[tobit((v_e + 6))] = tobit((rshift(bxor(v_o, lshift(v_b, 16)), 16) % 4294967296))
I8[tobit((v_e + 2))] = tobit((rshift(bxor(v_A, lshift(v_s, 16)), 16) % 4294967296))
I8[tobit((v_e + 1))] = tobit((rshift(bxor(v_A, lshift(v_c, 8)), 8) % 4294967296))
I8[tobit((v_t + 40))] = tobit(0)
I8[tobit((v_t + 39))] = tobit(0)
I8[tobit((v_t + 38))] = tobit(0)
I8[tobit((v_t + 37))] = tobit(0)
I8[tobit((v_t + 36))] = tobit(0)
I8[tobit((v_t + 35))] = tobit(0)
I8[tobit((v_t + 34))] = tobit(0)
I8[tobit((v_t + 33))] = tobit(0)
I8[tobit((v_t + 32))] = tobit(0)
I8[tobit((v_t + 31))] = tobit(0)
I8[tobit((v_t + 30))] = tobit(0)
I8[tobit((v_t + 29))] = tobit(0)
I8[tobit((v_t + 28))] = tobit(0)
I8[tobit((v_t + 27))] = tobit(0)
I8[tobit((v_t + 26))] = tobit(0)
I8[tobit((v_t + 25))] = tobit(0)
I8[tobit((v_t + 24))] = tobit(0)
I8[tobit((v_t + 23))] = tobit(0)
I8[tobit((v_t + 22))] = tobit(0)
I8[tobit((v_t + 21))] = tobit(0)
I8[tobit((v_t + 20))] = tobit(0)
I8[tobit((v_t + 19))] = tobit(0)
I8[tobit((v_t + 18))] = tobit(0)
I8[tobit((v_t + 17))] = tobit(0)
I8[tobit((v_t + 16))] = tobit(0)
I8[tobit((v_t + 15))] = tobit(0)
I8[tobit((v_t + 14))] = tobit(0)
I8[tobit((v_t + 13))] = tobit(0)
I8[tobit((v_t + 12))] = tobit(0)
I8[tobit((v_t + 11))] = tobit(0)
I8[tobit((v_t + 10))] = tobit(0)
I8[tobit((v_t + 9))] = tobit(0)
I8[tobit((v_t + 44))] = tobit(0)
I8[tobit((v_t + 45))] = tobit(0)
I8[tobit((v_t + 46))] = tobit(0)
I8[tobit((v_t + 47))] = tobit(0)
end

F.fT = function(v_A, v_r, v_e)
local v_t, v_o, v_a, v_u, v_c, v_s, v_l, v_b, v_v, v_g, v_p, v_d, v_h, v_k, v_y, v_w, v_C, v_E, v_I, v_m, v_Q, v_O, v_S, v_M = 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
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
v_d = 0
v_h = 0
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
v_M = 0
v_c = I32[arshift((v_A + 4), 2)]
v_o = U8[tobit((v_r + 3))]
v_a = U8[tobit((v_r + 1))]
v_u = U8[tobit((v_r + 2))]
v_t = tobit((B - 48))
v_s = U8[bor(0, v_r)]
I8[tobit((v_t + 40))] = tobit(v_s)
v_o = bxor(I32[arshift(v_c, 2)], bor(bor(bor(v_s, lshift(v_a, 8)), lshift(v_u, 16)), lshift(v_o, 24)))
I8[tobit((v_t + 40))] = tobit(v_o)
I8[tobit((v_t + 39))] = tobit((rshift(v_o, 8) % 4294967296))
I8[tobit((v_t + 38))] = tobit((rshift(v_o, 16) % 4294967296))
I8[tobit((v_t + 37))] = tobit((rshift(v_o, 24) % 4294967296))
v_o = bxor(I32[arshift((v_c + 4), 2)], bor(bor(bor(U8[tobit((v_r + 4))], lshift(U8[tobit((v_r + 5))], 8)), lshift(U8[tobit((v_r + 6))], 16)), lshift(U8[tobit((v_r + 7))], 24)))
I8[tobit((v_t + 36))] = tobit(v_o)
v_l = tobit((rshift(v_o, 8) % 4294967296))
I8[tobit((v_t + 35))] = tobit(v_l)
v_v = tobit((rshift(v_o, 16) % 4294967296))
I8[tobit((v_t + 34))] = tobit(v_v)
v_g = tobit((rshift(v_o, 24) % 4294967296))
I8[tobit((v_t + 33))] = tobit(v_g)
v_a = bor(bor(bor(U8[tobit((v_r + 8))], lshift(U8[tobit((v_r + 9))], 8)), lshift(U8[tobit((v_r + 10))], 16)), lshift(U8[tobit((v_r + 11))], 24))
I32[arshift((v_t + 44), 2)] = tobit((v_c + 12))
v_a = bxor(v_a, I32[arshift((v_c + 8), 2)])
I8[tobit((v_t + 32))] = tobit(v_a)
v_p = tobit((rshift(v_a, 8) % 4294967296))
I8[tobit((v_t + 31))] = tobit(v_p)
v_d = tobit((rshift(v_a, 16) % 4294967296))
I8[tobit((v_t + 30))] = tobit(v_d)
v_h = tobit((rshift(v_a, 24) % 4294967296))
I8[tobit((v_t + 29))] = tobit(v_h)
v_u = bxor(I32[arshift((v_c + 12), 2)], bor(bor(bor(U8[tobit((v_r + 12))], lshift(U8[tobit((v_r + 13))], 8)), lshift(U8[tobit((v_r + 14))], 16)), lshift(U8[tobit((v_r + 15))], 24)))
I8[tobit((v_t + 28))] = tobit(v_u)
v_k = tobit((rshift(v_u, 8) % 4294967296))
I8[tobit((v_t + 27))] = tobit(v_k)
v_y = tobit((rshift(v_u, 16) % 4294967296))
I8[tobit((v_t + 26))] = tobit(v_y)
v_w = tobit((rshift(v_u, 24) % 4294967296))
I8[tobit((v_t + 25))] = tobit(v_w)
v_r = tobit((v_c + 16))
v_A = I32[arshift(v_A, 2)]
if (bor(0, v_A) <= 3) then
v_C = U8[tobit((v_t + 37))]
v_E = U8[tobit((v_t + 38))]
else
do
v_I = tobit((rshift(v_A, 1) % 4294967296))
v_m = U8[tobit((v_t + 39))]
v_C = U8[tobit((v_t + 37))]
v_E = U8[tobit((v_t + 38))]
while true do
v_A = bxor(bxor(bxor(bxor(I32[arshift((30704 + lshift(v_w, 2)), 2)], I32[arshift((29680 + lshift(band(255, v_d), 2)), 2)]), I32[arshift((28656 + lshift(band(255, v_l), 2)), 2)]), I32[arshift((27632 + lshift(U8[tobit((v_t + 40))], 2)), 2)]), I32[arshift(v_r, 2)])
I8[tobit((v_t + 24))] = tobit(v_A)
v_c = bxor(bxor(bxor(bxor(I32[arshift((30704 + lshift(v_C, 2)), 2)], I32[arshift((29680 + lshift(band(255, v_y), 2)), 2)]), I32[arshift((28656 + lshift(band(255, v_p), 2)), 2)]), I32[arshift((27632 + lshift(band(255, v_o), 2)), 2)]), I32[arshift((v_r + 4), 2)])
I8[tobit((v_t + 20))] = tobit(v_c)
v_s = bxor(bxor(bxor(bxor(I32[arshift((30704 + lshift(v_g, 2)), 2)], I32[arshift((29680 + lshift(band(255, v_E), 2)), 2)]), I32[arshift((28656 + lshift(band(255, v_k), 2)), 2)]), I32[arshift((27632 + lshift(band(255, v_a), 2)), 2)]), I32[arshift((v_r + 8), 2)])
I8[tobit((v_t + 16))] = tobit(v_s)
v_b = bxor(bxor(bxor(bxor(I32[arshift((30704 + lshift(v_h, 2)), 2)], I32[arshift((29680 + lshift(band(255, v_v), 2)), 2)]), I32[arshift((28656 + lshift(band(255, v_m), 2)), 2)]), I32[arshift((27632 + lshift(band(255, v_u), 2)), 2)]), I32[arshift((v_r + 12), 2)])
I8[tobit((v_t + 12))] = tobit(v_b)
v_l = bxor(bxor(bxor(bxor(I32[arshift((30704 + band((rshift(v_b, 22) % 4294967296), 1020)), 2)], I32[arshift((29680 + band((rshift(v_s, 14) % 4294967296), 1020)), 2)]), I32[arshift((28656 + band((rshift(v_c, 6) % 4294967296), 1020)), 2)]), I32[arshift((27632 + lshift(band(255, v_A), 2)), 2)]), I32[arshift((v_r + 16), 2)])
I8[tobit((v_t + 40))] = tobit(v_l)
v_Q = tobit((rshift(v_A, 24) % 4294967296))
v_o = bxor(bxor(bxor(bxor(I32[arshift((30704 + lshift(v_Q, 2)), 2)], I32[arshift((29680 + band((rshift(v_b, 14) % 4294967296), 1020)), 2)]), I32[arshift((28656 + band((rshift(v_s, 6) % 4294967296), 1020)), 2)]), I32[arshift((27632 + lshift(band(255, v_c), 2)), 2)]), I32[arshift((v_r + 20), 2)])
I8[tobit((v_t + 36))] = tobit(v_o)
v_O = tobit((rshift(v_c, 24) % 4294967296))
v_a = bxor(bxor(bxor(bxor(I32[arshift((30704 + lshift(v_O, 2)), 2)], I32[arshift((29680 + band((rshift(v_A, 14) % 4294967296), 1020)), 2)]), I32[arshift((28656 + band((rshift(v_b, 6) % 4294967296), 1020)), 2)]), I32[arshift((27632 + lshift(band(255, v_s), 2)), 2)]), I32[arshift((v_r + 24), 2)])
I8[tobit((v_t + 32))] = tobit(v_a)
v_S = tobit((rshift(v_s, 24) % 4294967296))
v_u = bxor(bxor(bxor(bxor(I32[arshift((30704 + lshift(v_S, 2)), 2)], I32[arshift((29680 + band((rshift(v_c, 14) % 4294967296), 1020)), 2)]), I32[arshift((28656 + band((rshift(v_A, 6) % 4294967296), 1020)), 2)]), I32[arshift((27632 + lshift(band(255, v_b), 2)), 2)]), I32[arshift((v_r + 28), 2)])
I8[tobit((v_t + 28))] = tobit(v_u)
v_C = tobit((rshift(v_l, 24) % 4294967296))
v_E = tobit((rshift(v_l, 16) % 4294967296))
v_m = tobit((rshift(v_l, 8) % 4294967296))
v_g = tobit((rshift(v_o, 24) % 4294967296))
v_v = tobit((rshift(v_o, 16) % 4294967296))
v_l = tobit((rshift(v_o, 8) % 4294967296))
v_h = tobit((rshift(v_a, 24) % 4294967296))
v_d = tobit((rshift(v_a, 16) % 4294967296))
v_p = tobit((rshift(v_a, 8) % 4294967296))
v_w = tobit((rshift(v_u, 24) % 4294967296))
v_y = tobit((rshift(v_u, 16) % 4294967296))
v_k = tobit((rshift(v_u, 8) % 4294967296))
v_r = tobit((v_r + 32))
v_M = ((bor(0, v_I) > 2) and 1 or 0)
v_I = tobit((v_I - 1))
if not (v_M ~= 0) then goto B132 end
do
end
::C132::
end
end
::B132::
I8[tobit((v_t + 23))] = tobit((rshift(v_A, 8) % 4294967296))
I8[tobit((v_t + 39))] = tobit(v_m)
I8[tobit((v_t + 22))] = tobit((rshift(v_A, 16) % 4294967296))
I8[tobit((v_t + 21))] = tobit(v_Q)
I8[tobit((v_t + 19))] = tobit((rshift(v_c, 8) % 4294967296))
I8[tobit((v_t + 18))] = tobit((rshift(v_c, 16) % 4294967296))
I8[tobit((v_t + 17))] = tobit(v_O)
I8[tobit((v_t + 15))] = tobit((rshift(v_s, 8) % 4294967296))
I8[tobit((v_t + 14))] = tobit((rshift(v_s, 16) % 4294967296))
I8[tobit((v_t + 13))] = tobit(v_S)
I8[tobit((v_t + 11))] = tobit((rshift(v_b, 8) % 4294967296))
I8[tobit((v_t + 10))] = tobit((rshift(v_b, 16) % 4294967296))
end
v_A = bxor(bxor(bxor(bxor(I32[arshift((30704 + lshift(v_C, 2)), 2)], I32[arshift((29680 + lshift(band(255, v_y), 2)), 2)]), I32[arshift((28656 + lshift(band(255, v_p), 2)), 2)]), I32[arshift((27632 + lshift(band(255, v_o), 2)), 2)]), I32[arshift((v_r + 4), 2)])
v_c = U8[tobit((23280 + band((rshift(v_A, 8) % 4294967296), 255)))]
v_o = bxor(bxor(bxor(bxor(I32[arshift((30704 + lshift(v_g, 2)), 2)], I32[arshift((29680 + lshift(band(255, v_E), 2)), 2)]), I32[arshift((28656 + lshift(band(255, v_k), 2)), 2)]), I32[arshift((27632 + lshift(band(255, v_a), 2)), 2)]), I32[arshift((v_r + 8), 2)])
v_s = U8[tobit((23280 + band((rshift(v_o, 16) % 4294967296), 255)))]
v_b = U8[tobit((23280 + band((rshift(v_o, 8) % 4294967296), 255)))]
v_u = bxor(bxor(bxor(bxor(I32[arshift((30704 + lshift(v_h, 2)), 2)], I32[arshift((29680 + lshift(band(255, v_v), 2)), 2)]), I32[arshift((28656 + lshift(U8[tobit((v_t + 39))], 2)), 2)]), I32[arshift((27632 + lshift(band(255, v_u), 2)), 2)]), I32[arshift((v_r + 12), 2)])
v_C = U8[tobit((23280 + band((rshift(v_u, 16) % 4294967296), 255)))]
v_E = U8[tobit((23280 + band((rshift(v_u, 8) % 4294967296), 255)))]
v_v = U8[tobit((23280 + band((rshift(v_A, 16) % 4294967296), 255)))]
v_g = U8[tobit((23280 + tobit((rshift(v_u, 24) % 4294967296))))]
v_a = bxor(bxor(bxor(bxor(I32[arshift((30704 + lshift(v_w, 2)), 2)], I32[arshift((29680 + lshift(band(255, v_d), 2)), 2)]), I32[arshift((28656 + lshift(band(255, v_l), 2)), 2)]), I32[arshift((27632 + lshift(U8[tobit((v_t + 40))], 2)), 2)]), I32[arshift(v_r, 2)])
v_l = U8[tobit((23280 + band((rshift(v_a, 16) % 4294967296), 255)))]
v_p = U8[tobit((23280 + tobit((rshift(v_A, 24) % 4294967296))))]
v_d = U8[tobit((23280 + band((rshift(v_a, 8) % 4294967296), 255)))]
v_h = U8[tobit((23280 + tobit((rshift(v_o, 24) % 4294967296))))]
v_k = U8[tobit((23280 + tobit((rshift(v_a, 24) % 4294967296))))]
v_y = U8[tobit((23280 + band(255, v_a)))]
v_w = U8[tobit((23280 + band(255, v_A)))]
v_I = U8[tobit((23280 + band(255, v_o)))]
v_A = I32[arshift((v_r + 16), 2)]
v_o = I32[arshift((v_r + 20), 2)]
v_a = I32[arshift((v_r + 24), 2)]
v_r = I32[arshift((v_r + 28), 2)]
I8[tobit((v_e + 12))] = tobit(bxor(v_r, U8[tobit((23280 + band(255, v_u)))]))
I8[tobit((v_e + 8))] = tobit(bxor(v_a, v_I))
I8[tobit((v_e + 4))] = tobit(bxor(v_o, v_w))
I8[bor(0, v_e)] = tobit(bxor(v_A, v_y))
I8[tobit((v_e + 7))] = tobit((rshift(bxor(v_o, lshift(v_k, 24)), 24) % 4294967296))
I8[tobit((v_e + 15))] = tobit((rshift(bxor(v_r, lshift(v_h, 24)), 24) % 4294967296))
I8[tobit((v_e + 13))] = tobit((rshift(bxor(v_r, lshift(v_d, 8)), 8) % 4294967296))
I8[tobit((v_e + 11))] = tobit((rshift(bxor(v_a, lshift(v_p, 24)), 24) % 4294967296))
I8[tobit((v_e + 10))] = tobit((rshift(bxor(v_a, lshift(v_l, 16)), 16) % 4294967296))
I8[tobit((v_e + 3))] = tobit((rshift(bxor(v_A, lshift(v_g, 24)), 24) % 4294967296))
I8[tobit((v_e + 14))] = tobit((rshift(bxor(v_r, lshift(v_v, 16)), 16) % 4294967296))
I8[tobit((v_e + 9))] = tobit((rshift(bxor(v_a, lshift(v_E, 8)), 8) % 4294967296))
I8[tobit((v_e + 6))] = tobit((rshift(bxor(v_o, lshift(v_C, 16)), 16) % 4294967296))
I8[tobit((v_e + 5))] = tobit((rshift(bxor(v_o, lshift(v_b, 8)), 8) % 4294967296))
I8[tobit((v_e + 2))] = tobit((rshift(bxor(v_A, lshift(v_s, 16)), 16) % 4294967296))
I8[tobit((v_e + 1))] = tobit((rshift(bxor(v_A, lshift(v_c, 8)), 8) % 4294967296))
I8[tobit((v_t + 40))] = tobit(0)
I8[tobit((v_t + 39))] = tobit(0)
I8[tobit((v_t + 38))] = tobit(0)
I8[tobit((v_t + 37))] = tobit(0)
I8[tobit((v_t + 36))] = tobit(0)
I8[tobit((v_t + 35))] = tobit(0)
I8[tobit((v_t + 34))] = tobit(0)
I8[tobit((v_t + 33))] = tobit(0)
I8[tobit((v_t + 32))] = tobit(0)
I8[tobit((v_t + 31))] = tobit(0)
I8[tobit((v_t + 30))] = tobit(0)
I8[tobit((v_t + 29))] = tobit(0)
I8[tobit((v_t + 28))] = tobit(0)
I8[tobit((v_t + 27))] = tobit(0)
I8[tobit((v_t + 26))] = tobit(0)
I8[tobit((v_t + 25))] = tobit(0)
I8[tobit((v_t + 24))] = tobit(0)
I8[tobit((v_t + 23))] = tobit(0)
I8[tobit((v_t + 22))] = tobit(0)
I8[tobit((v_t + 21))] = tobit(0)
I8[tobit((v_t + 20))] = tobit(0)
I8[tobit((v_t + 19))] = tobit(0)
I8[tobit((v_t + 18))] = tobit(0)
I8[tobit((v_t + 17))] = tobit(0)
I8[tobit((v_t + 16))] = tobit(0)
I8[tobit((v_t + 15))] = tobit(0)
I8[tobit((v_t + 14))] = tobit(0)
I8[tobit((v_t + 13))] = tobit(0)
I8[tobit((v_t + 12))] = tobit(0)
I8[tobit((v_t + 11))] = tobit(0)
I8[tobit((v_t + 10))] = tobit(0)
I8[tobit((v_t + 9))] = tobit(0)
I8[tobit((v_t + 44))] = tobit(0)
I8[tobit((v_t + 45))] = tobit(0)
I8[tobit((v_t + 46))] = tobit(0)
I8[tobit((v_t + 47))] = tobit(0)
end

F.fP = function(v_A, v_r)
local v_e, v_n, v_t, v_o, v_a, v_u, v_c, v_s, v_l, v_b, v_v, v_g, v_p, v_d, v_h, v_k, v_y, v_w, v_C, v_E, v_I, v_m, v_Q, v_O, v_S, v_M = 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
v_n = 0
v_t = 0
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
v_d = 0
v_h = 0
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
v_M = 0
do
v_e = tobit((B - 256))
B = v_e
v_s = I32[arshift((v_A + 36), 2)]
v_h = I32[arshift((v_A + 32), 2)]
v_k = I32[arshift((v_A + 28), 2)]
v_y = I32[arshift((v_A + 24), 2)]
v_u = I32[arshift((v_A + 20), 2)]
v_l = I32[arshift((v_A + 16), 2)]
v_p = I32[arshift((v_A + 12), 2)]
v_d = I32[arshift((v_A + 8), 2)]
while true do
v_n = 1
v_o = lshift(v_t, 2)
I32[arshift((v_o + v_e), 2)] = tobit(bor(bor(bor(U8[tobit((bor(3, v_o) + v_r))], lshift(U8[tobit((bor(1, v_o) + v_r))], 16)), lshift(U8[tobit((v_r + v_o))], 24)), lshift(U8[tobit((bor(2, v_o) + v_r))], 8)))
v_t = tobit((v_t + 1))
if not (16 ~= bor(0, v_t)) then goto B133 end
do
end
::C133::
end
end
::B133::
do
do
while true do
do
v_C = lshift(v_S, 2)
v_S = 8
v_o = tobit((tobit((I32[arshift((v_e + v_C), 2)] + tobit((I32[arshift((v_C + 11248), 2)] + tobit((bxor(bxor(F.fKA(v_y, 26), F.fKA(v_y, 21)), F.fKA(v_y, 7)) + v_s)))))) + bxor(band(bxor(v_h, v_k), v_y), v_h)))
v_a = tobit((tobit((v_o + bxor(bxor(F.fKA(v_d, 30), F.fKA(v_d, 19)), F.fKA(v_d, 10)))) + bor(band(bor(v_d, v_p), v_l), band(v_d, v_p))))
v_t = tobit((bxor(bxor(F.fKA(v_a, 30), F.fKA(v_a, 19)), F.fKA(v_a, 10)) + bor(band(bor(v_a, v_d), v_p), band(v_a, v_d))))
v_c = tobit((v_o + v_u))
v_r = bor(4, v_C)
v_o = tobit((tobit((tobit((I32[arshift((11248 + v_r), 2)] + tobit((bxor(band(v_c, bxor(v_y, v_k)), v_k) + v_h)))) + bxor(bxor(F.fKA(v_c, 26), F.fKA(v_c, 21)), F.fKA(v_c, 7)))) + I32[arshift((v_r + v_e), 2)]))
v_b = tobit((v_t + v_o))
v_t = tobit((bxor(bxor(F.fKA(v_b, 30), F.fKA(v_b, 19)), F.fKA(v_b, 10)) + bor(band(bor(v_a, v_b), v_d), band(v_a, v_b))))
v_Q = tobit((v_o + v_l))
v_r = bor(8, v_C)
v_o = tobit((tobit((tobit((tobit((I32[arshift((11248 + v_r), 2)] + v_k)) + I32[arshift((v_r + v_e), 2)])) + bxor(band(v_Q, bxor(v_c, v_y)), v_y))) + bxor(bxor(F.fKA(v_Q, 26), F.fKA(v_Q, 21)), F.fKA(v_Q, 7))))
v_v = tobit((v_t + v_o))
v_t = tobit((bxor(bxor(F.fKA(v_v, 30), F.fKA(v_v, 19)), F.fKA(v_v, 10)) + bor(band(v_a, bor(v_b, v_v)), band(v_b, v_v))))
v_O = tobit((v_o + v_p))
v_r = bor(12, v_C)
v_o = tobit((tobit((tobit((tobit((I32[arshift((11248 + v_r), 2)] + v_y)) + I32[arshift((v_r + v_e), 2)])) + bxor(v_c, band(v_O, bxor(v_c, v_Q))))) + bxor(bxor(F.fKA(v_O, 26), F.fKA(v_O, 21)), F.fKA(v_O, 7))))
v_g = tobit((v_t + v_o))
v_t = tobit((bxor(bxor(F.fKA(v_g, 30), F.fKA(v_g, 19)), F.fKA(v_g, 10)) + bor(band(v_b, bor(v_v, v_g)), band(v_v, v_g))))
local t111 = v_c
v_r = bor(16, v_C)
v_r = tobit((tobit((t111 + I32[arshift((11248 + v_r), 2)])) + I32[arshift((v_r + v_e), 2)]))
local t113 = v_r
local t112 = v_Q
v_c = tobit((v_o + v_d))
v_o = tobit((tobit((t113 + bxor(t112, band(v_c, bxor(v_Q, v_O))))) + bxor(bxor(F.fKA(v_c, 26), F.fKA(v_c, 21)), F.fKA(v_c, 7))))
v_u = tobit((v_t + v_o))
v_t = tobit((bxor(bxor(F.fKA(v_u, 30), F.fKA(v_u, 19)), F.fKA(v_u, 10)) + bor(band(v_v, bor(v_u, v_g)), band(v_u, v_g))))
v_s = tobit((v_o + v_a))
local t114 = v_Q
v_r = bor(20, v_C)
v_o = tobit((tobit((tobit((tobit((t114 + I32[arshift((11248 + v_r), 2)])) + I32[arshift((v_r + v_e), 2)])) + bxor(v_O, band(v_s, bxor(v_c, v_O))))) + bxor(bxor(F.fKA(v_s, 26), F.fKA(v_s, 21)), F.fKA(v_s, 7))))
v_l = tobit((v_t + v_o))
v_t = tobit((bxor(bxor(F.fKA(v_l, 30), F.fKA(v_l, 19)), F.fKA(v_l, 10)) + bor(band(v_g, bor(v_u, v_l)), band(v_u, v_l))))
v_h = tobit((v_o + v_b))
local t115 = v_O
v_r = bor(24, v_C)
v_o = tobit((tobit((tobit((tobit((t115 + I32[arshift((11248 + v_r), 2)])) + I32[arshift((v_r + v_e), 2)])) + bxor(v_c, band(v_h, bxor(v_c, v_s))))) + bxor(bxor(F.fKA(v_h, 26), F.fKA(v_h, 21)), F.fKA(v_h, 7))))
v_k = tobit((v_o + v_v))
v_p = tobit((v_t + v_o))
v_t = tobit((bxor(bxor(F.fKA(v_p, 30), F.fKA(v_p, 19)), F.fKA(v_p, 10)) + bor(band(bor(v_l, v_p), v_u), band(v_l, v_p))))
local t117 = v_t
local t116 = v_c
v_r = bor(28, v_C)
v_r = tobit((tobit((tobit((tobit((t116 + I32[arshift((11248 + v_r), 2)])) + I32[arshift((v_r + v_e), 2)])) + bxor(band(v_k, bxor(v_s, v_h)), v_s))) + bxor(bxor(F.fKA(v_k, 26), F.fKA(v_k, 21)), F.fKA(v_k, 7))))
v_d = tobit((t117 + v_r))
v_y = tobit((v_r + v_g))
v_r = v_n
v_n = 0
if not (v_r ~= 0) then goto B134 end
end
do
end
::C134::
end
end
::B134::
end
do
do
v_t = I32[arshift(v_e, 2)]
v_S = 16
while true do
do
v_r = v_t
v_w = lshift(v_S, 2)
v_t = tobit((v_w + v_e))
v_c = I32[arshift((v_t - 8), 2)]
v_r = tobit((v_r + tobit((I32[arshift((v_t - 28), 2)] + bxor(bxor(F.fKA(v_c, 15), F.fKA(v_c, 13)), (rshift(v_c, 10) % 4294967296))))))
v_n = I32[arshift((v_t - 60), 2)]
v_a = tobit((bxor(bxor(F.fKA(v_n, 25), F.fKA(v_n, 14)), (rshift(v_n, 3) % 4294967296)) + v_r))
I32[arshift(v_t, 2)] = tobit(v_a)
v_r = bor(4, v_w)
v_o = I32[arshift((v_t - 4), 2)]
v_b = tobit((tobit((v_n + I32[arshift((v_t - 24), 2)])) + bxor(bxor(F.fKA(v_o, 15), F.fKA(v_o, 13)), (rshift(v_o, 10) % 4294967296))))
local t118 = v_b
v_n = I32[arshift((v_t - 56), 2)]
v_E = tobit((t118 + bxor(bxor(F.fKA(v_n, 25), F.fKA(v_n, 14)), (rshift(v_n, 3) % 4294967296))))
I32[arshift((v_r + v_e), 2)] = tobit(v_E)
v_b = bor(8, v_w)
v_v = tobit((I32[arshift((v_t - 20), 2)] + tobit((v_n + bxor(bxor(F.fKA(v_a, 15), F.fKA(v_a, 13)), (rshift(v_a, 10) % 4294967296))))))
local t119 = v_v
v_n = I32[arshift((v_t - 52), 2)]
v_I = tobit((t119 + bxor(bxor(F.fKA(v_n, 25), F.fKA(v_n, 14)), (rshift(v_n, 3) % 4294967296))))
I32[arshift((v_b + v_e), 2)] = tobit(v_I)
v_v = bor(12, v_w)
v_g = tobit((I32[arshift((v_t - 16), 2)] + tobit((v_n + bxor(bxor(F.fKA(v_E, 15), F.fKA(v_E, 13)), (rshift(v_E, 10) % 4294967296))))))
local t120 = v_g
v_n = I32[arshift((v_t - 48), 2)]
v_m = tobit((t120 + bxor(bxor(F.fKA(v_n, 25), F.fKA(v_n, 14)), (rshift(v_n, 3) % 4294967296))))
I32[arshift((v_v + v_e), 2)] = tobit(v_m)
v_g = bor(16, v_w)
v_C = tobit((I32[arshift((v_t - 12), 2)] + tobit((v_n + bxor(bxor(F.fKA(v_I, 15), F.fKA(v_I, 13)), (rshift(v_I, 10) % 4294967296))))))
local t121 = v_C
v_n = I32[arshift((v_t - 44), 2)]
v_M = tobit((t121 + bxor(bxor(F.fKA(v_n, 25), F.fKA(v_n, 14)), (rshift(v_n, 3) % 4294967296))))
I32[arshift((v_g + v_e), 2)] = tobit(v_M)
v_Q = bor(20, v_w)
v_c = tobit((tobit((v_n + v_c)) + bxor(bxor(F.fKA(v_m, 15), F.fKA(v_m, 13)), (rshift(v_m, 10) % 4294967296))))
local t122 = v_c
v_n = I32[arshift((v_t - 40), 2)]
v_C = tobit((t122 + bxor(bxor(F.fKA(v_n, 25), F.fKA(v_n, 14)), (rshift(v_n, 3) % 4294967296))))
I32[arshift((v_Q + v_e), 2)] = tobit(v_C)
v_O = bor(24, v_w)
v_o = tobit((tobit((v_n + v_o)) + bxor(bxor(F.fKA(v_M, 15), F.fKA(v_M, 13)), (rshift(v_M, 10) % 4294967296))))
local t123 = v_o
v_n = I32[arshift((v_t - 36), 2)]
v_c = tobit((t123 + bxor(bxor(F.fKA(v_n, 25), F.fKA(v_n, 14)), (rshift(v_n, 3) % 4294967296))))
I32[arshift((v_O + v_e), 2)] = tobit(v_c)
v_o = bor(28, v_w)
v_n = tobit((tobit((v_n + v_a)) + bxor(bxor(F.fKA(v_C, 15), F.fKA(v_C, 13)), (rshift(v_C, 10) % 4294967296))))
local t124 = v_n
v_t = I32[arshift((v_t - 32), 2)]
v_n = tobit((t124 + bxor(bxor(F.fKA(v_t, 25), F.fKA(v_t, 14)), (rshift(v_t, 3) % 4294967296))))
I32[arshift((v_o + v_e), 2)] = tobit(v_n)
v_a = tobit((v_a + tobit((tobit((I32[arshift((v_w + 11248), 2)] + tobit((bxor(bxor(F.fKA(v_y, 26), F.fKA(v_y, 21)), F.fKA(v_y, 7)) + v_s)))) + bxor(band(bxor(v_h, v_k), v_y), v_h)))))
v_w = tobit((tobit((v_a + bxor(bxor(F.fKA(v_d, 30), F.fKA(v_d, 19)), F.fKA(v_d, 10)))) + bor(band(bor(v_d, v_p), v_l), band(v_d, v_p))))
v_s = tobit((bxor(bxor(F.fKA(v_w, 30), F.fKA(v_w, 19)), F.fKA(v_w, 10)) + bor(band(bor(v_d, v_w), v_p), band(v_d, v_w))))
v_a = tobit((v_a + v_u))
v_r = tobit((tobit((tobit((I32[arshift((v_r + 11248), 2)] + tobit((bxor(band(v_a, bxor(v_y, v_k)), v_k) + v_h)))) + bxor(bxor(F.fKA(v_a, 26), F.fKA(v_a, 21)), F.fKA(v_a, 7)))) + v_E))
v_E = tobit((v_s + v_r))
v_u = tobit((bxor(bxor(F.fKA(v_E, 30), F.fKA(v_E, 19)), F.fKA(v_E, 10)) + bor(band(bor(v_w, v_E), v_d), band(v_w, v_E))))
local t126 = v_I
v_s = tobit((I32[arshift((v_b + 11248), 2)] + v_k))
local t125 = v_s
v_b = tobit((v_r + v_l))
v_r = tobit((t126 + tobit((tobit((t125 + bxor(band(v_b, bxor(v_a, v_y)), v_y))) + bxor(bxor(F.fKA(v_b, 26), F.fKA(v_b, 21)), F.fKA(v_b, 7))))))
v_I = tobit((v_u + v_r))
v_u = tobit((bxor(bxor(F.fKA(v_I, 30), F.fKA(v_I, 19)), F.fKA(v_I, 10)) + bor(band(v_w, bor(v_E, v_I)), band(v_E, v_I))))
local t129 = v_m
v_l = tobit((I32[arshift((v_v + 11248), 2)] + v_y))
local t128 = v_l
local t127 = v_a
v_v = tobit((v_r + v_p))
v_r = tobit((tobit((t129 + tobit((t128 + bxor(t127, band(v_v, bxor(v_a, v_b))))))) + bxor(bxor(F.fKA(v_v, 26), F.fKA(v_v, 21)), F.fKA(v_v, 7))))
v_m = tobit((v_u + v_r))
v_u = tobit((bxor(bxor(F.fKA(v_m, 30), F.fKA(v_m, 19)), F.fKA(v_m, 10)) + bor(band(v_E, bor(v_I, v_m)), band(v_I, v_m))))
v_a = tobit((v_M + tobit((v_a + I32[arshift((v_g + 11248), 2)]))))
local t131 = v_a
local t130 = v_b
v_g = tobit((v_r + v_d))
v_r = tobit((tobit((t131 + bxor(t130, band(v_g, bxor(v_b, v_v))))) + bxor(bxor(F.fKA(v_g, 26), F.fKA(v_g, 21)), F.fKA(v_g, 7))))
v_u = tobit((v_u + v_r))
v_a = tobit((bxor(bxor(F.fKA(v_u, 30), F.fKA(v_u, 19)), F.fKA(v_u, 10)) + bor(band(v_I, bor(v_u, v_m)), band(v_u, v_m))))
v_s = tobit((v_r + v_w))
v_r = tobit((tobit((tobit((v_C + tobit((v_b + I32[arshift((v_Q + 11248), 2)])))) + bxor(v_v, band(v_s, bxor(v_v, v_g))))) + bxor(bxor(F.fKA(v_s, 26), F.fKA(v_s, 21)), F.fKA(v_s, 7))))
v_l = tobit((v_a + v_r))
v_a = tobit((bxor(bxor(F.fKA(v_l, 30), F.fKA(v_l, 19)), F.fKA(v_l, 10)) + bor(band(v_m, bor(v_u, v_l)), band(v_u, v_l))))
v_h = tobit((v_r + v_E))
v_r = tobit((tobit((tobit((v_c + tobit((v_v + I32[arshift((v_O + 11248), 2)])))) + bxor(v_g, band(v_h, bxor(v_g, v_s))))) + bxor(bxor(F.fKA(v_h, 26), F.fKA(v_h, 21)), F.fKA(v_h, 7))))
v_k = tobit((v_r + v_I))
v_p = tobit((v_a + v_r))
v_a = tobit((bxor(bxor(F.fKA(v_p, 30), F.fKA(v_p, 19)), F.fKA(v_p, 10)) + bor(band(bor(v_l, v_p), v_u), band(v_l, v_p))))
local t132 = v_a
v_r = tobit((tobit((tobit((tobit((v_g + I32[arshift((v_o + 11248), 2)])) + v_n)) + bxor(band(v_k, bxor(v_s, v_h)), v_s))) + bxor(bxor(F.fKA(v_k, 26), F.fKA(v_k, 21)), F.fKA(v_k, 7))))
v_d = tobit((t132 + v_r))
v_y = tobit((v_r + v_m))
v_r = (((tobit(v_S) % 4294967296) < 56) and 1 or 0)
v_S = tobit((v_S + 8))
if not (v_r ~= 0) then goto B135 end
end
do
end
::C135::
end
end
::B135::
end
I32[arshift((v_A + 8), 2)] = tobit((I32[arshift((v_A + 8), 2)] + v_d))
I32[arshift((v_A + 12), 2)] = tobit((I32[arshift((v_A + 12), 2)] + v_p))
I32[arshift((v_A + 16), 2)] = tobit((I32[arshift((v_A + 16), 2)] + v_l))
I32[arshift((v_A + 20), 2)] = tobit((I32[arshift((v_A + 20), 2)] + v_u))
I32[arshift((v_A + 24), 2)] = tobit((I32[arshift((v_A + 24), 2)] + v_y))
I32[arshift((v_A + 28), 2)] = tobit((I32[arshift((v_A + 28), 2)] + v_k))
I32[arshift((v_A + 32), 2)] = tobit((I32[arshift((v_A + 32), 2)] + v_h))
I32[arshift((v_A + 36), 2)] = tobit((I32[arshift((v_A + 36), 2)] + v_s))
B = tobit((v_e + 256))
end

F.fK = function(v_A, v_r)
local v_e, v_n, v_t, v_o, v_a, v_u, v_c, v_s, v_l, v_b, v_v, v_g, v_p, v_d, v_h, v_k, v_y, v_w, v_C, v_E, v_B, v_I, v_m, v_Q, v_O, v_S = 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
v_I = 0
v_m = 0
v_Q = 0
v_O = 0
v_S = 0
do
v_t = bor(bor(bor(U8[tobit((v_r + 12))], lshift(U8[tobit((v_r + 13))], 8)), lshift(U8[tobit((v_r + 14))], 16)), lshift(U8[tobit((v_r + 15))], 24))
v_o = bor(bor(bor(U8[tobit((v_r + 4))], lshift(U8[tobit((v_r + 5))], 8)), lshift(U8[tobit((v_r + 6))], 16)), lshift(U8[tobit((v_r + 7))], 24))
v_a = bor(bor(bor(U8[tobit((v_r + 8))], lshift(U8[tobit((v_r + 9))], 8)), lshift(U8[tobit((v_r + 10))], 16)), lshift(U8[tobit((v_r + 11))], 24))
v_E = I32[arshift((v_A + 8), 2)]
local t133 = v_E
v_u = bor(bor(bor(U8[bor(0, v_r)], lshift(U8[tobit((v_r + 1))], 8)), lshift(U8[tobit((v_r + 2))], 16)), lshift(U8[tobit((v_r + 3))], 24))
local t135 = tobit((t133 + v_u))
v_e = I32[arshift((v_A + 12), 2)]
local t134 = v_e
v_n = I32[arshift((v_A + 16), 2)]
local t136 = tobit((t135 + band(t134, v_n)))
v_c = I32[arshift((v_A + 20), 2)]
v_I = F.fKA(tobit((t136 + band(v_c, bxor((-1), v_e)))), 3)
v_s = bor(bor(bor(U8[tobit((v_r + 16))], lshift(U8[tobit((v_r + 17))], 8)), lshift(U8[tobit((v_r + 18))], 16)), lshift(U8[tobit((v_r + 19))], 24))
v_Q = F.fKA(tobit((tobit((tobit((v_o + v_c)) + band(bxor((-1), v_I), v_n))) + band(v_I, v_e))), 7)
v_m = F.fKA(tobit((tobit((tobit((v_a + v_n)) + band(bxor((-1), v_Q), v_e))) + band(v_I, v_Q))), 11)
v_O = F.fKA(tobit((tobit((tobit((v_e + v_t)) + band(v_I, bxor((-1), v_m)))) + band(v_m, v_Q))), 19)
v_I = F.fKA(tobit((tobit((tobit((v_I + v_s)) + band(bxor((-1), v_O), v_Q))) + band(v_m, v_O))), 3)
v_l = bor(bor(bor(U8[tobit((v_r + 32))], lshift(U8[tobit((v_r + 33))], 8)), lshift(U8[tobit((v_r + 34))], 16)), lshift(U8[tobit((v_r + 35))], 24))
local t137 = v_Q
v_b = bor(bor(bor(U8[tobit((v_r + 20))], lshift(U8[tobit((v_r + 21))], 8)), lshift(U8[tobit((v_r + 22))], 16)), lshift(U8[tobit((v_r + 23))], 24))
v_Q = F.fKA(tobit((tobit((tobit((t137 + v_b)) + band(v_m, bxor((-1), v_I)))) + band(v_I, v_O))), 7)
v_v = bor(bor(bor(U8[tobit((v_r + 28))], lshift(U8[tobit((v_r + 29))], 8)), lshift(U8[tobit((v_r + 30))], 16)), lshift(U8[tobit((v_r + 31))], 24))
local t138 = v_m
v_g = bor(bor(bor(U8[tobit((v_r + 24))], lshift(U8[tobit((v_r + 25))], 8)), lshift(U8[tobit((v_r + 26))], 16)), lshift(U8[tobit((v_r + 27))], 24))
v_m = F.fKA(tobit((tobit((tobit((t138 + v_g)) + band(v_O, bxor((-1), v_Q)))) + band(v_I, v_Q))), 11)
v_O = F.fKA(tobit((tobit((tobit((v_O + v_v)) + band(v_I, bxor((-1), v_m)))) + band(v_m, v_Q))), 19)
v_I = F.fKA(tobit((tobit((tobit((v_I + v_l)) + band(v_Q, bxor((-1), v_O)))) + band(v_m, v_O))), 3)
v_p = bor(bor(bor(U8[tobit((v_r + 48))], lshift(U8[tobit((v_r + 49))], 8)), lshift(U8[tobit((v_r + 50))], 16)), lshift(U8[tobit((v_r + 51))], 24))
local t139 = v_Q
v_d = bor(bor(bor(U8[tobit((v_r + 36))], lshift(U8[tobit((v_r + 37))], 8)), lshift(U8[tobit((v_r + 38))], 16)), lshift(U8[tobit((v_r + 39))], 24))
v_Q = F.fKA(tobit((tobit((tobit((t139 + v_d)) + band(v_m, bxor((-1), v_I)))) + band(v_I, v_O))), 7)
v_h = bor(bor(bor(U8[tobit((v_r + 44))], lshift(U8[tobit((v_r + 45))], 8)), lshift(U8[tobit((v_r + 46))], 16)), lshift(U8[tobit((v_r + 47))], 24))
local t140 = v_m
v_k = bor(bor(bor(U8[tobit((v_r + 40))], lshift(U8[tobit((v_r + 41))], 8)), lshift(U8[tobit((v_r + 42))], 16)), lshift(U8[tobit((v_r + 43))], 24))
v_m = F.fKA(tobit((tobit((tobit((t140 + v_k)) + band(v_O, bxor((-1), v_Q)))) + band(v_I, v_Q))), 11)
v_O = F.fKA(tobit((tobit((tobit((v_O + v_h)) + band(v_I, bxor((-1), v_m)))) + band(v_m, v_Q))), 19)
v_I = F.fKA(tobit((tobit((tobit((v_I + v_p)) + band(v_Q, bxor((-1), v_O)))) + band(v_m, v_O))), 3)
v_y = bor(bor(bor(U8[tobit((v_r + 60))], lshift(U8[tobit((v_r + 61))], 8)), lshift(U8[tobit((v_r + 62))], 16)), lshift(U8[tobit((v_r + 63))], 24))
v_w = bor(bor(bor(U8[tobit((v_r + 56))], lshift(U8[tobit((v_r + 57))], 8)), lshift(U8[tobit((v_r + 58))], 16)), lshift(U8[tobit((v_r + 59))], 24))
local t141 = v_Q
v_C = bor(bor(bor(U8[tobit((v_r + 52))], lshift(U8[tobit((v_r + 53))], 8)), lshift(U8[tobit((v_r + 54))], 16)), lshift(U8[tobit((v_r + 55))], 24))
v_r = F.fKA(tobit((tobit((tobit((t141 + v_C)) + band(v_m, bxor((-1), v_I)))) + band(v_I, v_O))), 7)
v_Q = F.fKA(tobit((tobit((tobit((v_m + v_w)) + band(v_O, bxor((-1), v_r)))) + band(v_r, v_I))), 11)
v_S = band(v_r, v_Q)
v_m = F.fKA(tobit((v_S + tobit((tobit((v_O + v_y)) + band(v_I, bxor((-1), v_Q)))))), 19)
local t142 = tobit((v_I + v_u))
v_O = band(v_Q, v_m)
v_I = F.fKA(tobit((1518500249 + tobit((t142 + bor(bor(v_O, v_S), band(v_r, v_m)))))), 3)
local t143 = tobit((v_r + v_s))
v_S = band(v_I, v_m)
v_r = F.fKA(tobit((1518500249 + tobit((t143 + bor(bor(v_S, v_O), band(v_I, v_Q)))))), 5)
local t144 = tobit((v_Q + v_l))
v_O = band(v_r, v_I)
v_Q = F.fKA(tobit((1518500249 + tobit((t144 + bor(bor(v_O, v_S), band(v_r, v_m)))))), 9)
local t145 = tobit((v_m + v_p))
v_S = band(v_Q, v_r)
v_m = F.fKA(tobit((1518500249 + tobit((t145 + bor(bor(v_S, v_O), band(v_I, v_Q)))))), 13)
local t146 = tobit((v_I + v_o))
v_O = band(v_m, v_Q)
v_I = F.fKA(tobit((1518500249 + tobit((t146 + bor(bor(v_O, v_S), band(v_r, v_m)))))), 3)
local t147 = tobit((v_r + v_b))
v_S = band(v_I, v_m)
v_r = F.fKA(tobit((1518500249 + tobit((t147 + bor(bor(v_S, v_O), band(v_I, v_Q)))))), 5)
local t148 = tobit((v_Q + v_d))
v_O = band(v_r, v_I)
v_Q = F.fKA(tobit((1518500249 + tobit((t148 + bor(bor(v_O, v_S), band(v_r, v_m)))))), 9)
local t149 = tobit((v_m + v_C))
v_S = band(v_Q, v_r)
v_m = F.fKA(tobit((1518500249 + tobit((t149 + bor(bor(v_S, v_O), band(v_I, v_Q)))))), 13)
local t150 = tobit((v_I + v_a))
v_O = band(v_m, v_Q)
v_I = F.fKA(tobit((1518500249 + tobit((t150 + bor(bor(v_O, v_S), band(v_r, v_m)))))), 3)
local t151 = tobit((v_r + v_g))
v_S = band(v_I, v_m)
v_r = F.fKA(tobit((1518500249 + tobit((t151 + bor(bor(v_S, v_O), band(v_I, v_Q)))))), 5)
local t152 = tobit((v_Q + v_k))
v_O = band(v_r, v_I)
v_Q = F.fKA(tobit((1518500249 + tobit((t152 + bor(bor(v_O, v_S), band(v_r, v_m)))))), 9)
local t153 = tobit((v_m + v_w))
v_S = band(v_Q, v_r)
v_m = F.fKA(tobit((1518500249 + tobit((t153 + bor(bor(v_S, v_O), band(v_I, v_Q)))))), 13)
local t154 = tobit((v_I + v_t))
v_O = band(v_m, v_Q)
v_I = F.fKA(tobit((1518500249 + tobit((t154 + bor(bor(v_O, v_S), band(v_r, v_m)))))), 3)
local t155 = tobit((v_r + v_v))
v_S = band(v_I, v_m)
v_r = F.fKA(tobit((1518500249 + tobit((t155 + bor(bor(v_S, v_O), band(v_I, v_Q)))))), 5)
v_B = tobit((v_m + v_y))
local t156 = tobit((v_Q + v_h))
v_O = band(v_r, v_I)
v_m = F.fKA(tobit((1518500249 + tobit((t156 + bor(bor(v_O, v_S), band(v_r, v_m)))))), 9)
v_Q = F.fKA(tobit((1518500249 + tobit((v_B + bor(v_O, band(v_m, bor(v_r, v_I))))))), 13)
v_O = tobit((v_m + v_s))
local t157 = tobit((v_I + v_u))
v_m = bxor(v_m, v_Q)
v_I = F.fKA(tobit((1859775393 + tobit((t157 + bxor(v_m, v_r))))), 3)
v_m = F.fKA(tobit((1859775393 + tobit((tobit((v_r + v_l)) + bxor(v_I, v_m))))), 9)
v_r = F.fKA(tobit((1859775393 + tobit((v_O + bxor(bxor(v_I, v_Q), v_m))))), 11)
v_Q = F.fKA(tobit((1859775393 + tobit((tobit((v_Q + v_p)) + bxor(bxor(v_r, v_I), v_m))))), 15)
v_I = F.fKA(tobit((1859775393 + tobit((tobit((v_I + v_a)) + bxor(bxor(v_Q, v_r), v_m))))), 3)
v_m = F.fKA(tobit((1859775393 + tobit((tobit((v_m + v_k)) + bxor(bxor(v_I, v_r), v_Q))))), 9)
v_r = F.fKA(tobit((1859775393 + tobit((tobit((v_r + v_g)) + bxor(bxor(v_m, v_I), v_Q))))), 11)
v_Q = F.fKA(tobit((1859775393 + tobit((tobit((v_Q + v_w)) + bxor(bxor(v_r, v_I), v_m))))), 15)
v_I = F.fKA(tobit((1859775393 + tobit((tobit((v_I + v_o)) + bxor(bxor(v_Q, v_r), v_m))))), 3)
v_m = F.fKA(tobit((1859775393 + tobit((tobit((v_m + v_d)) + bxor(bxor(v_I, v_r), v_Q))))), 9)
v_r = F.fKA(tobit((1859775393 + tobit((tobit((v_r + v_b)) + bxor(bxor(v_m, v_I), v_Q))))), 11)
v_O = tobit((v_I + v_t))
v_I = F.fKA(tobit((1859775393 + tobit((tobit((v_Q + v_C)) + bxor(bxor(v_r, v_I), v_m))))), 15)
v_Q = F.fKA(tobit((1859775393 + tobit((v_O + bxor(bxor(v_I, v_r), v_m))))), 3)
I32[arshift((v_A + 8), 2)] = tobit((v_Q + v_E))
v_m = F.fKA(tobit((1859775393 + tobit((tobit((v_m + v_h)) + bxor(bxor(v_Q, v_r), v_I))))), 9)
I32[arshift((v_A + 20), 2)] = tobit((v_m + v_c))
v_r = F.fKA(tobit((1859775393 + tobit((tobit((v_r + v_v)) + bxor(bxor(v_m, v_I), v_Q))))), 11)
I32[arshift((v_A + 16), 2)] = tobit((v_r + v_n))
I32[arshift((v_A + 12), 2)] = tobit((F.fKA(tobit((1859775393 + tobit((tobit((v_I + v_y)) + bxor(bxor(v_r, v_m), v_Q))))), 15) + v_e))
end
end

F.fR = function(v_A, v_r, v_e, v_t, v_o, v_a)
local v_u, v_c, v_s = 0, 0, 0
v_c = 0
v_s = 0
v_u = tobit((B - 16))
B = v_u
v_s = (-34)
do
if (not (band(15, v_e) ~= 0)) then
do
if (v_r ~= 0) then
v_s = 0
if (not (v_e ~= 0)) then
goto L136
end
if (1 ~= bor(0, v_r)) then
goto L137
end
do
while true do
I8[bor(0, v_a)] = tobit(bxor(U8[bor(0, v_t)], U8[bor(0, v_o)]))
I8[tobit((v_a + 1))] = tobit(bxor(U8[tobit((v_t + 1))], U8[tobit((v_o + 1))]))
I8[tobit((v_a + 2))] = tobit(bxor(U8[tobit((v_t + 2))], U8[tobit((v_o + 2))]))
I8[tobit((v_a + 3))] = tobit(bxor(U8[tobit((v_t + 3))], U8[tobit((v_o + 3))]))
I8[tobit((v_a + 4))] = tobit(bxor(U8[tobit((v_t + 4))], U8[tobit((v_o + 4))]))
I8[tobit((v_a + 5))] = tobit(bxor(U8[tobit((v_t + 5))], U8[tobit((v_o + 5))]))
I8[tobit((v_a + 6))] = tobit(bxor(U8[tobit((v_t + 6))], U8[tobit((v_o + 6))]))
I8[tobit((v_a + 7))] = tobit(bxor(U8[tobit((v_t + 7))], U8[tobit((v_o + 7))]))
I8[tobit((v_a + 8))] = tobit(bxor(U8[tobit((v_t + 8))], U8[tobit((v_o + 8))]))
I8[tobit((v_a + 9))] = tobit(bxor(U8[tobit((v_t + 9))], U8[tobit((v_o + 9))]))
I8[tobit((v_a + 10))] = tobit(bxor(U8[tobit((v_t + 10))], U8[tobit((v_o + 10))]))
I8[tobit((v_a + 11))] = tobit(bxor(U8[tobit((v_t + 11))], U8[tobit((v_o + 11))]))
I8[tobit((v_a + 12))] = tobit(bxor(U8[tobit((v_t + 12))], U8[tobit((v_o + 12))]))
I8[tobit((v_a + 13))] = tobit(bxor(U8[tobit((v_t + 13))], U8[tobit((v_o + 13))]))
I8[tobit((v_a + 14))] = tobit(bxor(U8[tobit((v_t + 14))], U8[tobit((v_o + 14))]))
I8[tobit((v_a + 15))] = tobit(bxor(U8[tobit((v_t + 15))], U8[tobit((v_o + 15))]))
F.fT(v_A, v_a, v_a)
v_r = bor(bor(bor(U8[tobit((v_a + 12))], lshift(U8[tobit((v_a + 13))], 8)), lshift(U8[tobit((v_a + 14))], 16)), lshift(U8[tobit((v_a + 15))], 24))
v_c = bor(bor(bor(U8[tobit((v_a + 8))], lshift(U8[tobit((v_a + 9))], 8)), lshift(U8[tobit((v_a + 10))], 16)), lshift(U8[tobit((v_a + 11))], 24))
I8[tobit((v_t + 8))] = tobit(v_c)
I8[tobit((v_t + 9))] = tobit((rshift(v_c, 8) % 4294967296))
I8[tobit((v_t + 10))] = tobit((rshift(v_c, 16) % 4294967296))
I8[tobit((v_t + 11))] = tobit((rshift(v_c, 24) % 4294967296))
I8[tobit((v_t + 12))] = tobit(v_r)
I8[tobit((v_t + 13))] = tobit((rshift(v_r, 8) % 4294967296))
I8[tobit((v_t + 14))] = tobit((rshift(v_r, 16) % 4294967296))
I8[tobit((v_t + 15))] = tobit((rshift(v_r, 24) % 4294967296))
v_r = bor(bor(bor(U8[tobit((v_a + 4))], lshift(U8[tobit((v_a + 5))], 8)), lshift(U8[tobit((v_a + 6))], 16)), lshift(U8[tobit((v_a + 7))], 24))
v_c = bor(bor(bor(U8[bor(0, v_a)], lshift(U8[tobit((v_a + 1))], 8)), lshift(U8[tobit((v_a + 2))], 16)), lshift(U8[tobit((v_a + 3))], 24))
I8[bor(0, v_t)] = tobit(v_c)
I8[tobit((v_t + 1))] = tobit((rshift(v_c, 8) % 4294967296))
I8[tobit((v_t + 2))] = tobit((rshift(v_c, 16) % 4294967296))
I8[tobit((v_t + 3))] = tobit((rshift(v_c, 24) % 4294967296))
I8[tobit((v_t + 4))] = tobit(v_r)
I8[tobit((v_t + 5))] = tobit((rshift(v_r, 8) % 4294967296))
I8[tobit((v_t + 6))] = tobit((rshift(v_r, 16) % 4294967296))
I8[tobit((v_t + 7))] = tobit((rshift(v_r, 24) % 4294967296))
v_a = tobit((v_a + 16))
v_o = tobit((v_o + 16))
v_e = tobit((v_e - 16))
if not (v_e ~= 0) then goto B138 end
do
end
::C138::
end
end
::B138::
goto L136
end
v_s = 0
if (not (v_e ~= 0)) then
goto L136
end
do
while true do
v_r = bor(bor(bor(U8[tobit((v_o + 4))], lshift(U8[tobit((v_o + 5))], 8)), lshift(U8[tobit((v_o + 6))], 16)), lshift(U8[tobit((v_o + 7))], 24))
I32[arshift(v_u, 2)] = tobit(bor(bor(bor(U8[bor(0, v_o)], lshift(U8[tobit((v_o + 1))], 8)), lshift(U8[tobit((v_o + 2))], 16)), lshift(U8[tobit((v_o + 3))], 24)))
I32[arshift((v_u + 4), 2)] = tobit(v_r)
v_r = bor(bor(bor(U8[tobit((v_o + 12))], lshift(U8[tobit((v_o + 13))], 8)), lshift(U8[tobit((v_o + 14))], 16)), lshift(U8[tobit((v_o + 15))], 24))
I32[arshift((v_u + 8), 2)] = tobit(bor(bor(bor(U8[tobit((v_o + 8))], lshift(U8[tobit((v_o + 9))], 8)), lshift(U8[tobit((v_o + 10))], 16)), lshift(U8[tobit((v_o + 11))], 24)))
I32[arshift((v_u + 12), 2)] = tobit(v_r)
F.fj(v_A, v_o, v_a)
I8[bor(0, v_a)] = tobit(bxor(U8[bor(0, v_t)], U8[bor(0, v_a)]))
I8[tobit((v_a + 1))] = tobit(bxor(U8[tobit((v_t + 1))], U8[tobit((v_a + 1))]))
I8[tobit((v_a + 2))] = tobit(bxor(U8[tobit((v_t + 2))], U8[tobit((v_a + 2))]))
I8[tobit((v_a + 3))] = tobit(bxor(U8[tobit((v_t + 3))], U8[tobit((v_a + 3))]))
I8[tobit((v_a + 4))] = tobit(bxor(U8[tobit((v_t + 4))], U8[tobit((v_a + 4))]))
I8[tobit((v_a + 5))] = tobit(bxor(U8[tobit((v_t + 5))], U8[tobit((v_a + 5))]))
I8[tobit((v_a + 6))] = tobit(bxor(U8[tobit((v_t + 6))], U8[tobit((v_a + 6))]))
I8[tobit((v_a + 7))] = tobit(bxor(U8[tobit((v_t + 7))], U8[tobit((v_a + 7))]))
I8[tobit((v_a + 8))] = tobit(bxor(U8[tobit((v_t + 8))], U8[tobit((v_a + 8))]))
I8[tobit((v_a + 9))] = tobit(bxor(U8[tobit((v_t + 9))], U8[tobit((v_a + 9))]))
I8[tobit((v_a + 10))] = tobit(bxor(U8[tobit((v_t + 10))], U8[tobit((v_a + 10))]))
I8[tobit((v_a + 11))] = tobit(bxor(U8[tobit((v_t + 11))], U8[tobit((v_a + 11))]))
I8[tobit((v_a + 12))] = tobit(bxor(U8[tobit((v_t + 12))], U8[tobit((v_a + 12))]))
I8[tobit((v_a + 13))] = tobit(bxor(U8[tobit((v_t + 13))], U8[tobit((v_a + 13))]))
I8[tobit((v_a + 14))] = tobit(bxor(U8[tobit((v_t + 14))], U8[tobit((v_a + 14))]))
I8[tobit((v_a + 15))] = tobit(bxor(U8[tobit((v_t + 15))], U8[tobit((v_a + 15))]))
v_r = I32[arshift((v_u + 12), 2)]
v_c = I32[arshift((v_u + 8), 2)]
I8[tobit((v_t + 8))] = tobit(v_c)
I8[tobit((v_t + 9))] = tobit((rshift(v_c, 8) % 4294967296))
I8[tobit((v_t + 10))] = tobit((rshift(v_c, 16) % 4294967296))
I8[tobit((v_t + 11))] = tobit((rshift(v_c, 24) % 4294967296))
I8[tobit((v_t + 12))] = tobit(v_r)
I8[tobit((v_t + 13))] = tobit((rshift(v_r, 8) % 4294967296))
I8[tobit((v_t + 14))] = tobit((rshift(v_r, 16) % 4294967296))
I8[tobit((v_t + 15))] = tobit((rshift(v_r, 24) % 4294967296))
v_r = I32[arshift((v_u + 4), 2)]
v_c = I32[arshift(v_u, 2)]
I8[bor(0, v_t)] = tobit(v_c)
I8[tobit((v_t + 1))] = tobit((rshift(v_c, 8) % 4294967296))
I8[tobit((v_t + 2))] = tobit((rshift(v_c, 16) % 4294967296))
I8[tobit((v_t + 3))] = tobit((rshift(v_c, 24) % 4294967296))
I8[tobit((v_t + 4))] = tobit(v_r)
I8[tobit((v_t + 5))] = tobit((rshift(v_r, 8) % 4294967296))
I8[tobit((v_t + 6))] = tobit((rshift(v_r, 16) % 4294967296))
I8[tobit((v_t + 7))] = tobit((rshift(v_r, 24) % 4294967296))
v_a = tobit((v_a + 16))
v_o = tobit((v_o + 16))
v_e = tobit((v_e - 16))
if not (v_e ~= 0) then goto B139 end
do
end
::C139::
end
end
::B139::
goto L136
end
::L137::
do
while true do
I8[bor(0, v_a)] = tobit(bxor(U8[bor(0, v_t)], U8[bor(0, v_o)]))
I8[tobit((v_a + 1))] = tobit(bxor(U8[tobit((v_t + 1))], U8[tobit((v_o + 1))]))
I8[tobit((v_a + 2))] = tobit(bxor(U8[tobit((v_t + 2))], U8[tobit((v_o + 2))]))
I8[tobit((v_a + 3))] = tobit(bxor(U8[tobit((v_t + 3))], U8[tobit((v_o + 3))]))
I8[tobit((v_a + 4))] = tobit(bxor(U8[tobit((v_t + 4))], U8[tobit((v_o + 4))]))
I8[tobit((v_a + 5))] = tobit(bxor(U8[tobit((v_t + 5))], U8[tobit((v_o + 5))]))
I8[tobit((v_a + 6))] = tobit(bxor(U8[tobit((v_t + 6))], U8[tobit((v_o + 6))]))
I8[tobit((v_a + 7))] = tobit(bxor(U8[tobit((v_t + 7))], U8[tobit((v_o + 7))]))
I8[tobit((v_a + 8))] = tobit(bxor(U8[tobit((v_t + 8))], U8[tobit((v_o + 8))]))
I8[tobit((v_a + 9))] = tobit(bxor(U8[tobit((v_t + 9))], U8[tobit((v_o + 9))]))
I8[tobit((v_a + 10))] = tobit(bxor(U8[tobit((v_t + 10))], U8[tobit((v_o + 10))]))
I8[tobit((v_a + 11))] = tobit(bxor(U8[tobit((v_t + 11))], U8[tobit((v_o + 11))]))
I8[tobit((v_a + 12))] = tobit(bxor(U8[tobit((v_t + 12))], U8[tobit((v_o + 12))]))
I8[tobit((v_a + 13))] = tobit(bxor(U8[tobit((v_t + 13))], U8[tobit((v_o + 13))]))
I8[tobit((v_a + 14))] = tobit(bxor(U8[tobit((v_t + 14))], U8[tobit((v_o + 14))]))
I8[tobit((v_a + 15))] = tobit(bxor(U8[tobit((v_t + 15))], U8[tobit((v_o + 15))]))
F.fj(v_A, v_a, v_a)
v_r = bor(bor(bor(U8[tobit((v_a + 12))], lshift(U8[tobit((v_a + 13))], 8)), lshift(U8[tobit((v_a + 14))], 16)), lshift(U8[tobit((v_a + 15))], 24))
v_c = bor(bor(bor(U8[tobit((v_a + 8))], lshift(U8[tobit((v_a + 9))], 8)), lshift(U8[tobit((v_a + 10))], 16)), lshift(U8[tobit((v_a + 11))], 24))
I8[tobit((v_t + 8))] = tobit(v_c)
I8[tobit((v_t + 9))] = tobit((rshift(v_c, 8) % 4294967296))
I8[tobit((v_t + 10))] = tobit((rshift(v_c, 16) % 4294967296))
I8[tobit((v_t + 11))] = tobit((rshift(v_c, 24) % 4294967296))
I8[tobit((v_t + 12))] = tobit(v_r)
I8[tobit((v_t + 13))] = tobit((rshift(v_r, 8) % 4294967296))
I8[tobit((v_t + 14))] = tobit((rshift(v_r, 16) % 4294967296))
I8[tobit((v_t + 15))] = tobit((rshift(v_r, 24) % 4294967296))
v_r = bor(bor(bor(U8[tobit((v_a + 4))], lshift(U8[tobit((v_a + 5))], 8)), lshift(U8[tobit((v_a + 6))], 16)), lshift(U8[tobit((v_a + 7))], 24))
v_c = bor(bor(bor(U8[bor(0, v_a)], lshift(U8[tobit((v_a + 1))], 8)), lshift(U8[tobit((v_a + 2))], 16)), lshift(U8[tobit((v_a + 3))], 24))
I8[bor(0, v_t)] = tobit(v_c)
I8[tobit((v_t + 1))] = tobit((rshift(v_c, 8) % 4294967296))
I8[tobit((v_t + 2))] = tobit((rshift(v_c, 16) % 4294967296))
I8[tobit((v_t + 3))] = tobit((rshift(v_c, 24) % 4294967296))
I8[tobit((v_t + 4))] = tobit(v_r)
I8[tobit((v_t + 5))] = tobit((rshift(v_r, 8) % 4294967296))
I8[tobit((v_t + 6))] = tobit((rshift(v_r, 16) % 4294967296))
I8[tobit((v_t + 7))] = tobit((rshift(v_r, 24) % 4294967296))
v_a = tobit((v_a + 16))
v_o = tobit((v_o + 16))
v_e = tobit((v_e - 16))
if not (v_e ~= 0) then goto B140 end
do
end
::C140::
end
end
::B140::
end
end
::L136::
B = tobit((v_u + 16))
do return v_s end
end

F.fD = function(v_A)
local v_r, v_e, v_t, v_o, v_a, v_u, v_c, v_s = 0, 0, 0, 0, 0, 0, 0, 0
v_t = 0
v_o = 0
v_a = 0
v_u = 0
v_c = 0
v_s = 0
do
v_r = tobit((B - 112))
B = v_r
v_e = F.fm(32)
F.fPA(v_r, 0, 108)
v_t = v_r
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
v_a = F.fpA(v_A)
if (v_a ~= 0) then
do
do
v_o = I32[arshift(v_t, 2)]
v_u = tobit((v_o + v_a))
I32[arshift(v_t, 2)] = tobit(v_u)
if ((tobit(v_o) % 4294967296) > (tobit(v_u) % 4294967296)) then
I32[arshift((v_t + 4), 2)] = tobit((I32[arshift((v_t + 4), 2)] + 1))
end
v_u = 0
v_o = band(v_o, 63)
if (v_o ~= 0) then
v_c = tobit((64 - v_o))
if ((tobit(v_c) % 4294967296) > (tobit(v_a) % 4294967296)) then
v_u = v_o
else
local t158 = v_o
v_s = tobit((v_t + 40))
F.fTA(tobit((t158 + v_s)), v_A, v_c)
F.fP(v_t, v_s)
v_a = tobit((v_a - v_c))
v_A = tobit((v_A + v_c))
end
end
if ((tobit(v_a) % 4294967296) >= 64) then
do
while true do
F.fP(v_t, v_A)
v_A = tobit((v_A - (-64)))
v_a = tobit((v_a + (-64)))
if not ((tobit(v_a) % 4294967296) > 63) then goto B141 end
do
end
::C141::
end
end
::B141::
end
end
if (v_a ~= 0) then
F.fTA(tobit((40 + tobit((v_t + v_u)))), v_A, v_a)
end
end
end
end
do
v_t = tobit((v_r + 40))
v_o = I32[arshift(v_r, 2)]
local t159 = v_t
v_u = band(63, v_o)
I8[tobit((t159 + v_u))] = tobit(128)
v_A = tobit((v_u + 1))
if ((tobit(v_u) % 4294967296) <= 55) then
F.fPA(tobit((40 + tobit((v_A + v_r)))), 0, tobit((55 - v_u)))
else
F.fPA(tobit((40 + tobit((v_A + v_r)))), 0, bxor(63, v_u))
F.fP(v_r, v_t)
I32[arshift((v_t + 48), 2)] = tobit(0)
I32[arshift((v_t + 52), 2)] = tobit(0)
I32[arshift((v_t + 40), 2)] = tobit(0)
I32[arshift((v_t + 44), 2)] = tobit(0)
I32[arshift((v_t + 32), 2)] = tobit(0)
I32[arshift((v_t + 36), 2)] = tobit(0)
I32[arshift((v_t + 24), 2)] = tobit(0)
I32[arshift((v_t + 28), 2)] = tobit(0)
I32[arshift((v_t + 16), 2)] = tobit(0)
I32[arshift((v_t + 20), 2)] = tobit(0)
I32[arshift((v_t + 8), 2)] = tobit(0)
I32[arshift((v_t + 12), 2)] = tobit(0)
I32[arshift(v_t, 2)] = tobit(0)
I32[arshift((v_t + 4), 2)] = tobit(0)
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
F.fP(v_r, v_t)
I8[bor(0, v_e)] = tobit(U8[tobit((v_r + 11))])
I8[tobit((v_e + 1))] = tobit(U16[arshift((v_r + 10), 1)])
I8[tobit((v_e + 2))] = tobit((rshift(I32[arshift((v_r + 8), 2)], 8) % 4294967296))
I8[tobit((v_e + 3))] = tobit(I32[arshift((v_r + 8), 2)])
I8[tobit((v_e + 4))] = tobit(U8[tobit((v_r + 15))])
I8[tobit((v_e + 5))] = tobit(U16[arshift((v_r + 14), 1)])
I8[tobit((v_e + 6))] = tobit((rshift(I32[arshift((v_r + 12), 2)], 8) % 4294967296))
I8[tobit((v_e + 7))] = tobit(I32[arshift((v_r + 12), 2)])
I8[tobit((v_e + 8))] = tobit(U8[tobit((v_r + 19))])
I8[tobit((v_e + 9))] = tobit(U16[arshift((v_r + 18), 1)])
I8[tobit((v_e + 10))] = tobit((rshift(I32[arshift((v_r + 16), 2)], 8) % 4294967296))
I8[tobit((v_e + 11))] = tobit(I32[arshift((v_r + 16), 2)])
I8[tobit((v_e + 12))] = tobit(U8[tobit((v_r + 23))])
I8[tobit((v_e + 13))] = tobit(U16[arshift((v_r + 22), 1)])
I8[tobit((v_e + 14))] = tobit((rshift(I32[arshift((v_r + 20), 2)], 8) % 4294967296))
I8[tobit((v_e + 15))] = tobit(I32[arshift((v_r + 20), 2)])
I8[tobit((v_e + 16))] = tobit(U8[tobit((v_r + 27))])
I8[tobit((v_e + 17))] = tobit(U16[arshift((v_r + 26), 1)])
I8[tobit((v_e + 18))] = tobit((rshift(I32[arshift((v_r + 24), 2)], 8) % 4294967296))
I8[tobit((v_e + 19))] = tobit(I32[arshift((v_r + 24), 2)])
I8[tobit((v_e + 20))] = tobit(U8[tobit((v_r + 31))])
I8[tobit((v_e + 21))] = tobit(U16[arshift((v_r + 30), 1)])
I8[tobit((v_e + 22))] = tobit((rshift(I32[arshift((v_r + 28), 2)], 8) % 4294967296))
I8[tobit((v_e + 23))] = tobit(I32[arshift((v_r + 28), 2)])
I8[tobit((v_e + 24))] = tobit(U8[tobit((v_r + 35))])
I8[tobit((v_e + 25))] = tobit(U16[arshift((v_r + 34), 1)])
I8[tobit((v_e + 26))] = tobit((rshift(I32[arshift((v_r + 32), 2)], 8) % 4294967296))
I8[tobit((v_e + 27))] = tobit(I32[arshift((v_r + 32), 2)])
if not (I32[arshift((v_r + 104), 2)] ~= 0) then
I8[tobit((v_e + 28))] = tobit(U8[tobit((v_r + 39))])
I8[tobit((v_e + 29))] = tobit(U16[arshift((v_r + 38), 1)])
I8[tobit((v_e + 30))] = tobit((rshift(I32[arshift((v_r + 36), 2)], 8) % 4294967296))
I8[tobit((v_e + 31))] = tobit(I32[arshift((v_r + 36), 2)])
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
do return v_e end
end
end

F.fL = function(v_A)
local v_r, v_e, v_n, v_t, v_o, v_f, v_a = 0, 0, 0, 0, 0, 0, 0
v_r = 0
v_e = 0
v_n = 0
v_t = 0
v_o = 0
v_f = 0
v_a = 0
do
do
do
if (v_A ~= 0) then
do
do
v_n = tobit((v_A - 8))
local t161 = v_n
local t160 = (-8)
v_r = I32[arshift((v_A - 4), 2)]
v_A = band(t160, v_r)
v_o = tobit((t161 + v_A))
end
do
do
do
if (not (band(1, v_r) ~= 0)) then
do
if (not (band(3, v_r) ~= 0)) then
goto L142
end
do
local t162 = v_n
v_r = I32[arshift(v_n, 2)]
v_n = tobit((t162 - v_r))
if ((tobit(v_n) % 4294967296) < U32[5685]) then
goto L142
end
end
do
v_A = tobit((v_A + v_r))
if (I32[5686] == bor(0, v_n)) then
v_r = I32[arshift((v_o + 4), 2)]
if (3 == band(3, v_r)) then
I32[5683] = tobit(v_A)
I32[arshift((v_o + 4), 2)] = tobit(band((-2), v_r))
I32[arshift((v_n + 4), 2)] = tobit(bor(1, v_A))
I32[arshift((v_A + v_n), 2)] = tobit(v_A)
do return end
end
else
do
if ((tobit(v_r) % 4294967296) <= 255) then
v_t = I32[arshift((v_n + 8), 2)]
v_r = tobit((rshift(v_r, 3) % 4294967296))
v_e = I32[arshift((v_n + 12), 2)]
if (bor(0, v_e) == bor(0, v_t)) then
I32[5681] = tobit(band(I32[5681], F.fKA((-2), v_r)))
goto L143
end
I32[arshift((v_t + 12), 2)] = tobit(v_e)
I32[arshift((v_e + 8), 2)] = tobit(v_t)
goto L143
end
do
v_a = I32[arshift((v_n + 24), 2)]
local t163 = bor(0, v_n)
v_r = I32[arshift((v_n + 12), 2)]
if (t163 == bor(0, v_r)) then
do
v_t = tobit((v_n + 20))
v_e = I32[arshift(v_t, 2)]
local t164 = (v_e ~= 0)
if not t164 then
v_t = tobit((v_n + 16))
v_e = I32[arshift(v_t, 2)]
t164 = (v_e ~= 0)
end
if t164 then
do
do
do
while true do
do
v_f = v_t
v_r = v_e
v_t = tobit((v_r + 20))
v_e = I32[arshift(v_t, 2)]
local t165 = v_e
if t165 == 0 then
v_t = tobit((v_r + 16))
v_e = I32[arshift((v_r + 16), 2)]
t165 = v_e
end
if not (t165 ~= 0) then goto B144 end
end
do
end
::C144::
end
end
::B144::
end
I32[arshift(v_f, 2)] = tobit(0)
end
else
v_r = 0
end
end
else
v_e = I32[arshift((v_n + 8), 2)]
I32[arshift((v_e + 12), 2)] = tobit(v_r)
I32[arshift((v_r + 8), 2)] = tobit(v_e)
end
end
if (not (v_a ~= 0)) then
goto L143
end
v_t = I32[arshift((v_n + 28), 2)]
do
v_e = tobit((23028 + lshift(v_t, 2)))
if (I32[arshift(v_e, 2)] == bor(0, v_n)) then
I32[arshift(v_e, 2)] = tobit(v_r)
if (v_r ~= 0) then
goto L145
end
I32[5682] = tobit(band(I32[5682], F.fKA((-2), v_t)))
goto L143
end
I32[arshift((v_a + ((I32[arshift((v_a + 16), 2)] == bor(0, v_n)) and 16 or 20)), 2)] = tobit(v_r)
if (not (v_r ~= 0)) then
goto L143
end
end
::L145::
I32[arshift((v_r + 24), 2)] = tobit(v_a)
v_e = I32[arshift((v_n + 16), 2)]
if (v_e ~= 0) then
I32[arshift((v_r + 16), 2)] = tobit(v_e)
I32[arshift((v_e + 24), 2)] = tobit(v_r)
end
v_e = I32[arshift((v_n + 20), 2)]
if (not (v_e ~= 0)) then
goto L143
end
I32[arshift((v_r + 20), 2)] = tobit(v_e)
I32[arshift((v_e + 24), 2)] = tobit(v_r)
end
end
end
end
end
end
end
::L143::
end
do
local t166 = (not ((tobit(v_n) % 4294967296) >= (tobit(v_o) % 4294967296)))
if t166 then
v_r = I32[arshift((v_o + 4), 2)]
t166 = (band(1, v_r) ~= 0)
end
if t166 then
do
do
do
do
do
if (not (band(2, v_r) ~= 0)) then
do
if (I32[5687] == bor(0, v_o)) then
I32[5687] = tobit(v_n)
v_A = tobit((I32[5684] + v_A))
I32[5684] = tobit(v_A)
I32[arshift((v_n + 4), 2)] = tobit(bor(1, v_A))
if (I32[5686] ~= bor(0, v_n)) then
goto L142
end
I32[5683] = tobit(0)
I32[5686] = tobit(0)
do return end
end
if (I32[5686] == bor(0, v_o)) then
I32[5686] = tobit(v_n)
v_A = tobit((I32[5683] + v_A))
I32[5683] = tobit(v_A)
I32[arshift((v_n + 4), 2)] = tobit(bor(1, v_A))
I32[arshift((v_A + v_n), 2)] = tobit(v_A)
do return end
end
v_A = tobit((band((-8), v_r) + v_A))
do
do
do
if ((tobit(v_r) % 4294967296) <= 255) then
v_t = I32[arshift((v_o + 8), 2)]
v_r = tobit((rshift(v_r, 3) % 4294967296))
v_e = I32[arshift((v_o + 12), 2)]
if (bor(0, v_e) == bor(0, v_t)) then
I32[5681] = tobit(band(I32[5681], F.fKA((-2), v_r)))
goto L147
end
I32[arshift((v_t + 12), 2)] = tobit(v_e)
I32[arshift((v_e + 8), 2)] = tobit(v_t)
else
do
do
v_a = I32[arshift((v_o + 24), 2)]
local t167 = bor(0, v_o)
v_r = I32[arshift((v_o + 12), 2)]
if (t167 == bor(0, v_r)) then
do
v_t = tobit((v_o + 20))
v_e = I32[arshift(v_t, 2)]
local t168 = (v_e ~= 0)
if not t168 then
v_t = tobit((v_o + 16))
v_e = I32[arshift(v_t, 2)]
t168 = (v_e ~= 0)
end
if t168 then
do
do
do
while true do
do
v_f = v_t
v_r = v_e
v_t = tobit((v_r + 20))
v_e = I32[arshift(v_t, 2)]
local t169 = v_e
if t169 == 0 then
v_t = tobit((v_r + 16))
v_e = I32[arshift((v_r + 16), 2)]
t169 = v_e
end
if not (t169 ~= 0) then goto B148 end
end
do
end
::C148::
end
end
::B148::
end
I32[arshift(v_f, 2)] = tobit(0)
end
else
v_r = 0
end
end
else
v_e = I32[arshift((v_o + 8), 2)]
I32[arshift((v_e + 12), 2)] = tobit(v_r)
I32[arshift((v_r + 8), 2)] = tobit(v_e)
end
end
if (v_a ~= 0) then
v_t = I32[arshift((v_o + 28), 2)]
do
v_e = tobit((23028 + lshift(v_t, 2)))
if (I32[arshift(v_e, 2)] == bor(0, v_o)) then
I32[arshift(v_e, 2)] = tobit(v_r)
if (v_r ~= 0) then
goto L149
end
I32[5682] = tobit(band(I32[5682], F.fKA((-2), v_t)))
goto L147
end
I32[arshift((v_a + ((I32[arshift((v_a + 16), 2)] == bor(0, v_o)) and 16 or 20)), 2)] = tobit(v_r)
if (not (v_r ~= 0)) then
goto L147
end
end
::L149::
I32[arshift((v_r + 24), 2)] = tobit(v_a)
v_e = I32[arshift((v_o + 16), 2)]
if (v_e ~= 0) then
I32[arshift((v_r + 16), 2)] = tobit(v_e)
I32[arshift((v_e + 24), 2)] = tobit(v_r)
end
v_e = I32[arshift((v_o + 20), 2)]
if (v_e ~= 0) then
I32[arshift((v_r + 20), 2)] = tobit(v_e)
I32[arshift((v_e + 24), 2)] = tobit(v_r)
end
end
end
end
end
end
::L147::
end
I32[arshift((v_n + 4), 2)] = tobit(bor(1, v_A))
I32[arshift((v_A + v_n), 2)] = tobit(v_A)
if (I32[5686] ~= bor(0, v_n)) then
goto L146
end
I32[5683] = tobit(v_A)
do return end
end
end
end
I32[arshift((v_o + 4), 2)] = tobit(band((-2), v_r))
I32[arshift((v_n + 4), 2)] = tobit(bor(1, v_A))
I32[arshift((v_A + v_n), 2)] = tobit(v_A)
end
end
::L146::
end
do
if ((tobit(v_A) % 4294967296) <= 255) then
do
v_A = tobit((rshift(v_A, 3) % 4294967296))
v_r = tobit((22764 + lshift(v_A, 3)))
v_e = I32[5681]
local t170 = v_e
v_A = lshift(1, v_A)
if (band(t170, v_A) ~= 0) then
v_A = I32[arshift((v_r + 8), 2)]
else
I32[5681] = tobit(bor(v_A, v_e))
v_A = v_r
end
I32[arshift((v_r + 8), 2)] = tobit(v_n)
I32[arshift((v_A + 12), 2)] = tobit(v_n)
I32[arshift((v_n + 12), 2)] = tobit(v_r)
I32[arshift((v_n + 8), 2)] = tobit(v_A)
do return end
end
end
end
do
v_t = 31
I32[arshift((v_n + 16), 2)] = tobit(0)
I32[arshift((v_n + 20), 2)] = tobit(0)
if ((tobit(v_A) % 4294967296) <= 16777215) then
v_r = tobit((rshift(v_A, 8) % 4294967296))
local t171 = v_r
v_f = band((rshift((v_r + 1048320), 16) % 4294967296), 8)
v_r = lshift(t171, v_f)
local t172 = v_r
v_t = band((rshift((v_r + 520192), 16) % 4294967296), 4)
v_r = lshift(t172, v_t)
local t173 = v_r
v_e = band((rshift((v_r + 245760), 16) % 4294967296), 2)
v_r = tobit((tobit((rshift(lshift(t173, v_e), 15) % 4294967296)) - bor(bor(v_e, v_t), v_f)))
v_t = tobit((28 + bor(lshift(v_r, 1), band((rshift(v_A, (v_r + 21)) % 4294967296), 1))))
end
I32[arshift((v_n + 28), 2)] = tobit(v_t)
v_f = tobit((23028 + lshift(v_t, 2)))
end
do
do
do
do
do
do
do
v_e = I32[5682]
local t174 = v_e
v_r = lshift(1, v_t)
if (band(t174, v_r) ~= 0) then
do
v_t = lshift(v_A, ((31 == bor(0, v_t)) and 0 or tobit((25 - tobit((rshift(v_t, 1) % 4294967296))))))
v_r = I32[arshift(v_f, 2)]
while true do
do
v_e = v_r
if (band((-8), I32[arshift((v_r + 4), 2)]) == bor(0, v_A)) then
goto L151
end
v_r = tobit((rshift(v_t, 29) % 4294967296))
v_t = lshift(v_t, 1)
v_f = tobit((v_e + band(4, v_r)))
v_r = I32[arshift((16 + v_f), 2)]
if (not (v_r ~= 0)) then
goto B152
end
end
::C152::
end
end
::B152::
I32[arshift((v_f + 16), 2)] = tobit(v_n)
I32[arshift((v_n + 24), 2)] = tobit(v_e)
else
I32[5682] = tobit(bor(v_r, v_e))
I32[arshift(v_f, 2)] = tobit(v_n)
I32[arshift((v_n + 24), 2)] = tobit(v_f)
end
end
I32[arshift((v_n + 12), 2)] = tobit(v_n)
I32[arshift((v_n + 8), 2)] = tobit(v_n)
goto L150
end
end
::L151::
end
v_A = I32[arshift((v_e + 8), 2)]
I32[arshift((v_A + 12), 2)] = tobit(v_n)
I32[arshift((v_e + 8), 2)] = tobit(v_n)
I32[arshift((v_n + 24), 2)] = tobit(0)
I32[arshift((v_n + 12), 2)] = tobit(v_e)
I32[arshift((v_n + 8), 2)] = tobit(v_A)
end
end
::L150::
end
do
v_A = tobit((I32[5689] - 1))
local t175 = v_A
if t175 == 0 then
t175 = (-1)
end
I32[5689] = tobit(t175)
end
end
end
end
end
end
end
end
::L142::
end
end

F.fF = function(v_A, v_r, v_e)
local v_t, v_o, v_a, v_u, v_c, v_s, v_l, v_b, v_v, v_g = 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
v_t = 0
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
v_t = bor(bor(bor(U8[tobit((v_r + 12))], lshift(U8[tobit((v_r + 13))], 8)), lshift(U8[tobit((v_r + 14))], 16)), lshift(U8[tobit((v_r + 15))], 24))
v_a = bxor(I32[arshift((v_A + 16), 2)], bor(bor(bor(lshift(v_t, 24), band(lshift(v_t, 8), 16711680)), band((rshift(v_t, 8) % 4294967296), 65280)), (rshift(v_t, 24) % 4294967296)))
v_t = bor(bor(bor(U8[tobit((v_r + 8))], lshift(U8[tobit((v_r + 9))], 8)), lshift(U8[tobit((v_r + 10))], 16)), lshift(U8[tobit((v_r + 11))], 24))
v_l = bxor(I32[arshift((v_A + 12), 2)], bor(bor(bor(lshift(v_t, 24), band(lshift(v_t, 8), 16711680)), band((rshift(v_t, 8) % 4294967296), 65280)), (rshift(v_t, 24) % 4294967296)))
v_t = bor(bor(bor(U8[tobit((v_r + 4))], lshift(U8[tobit((v_r + 5))], 8)), lshift(U8[tobit((v_r + 6))], 16)), lshift(U8[tobit((v_r + 7))], 24))
v_u = bxor(I32[arshift((v_A + 8), 2)], bor(bor(bor(lshift(v_t, 24), band(lshift(v_t, 8), 16711680)), band((rshift(v_t, 8) % 4294967296), 65280)), (rshift(v_t, 24) % 4294967296)))
v_r = bor(bor(bor(U8[bor(0, v_r)], lshift(U8[tobit((v_r + 1))], 8)), lshift(U8[tobit((v_r + 2))], 16)), lshift(U8[tobit((v_r + 3))], 24))
v_t = bxor(I32[arshift((v_A + 4), 2)], bor(bor(bor(lshift(v_r, 24), band(lshift(v_r, 8), 16711680)), band((rshift(v_r, 8) % 4294967296), 65280)), (rshift(v_r, 24) % 4294967296)))
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
v_o = U8[tobit((7840 + tobit((rshift(v_A, 24) % 4294967296))))]
v_g = v_a
v_a = bor(bor(bor(U8[tobit((7584 + band(255, v_A)))], lshift(U8[tobit((8096 + band((rshift(v_A, 16) % 4294967296), 255)))], 16)), lshift(v_o, 24)), lshift(U8[tobit((8352 + band((rshift(v_A, 8) % 4294967296), 255)))], 8))
v_A = bxor(I32[arshift(v_r, 2)], v_t)
v_A = bxor(bor(v_o, lshift(v_a, 8)), bor(bor(bor(lshift(U8[tobit((7840 + band((rshift(v_A, 16) % 4294967296), 255)))], 16), lshift(U8[tobit((7584 + tobit((rshift(v_A, 24) % 4294967296))))], 24)), lshift(U8[tobit((8096 + band((rshift(v_A, 8) % 4294967296), 255)))], 8)), U8[tobit((8352 + band(255, v_A)))]))
v_s = bxor(F.fKA(v_A, 16), v_a)
local t176 = v_g
v_b = bxor(F.fKA(v_s, 24), v_A)
v_a = bxor(t176, v_b)
v_A = bxor(v_a, I32[arshift((v_r + 12), 2)])
v_o = U8[tobit((7840 + tobit((rshift(v_A, 24) % 4294967296))))]
v_c = bor(bor(bor(U8[tobit((7584 + band(255, v_A)))], lshift(U8[tobit((8096 + band((rshift(v_A, 16) % 4294967296), 255)))], 16)), lshift(v_o, 24)), lshift(U8[tobit((8352 + band((rshift(v_A, 8) % 4294967296), 255)))], 8))
v_l = bxor(bxor(F.fKA(v_b, 24), v_l), v_s)
v_A = bxor(v_l, I32[arshift((v_r + 8), 2)])
v_A = bxor(bor(v_o, lshift(v_c, 8)), bor(bor(bor(lshift(U8[tobit((7840 + band((rshift(v_A, 16) % 4294967296), 255)))], 16), lshift(U8[tobit((7584 + tobit((rshift(v_A, 24) % 4294967296))))], 24)), lshift(U8[tobit((8096 + band((rshift(v_A, 8) % 4294967296), 255)))], 8)), U8[tobit((8352 + band(255, v_A)))]))
v_s = bxor(F.fKA(v_A, 16), v_c)
local t177 = v_u
v_b = bxor(F.fKA(v_s, 24), v_A)
v_u = bxor(t177, v_b)
v_A = bxor(v_u, I32[arshift((v_r + 20), 2)])
v_o = U8[tobit((7840 + tobit((rshift(v_A, 24) % 4294967296))))]
v_c = bor(bor(bor(U8[tobit((7584 + band(255, v_A)))], lshift(U8[tobit((8096 + band((rshift(v_A, 16) % 4294967296), 255)))], 16)), lshift(v_o, 24)), lshift(U8[tobit((8352 + band((rshift(v_A, 8) % 4294967296), 255)))], 8))
v_t = bxor(bxor(F.fKA(v_b, 24), v_t), v_s)
v_A = bxor(v_t, I32[arshift((v_r + 16), 2)])
v_A = bxor(bor(v_o, lshift(v_c, 8)), bor(bor(bor(lshift(U8[tobit((7840 + band((rshift(v_A, 16) % 4294967296), 255)))], 16), lshift(U8[tobit((7584 + tobit((rshift(v_A, 24) % 4294967296))))], 24)), lshift(U8[tobit((8096 + band((rshift(v_A, 8) % 4294967296), 255)))], 8)), U8[tobit((8352 + band(255, v_A)))]))
v_s = bxor(F.fKA(v_A, 16), v_c)
local t178 = v_a
v_b = bxor(F.fKA(v_s, 24), v_A)
v_a = bxor(t178, v_b)
v_A = bxor(v_a, I32[arshift((v_r + 28), 2)])
v_o = U8[tobit((7840 + tobit((rshift(v_A, 24) % 4294967296))))]
v_c = bor(bor(bor(U8[tobit((7584 + band(255, v_A)))], lshift(U8[tobit((8096 + band((rshift(v_A, 16) % 4294967296), 255)))], 16)), lshift(v_o, 24)), lshift(U8[tobit((8352 + band((rshift(v_A, 8) % 4294967296), 255)))], 8))
v_l = bxor(bxor(F.fKA(v_b, 24), v_l), v_s)
v_A = bxor(v_l, I32[arshift((v_r + 24), 2)])
v_A = bxor(bor(v_o, lshift(v_c, 8)), bor(bor(bor(lshift(U8[tobit((7840 + band((rshift(v_A, 16) % 4294967296), 255)))], 16), lshift(U8[tobit((7584 + tobit((rshift(v_A, 24) % 4294967296))))], 24)), lshift(U8[tobit((8096 + band((rshift(v_A, 8) % 4294967296), 255)))], 8)), U8[tobit((8352 + band(255, v_A)))]))
v_s = bxor(F.fKA(v_A, 16), v_c)
local t179 = v_u
v_b = bxor(F.fKA(v_s, 24), v_A)
v_u = bxor(t179, v_b)
v_A = bxor(v_u, I32[arshift((v_r + 36), 2)])
v_o = U8[tobit((7840 + tobit((rshift(v_A, 24) % 4294967296))))]
v_c = bor(bor(bor(U8[tobit((7584 + band(255, v_A)))], lshift(U8[tobit((8096 + band((rshift(v_A, 16) % 4294967296), 255)))], 16)), lshift(v_o, 24)), lshift(U8[tobit((8352 + band((rshift(v_A, 8) % 4294967296), 255)))], 8))
v_t = bxor(bxor(F.fKA(v_b, 24), v_t), v_s)
v_A = bxor(v_t, I32[arshift((v_r + 32), 2)])
v_A = bxor(bor(v_o, lshift(v_c, 8)), bor(bor(bor(lshift(U8[tobit((7840 + band((rshift(v_A, 16) % 4294967296), 255)))], 16), lshift(U8[tobit((7584 + tobit((rshift(v_A, 24) % 4294967296))))], 24)), lshift(U8[tobit((8096 + band((rshift(v_A, 8) % 4294967296), 255)))], 8)), U8[tobit((8352 + band(255, v_A)))]))
v_c = bxor(F.fKA(v_A, 16), v_c)
local t180 = v_a
v_s = bxor(F.fKA(v_c, 24), v_A)
v_a = bxor(t180, v_s)
v_A = bxor(v_a, I32[arshift((v_r + 44), 2)])
v_o = U8[tobit((7840 + tobit((rshift(v_A, 24) % 4294967296))))]
v_g = v_u
v_u = bor(bor(bor(U8[tobit((7584 + band(255, v_A)))], lshift(U8[tobit((8096 + band((rshift(v_A, 16) % 4294967296), 255)))], 16)), lshift(v_o, 24)), lshift(U8[tobit((8352 + band((rshift(v_A, 8) % 4294967296), 255)))], 8))
v_l = bxor(bxor(F.fKA(v_s, 24), v_c), v_l)
v_A = bxor(v_l, I32[arshift((v_r + 40), 2)])
v_A = bxor(bor(v_o, lshift(v_u, 8)), bor(bor(bor(lshift(U8[tobit((7840 + band((rshift(v_A, 16) % 4294967296), 255)))], 16), lshift(U8[tobit((7584 + tobit((rshift(v_A, 24) % 4294967296))))], 24)), lshift(U8[tobit((8096 + band((rshift(v_A, 8) % 4294967296), 255)))], 8)), U8[tobit((8352 + band(255, v_A)))]))
v_o = bxor(F.fKA(v_A, 16), v_u)
local t181 = v_g
v_A = bxor(F.fKA(v_o, 24), v_A)
v_u = bxor(t181, v_A)
v_t = bxor(bxor(F.fKA(v_A, 24), v_t), v_o)
v_v = tobit((v_v - 1))
if (not (v_v ~= 0)) then
v_r = tobit((v_r + 48))
goto B153
end
end
v_l = bxor(bor(I32[arshift((v_r + 60), 2)], v_a), v_l)
v_a = bxor(F.fKA(band(v_l, I32[arshift((v_r + 56), 2)]), 1), v_a)
v_u = bxor(F.fKA(band(I32[arshift((v_r + 48), 2)], v_t), 1), v_u)
v_t = bxor(bor(v_u, I32[arshift((v_r + 52), 2)]), v_t)
v_r = tobit((v_r - (-64)))
end
end
::C153::
end
end
::B153::
end
end
end
v_v = I32[arshift(v_r, 2)]
v_o = I32[arshift((v_r + 4), 2)]
v_c = I32[arshift((v_r + 8), 2)]
v_A = bxor(I32[arshift((v_r + 12), 2)], v_u)
I8[tobit((v_e + 15))] = tobit(v_A)
v_r = bxor(v_t, v_c)
I8[tobit((v_e + 11))] = tobit(v_r)
v_t = bxor(v_o, v_a)
I8[tobit((v_e + 7))] = tobit(v_t)
v_a = bxor(v_l, v_v)
I8[tobit((v_e + 3))] = tobit(v_a)
I8[tobit((v_e + 14))] = tobit((rshift(v_A, 8) % 4294967296))
I8[tobit((v_e + 13))] = tobit((rshift(v_A, 16) % 4294967296))
I8[tobit((v_e + 12))] = tobit((rshift(v_A, 24) % 4294967296))
I8[tobit((v_e + 10))] = tobit((rshift(v_r, 8) % 4294967296))
I8[tobit((v_e + 9))] = tobit((rshift(v_r, 16) % 4294967296))
I8[tobit((v_e + 8))] = tobit((rshift(v_r, 24) % 4294967296))
I8[tobit((v_e + 6))] = tobit((rshift(v_t, 8) % 4294967296))
I8[tobit((v_e + 5))] = tobit((rshift(v_t, 16) % 4294967296))
I8[tobit((v_e + 4))] = tobit((rshift(v_t, 24) % 4294967296))
I8[tobit((v_e + 2))] = tobit((rshift(v_a, 8) % 4294967296))
I8[tobit((v_e + 1))] = tobit((rshift(v_a, 16) % 4294967296))
I8[bor(0, v_e)] = tobit((rshift(v_a, 24) % 4294967296))
do return 0 end
end

F.fH = function(v_A, v_r, v_e)
local v_t, v_o, v_a, v_u, v_c, v_s = 0, 0, 0, 0, 0, 0
v_t = 0
v_o = 0
v_a = 0
v_u = 0
v_c = 0
v_s = 0
do
do
do
v_t = bor(bor(bor(U8[bor(0, v_r)], lshift(U8[tobit((v_r + 1))], 8)), lshift(U8[tobit((v_r + 2))], 16)), lshift(U8[tobit((v_r + 3))], 24))
v_t = bor(bor(bor(lshift(v_t, 24), band(lshift(v_t, 8), 16711680)), band((rshift(v_t, 8) % 4294967296), 65280)), (rshift(v_t, 24) % 4294967296))
local t183 = v_t
local t182 = (rshift(v_t, 4) % 4294967296)
v_r = bor(bor(bor(U8[tobit((v_r + 4))], lshift(U8[tobit((v_r + 5))], 8)), lshift(U8[tobit((v_r + 6))], 16)), lshift(U8[tobit((v_r + 7))], 24))
v_r = bor(bor(bor(lshift(v_r, 24), band(lshift(v_r, 8), 16711680)), band((rshift(v_r, 8) % 4294967296), 65280)), (rshift(v_r, 24) % 4294967296))
v_o = band(252645135, bxor(t182, v_r))
v_t = bxor(t183, lshift(v_o, 4))
v_o = bxor(v_o, v_r)
local t184 = v_o
v_r = bxor((rshift(v_t, 16) % 4294967296), band(65535, v_o))
v_o = bxor(t184, v_r)
local t186 = v_o
local t185 = (rshift(v_o, 2) % 4294967296)
v_r = bxor(v_t, lshift(v_r, 16))
v_t = band(858993459, bxor(t185, v_r))
v_o = bxor(t186, lshift(v_t, 2))
local t187 = (rshift(v_o, 8) % 4294967296)
v_r = bxor(v_r, v_t)
v_t = band(16711935, bxor(t187, v_r))
v_o = F.fKA(bxor(lshift(v_t, 8), v_o), 1)
local t189 = v_o
local t188 = (-1431655766)
v_r = bxor(v_r, v_t)
v_t = band(t188, bxor(v_r, v_o))
v_o = bxor(t189, v_t)
v_r = F.fKA(bxor(v_r, v_t), 1)
v_t = v_A
v_u = 1
end
while true do
v_s = v_o
v_c = bxor(I32[arshift((v_t + 4), 2)], F.fKA(v_o, 28))
v_a = v_r
v_r = bxor(I32[arshift(v_t, 2)], v_o)
v_r = bxor(bxor(bxor(bxor(bxor(bxor(bxor(bxor(I32[arshift((2176 + lshift(band(63, v_c), 2)), 2)], v_a), I32[arshift((1152 + lshift(band(63, v_r), 2)), 2)]), I32[arshift((1408 + band((rshift(v_r, 6) % 4294967296), 252)), 2)]), I32[arshift((1664 + band((rshift(v_r, 14) % 4294967296), 252)), 2)]), I32[arshift((1920 + band((rshift(v_r, 22) % 4294967296), 252)), 2)]), I32[arshift((2432 + band((rshift(v_c, 6) % 4294967296), 252)), 2)]), I32[arshift((2688 + band((rshift(v_c, 14) % 4294967296), 252)), 2)]), I32[arshift((2944 + band((rshift(v_c, 22) % 4294967296), 252)), 2)])
v_o = bxor(v_r, I32[arshift((v_t + 8), 2)])
v_a = bxor(bxor(bxor(bxor(v_s, I32[arshift((1152 + lshift(band(63, v_o), 2)), 2)]), I32[arshift((1408 + band((rshift(v_o, 6) % 4294967296), 252)), 2)]), I32[arshift((1664 + band((rshift(v_o, 14) % 4294967296), 252)), 2)]), I32[arshift((1920 + band((rshift(v_o, 22) % 4294967296), 252)), 2)])
v_o = bxor(I32[arshift((v_t + 12), 2)], F.fKA(v_r, 28))
v_o = bxor(bxor(bxor(bxor(v_a, I32[arshift((2176 + lshift(band(63, v_o), 2)), 2)]), I32[arshift((2432 + band((rshift(v_o, 6) % 4294967296), 252)), 2)]), I32[arshift((2688 + band((rshift(v_o, 14) % 4294967296), 252)), 2)]), I32[arshift((2944 + band((rshift(v_o, 22) % 4294967296), 252)), 2)])
if not (8 ~= bor(0, v_u)) then goto B154 end
do
v_t = tobit((v_t + 16))
v_u = tobit((v_u + 1))
end
::C154::
end
end
::B154::
end
do
v_t = tobit((v_A + 128))
v_u = 1
while true do
v_a = v_r
v_c = bxor(I32[arshift((v_t + 4), 2)], F.fKA(v_r, 28))
v_r = bxor(I32[arshift(v_t, 2)], v_r)
v_o = bxor(bxor(bxor(bxor(bxor(bxor(bxor(bxor(I32[arshift((2176 + lshift(band(63, v_c), 2)), 2)], I32[arshift((1152 + lshift(band(63, v_r), 2)), 2)]), v_o), I32[arshift((1408 + band((rshift(v_r, 6) % 4294967296), 252)), 2)]), I32[arshift((1664 + band((rshift(v_r, 14) % 4294967296), 252)), 2)]), I32[arshift((1920 + band((rshift(v_r, 22) % 4294967296), 252)), 2)]), I32[arshift((2432 + band((rshift(v_c, 6) % 4294967296), 252)), 2)]), I32[arshift((2688 + band((rshift(v_c, 14) % 4294967296), 252)), 2)]), I32[arshift((2944 + band((rshift(v_c, 22) % 4294967296), 252)), 2)])
v_r = bxor(v_o, I32[arshift((v_t + 8), 2)])
v_a = bxor(bxor(bxor(bxor(v_a, I32[arshift((1152 + lshift(band(63, v_r), 2)), 2)]), I32[arshift((1408 + band((rshift(v_r, 6) % 4294967296), 252)), 2)]), I32[arshift((1664 + band((rshift(v_r, 14) % 4294967296), 252)), 2)]), I32[arshift((1920 + band((rshift(v_r, 22) % 4294967296), 252)), 2)])
v_r = bxor(I32[arshift((v_t + 12), 2)], F.fKA(v_o, 28))
v_r = bxor(bxor(bxor(bxor(v_a, I32[arshift((2176 + lshift(band(63, v_r), 2)), 2)]), I32[arshift((2432 + band((rshift(v_r, 6) % 4294967296), 252)), 2)]), I32[arshift((2688 + band((rshift(v_r, 14) % 4294967296), 252)), 2)]), I32[arshift((2944 + band((rshift(v_r, 22) % 4294967296), 252)), 2)])
if not (8 ~= bor(0, v_u)) then goto B155 end
do
v_t = tobit((v_t + 16))
v_u = tobit((v_u + 1))
end
::C155::
end
end
::B155::
do
v_t = tobit((v_A + 256))
v_u = 1
while true do
v_A = bxor(I32[arshift((v_t + 4), 2)], F.fKA(v_o, 28))
v_a = v_r
v_r = bxor(I32[arshift(v_t, 2)], v_o)
v_r = bxor(bxor(bxor(bxor(bxor(bxor(bxor(bxor(I32[arshift((2176 + lshift(band(63, v_A), 2)), 2)], v_a), I32[arshift((1152 + lshift(band(63, v_r), 2)), 2)]), I32[arshift((1408 + band((rshift(v_r, 6) % 4294967296), 252)), 2)]), I32[arshift((1664 + band((rshift(v_r, 14) % 4294967296), 252)), 2)]), I32[arshift((1920 + band((rshift(v_r, 22) % 4294967296), 252)), 2)]), I32[arshift((2432 + band((rshift(v_A, 6) % 4294967296), 252)), 2)]), I32[arshift((2688 + band((rshift(v_A, 14) % 4294967296), 252)), 2)]), I32[arshift((2944 + band((rshift(v_A, 22) % 4294967296), 252)), 2)])
v_A = bxor(v_r, I32[arshift((v_t + 8), 2)])
v_a = bxor(bxor(bxor(bxor(I32[arshift((1152 + lshift(band(63, v_A), 2)), 2)], v_o), I32[arshift((1408 + band((rshift(v_A, 6) % 4294967296), 252)), 2)]), I32[arshift((1664 + band((rshift(v_A, 14) % 4294967296), 252)), 2)]), I32[arshift((1920 + band((rshift(v_A, 22) % 4294967296), 252)), 2)])
v_A = bxor(I32[arshift((v_t + 12), 2)], F.fKA(v_r, 28))
v_o = bxor(bxor(bxor(bxor(v_a, I32[arshift((2176 + lshift(band(63, v_A), 2)), 2)]), I32[arshift((2432 + band((rshift(v_A, 6) % 4294967296), 252)), 2)]), I32[arshift((2688 + band((rshift(v_A, 14) % 4294967296), 252)), 2)]), I32[arshift((2944 + band((rshift(v_A, 22) % 4294967296), 252)), 2)])
if not (8 ~= bor(0, v_u)) then goto B156 end
do
v_t = tobit((v_t + 16))
v_u = tobit((v_u + 1))
end
::C156::
end
end
::B156::
do
v_s = lshift(v_r, 31)
local t192 = v_s
v_a = v_r
local t191 = v_a
local t190 = (-1431655766)
v_A = F.fKA(v_o, 31)
v_r = band(t190, bxor(v_A, v_r))
v_t = bor(t192, (rshift(bxor(t191, v_r), 1) % 4294967296))
local t194 = v_t
local t193 = (rshift(v_t, 8) % 4294967296)
v_A = bxor(v_A, v_r)
v_r = band(16711935, bxor(t193, v_A))
v_t = bxor(t194, lshift(v_r, 8))
local t196 = v_t
local t195 = (rshift(v_t, 2) % 4294967296)
v_A = bxor(v_A, v_r)
v_r = band(858993459, bxor(t195, v_A))
v_t = bxor(t196, lshift(v_r, 2))
local t197 = band(65535, v_t)
v_A = bxor(v_A, v_r)
v_r = bxor(t197, (rshift(v_A, 16) % 4294967296))
v_o = bxor(lshift(v_r, 16), v_A)
v_A = bxor(v_r, v_t)
local t198 = v_A
v_r = band(252645135, bxor((rshift(v_o, 4) % 4294967296), v_A))
v_A = bxor(t198, v_r)
I8[tobit((v_e + 7))] = tobit(v_A)
I8[tobit((v_e + 6))] = tobit((rshift(v_A, 8) % 4294967296))
I8[tobit((v_e + 5))] = tobit((rshift(v_A, 16) % 4294967296))
I8[tobit((v_e + 4))] = tobit((rshift(v_A, 24) % 4294967296))
v_A = bxor(v_o, lshift(v_r, 4))
I8[tobit((v_e + 3))] = tobit(v_A)
I8[tobit((v_e + 2))] = tobit((rshift(v_A, 8) % 4294967296))
I8[tobit((v_e + 1))] = tobit((rshift(v_A, 16) % 4294967296))
I8[bor(0, v_e)] = tobit((rshift(v_A, 24) % 4294967296))
do return 0 end
end
end

F.fN = function(v_A, v_r, v_e, v_n)
local v_t, v_o, v_a, v_u, v_c, v_s, v_l, v_b, v_v, v_g, v_p, v_d, v_h, v_k, v_y, v_w, v_C, v_E, v_m, v_Q, v_O, v_S, v_M, v_x, v_j, v_T, v_P, v_K, v_R, v_D = 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
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
v_d = 0
v_h = 0
v_k = 0
v_y = 0
v_w = 0
v_C = 0
v_E = 0
v_m = 0
v_Q = 0
v_O = 0
v_S = 0
v_M = 0
v_x = 0
v_j = 0
v_T = 0
v_P = 0
v_K = 0
v_R = 0
v_D = 0
do
v_t = tobit((B - 32))
B = v_t
v_g = (-20)
v_r = F.fBA(v_r, v_n)
if not (bor(((not (v_r ~= 0)) and 1 or 0), ((16 ~= I32[arshift((v_r + 24), 2)]) and 1 or 0)) ~= 0) then
F.fAA(v_A)
v_g = F.flA(v_A, v_r)
local t199 = (v_g ~= 0)
if not t199 then
v_g = F.fIA(v_A, v_e, v_n)
t199 = (v_g ~= 0)
end
if not t199 then
v_r = v_t
I32[arshift((v_r + 16), 2)] = tobit(0)
I32[arshift((v_r + 20), 2)] = tobit(0)
I32[arshift((v_r + 24), 2)] = tobit(0)
I32[arshift((v_r + 28), 2)] = tobit(0)
I32[arshift((v_r + 12), 2)] = tobit(0)
v_g = F.fW(v_A, tobit((v_r + 16)), tobit((v_r + 16)), tobit((v_r + 12)))
if not (v_g ~= 0) then
v_e = v_t
v_E = U8[tobit((v_e + 31))]
v_m = U8[tobit((v_e + 30))]
v_Q = U8[tobit((v_e + 27))]
v_j = U8[tobit((v_e + 26))]
v_O = U8[tobit((v_e + 25))]
v_T = U8[tobit((v_e + 24))]
v_k = U8[tobit((v_e + 29))]
v_a = U8[tobit((v_e + 28))]
v_n = U8[tobit((v_e + 23))]
v_c = U8[tobit((v_e + 22))]
v_u = U8[tobit((v_e + 19))]
v_s = U8[tobit((v_e + 18))]
v_v = U8[tobit((v_e + 17))]
v_y = U8[tobit((v_e + 16))]
v_r = U8[tobit((v_e + 21))]
v_o = U8[tobit((v_e + 20))]
I32[arshift((v_A + 192), 2)] = tobit(0)
I32[arshift((v_A + 196), 2)] = tobit(0)
I32[arshift((v_A + 64), 2)] = tobit(0)
I32[arshift((v_A + 68), 2)] = tobit(0)
v_e = v_r
local t200 = (rshift(v_o, 8) % 4294967296)
v_r = tobit((rshift(v_r, 16) % 4294967296))
v_w = bor(t200, v_r)
local t201 = lshift(v_c, 8)
v_S = bor(lshift(v_e, 16), lshift(v_o, 24))
v_l = bor(bor(t201, v_S), v_n)
local t202 = lshift(v_s, 8)
v_v = bor(lshift(v_v, 16), lshift(v_y, 24))
v_r = bor(bor(t202, v_v), v_u)
v_r = bor(bor(v_r, v_w), (rshift(v_c, 24) % 4294967296))
v_c = v_r
I32[arshift((v_A + 256), 2)] = tobit(v_l)
I32[arshift((v_A + 260), 2)] = tobit(v_r)
v_r = tobit((rshift(v_a, 8) % 4294967296))
local t203 = v_r
v_e = tobit((rshift(v_k, 16) % 4294967296))
v_u = bor(t203, v_e)
local t204 = lshift(v_j, 8)
v_s = bor(lshift(v_O, 16), lshift(v_T, 24))
v_r = bor(bor(t204, v_s), v_Q)
v_r = bor(bor(v_r, v_u), (rshift(v_m, 24) % 4294967296))
v_u = v_r
local t205 = lshift(v_m, 8)
v_a = bor(lshift(v_k, 16), lshift(v_a, 24))
v_o = v_a
v_b = bor(bor(t205, v_o), v_E)
I32[arshift((v_A + 128), 2)] = tobit(v_b)
I32[arshift((v_A + 132), 2)] = tobit(v_r)
v_e = v_c
v_r = tobit((rshift(v_e, 1) % 4294967296))
v_a = bor(lshift(band(1, v_e), 31), (rshift(v_l, 1) % 4294967296))
v_d = bxor(F.fCA(band(1, v_E), 0, 0, (-520093696)), v_a)
v_r = bxor(v_r, Iv)
v_s = v_r
I32[arshift((v_A + 224), 2)] = tobit(v_d)
I32[arshift((v_A + 228), 2)] = tobit(v_r)
v_o = v_u
v_r = tobit((rshift(v_o, 1) % 4294967296))
v_p = bor(lshift(band(1, v_o), 31), (rshift(v_b, 1) % 4294967296))
local t206 = v_r
v_n = lshift(v_n, 31)
v_r = bor(t206, v_n)
v_v = v_r
I32[arshift((v_A + 96), 2)] = tobit(v_p)
I32[arshift((v_A + 100), 2)] = tobit(v_r)
v_n = v_r
v_r = tobit((rshift(v_r, 1) % 4294967296))
v_h = bor(lshift(band(1, v_n), 31), (rshift(v_p, 1) % 4294967296))
local t207 = v_r
v_e = lshift(v_a, 31)
v_r = bor(t207, v_e)
v_y = v_r
I32[arshift((v_A + 80), 2)] = tobit(v_h)
I32[arshift((v_A + 84), 2)] = tobit(v_r)
v_e = v_s
v_r = tobit((rshift(v_e, 1) % 4294967296))
v_a = bor(lshift(band(1, v_e), 31), (rshift(v_d, 1) % 4294967296))
v_C = bxor(F.fCA(band(1, v_p), 0, 0, (-520093696)), v_a)
v_e = bxor(Iv, v_r)
v_M = v_e
I32[arshift((v_A + 208), 2)] = tobit(v_C)
I32[arshift((v_A + 212), 2)] = tobit(v_e)
v_e = bxor(v_n, v_y)
v_E = v_e
v_R = bxor(v_p, v_h)
I32[arshift((v_A + 112), 2)] = tobit(v_R)
I32[arshift((v_A + 116), 2)] = tobit(v_e)
v_n = v_y
v_r = tobit((rshift(v_n, 1) % 4294967296))
v_x = bor(lshift(band(1, v_n), 31), (rshift(v_h, 1) % 4294967296))
local t208 = v_r
v_e = lshift(v_a, 31)
v_r = bor(t208, v_e)
v_P = v_r
I32[arshift((v_A + 72), 2)] = tobit(v_x)
I32[arshift((v_A + 76), 2)] = tobit(v_r)
v_r = bxor(v_s, v_M)
v_m = v_r
v_Q = bxor(v_d, v_C)
I32[arshift((v_A + 240), 2)] = tobit(v_Q)
I32[arshift((v_A + 244), 2)] = tobit(v_r)
v_e = v_M
v_r = tobit((rshift(v_e, 1) % 4294967296))
v_o = bxor(F.fCA(band(1, v_h), 0, 0, (-520093696)), bor(lshift(band(1, v_e), 31), (rshift(v_C, 1) % 4294967296)))
v_r = bxor(v_r, Iv)
v_e = v_r
I32[arshift((v_A + 200), 2)] = tobit(v_o)
I32[arshift((v_A + 204), 2)] = tobit(v_r)
v_r = bxor(v_n, v_P)
v_D = v_r
v_K = bxor(v_h, v_x)
I32[arshift((v_A + 88), 2)] = tobit(v_K)
I32[arshift((v_A + 92), 2)] = tobit(v_r)
v_r = bxor(v_v, v_P)
v_j = v_r
v_O = bxor(v_p, v_x)
I32[arshift((v_A + 104), 2)] = tobit(v_O)
I32[arshift((v_A + 108), 2)] = tobit(v_r)
v_r = bxor(v_e, v_M)
v_S = v_r
v_w = bxor(v_o, v_C)
I32[arshift((v_A + 216), 2)] = tobit(v_w)
I32[arshift((v_A + 220), 2)] = tobit(v_r)
v_r = bxor(v_e, v_s)
v_T = v_r
v_k = bxor(v_o, v_d)
I32[arshift((v_A + 232), 2)] = tobit(v_k)
I32[arshift((v_A + 236), 2)] = tobit(v_r)
I32[arshift((v_A + 264), 2)] = tobit(bxor(v_o, v_l))
I32[arshift((v_A + 268), 2)] = tobit(bxor(v_e, v_c))
v_r = bxor(v_v, v_D)
v_a = v_r
v_o = bxor(v_p, v_K)
I32[arshift((v_A + 120), 2)] = tobit(v_o)
I32[arshift((v_A + 124), 2)] = tobit(v_r)
v_n = bxor(v_s, v_S)
v_e = v_n
v_r = bxor(v_d, v_w)
I32[arshift((v_A + 248), 2)] = tobit(v_r)
I32[arshift((v_A + 252), 2)] = tobit(v_e)
I32[arshift((v_A + 272), 2)] = tobit(bxor(v_l, v_C))
I32[arshift((v_A + 276), 2)] = tobit(bxor(v_c, v_M))
I32[arshift((v_A + 136), 2)] = tobit(bxor(v_b, v_x))
I32[arshift((v_A + 140), 2)] = tobit(bxor(v_u, v_P))
I32[arshift((v_A + 144), 2)] = tobit(bxor(v_b, v_h))
I32[arshift((v_A + 148), 2)] = tobit(bxor(v_u, v_y))
I32[arshift((v_A + 280), 2)] = tobit(bxor(v_l, v_w))
I32[arshift((v_A + 284), 2)] = tobit(bxor(v_c, v_S))
I32[arshift((v_A + 152), 2)] = tobit(bxor(v_b, v_K))
I32[arshift((v_A + 156), 2)] = tobit(bxor(v_u, v_D))
I32[arshift((v_A + 288), 2)] = tobit(bxor(v_l, v_d))
I32[arshift((v_A + 292), 2)] = tobit(bxor(v_c, v_s))
I32[arshift((v_A + 160), 2)] = tobit(bxor(v_b, v_p))
I32[arshift((v_A + 164), 2)] = tobit(bxor(v_u, v_v))
I32[arshift((v_A + 296), 2)] = tobit(bxor(v_l, v_k))
I32[arshift((v_A + 300), 2)] = tobit(bxor(v_c, v_T))
I32[arshift((v_A + 168), 2)] = tobit(bxor(v_b, v_O))
I32[arshift((v_A + 172), 2)] = tobit(bxor(v_u, v_j))
I32[arshift((v_A + 304), 2)] = tobit(bxor(v_l, v_Q))
I32[arshift((v_A + 308), 2)] = tobit(bxor(v_c, v_m))
I32[arshift((v_A + 176), 2)] = tobit(bxor(v_b, v_R))
I32[arshift((v_A + 180), 2)] = tobit(bxor(v_u, v_E))
I32[arshift((v_A + 312), 2)] = tobit(bxor(v_r, v_l))
I32[arshift((v_A + 316), 2)] = tobit(bxor(v_e, v_c))
I32[arshift((v_A + 184), 2)] = tobit(bxor(v_o, v_b))
I32[arshift((v_A + 188), 2)] = tobit(bxor(v_u, v_a))
end
end
end
B = tobit((v_t + 32))
do return v_g end
end
end

F.fU = function(v_A, v_r, v_e, v_t)
local v_o, v_a, v_u, v_c, v_s, v_l, v_b, v_v, v_g, v_p, v_d, v_h, v_k, v_y, v_w, v_C, v_E, v_I, v_m, v_Q, v_O = 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
v_a = 0
v_u = 0
v_c = 0
v_s = 0
v_l = 0
v_b = 0
v_v = 0
v_g = 0
v_p = 0
v_d = 0
v_h = 0
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
local t209 = (((tobit(v_e) % 4294967296) < (tobit(v_t) % 4294967296)) and 1 or 0)
if t209 ~= 0 then
v_a = (-20)
t209 = (((tobit((v_t - v_e)) % 4294967296) < (tobit(v_r) % 4294967296)) and 1 or 0)
end
local t210 = t209
if t210 == 0 then
v_a = (-20)
v_s = I32[arshift((v_A + 324), 2)]
v_u = v_s
v_l = I32[arshift((v_A + 320), 2)]
local t211 = v_l
v_c = v_r
v_v = tobit((t211 + v_c))
v_u = (((tobit(v_v) % 4294967296) < (tobit(v_c) % 4294967296)) and tobit((v_u + 1)) or v_u)
v_c = v_u
t210 = bor(bor(bor(band(((bor(0, v_s) == bor(0, v_u)) and 1 or 0), (((tobit(v_l) % 4294967296) > (tobit(v_v) % 4294967296)) and 1 or 0)), (((tobit(v_u) % 4294967296) < (tobit(v_s) % 4294967296)) and 1 or 0)), band(((15 == bor(0, v_u)) and 1 or 0), (((tobit(v_v) % 4294967296) > 4294967264) and 1 or 0))), (((tobit(v_u) % 4294967296) > 15) and 1 or 0))
end
if (not (t210 ~= 0)) then
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
v_a = F.fW(v_A, v_E, tobit((v_o + 16)), tobit((v_o + 12)))
if (v_a ~= 0) then
goto L157
end
do
do
v_h = (((tobit(v_r) % 4294967296) < 16) and v_r or 16)
v_u = (((tobit(v_h) % 4294967296) > 1) and v_h or 1)
v_a = 0
while true do
do
if not (I32[arshift((v_A + 384), 2)] ~= 0) then
v_c = tobit((v_A + v_a))
I8[tobit((368 + v_c))] = tobit(bxor(U8[tobit((v_c + 368))], U8[tobit((v_e + v_a))]))
end
v_c = bxor(U8[tobit((v_e + v_a))], U8[tobit((tobit((v_o + 16)) + v_a))])
I8[tobit((v_t + v_a))] = tobit(v_c)
if (1 == I32[arshift((v_A + 384), 2)]) then
v_v = tobit((v_A + v_a))
I8[tobit((368 + v_v))] = tobit(bxor(v_c, U8[tobit((v_v + 368))]))
end
local t212 = bor(0, v_u)
v_a = tobit((v_a + 1))
if not (t212 ~= bor(0, v_a)) then goto B159 end
end
do
end
::C159::
end
end
::B159::
end
do
do
do
v_I = v_s
v_k = tobit((v_A - (-64)))
v_u = U8[tobit((v_s + 15))]
local t213 = v_k
v_p = band((rshift(v_u, 1) % 4294967296), 120)
v_c = tobit((t213 + v_p))
v_l = I32[arshift(v_c, 2)]
v_d = I32[arshift((v_c + 4), 2)]
v_y = tobit((v_A + 192))
local t214 = v_y
v_b = lshift(band(15, v_u), 3)
v_c = tobit((t214 + v_b))
v_u = I32[arshift((4 + v_c), 2)]
v_v = I32[arshift(v_c, 2)]
v_c = lshift(v_v, 28)
v_g = v_l
local t216 = v_g
v_a = tobit((v_b + v_k))
v_l = I32[arshift((4 + v_a), 2)]
local t215 = lshift(band(15, v_l), 28)
v_b = I32[arshift(v_a, 2)]
v_g = bxor(t216, bor(t215, (rshift(v_b, 4) % 4294967296)))
v_c = bxor(bor((rshift(v_l, 4) % 4294967296), v_c), v_d)
v_a = tobit((v_p + v_y))
v_l = I32[arshift(v_a, 2)]
v_p = I32[arshift((v_a + 4), 2)]
v_a = tobit((11120 + lshift(band(15, v_b), 3)))
v_b = bxor(bor(lshift(band(15, v_u), 28), (rshift(v_v, 4) % 4294967296)), v_l)
local t217 = (rshift(v_u, 4) % 4294967296)
v_a = lshift(I32[arshift(v_a, 2)], 16)
v_u = bxor(bxor(t217, v_a), v_p)
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
v_d = I32[arshift((v_a + 4), 2)]
v_a = tobit((11120 + lshift(band(15, v_g), 3)))
v_p = lshift(I32[arshift(v_a, 2)], 16)
v_a = tobit((rshift(v_u, 4) % 4294967296))
v_p = bxor(bxor(v_a, v_p), v_d)
v_l = bxor(v_l, bor(lshift(band(15, v_u), 28), (rshift(v_b, 4) % 4294967296)))
v_d = lshift(v_l, 28)
v_a = tobit((v_k + v_C))
v_C = I32[arshift(v_a, 2)]
v_O = I32[arshift((v_a + 4), 2)]
local t218 = (rshift(v_c, 4) % 4294967296)
v_a = lshift(v_b, 28)
v_b = bxor(bor(t218, v_a), v_O)
local t220 = lshift(band(15, v_b), 28)
local t219 = bor(lshift(band(15, v_c), 28), (rshift(v_g, 4) % 4294967296))
v_u = 0
v_u = bxor(bor(t219, v_u), v_C)
v_g = bxor(bor(t220, (rshift(v_u, 4) % 4294967296)), v_m)
v_c = bxor(bor((rshift(v_b, 4) % 4294967296), v_d), v_Q)
v_a = tobit((v_y + v_w))
v_d = I32[arshift(v_a, 2)]
v_w = I32[arshift((v_a + 4), 2)]
v_u = tobit((11120 + lshift(band(15, v_u), 3)))
v_a = lshift(I32[arshift(v_u, 2)], 16)
v_u = v_p
v_b = bxor(bor(lshift(band(15, v_u), 28), (rshift(v_l, 4) % 4294967296)), v_d)
v_u = bxor(bxor((rshift(v_u, 4) % 4294967296), v_a), v_w)
v_a = tobit((v_v - 1))
if not (v_v ~= 0) then goto B160 end
end
do
end
::C160::
end
end
::B160::
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
v_t = tobit((v_t + v_h))
v_e = tobit((v_e + v_h))
v_r = tobit((v_r - v_h))
if (not (v_r ~= 0)) then
goto B158
end
end
end
::C158::
end
end
::B158::
end
end
end
v_a = 0
end
end
end
end
::L157::
end
B = tobit((v_o + 32))
do return v_a end
end

F.fY = function()
local v_A, v_r, v_e, v_t, v_o, v_a = 0, 0, 0, 0, 0, 0
v_r = 0
v_e = 0
v_t = 0
v_o = 0
v_a = 0
v_A = tobit((B - 384))
B = v_A
F.fLA(tobit((v_A + 104)))
I8[tobit((v_A + 56))] = tobit(109)
I8[tobit((v_A + 57))] = tobit(102)
I8[tobit((v_A + 58))] = tobit(118)
I8[tobit((v_A + 59))] = tobit(53)
I8[tobit((v_A + 60))] = tobit(106)
I8[tobit((v_A + 61))] = tobit(103)
I8[tobit((v_A + 62))] = tobit(57)
I8[tobit((v_A + 63))] = tobit(97)
I8[tobit((v_A + 48))] = tobit(52)
I8[tobit((v_A + 49))] = tobit(113)
I8[tobit((v_A + 50))] = tobit(117)
I8[tobit((v_A + 51))] = tobit(115)
I8[tobit((v_A + 52))] = tobit(108)
I8[tobit((v_A + 53))] = tobit(121)
I8[tobit((v_A + 54))] = tobit(49)
I8[tobit((v_A + 55))] = tobit(119)
F.fZ(tobit((v_A + 104)), tobit((v_A + 48)), 128)
v_r = bor(bor(bor(U8[13560], lshift(U8[13561], 8)), lshift(U8[13562], 16)), lshift(U8[13563], 24))
I32[arshift((v_A + 8), 2)] = tobit(bor(bor(bor(U8[13556], lshift(U8[13557], 8)), lshift(U8[13558], 16)), lshift(U8[13559], 24)))
I32[arshift((v_A + 12), 2)] = tobit(v_r)
v_r = bor(bor(bor(U8[13568], lshift(U8[13569], 8)), lshift(U8[13570], 16)), lshift(U8[13571], 24))
I32[arshift((v_A + 16), 2)] = tobit(bor(bor(bor(U8[13564], lshift(U8[13565], 8)), lshift(U8[13566], 16)), lshift(U8[13567], 24)))
I32[arshift((v_A + 20), 2)] = tobit(v_r)
v_r = bor(bor(bor(U8[13576], lshift(U8[13577], 8)), lshift(U8[13578], 16)), lshift(U8[13579], 24))
I32[arshift((v_A + 24), 2)] = tobit(bor(bor(bor(U8[13572], lshift(U8[13573], 8)), lshift(U8[13574], 16)), lshift(U8[13575], 24)))
I32[arshift((v_A + 28), 2)] = tobit(v_r)
I8[tobit((v_A + 40))] = tobit(55)
I8[tobit((v_A + 41))] = tobit(114)
I8[tobit((v_A + 42))] = tobit(122)
I8[tobit((v_A + 43))] = tobit(116)
I8[tobit((v_A + 44))] = tobit(56)
I8[tobit((v_A + 45))] = tobit(50)
I8[tobit((v_A + 46))] = tobit(115)
I8[tobit((v_A + 47))] = tobit(52)
I8[tobit((v_A + 32))] = tobit(51)
I8[tobit((v_A + 33))] = tobit(99)
I8[tobit((v_A + 34))] = tobit(104)
I8[tobit((v_A + 35))] = tobit(121)
I8[tobit((v_A + 36))] = tobit(97)
I8[tobit((v_A + 37))] = tobit(48)
I8[tobit((v_A + 38))] = tobit(110)
I8[tobit((v_A + 39))] = tobit(107)
v_r = bor(bor(bor(U8[13552], lshift(U8[13553], 8)), lshift(U8[13554], 16)), lshift(U8[13555], 24))
I32[arshift(v_A, 2)] = tobit(bor(bor(bor(U8[13548], lshift(U8[13549], 8)), lshift(U8[13550], 16)), lshift(U8[13551], 24)))
I32[arshift((v_A + 4), 2)] = tobit(v_r)
v_o = 32
F.fR(tobit((v_A + 104)), 0, 32, tobit((v_A + 32)), v_A, tobit((v_A - (-64))))
F.fhA(tobit((v_A + 104)))
do
do
do
v_e = U8[tobit((v_A + 95))]
local t221 = (((tobit(band((v_e - 1), 255)) % 4294967296) > 15) and 1 or 0)
if t221 == 0 then
v_r = 2
v_o = 31
t221 = (((tobit(v_e) % 4294967296) < 2) and 1 or 0)
end
if (not (t221 ~= 0)) then
do
v_o = 30
while true do
do
if (bor(((bor(0, v_e) ~= U8[tobit((tobit((v_A - (-64))) + v_o))]) and 1 or 0), (((tobit(v_e) % 4294967296) <= (tobit(band(255, v_r)) % 4294967296)) and 1 or 0)) ~= 0) then
goto L161
end
v_r = tobit((v_r + 1))
v_o = tobit((v_o - 1))
end
::C162::
end
end
::B162::
end
end
end
::L161::
end
v_r = F.fm(tobit((v_o + 1)))
F.fPA(tobit((v_r + v_o)), 0, (((-1) ~= bor(0, v_o)) and 1 or 0))
v_e = F.fTA(v_r, tobit((v_A - (-64))), v_o)
v_t = I32[8013]
v_a = F.fm(tobit((v_t + 17)))
v_o = I32[8012]
v_r = F.fPA(tobit((v_t + v_a)), 0, (((tobit(v_t) % 4294967296) < 4294967279) and 17 or 0))
v_o = F.fTA(v_a, v_o, v_t)
v_t = bor(bor(bor(U8[tobit((v_e + 12))], lshift(U8[tobit((v_e + 13))], 8)), lshift(U8[tobit((v_e + 14))], 16)), lshift(U8[tobit((v_e + 15))], 24))
v_a = bor(bor(bor(U8[tobit((v_e + 8))], lshift(U8[tobit((v_e + 9))], 8)), lshift(U8[tobit((v_e + 10))], 16)), lshift(U8[tobit((v_e + 11))], 24))
I8[tobit((v_r + 8))] = tobit(v_a)
I8[tobit((v_r + 9))] = tobit((rshift(v_a, 8) % 4294967296))
I8[tobit((v_r + 10))] = tobit((rshift(v_a, 16) % 4294967296))
I8[tobit((v_r + 11))] = tobit((rshift(v_a, 24) % 4294967296))
I8[tobit((v_r + 12))] = tobit(v_t)
I8[tobit((v_r + 13))] = tobit((rshift(v_t, 8) % 4294967296))
I8[tobit((v_r + 14))] = tobit((rshift(v_t, 16) % 4294967296))
I8[tobit((v_r + 15))] = tobit((rshift(v_t, 24) % 4294967296))
v_t = bor(bor(bor(U8[tobit((v_e + 4))], lshift(U8[tobit((v_e + 5))], 8)), lshift(U8[tobit((v_e + 6))], 16)), lshift(U8[tobit((v_e + 7))], 24))
v_a = bor(bor(bor(U8[bor(0, v_e)], lshift(U8[tobit((v_e + 1))], 8)), lshift(U8[tobit((v_e + 2))], 16)), lshift(U8[tobit((v_e + 3))], 24))
I8[bor(0, v_r)] = tobit(v_a)
I8[tobit((v_r + 1))] = tobit((rshift(v_a, 8) % 4294967296))
I8[tobit((v_r + 2))] = tobit((rshift(v_a, 16) % 4294967296))
I8[tobit((v_r + 3))] = tobit((rshift(v_a, 24) % 4294967296))
I8[tobit((v_r + 4))] = tobit(v_t)
I8[tobit((v_r + 5))] = tobit((rshift(v_t, 8) % 4294967296))
I8[tobit((v_r + 6))] = tobit((rshift(v_t, 16) % 4294967296))
I8[tobit((v_r + 7))] = tobit((rshift(v_t, 24) % 4294967296))
F.fL(v_e)
B = tobit((v_A + 384))
do return v_o end
end

F.fG = function(v_A, v_r, v_e, v_n)
local v_t, v_o, v_a, v_u, v_c, v_s, v_l, v_v, v_p, v_d, v_h, v_k, v_y, v_w, v_C, v_E = 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
v_t = 0
v_o = 0
v_a = 0
v_u = 0
v_c = 0
v_s = 0
v_l = 0
v_v = 0
v_p = 0
v_d = 0
v_h = 0
v_k = 0
v_y = 0
v_w = 0
v_C = 0
v_E = 0
do
do
do
v_a = I32[arshift(v_A, 2)]
if (not ((tobit(v_a) % 4294967296) <= U32[arshift((v_A + 4), 2)])) then
do
if (v_e ~= 0) then
v_c = band(1, v_e)
if (1 ~= bor(0, v_e)) then
do
v_u = band((-2), v_e)
while true do
v_t = bxor(I32[arshift((12512 + lshift(bxor(U8[tobit((v_r + v_o))], band(255, v_t)), 2)), 2)], (rshift(v_t, 8) % 4294967296))
v_t = bxor(I32[arshift((12512 + lshift(bxor(U8[tobit((bor(1, v_o) + v_r))], band(255, v_t)), 2)), 2)], (rshift(v_t, 8) % 4294967296))
v_o = tobit((v_o + 2))
v_u = tobit((v_u - 2))
if not (v_u ~= 0) then goto B164 end
do
end
::C164::
end
end
::B164::
end
if (v_c ~= 0) then
v_t = bxor(I32[arshift((12512 + lshift(bxor(U8[tobit((v_r + v_o))], band(255, v_t)), 2)), 2)], (rshift(v_t, 8) % 4294967296))
end
v_t = imul(v_t, 4097)
else
v_t = 0
end
do
v_t = imul(bxor((rshift(v_t, 22) % 4294967296), v_t), 17)
v_t = imul(bxor((rshift(v_t, 9) % 4294967296), v_t), 1025)
v_t = imul(bxor((rshift(v_t, 2) % 4294967296), v_t), 129)
v_t = tobit(fmod((tobit(imul(bxor((rshift(v_t, 15) % 4294967296), (rshift(v_t, 3) % 4294967296)), (-1640531535))) % 4294967296), (tobit(v_a) % 4294967296)))
v_o = I32[arshift((v_A + 8), 2)]
v_A = tobit((lshift(v_t, 4) + v_o))
v_w = I32[arshift((8 + v_A), 2)]
local t222 = bor(((not (v_w ~= 0)) and 1 or 0), ((I32[arshift((v_A + 4), 2)] ~= bor(0, v_e)) and 1 or 0))
if t222 == 0 then
t222 = F.fSA(I32[arshift((v_o + lshift(v_t, 4)), 2)], v_r, v_e)
end
if (t222 ~= 0) then
do
local t223 = v_o
v_A = tobit(fmod((tobit((v_t + 1)) % 4294967296), (tobit(v_a) % 4294967296)))
v_p = I32[arshift((8 + tobit((t223 + lshift(v_A, 4)))), 2)]
local t224 = (not (v_p ~= 0))
if not t224 then
v_u = tobit((v_o + lshift(v_A, 4)))
t224 = (I32[arshift((4 + v_u), 2)] ~= bor(0, v_e))
end
if (t224 or (F.fSA(I32[arshift(v_u, 2)], v_r, v_e) ~= 0)) then
do
local t225 = v_o
v_u = tobit(fmod((tobit((v_A + 1)) % 4294967296), (tobit(v_a) % 4294967296)))
v_c = tobit((t225 + lshift(v_u, 4)))
v_d = I32[arshift((8 + v_c), 2)]
if ((bor(((not (v_d ~= 0)) and 1 or 0), ((I32[arshift((v_c + 4), 2)] ~= bor(0, v_e)) and 1 or 0)) ~= 0) or (F.fSA(I32[arshift((v_o + lshift(v_u, 4)), 2)], v_r, v_e) ~= 0)) then
do
local t226 = v_o
v_c = tobit(fmod((tobit((v_u + 1)) % 4294967296), (tobit(v_a) % 4294967296)))
v_h = I32[arshift((8 + tobit((t226 + lshift(v_c, 4)))), 2)]
local t227 = (not (v_h ~= 0))
if not t227 then
v_s = tobit((v_o + lshift(v_c, 4)))
t227 = (I32[arshift((4 + v_s), 2)] ~= bor(0, v_e))
end
if (t227 or (F.fSA(I32[arshift(v_s, 2)], v_r, v_e) ~= 0)) then
do
local t228 = v_o
v_s = tobit(fmod((tobit((v_c + 1)) % 4294967296), (tobit(v_a) % 4294967296)))
v_l = tobit((t228 + lshift(v_s, 4)))
v_k = I32[arshift((8 + v_l), 2)]
if ((bor(((not (v_k ~= 0)) and 1 or 0), ((I32[arshift((v_l + 4), 2)] ~= bor(0, v_e)) and 1 or 0)) ~= 0) or (F.fSA(I32[arshift((v_o + lshift(v_s, 4)), 2)], v_r, v_e) ~= 0)) then
do
local t229 = v_o
v_l = tobit(fmod((tobit((v_s + 1)) % 4294967296), (tobit(v_a) % 4294967296)))
v_C = I32[arshift((8 + tobit((t229 + lshift(v_l, 4)))), 2)]
local t230 = (not (v_C ~= 0))
if not t230 then
v_v = tobit((v_o + lshift(v_l, 4)))
t230 = (I32[arshift((4 + v_v), 2)] ~= bor(0, v_e))
end
if (t230 or (F.fSA(I32[arshift(v_v, 2)], v_r, v_e) ~= 0)) then
do
local t231 = v_o
v_v = tobit(fmod((tobit((v_l + 1)) % 4294967296), (tobit(v_a) % 4294967296)))
v_y = tobit((t231 + lshift(v_v, 4)))
v_E = I32[arshift((8 + v_y), 2)]
if ((bor(((not (v_E ~= 0)) and 1 or 0), ((I32[arshift((v_y + 4), 2)] ~= bor(0, v_e)) and 1 or 0)) ~= 0) or (F.fSA(I32[arshift((v_o + lshift(v_v, 4)), 2)], v_r, v_e) ~= 0)) then
do
local t232 = v_o
v_a = tobit(fmod((tobit((v_v + 1)) % 4294967296), (tobit(v_a) % 4294967296)))
v_y = I32[arshift((8 + tobit((t232 + lshift(v_a, 4)))), 2)]
local t233 = (not (v_y ~= 0))
if not t233 then
v_o = tobit((v_o + lshift(v_a, 4)))
t233 = (I32[arshift((4 + v_o), 2)] ~= bor(0, v_e))
end
if (t233 or (F.fSA(I32[arshift(v_o, 2)], v_r, v_e) ~= 0)) then
do
v_o = 0
if (tobit((v_y + tobit((tobit((tobit((tobit((tobit((tobit((v_p + v_w)) + v_d)) + v_h)) + v_k)) + v_C)) + v_E)))) >= 8) then
goto L163
end
do
v_e = bor(((not (v_w ~= 0)) and 1 or 0), ((not (v_p ~= 0)) and 1 or 0))
v_p = bor(v_e, ((not (v_d ~= 0)) and 1 or 0))
v_d = bor(v_p, ((not (v_h ~= 0)) and 1 or 0))
v_h = bor(v_d, ((not (v_k ~= 0)) and 1 or 0))
v_k = bor(v_h, ((not (v_C ~= 0)) and 1 or 0))
v_r = bor(v_k, ((not (v_E ~= 0)) and 1 or 0))
v_t = ((v_r ~= 0) and ((v_k ~= 0) and ((v_h ~= 0) and ((v_d ~= 0) and ((v_p ~= 0) and ((v_e ~= 0) and ((v_w ~= 0) and v_A or v_t) or v_u) or v_c) or v_s) or v_l) or v_v) or v_a)
local t234 = ((not (v_r ~= 0)) and 1 or 0)
if t234 ~= 0 then
t234 = v_y
end
if (t234 ~= 0) then
goto L163
end
end
end
else
v_t = v_a
end
end
else
v_t = v_v
end
end
else
v_t = v_l
end
end
else
v_t = v_s
end
end
else
v_t = v_c
end
end
else
v_t = v_u
end
end
else
v_t = v_A
end
end
end
end
I32[arshift(v_n, 2)] = tobit(v_t)
v_o = 1
end
end
end
end
::L163::
end
do return v_o end
end

F.fJ = function(v_A, v_r)
local v_e, v_n, v_t, v_o, v_a, v_u, v_c, v_s, v_l, v_b, v_v, v_g, v_p, v_d = 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
v_e = 0
v_n = 0
v_t = 0
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
v_d = 0
do
do
do
v_e = bor(bor(bor(U8[tobit((v_r + 4))], lshift(U8[tobit((v_r + 5))], 8)), lshift(U8[tobit((v_r + 6))], 16)), lshift(U8[tobit((v_r + 7))], 24))
v_n = bor(bor(bor(lshift(v_e, 24), band(lshift(v_e, 8), 16711680)), band((rshift(v_e, 8) % 4294967296), 65280)), (rshift(v_e, 24) % 4294967296))
v_t = U8[bor(0, v_r)]
v_e = bor(bor(bor(U8[tobit((v_r + 3))], lshift(U8[tobit((v_r + 1))], 16)), lshift(v_t, 24)), lshift(U8[tobit((v_r + 2))], 8))
local t235 = (-269488145)
v_a = band(252645135, bxor((rshift(v_n, 4) % 4294967296), v_e))
v_r = bor(band(t235, bxor(lshift(v_a, 4), v_n)), band(269488144, v_e))
v_o = band(268435455, bor(bor(bor(bor(bor(bor(bor(lshift(I32[arshift((1088 + band((rshift(v_r, 7) % 4294967296), 60)), 2)], 2), lshift(I32[arshift((1088 + band(lshift(v_r, 1), 60)), 2)], 3)), lshift(I32[arshift((1088 + band((rshift(v_r, 15) % 4294967296), 60)), 2)], 1)), I32[arshift((1088 + band((rshift(v_r, 23) % 4294967296), 60)), 2)]), lshift(I32[arshift((1088 + band((rshift(v_r, 2) % 4294967296), 60)), 2)], 7)), lshift(I32[arshift((1088 + band((rshift(v_r, 10) % 4294967296), 60)), 2)], 6)), lshift(I32[arshift((1088 + band((rshift(v_r, 18) % 4294967296), 60)), 2)], 5)), lshift(I32[arshift((1088 + band((rshift(v_r, 26) % 4294967296), 60)), 2)], 4)))
v_r = bxor(v_e, v_a)
v_n = band(268435455, bor(bor(bor(bor(bor(bor(bor(lshift(I32[arshift((1024 + band((rshift(v_r, 6) % 4294967296), 60)), 2)], 2), lshift(I32[arshift((1024 + lshift(band(15, v_r), 2)), 2)], 3)), lshift(I32[arshift((1024 + band((rshift(v_r, 14) % 4294967296), 60)), 2)], 1)), I32[arshift((1024 + band((rshift(v_r, 22) % 4294967296), 60)), 2)]), lshift(I32[arshift((1024 + band((rshift(v_r, 3) % 4294967296), 60)), 2)], 7)), lshift(I32[arshift((1024 + band((rshift(v_r, 11) % 4294967296), 60)), 2)], 6)), lshift(I32[arshift((1024 + band((rshift(v_r, 19) % 4294967296), 60)), 2)], 5)), lshift(I32[arshift((1024 + band((rshift(v_t, 3) % 4294967296), 28)), 2)], 4)))
end
while true do
if (bor(((not (band(lshift(1, v_c), 33027) ~= 0)) and 1 or 0), (((tobit(v_c) % 4294967296) > 15) and 1 or 0)) ~= 0) then
v_a = tobit((rshift(v_n, 26) % 4294967296))
v_s = tobit((rshift(v_o, 26) % 4294967296))
v_r = lshift(v_o, 2)
v_u = band(268435452, v_r)
v_e = lshift(v_n, 2)
v_t = band(268435452, v_e)
else
v_a = tobit((rshift(v_n, 27) % 4294967296))
v_s = tobit((rshift(v_o, 27) % 4294967296))
v_r = lshift(v_o, 1)
v_u = band(268435454, v_r)
v_e = lshift(v_n, 1)
v_t = band(268435454, v_e)
end
v_n = bor(v_t, v_a)
v_l = lshift(v_n, 10)
v_o = bor(v_u, v_s)
v_b = tobit((rshift(v_o, 3) % 4294967296))
v_u = tobit((rshift(v_u, 14) % 4294967296))
I32[arshift(v_A, 2)] = tobit(bor(bor(bor(bor(bor(bor(bor(bor(bor(bor(bor(bor(bor(bor(bor(bor(bor(bor(bor(bor(bor(band((rshift(v_r, 24) % 4294967296), 1), band((rshift(v_r, 26) % 4294967296), 2)), band((rshift(v_r, 18) % 4294967296), 4)), band(8, v_b)), band((rshift(v_r, 10) % 4294967296), 16)), band((rshift(v_r, 5) % 4294967296), 32)), band(512, v_u)), band((rshift(v_r, 1) % 4294967296), 1024)), band(lshift(v_o, 6), 2048)), band((rshift(v_r, 4) % 4294967296), 4096)), band((rshift(v_r, 13) % 4294967296), 8192)), band(256, v_r)), band((rshift(v_e, 10) % 4294967296), 65536)), band(lshift(v_t, 2), 131072)), band(262144, v_l)), band((rshift(v_e, 1) % 4294967296), 1048576)), band(lshift(v_e, 9), 2097152)), band(lshift(v_e, 6), 16777216)), band(lshift(v_n, 18), 34078720)), band(lshift(v_e, 14), 134217728)), band(lshift(v_t, 4), 603979776)), band(lshift(v_a, 28), 268435456)))
v_a = band((rshift(v_r, 21) % 4294967296), 2)
v_v = band((rshift(v_r, 7) % 4294967296), 32)
v_g = band((rshift(v_r, 9) % 4294967296), 1024)
v_p = band((rshift(v_r, 2) % 4294967296), 8192)
v_d = band(512, v_r)
v_r = lshift(v_n, 15)
I32[arshift((v_A + 4), 2)] = tobit(bor(bor(bor(bor(bor(bor(bor(bor(bor(bor(bor(bor(bor(bor(bor(bor(bor(bor(bor(bor(bor(v_a, band(lshift(v_s, 2), 4)), band(17, v_b)), v_v), band(lshift(v_o, 7), 256)), v_g), band(2056, v_u)), band(lshift(v_o, 8), 4096)), v_p), v_d), band((rshift(v_e, 4) % 4294967296), 65536)), band((rshift(v_e, 6) % 4294967296), 262144)), band(lshift(v_t, 3), 524288)), band(lshift(v_e, 11), 1048576)), band(lshift(v_n, 16), 2097152)), band(lshift(v_t, 1), 16777216)), band((rshift(v_e, 2) % 4294967296), 33554432)), band(lshift(v_n, 22), 67108864)), band(134217728, v_l)), band(536870912, v_r)), band(lshift(v_e, 17), 268435456)), band(131072, v_r)))
v_A = tobit((v_A + 8))
v_c = tobit((v_c + 1))
if not (16 ~= bor(0, v_c)) then goto B165 end
do
end
::C165::
end
end
::B165::
end
end

F.fq = function(v_A)

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

F.fW = function(v_A, v_r, v_e, v_n)
local v_t, v_o, v_f, v_a, v_u = 0, 0, 0, 0, 0
v_t = 0
v_o = 0
v_f = 0
v_a = 0
v_u = 0
v_a = 16
v_t = (-24832)
do
do
do
local t236 = (v_A ~= 0)
if t236 then
v_o = I32[arshift(v_A, 2)]
t236 = (not (bor(((not (v_o ~= 0)) and 1 or 0), ((not (v_n ~= 0)) and 1 or 0)) ~= 0))
end
if t236 then
do
I32[arshift(v_n, 2)] = tobit(0)
v_f = I32[arshift((v_o + 24), 2)]
if (not (v_f ~= 0)) then
do return (-25472) end
end
do
do
v_u = I32[arshift((v_o + 4), 2)]
do
local sw169 = tobit((v_u - 1))
if sw169 == 5 then goto K169_0
elseif sw169 == 0 then goto K169_1
else goto K169_2 end
::K169_0::
do
goto L168
end
::K169_1::
do
goto S169
end
::K169_2::
do
goto L167
end
end
::S169::
v_t = (-25216)
if (16 ~= bor(0, v_f)) then
goto L166
end
I32[arshift(v_n, 2)] = tobit(16)
do return bor(0, YA[I32[arshift((I32[arshift((v_o + 28), 2)] + 4), 2)]](I32[arshift((v_A + 60), 2)], I32[arshift((v_A + 8), 2)], v_r, v_e)) end
end
::L168::
I32[arshift(v_n, 2)] = tobit(16)
do return F.fU(I32[arshift((v_A + 60), 2)], 16, v_r, v_e) end
end
::L167::
do
local t237 = bor(I32[arshift((v_A + 36), 2)], fmod(16, (tobit(v_f) % 4294967296)))
if t237 ~= 0 then
t237 = ((bor(0, v_r) == bor(0, v_e)) and 1 or 0)
end
if (not (t237 ~= 0)) then
do
v_t = (-24704)
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
local sw173 = tobit((v_u - 2))
if sw173 == 0 then goto K173_0
elseif sw173 == 1 then goto K173_1
elseif sw173 == 3 then goto K173_2
elseif sw173 == 5 then goto K173_3
else goto K173_4 end
::K173_0::
do
do
do
do
do
do
do
do
do
local sw176 = I32[arshift((v_A + 8), 2)]
if sw176 == 0 then goto K176_0
elseif sw176 == 1 then goto K176_1
else goto K176_2 end
::K176_0::
do
do
local t238 = v_f
v_t = I32[arshift((v_A + 36), 2)]
v_o = tobit((t238 - v_t))
if (not (I32[arshift((v_A + 12), 2)] ~= 0)) then
goto L175
end
end
if ((tobit(v_o) % 4294967296) >= 16) then
goto L171
end
goto L174
end
::K176_1::
do
goto S176
end
::K176_2::
do
goto L174
end
end
::S176::
end
do
local t239 = v_f
v_t = I32[arshift((v_A + 36), 2)]
if ((tobit((t239 - v_t)) % 4294967296) <= 16) then
goto L174
end
end
goto L171
end
end
::L175::
end
if ((tobit(v_o) % 4294967296) > 16) then
goto L171
end
end
end
::L174::
end
do
v_t = I32[arshift((v_A + 36), 2)]
if (v_t ~= 0) then
do
do
v_a = tobit((v_A + 20))
local t240 = tobit((v_a + v_t))
local t241 = v_r
v_o = tobit((v_f - v_t))
F.fTA(t240, t241, v_o)
v_t = bor(0, YA[I32[arshift((I32[arshift((I32[arshift(v_A, 2)] + 28), 2)] + 8), 2)]](I32[arshift((v_A + 60), 2)], I32[arshift((v_A + 8), 2)], v_f, tobit((v_A + 40)), v_a, v_e))
if (v_t ~= 0) then
goto L166
end
end
I32[arshift(v_n, 2)] = tobit((v_f + I32[arshift(v_n, 2)]))
I32[arshift((v_A + 36), 2)] = tobit(0)
v_a = tobit((16 - v_o))
v_e = tobit((v_e + v_f))
v_r = tobit((v_r + v_o))
end
end
end
v_t = 0
if (not (v_a ~= 0)) then
goto L166
end
do
v_o = tobit(fmod((tobit(v_a) % 4294967296), (tobit(v_f) % 4294967296)))
if not (v_o ~= 0) then
v_o = 0
if not (I32[arshift((v_A + 8), 2)] ~= 0) then
v_o = ((I32[arshift((v_A + 12), 2)] ~= 0) and v_f or 0)
end
end
local t242 = tobit((v_A + 20))
v_f = tobit((v_a - v_o))
F.fTA(t242, tobit((v_f + v_r)), v_o)
I32[arshift((v_A + 36), 2)] = tobit((I32[arshift((v_A + 36), 2)] + v_o))
if (not (v_f ~= 0)) then
goto L166
end
end
v_t = bor(0, YA[I32[arshift((I32[arshift((I32[arshift(v_A, 2)] + 28), 2)] + 8), 2)]](I32[arshift((v_A + 60), 2)], I32[arshift((v_A + 8), 2)], v_f, tobit((v_A + 40)), v_r, v_e))
if (v_t ~= 0) then
goto L166
end
I32[arshift(v_n, 2)] = tobit((v_f + I32[arshift(v_n, 2)]))
goto L170
end
::K173_1::
do
v_t = bor(0, YA[I32[arshift((I32[arshift((v_o + 28), 2)] + 12), 2)]](I32[arshift((v_A + 60), 2)], I32[arshift((v_A + 8), 2)], 16, tobit((v_A + 36)), tobit((v_A + 40)), v_r, v_e))
if (not (v_t ~= 0)) then
goto L172
end
goto L166
end
::K173_2::
do
v_t = bor(0, YA[I32[arshift((I32[arshift((v_o + 28), 2)] + 16), 2)]](I32[arshift((v_A + 60), 2)], 16, tobit((v_A + 36)), tobit((v_A + 40)), tobit((v_A + 20)), v_r, v_e))
if (not (v_t ~= 0)) then
goto L172
end
goto L166
end
::K173_3::
do
goto S173
end
::K173_4::
do
goto L166
end
end
::S173::
end
v_t = bor(0, YA[I32[arshift((I32[arshift((v_o + 28), 2)] + 20), 2)]](I32[arshift((v_A + 60), 2)], 16, v_r, v_e))
if (v_t ~= 0) then
goto L166
end
end
end
::L172::
end
I32[arshift(v_n, 2)] = tobit(16)
goto L170
end
end
::L171::
end
F.fTA(tobit((20 + tobit((v_A + v_t)))), v_r, 16)
I32[arshift((v_A + 36), 2)] = tobit((I32[arshift((v_A + 36), 2)] + 16))
end
end
::L170::
end
v_t = 0
end
end
end
end
end
end
end
::L166::
end
do return v_t end
end

F.fV = function(v_A)
local v_r, v_e, v_t, v_o, v_a, v_u = 0, 0, 0, 0, 0, 0
v_r = 0
v_e = 0
v_t = 0
v_o = 0
v_a = 0
v_u = 0
do
local t243 = (v_A ~= 0)
if not t243 then
v_A = I32[8016]
t243 = (v_A ~= 0)
end
if t243 then
do
v_t = 10657
v_o = tobit((B - 32))
I32[arshift((24 + v_o), 2)] = tobit(0)
I32[arshift((v_o + 28), 2)] = tobit(0)
I32[arshift((v_o + 16), 2)] = tobit(0)
I32[arshift((v_o + 20), 2)] = tobit(0)
I32[arshift((v_o + 8), 2)] = tobit(0)
I32[arshift((v_o + 12), 2)] = tobit(0)
I32[arshift(v_o, 2)] = tobit(0)
I32[arshift((v_o + 4), 2)] = tobit(0)
v_e = 0
v_r = U8[10657]
if (v_r ~= 0) then
v_u = v_A
v_e = U8[10658]
if (v_e ~= 0) then
do
v_a = tobit((v_o + band((rshift(v_r, 3) % 4294967296), 28)))
I32[arshift(v_a, 2)] = tobit(bor(I32[arshift(v_a, 2)], lshift(1, v_r)))
while true do
v_r = band(31, v_e)
v_a = tobit((rshift(v_e, 3) % 4294967296))
v_e = U8[tobit((v_t + 2))]
v_a = tobit((v_o + band(28, v_a)))
I32[arshift(v_a, 2)] = tobit(bor(I32[arshift(v_a, 2)], lshift(1, v_r)))
v_t = tobit((v_t + 1))
if not (v_e ~= 0) then goto B177 end
do
end
::C177::
end
end
::B177::
v_r = v_A
do
v_e = U8[bor(0, v_u)]
if (v_e ~= 0) then
do
v_t = v_u
while true do
do
if (not (band((rshift(I32[arshift((v_o + band((rshift(v_e, 3) % 4294967296), 28)), 2)], v_e) % 4294967296), 1) ~= 0)) then
v_r = v_t
goto L178
end
v_e = U8[tobit((v_t + 1))]
v_r = tobit((v_t + 1))
v_t = v_r
if (not (v_e ~= 0)) then
goto B179
end
end
::C179::
end
end
::B179::
end
end
::L178::
v_e = tobit((v_r - v_u))
else
do
v_e = v_A
while true do
v_t = v_e
v_e = tobit((v_e + 1))
if not (bor(0, v_r) == U8[bor(0, v_t)]) then goto B180 end
do
end
::C180::
end
end
::B180::
v_e = tobit((v_t - v_u))
end
end
v_e = tobit((v_e + v_A))
if (not (U8[bor(0, v_e)] ~= 0)) then
I32[8016] = tobit(0)
do return 0 end
end
v_u = v_e
v_A = 10657
v_o = tobit((B - 32))
B = v_o
v_a = I8[10657]
do
do
do
if ((U8[10658] ~= 0) and (v_a ~= 0)) then
F.fPA(v_o, 0, 32)
v_r = U8[10657]
if (v_r ~= 0) then
do
while true do
v_t = tobit((v_o + band((rshift(v_r, 3) % 4294967296), 28)))
I32[arshift(v_t, 2)] = tobit(bor(I32[arshift(v_t, 2)], lshift(1, v_r)))
v_r = U8[tobit((v_A + 1))]
v_A = tobit((v_A + 1))
if not (v_r ~= 0) then goto B182 end
do
end
::C182::
end
end
::B182::
end
v_t = v_e
v_r = U8[bor(0, v_e)]
if (v_r ~= 0) then
do
v_A = v_u
while true do
do
if (band((rshift(I32[arshift((v_o + band((rshift(v_r, 3) % 4294967296), 28)), 2)], v_r) % 4294967296), 1) ~= 0) then
v_t = v_A
goto L181
end
v_r = U8[tobit((v_A + 1))]
v_t = tobit((v_A + 1))
v_A = v_t
if (not (v_r ~= 0)) then
goto B183
end
end
::C183::
end
end
::B183::
end
else
do
v_A = v_e
do
do
do
v_t = band(255, v_a)
if (v_t ~= 0) then
do
if (band(3, v_A) ~= 0) then
do
while true do
do
v_r = U8[bor(0, v_A)]
if (bor(((not (v_r ~= 0)) and 1 or 0), ((bor(0, v_r) == band(255, v_a)) and 1 or 0)) ~= 0) then
goto L184
end
v_A = tobit((v_A + 1))
if (not (band(3, v_A) ~= 0)) then
goto B185
end
end
::C185::
end
end
::B185::
end
do
do
do
local t244 = (-1)
v_r = I32[arshift(v_A, 2)]
if (not (band(band(bxor(t244, v_r), (v_r - 16843009)), (-2139062144)) ~= 0)) then
do
do
v_t = imul(v_t, 16843009)
while true do
do
do
do
local t245 = (-1)
v_r = bxor(v_r, v_t)
if (band(band(bxor(t245, v_r), (v_r - 16843009)), (-2139062144)) ~= 0) then
goto L186
end
end
v_r = I32[arshift((v_A + 4), 2)]
v_A = tobit((v_A + 4))
if (band(band((v_r - 16843009), bxor((-1), v_r)), (-2139062144)) ~= 0) then
goto B187
end
end
end
::C187::
end
end
::B187::
end
end
end
end
::L186::
end
do
do
while true do
do
v_t = v_A
v_r = U8[bor(0, v_A)]
local t246 = v_r
if t246 ~= 0 then
v_A = tobit((v_t + 1))
t246 = ((bor(0, v_r) ~= band(255, v_a)) and 1 or 0)
end
if not (t246 ~= 0) then goto B188 end
end
do
end
::C188::
end
end
::B188::
end
v_A = v_t
end
else
v_A = tobit((F.fpA(v_A) + v_A))
end
end
end
::L184::
end
v_t = v_A
end
end
end
end
::L181::
end
B = tobit((v_o + 32))
v_A = tobit((tobit((v_t - v_u)) + v_e))
if (U8[bor(0, v_A)] ~= 0) then
I32[8016] = tobit((v_A + 1))
I8[bor(0, v_A)] = tobit(0)
do return v_e end
end
I32[8016] = tobit(0)
end
end
end
do return v_e end
end

F.fZ = function(v_A, v_r, v_e)
local v_t, v_o, v_a, v_u = 0, 0, 0, 0
v_a = 0
v_u = 0
v_t = tobit((B - 288))
B = v_t
F.fPA(tobit((v_t + 8)), 0, 280)
I32[arshift((v_A + 4), 2)] = tobit((v_A + 8))
v_o = F.fM(tobit((v_t + 8)), v_r, v_e)
if (not (v_o ~= 0)) then
v_e = I32[arshift((v_t + 8), 2)]
I32[arshift(v_A, 2)] = tobit(v_e)
v_u = I32[arshift((v_t + 12), 2)]
v_a = tobit((v_u + lshift(v_e, 4)))
I32[arshift((v_A + 8), 2)] = tobit(I32[arshift(v_a, 2)])
I32[arshift((v_A + 12), 2)] = tobit(I32[arshift((v_a + 4), 2)])
I32[arshift((v_A + 16), 2)] = tobit(I32[arshift((v_a + 8), 2)])
I32[arshift((v_A + 20), 2)] = tobit(I32[arshift((v_a + 12), 2)])
v_A = tobit((v_A + 24))
v_r = tobit((v_a - 16))
if (bor(0, v_e) < 2) then
v_e = tobit((v_a + 16))
else
do
while true do
v_a = I32[arshift(v_r, 2)]
I32[arshift(v_A, 2)] = tobit(bxor(bxor(bxor(I32[arshift((24560 + lshift(U8[tobit((23280 + band((rshift(v_a, 8) % 4294967296), 255)))], 2)), 2)], I32[arshift((23536 + lshift(U8[tobit((23280 + band(255, v_a)))], 2)), 2)]), I32[arshift((25584 + lshift(U8[tobit((23280 + band((rshift(v_a, 16) % 4294967296), 255)))], 2)), 2)]), I32[arshift((26608 + lshift(U8[tobit((23280 + tobit((rshift(v_a, 24) % 4294967296))))], 2)), 2)]))
v_a = I32[arshift((v_r + 4), 2)]
I32[arshift((v_A + 4), 2)] = tobit(bxor(bxor(bxor(I32[arshift((24560 + lshift(U8[tobit((23280 + band((rshift(v_a, 8) % 4294967296), 255)))], 2)), 2)], I32[arshift((23536 + lshift(U8[tobit((23280 + band(255, v_a)))], 2)), 2)]), I32[arshift((25584 + lshift(U8[tobit((23280 + band((rshift(v_a, 16) % 4294967296), 255)))], 2)), 2)]), I32[arshift((26608 + lshift(U8[tobit((23280 + tobit((rshift(v_a, 24) % 4294967296))))], 2)), 2)]))
v_a = I32[arshift((v_r + 8), 2)]
I32[arshift((v_A + 8), 2)] = tobit(bxor(bxor(bxor(I32[arshift((24560 + lshift(U8[tobit((23280 + band((rshift(v_a, 8) % 4294967296), 255)))], 2)), 2)], I32[arshift((23536 + lshift(U8[tobit((23280 + band(255, v_a)))], 2)), 2)]), I32[arshift((25584 + lshift(U8[tobit((23280 + band((rshift(v_a, 16) % 4294967296), 255)))], 2)), 2)]), I32[arshift((26608 + lshift(U8[tobit((23280 + tobit((rshift(v_a, 24) % 4294967296))))], 2)), 2)]))
v_a = I32[arshift((v_r + 12), 2)]
I32[arshift((v_A + 12), 2)] = tobit(bxor(bxor(bxor(I32[arshift((24560 + lshift(U8[tobit((23280 + band((rshift(v_a, 8) % 4294967296), 255)))], 2)), 2)], I32[arshift((23536 + lshift(U8[tobit((23280 + band(255, v_a)))], 2)), 2)]), I32[arshift((25584 + lshift(U8[tobit((23280 + band((rshift(v_a, 16) % 4294967296), 255)))], 2)), 2)]), I32[arshift((26608 + lshift(U8[tobit((23280 + tobit((rshift(v_a, 24) % 4294967296))))], 2)), 2)]))
v_r = tobit((v_r - 16))
v_A = tobit((v_A + 16))
v_a = ((bor(0, v_e) > 2) and 1 or 0)
v_e = tobit((v_e - 1))
if not (v_a ~= 0) then goto B189 end
do
end
::C189::
end
end
::B189::
v_r = v_u
v_e = tobit((v_r + 32))
end
I32[arshift(v_A, 2)] = tobit(I32[arshift(v_r, 2)])
I32[arshift((v_A + 4), 2)] = tobit(I32[arshift((v_e - 28), 2)])
I32[arshift((v_A + 8), 2)] = tobit(I32[arshift((v_e - 24), 2)])
I32[arshift((v_A + 12), 2)] = tobit(I32[arshift((v_e - 20), 2)])
end
do
v_r = 266
v_A = tobit((v_t + 8))
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
if not (v_r ~= 0) then goto B190 end
do
v_A = tobit((v_A + 14))
v_r = tobit((v_r - 14))
end
::C190::
end
end
::B190::
B = tobit((v_t + 288))
do return v_o end
end

F.fz = function(v_A, v_r, v_e)
local v_t, v_o, v_a, v_u, v_c = 0, 0, 0, 0, 0
v_t = 0
v_o = 0
v_a = 0
v_u = 0
v_c = 0
do
do
do
v_t = bor(bor(bor(U8[bor(0, v_r)], lshift(U8[tobit((v_r + 1))], 8)), lshift(U8[tobit((v_r + 2))], 16)), lshift(U8[tobit((v_r + 3))], 24))
v_t = bor(bor(bor(lshift(v_t, 24), band(lshift(v_t, 8), 16711680)), band((rshift(v_t, 8) % 4294967296), 65280)), (rshift(v_t, 24) % 4294967296))
local t248 = v_t
local t247 = (rshift(v_t, 4) % 4294967296)
v_r = bor(bor(bor(U8[tobit((v_r + 4))], lshift(U8[tobit((v_r + 5))], 8)), lshift(U8[tobit((v_r + 6))], 16)), lshift(U8[tobit((v_r + 7))], 24))
v_r = bor(bor(bor(lshift(v_r, 24), band(lshift(v_r, 8), 16711680)), band((rshift(v_r, 8) % 4294967296), 65280)), (rshift(v_r, 24) % 4294967296))
v_o = band(252645135, bxor(t247, v_r))
v_t = bxor(t248, lshift(v_o, 4))
v_o = bxor(v_o, v_r)
local t249 = v_o
v_r = bxor((rshift(v_t, 16) % 4294967296), band(65535, v_o))
v_o = bxor(t249, v_r)
local t251 = v_o
local t250 = (rshift(v_o, 2) % 4294967296)
v_r = bxor(v_t, lshift(v_r, 16))
v_t = band(858993459, bxor(t250, v_r))
v_o = bxor(t251, lshift(v_t, 2))
local t252 = (rshift(v_o, 8) % 4294967296)
v_r = bxor(v_r, v_t)
v_t = band(16711935, bxor(t252, v_r))
v_o = F.fKA(bxor(lshift(v_t, 8), v_o), 1)
v_a = v_o
local t254 = v_a
local t253 = (-1431655766)
v_r = bxor(v_r, v_t)
v_o = band(t253, bxor(v_r, v_o))
v_t = bxor(t254, v_o)
v_r = F.fKA(bxor(v_r, v_o), 1)
v_o = 1
end
while true do
v_a = v_t
v_u = bxor(I32[arshift((v_A + 4), 2)], F.fKA(v_t, 28))
v_c = v_r
v_r = bxor(I32[arshift(v_A, 2)], v_t)
v_r = bxor(bxor(bxor(bxor(bxor(bxor(bxor(bxor(I32[arshift((2176 + lshift(band(63, v_u), 2)), 2)], v_c), I32[arshift((1152 + lshift(band(63, v_r), 2)), 2)]), I32[arshift((1408 + band((rshift(v_r, 6) % 4294967296), 252)), 2)]), I32[arshift((1664 + band((rshift(v_r, 14) % 4294967296), 252)), 2)]), I32[arshift((1920 + band((rshift(v_r, 22) % 4294967296), 252)), 2)]), I32[arshift((2432 + band((rshift(v_u, 6) % 4294967296), 252)), 2)]), I32[arshift((2688 + band((rshift(v_u, 14) % 4294967296), 252)), 2)]), I32[arshift((2944 + band((rshift(v_u, 22) % 4294967296), 252)), 2)])
v_t = bxor(v_r, I32[arshift((v_A + 8), 2)])
v_a = bxor(bxor(bxor(bxor(v_a, I32[arshift((1152 + lshift(band(63, v_t), 2)), 2)]), I32[arshift((1408 + band((rshift(v_t, 6) % 4294967296), 252)), 2)]), I32[arshift((1664 + band((rshift(v_t, 14) % 4294967296), 252)), 2)]), I32[arshift((1920 + band((rshift(v_t, 22) % 4294967296), 252)), 2)])
v_t = bxor(I32[arshift((v_A + 12), 2)], F.fKA(v_r, 28))
v_t = bxor(bxor(bxor(bxor(v_a, I32[arshift((2176 + lshift(band(63, v_t), 2)), 2)]), I32[arshift((2432 + band((rshift(v_t, 6) % 4294967296), 252)), 2)]), I32[arshift((2688 + band((rshift(v_t, 14) % 4294967296), 252)), 2)]), I32[arshift((2944 + band((rshift(v_t, 22) % 4294967296), 252)), 2)])
if not (8 ~= bor(0, v_o)) then goto B191 end
do
v_A = tobit((v_A + 16))
v_o = tobit((v_o + 1))
end
::C191::
end
end
::B191::
end
do
v_a = lshift(v_r, 31)
local t257 = v_a
v_o = v_r
local t256 = v_o
local t255 = (-1431655766)
v_A = F.fKA(v_t, 31)
v_r = band(t255, bxor(v_A, v_r))
v_t = bor(t257, (rshift(bxor(t256, v_r), 1) % 4294967296))
local t259 = v_t
local t258 = (rshift(v_t, 8) % 4294967296)
v_A = bxor(v_A, v_r)
v_r = band(16711935, bxor(t258, v_A))
v_t = bxor(t259, lshift(v_r, 8))
local t261 = v_t
local t260 = (rshift(v_t, 2) % 4294967296)
v_A = bxor(v_A, v_r)
v_r = band(858993459, bxor(t260, v_A))
v_t = bxor(t261, lshift(v_r, 2))
local t262 = band(65535, v_t)
v_A = bxor(v_A, v_r)
v_r = bxor(t262, (rshift(v_A, 16) % 4294967296))
v_o = bxor(lshift(v_r, 16), v_A)
v_A = bxor(v_r, v_t)
local t263 = v_A
v_r = band(252645135, bxor((rshift(v_o, 4) % 4294967296), v_A))
v_A = bxor(t263, v_r)
I8[tobit((v_e + 7))] = tobit(v_A)
I8[tobit((v_e + 6))] = tobit((rshift(v_A, 8) % 4294967296))
I8[tobit((v_e + 5))] = tobit((rshift(v_A, 16) % 4294967296))
I8[tobit((v_e + 4))] = tobit((rshift(v_A, 24) % 4294967296))
v_A = bxor(v_o, lshift(v_r, 4))
I8[tobit((v_e + 3))] = tobit(v_A)
I8[tobit((v_e + 2))] = tobit((rshift(v_A, 8) % 4294967296))
I8[tobit((v_e + 1))] = tobit((rshift(v_A, 16) % 4294967296))
I8[bor(0, v_e)] = tobit((rshift(v_A, 24) % 4294967296))
do return 0 end
end
end

F.fX = function(v_A, v_r, v_e, v_t, v_o, v_i)
local v_a, v_u = 0, 0
v_a = 0
v_u = 0
v_u = (-50)
do
if (not (band(7, v_e) ~= 0)) then
if (1 == bor(0, v_r)) then
v_u = 0
if (v_e ~= 0) then
do
v_r = U8[bor(0, v_t)]
while true do
I8[bor(0, v_i)] = tobit(bxor(U8[bor(0, v_o)], v_r))
I8[tobit((v_i + 1))] = tobit(bxor(U8[tobit((v_t + 1))], U8[tobit((v_o + 1))]))
I8[tobit((v_i + 2))] = tobit(bxor(U8[tobit((v_t + 2))], U8[tobit((v_o + 2))]))
I8[tobit((v_i + 3))] = tobit(bxor(U8[tobit((v_t + 3))], U8[tobit((v_o + 3))]))
I8[tobit((v_i + 4))] = tobit(bxor(U8[tobit((v_t + 4))], U8[tobit((v_o + 4))]))
I8[tobit((v_i + 5))] = tobit(bxor(U8[tobit((v_t + 5))], U8[tobit((v_o + 5))]))
I8[tobit((v_i + 6))] = tobit(bxor(U8[tobit((v_t + 6))], U8[tobit((v_o + 6))]))
I8[tobit((v_i + 7))] = tobit(bxor(U8[tobit((v_t + 7))], U8[tobit((v_o + 7))]))
F.fz(v_A, v_i, v_i)
v_a = bor(bor(bor(U8[tobit((v_i + 4))], lshift(U8[tobit((v_i + 5))], 8)), lshift(U8[tobit((v_i + 6))], 16)), lshift(U8[tobit((v_i + 7))], 24))
v_r = bor(bor(bor(U8[bor(0, v_i)], lshift(U8[tobit((v_i + 1))], 8)), lshift(U8[tobit((v_i + 2))], 16)), lshift(U8[tobit((v_i + 3))], 24))
I8[bor(0, v_t)] = tobit(v_r)
I8[tobit((v_t + 1))] = tobit((rshift(v_r, 8) % 4294967296))
I8[tobit((v_t + 2))] = tobit((rshift(v_r, 16) % 4294967296))
I8[tobit((v_t + 3))] = tobit((rshift(v_r, 24) % 4294967296))
I8[tobit((v_t + 4))] = tobit(v_a)
I8[tobit((v_t + 5))] = tobit((rshift(v_a, 8) % 4294967296))
I8[tobit((v_t + 6))] = tobit((rshift(v_a, 16) % 4294967296))
I8[tobit((v_t + 7))] = tobit((rshift(v_a, 24) % 4294967296))
v_i = tobit((v_i + 8))
v_o = tobit((v_o + 8))
v_e = tobit((v_e - 8))
if not (v_e ~= 0) then goto B193 end
do
end
::C193::
end
end
::B193::
end
else
v_u = 0
if (not (v_e ~= 0)) then
goto L192
end
do
while true do
v_a = bor(bor(bor(U8[tobit((v_o + 4))], lshift(U8[tobit((v_o + 5))], 8)), lshift(U8[tobit((v_o + 6))], 16)), lshift(U8[tobit((v_o + 7))], 24))
v_r = bor(bor(bor(U8[bor(0, v_o)], lshift(U8[tobit((v_o + 1))], 8)), lshift(U8[tobit((v_o + 2))], 16)), lshift(U8[tobit((v_o + 3))], 24))
F.fz(v_A, v_o, v_i)
I8[bor(0, v_i)] = tobit(bxor(U8[bor(0, v_t)], U8[bor(0, v_i)]))
I8[tobit((v_i + 1))] = tobit(bxor(U8[tobit((v_t + 1))], U8[tobit((v_i + 1))]))
I8[tobit((v_i + 2))] = tobit(bxor(U8[tobit((v_t + 2))], U8[tobit((v_i + 2))]))
I8[tobit((v_i + 3))] = tobit(bxor(U8[tobit((v_t + 3))], U8[tobit((v_i + 3))]))
I8[tobit((v_i + 4))] = tobit(bxor(U8[tobit((v_t + 4))], U8[tobit((v_i + 4))]))
I8[tobit((v_i + 5))] = tobit(bxor(U8[tobit((v_t + 5))], U8[tobit((v_i + 5))]))
I8[tobit((v_i + 6))] = tobit(bxor(U8[tobit((v_t + 6))], U8[tobit((v_i + 6))]))
I8[tobit((v_i + 7))] = tobit(bxor(U8[tobit((v_t + 7))], U8[tobit((v_i + 7))]))
I8[bor(0, v_t)] = tobit(v_r)
I8[tobit((v_t + 1))] = tobit((rshift(v_r, 8) % 4294967296))
I8[tobit((v_t + 2))] = tobit((rshift(v_r, 16) % 4294967296))
I8[tobit((v_t + 3))] = tobit((rshift(v_r, 24) % 4294967296))
I8[tobit((v_t + 4))] = tobit(v_a)
I8[tobit((v_t + 5))] = tobit((rshift(v_a, 8) % 4294967296))
I8[tobit((v_t + 6))] = tobit((rshift(v_a, 16) % 4294967296))
I8[tobit((v_t + 7))] = tobit((rshift(v_a, 24) % 4294967296))
v_i = tobit((v_i + 8))
v_o = tobit((v_o + 8))
v_e = tobit((v_e - 8))
if not (v_e ~= 0) then goto B194 end
do
end
::C194::
end
end
::B194::
end
end
end
::L192::
do return v_u end
end

F.f_ = function(v_A)

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
I8[tobit((v_A - (-64)))] = tobit(0)
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
end
end

F.fS_ = function(v_A, v_r, v_e)
local v_n, v_t, v_o, v_i, v_f, v_a, v_u, v_c, v_s = 0, 0, 0, 0, 0, 0, 0, 0, 0
v_n = 0
v_t = 0
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
v_t = v_r
if (v_r ~= 0) then
v_n = v_e
if (not (v_n ~= 0)) then
goto L204
end
goto L203
end
v_A = tobit(toint(((tobit(v_A) % 4294967296) / (tobit(v_e) % 4294967296))))
Iv = 0
goto L195
end
::L204::
if (not (v_A ~= 0)) then
goto L202
end
goto L201
end
::L203::
if (not (band((v_n - 1), v_n) ~= 0)) then
goto L200
end
v_f = tobit((tobit((clz32(v_n) + 33)) - clz32(v_t)))
v_a = tobit((0 - v_f))
goto L198
end
::L202::
v_A = tobit(toint(((tobit(v_t) % 4294967296) / 0)))
Iv = 0
goto L195
end
::L201::
v_n = tobit((32 - clz32(v_t)))
if ((tobit(v_n) % 4294967296) < 31) then
goto L199
end
goto L197
end
::L200::
if (1 == bor(0, v_n)) then
goto L196
end
v_n = ((v_n ~= 0) and tobit((31 - clz32(bxor((v_n - 1), v_n)))) or 32)
v_e = band(31, v_n)
if ((tobit(band(63, v_n)) % 4294967296) >= 32) then
v_t = 0
v_A = tobit((rshift(v_r, v_e) % 4294967296))
else
v_t = tobit((rshift(v_r, v_e) % 4294967296))
v_A = bor(lshift(band((lshift(1, v_e) - 1), v_r), (32 - v_e)), (rshift(v_A, v_e) % 4294967296))
end
Iv = v_t
goto L195
end
::L199::
v_f = tobit((v_n + 1))
v_a = tobit((63 - v_n))
end
::L198::
do
v_n = v_r
v_t = band(63, v_f)
v_o = band(31, v_t)
if ((tobit(v_t) % 4294967296) >= 32) then
v_t = 0
v_o = tobit((rshift(v_n, v_o) % 4294967296))
else
v_t = tobit((rshift(v_n, v_o) % 4294967296))
v_o = bor(lshift(band((lshift(1, v_o) - 1), v_n), (32 - v_o)), (rshift(v_A, v_o) % 4294967296))
end
v_a = band(v_a, 63)
v_n = band(31, v_a)
if ((tobit(v_a) % 4294967296) >= 32) then
v_r = lshift(v_A, v_n)
v_A = 0
else
v_r = bor(band((lshift(1, v_n) - 1), (rshift(v_A, (32 - v_n)) % 4294967296)), lshift(v_r, v_n))
v_A = lshift(v_A, v_n)
end
if (v_f ~= 0) then
do
do
do
local t264 = (-1)
v_n = tobit((v_e - 1))
v_a = ((t264 ~= bor(0, v_n)) and 0 or (-1))
end
while true do
do
v_i = bor(lshift(v_o, 1), (rshift(v_r, 31) % 4294967296))
v_u = v_i
local t267 = v_u
local t266 = v_e
local t265 = v_a
v_t = bor(lshift(v_t, 1), (rshift(v_o, 31) % 4294967296))
v_i = arshift((t265 - tobit((v_t + (((tobit(v_n) % 4294967296) < (tobit(v_i) % 4294967296)) and 1 or 0)))), 31)
v_c = band(t266, v_i)
v_o = tobit((t267 - v_c))
v_t = tobit((v_t - (((tobit(v_u) % 4294967296) < (tobit(v_c) % 4294967296)) and 1 or 0)))
v_r = bor(lshift(v_r, 1), (rshift(v_A, 31) % 4294967296))
v_A = bor(v_s, lshift(v_A, 1))
v_i = band(v_i, 1)
v_s = v_i
v_f = tobit((v_f - 1))
if not (v_f ~= 0) then goto B205 end
end
do
end
::C205::
end
end
::B205::
end
end
end
Iv = bor(lshift(v_r, 1), (rshift(v_A, 31) % 4294967296))
v_A = bor(v_i, lshift(v_A, 1))
goto L195
end
end
::L197::
end
v_A = 0
v_r = 0
end
end
::L196::
end
Iv = v_r
end
end
::L195::
end
do return v_A end
end

F.fAA = function(v_A)
local v_r = 0
v_r = 0
if (v_A ~= 0) then
v_r = I32[arshift((v_A + 60), 2)]
if (v_r ~= 0) then
YA[I32[arshift((I32[arshift((I32[arshift(v_A, 2)] + 28), 2)] + 36), 2)]](v_r)
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

F.frA = function(v_A, v_r)
local v_e, v_n = 0, 0
v_e = 0
v_n = 0
F.fJ(v_A, v_r)
v_r = I32[arshift(v_A, 2)]
v_e = I32[arshift((v_A + 4), 2)]
v_n = I32[arshift((v_A + 124), 2)]
I32[arshift(v_A, 2)] = tobit(I32[arshift((v_A + 120), 2)])
I32[arshift((v_A + 4), 2)] = tobit(v_n)
I32[arshift((v_A + 120), 2)] = tobit(v_r)
I32[arshift((v_A + 124), 2)] = tobit(v_e)
v_r = I32[arshift((v_A + 8), 2)]
v_e = I32[arshift((v_A + 12), 2)]
v_n = I32[arshift((v_A + 116), 2)]
I32[arshift((v_A + 8), 2)] = tobit(I32[arshift((v_A + 112), 2)])
I32[arshift((v_A + 12), 2)] = tobit(v_n)
I32[arshift((v_A + 112), 2)] = tobit(v_r)
I32[arshift((v_A + 116), 2)] = tobit(v_e)
v_r = I32[arshift((v_A + 104), 2)]
v_e = I32[arshift((v_A + 108), 2)]
v_n = I32[arshift((v_A + 20), 2)]
I32[arshift((v_A + 104), 2)] = tobit(I32[arshift((v_A + 16), 2)])
I32[arshift((v_A + 108), 2)] = tobit(v_n)
I32[arshift((v_A + 16), 2)] = tobit(v_r)
I32[arshift((v_A + 20), 2)] = tobit(v_e)
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

F.feA = function(v_A, v_r, v_e, v_t)
local v_o, v_a, v_u, v_c = 0, 0, 0, 0
v_o = 0
v_a = 0
v_u = 0
v_c = 0
v_a = bor(bor(bor(U8[tobit((v_e + 4))], lshift(U8[tobit((v_e + 5))], 8)), lshift(U8[tobit((v_e + 6))], 16)), lshift(U8[tobit((v_e + 7))], 24))
v_a = bor(bor(bor(lshift(v_a, 24), band(lshift(v_a, 8), 16711680)), band((rshift(v_a, 8) % 4294967296), 65280)), (rshift(v_a, 24) % 4294967296))
v_e = bor(bor(bor(U8[bor(0, v_e)], lshift(U8[tobit((v_e + 1))], 8)), lshift(U8[tobit((v_e + 2))], 16)), lshift(U8[tobit((v_e + 3))], 24))
v_u = bor(bor(bor(lshift(v_e, 24), band(lshift(v_e, 8), 16711680)), band((rshift(v_e, 8) % 4294967296), 65280)), (rshift(v_e, 24) % 4294967296))
if (v_r ~= 0) then
do
v_r = 0
v_e = tobit((v_A + 72))
while true do
v_o = bxor(I32[arshift((lshift(v_r, 2) + v_A), 2)], v_u)
v_u = bxor((bxor((I32[arshift((1024 + tobit((v_e + band((rshift(v_o, 14) % 4294967296), 1020)))), 2)] + I32[arshift((v_e + band((rshift(v_o, 22) % 4294967296), 1020)), 2)]), I32[arshift((2048 + tobit((v_e + band((rshift(v_o, 6) % 4294967296), 1020)))), 2)]) + I32[arshift((3072 + tobit((v_e + lshift(band(255, v_o), 2)))), 2)]), v_a)
v_a = v_o
v_r = tobit((v_r + 1))
if not (16 ~= bor(0, v_r)) then goto B206 end
do
end
::C206::
end
end
::B206::
v_e = bxor(I32[arshift((v_A + 64), 2)], v_u)
v_A = tobit((v_A + 68))
else
do
v_e = 17
v_c = tobit((v_A + 72))
while true do
v_o = bxor(I32[arshift((lshift(v_e, 2) + v_A), 2)], v_u)
v_u = bxor((bxor((I32[arshift((1024 + tobit((band((rshift(v_o, 14) % 4294967296), 1020) + v_c))), 2)] + I32[arshift((band((rshift(v_o, 22) % 4294967296), 1020) + v_c), 2)]), I32[arshift((2048 + tobit((band((rshift(v_o, 6) % 4294967296), 1020) + v_c))), 2)]) + I32[arshift((3072 + tobit((lshift(band(255, v_o), 2) + v_c))), 2)]), v_a)
v_r = (((tobit(v_e) % 4294967296) > 2) and 1 or 0)
v_e = tobit((v_e - 1))
v_a = v_o
if not (v_r ~= 0) then goto B207 end
do
end
::C207::
end
end
::B207::
v_e = bxor(I32[arshift((v_A + 4), 2)], v_u)
end
v_A = I32[arshift(v_A, 2)]
I8[tobit((v_t + 7))] = tobit(v_e)
I8[tobit((v_t + 6))] = tobit((rshift(v_e, 8) % 4294967296))
I8[tobit((v_t + 5))] = tobit((rshift(v_e, 16) % 4294967296))
I8[tobit((v_t + 4))] = tobit((rshift(v_e, 24) % 4294967296))
v_A = bxor(v_A, v_o)
I8[tobit((v_t + 3))] = tobit(v_A)
I8[tobit((v_t + 2))] = tobit((rshift(v_A, 8) % 4294967296))
I8[tobit((v_t + 1))] = tobit((rshift(v_A, 16) % 4294967296))
I8[bor(0, v_t)] = tobit((rshift(v_A, 24) % 4294967296))
do return 0 end
end

F.fnA = function(v_A, v_r, v_e, v_t)
local v_o, v_a, v_u, v_c, v_s, v_l = 0, 0, 0, 0, 0, 0
v_l = 0
v_o = tobit((B - 400))
B = v_o
v_l = tobit((v_r + 1))
v_s = F.fPA(F.fm(v_l), 0, v_l)
F.fHA(tobit((v_o + 8)))
F.fN(tobit((v_o + 8)), 2, v_t, 256)
v_a = tobit((B - 16))
B = v_a
I32[arshift((v_a + 12), 2)] = tobit(0)
v_l = tobit((v_o + 8))
v_t = v_l
I32[arshift((352 + v_t), 2)] = tobit(0)
I32[arshift((v_t + 356), 2)] = tobit(0)
I32[arshift((v_t + 384), 2)] = tobit(0)
I32[arshift((v_t + 320), 2)] = tobit(0)
I32[arshift((v_t + 324), 2)] = tobit(0)
I32[arshift((v_t + 376), 2)] = tobit(0)
I32[arshift((v_t + 380), 2)] = tobit(0)
I32[arshift((v_t + 368), 2)] = tobit(0)
I32[arshift((v_t + 372), 2)] = tobit(0)
I32[arshift((v_t + 360), 2)] = tobit(0)
I32[arshift((v_t + 364), 2)] = tobit(0)
I32[arshift((v_t + 328), 2)] = tobit(0)
I32[arshift((v_t + 332), 2)] = tobit(0)
v_u = bor(bor(bor(U8[tobit((v_e + 4))], lshift(U8[tobit((v_e + 5))], 8)), lshift(U8[tobit((v_e + 6))], 16)), lshift(U8[tobit((v_e + 7))], 24))
v_t = tobit((v_t + 352))
v_c = bor(bor(bor(U8[bor(0, v_e)], lshift(U8[tobit((v_e + 1))], 8)), lshift(U8[tobit((v_e + 2))], 16)), lshift(U8[tobit((v_e + 3))], 24))
I8[bor(0, v_t)] = tobit(v_c)
I8[tobit((v_t + 1))] = tobit((rshift(v_c, 8) % 4294967296))
I8[tobit((v_t + 2))] = tobit((rshift(v_c, 16) % 4294967296))
I8[tobit((v_t + 3))] = tobit((rshift(v_c, 24) % 4294967296))
I8[tobit((v_t + 4))] = tobit(v_u)
I8[tobit((v_t + 5))] = tobit((rshift(v_u, 8) % 4294967296))
I8[tobit((v_t + 6))] = tobit((rshift(v_u, 16) % 4294967296))
I8[tobit((v_t + 7))] = tobit((rshift(v_u, 24) % 4294967296))
v_e = bor(bor(bor(U8[tobit((v_e + 8))], lshift(U8[tobit((v_e + 9))], 8)), lshift(U8[tobit((v_e + 10))], 16)), lshift(U8[tobit((v_e + 11))], 24))
I8[tobit((v_t + 8))] = tobit(v_e)
I8[tobit((v_t + 9))] = tobit((rshift(v_e, 8) % 4294967296))
I8[tobit((v_t + 10))] = tobit((rshift(v_e, 16) % 4294967296))
I8[tobit((v_t + 11))] = tobit((rshift(v_e, 24) % 4294967296))
I8[tobit((v_l + 367))] = tobit(1)
if not (F.fW(v_l, v_t, tobit((v_l + 336)), tobit((v_a + 12))) ~= 0) then
I32[arshift((v_l + 328), 2)] = tobit(0)
I32[arshift((v_l + 332), 2)] = tobit(0)
end
B = tobit((v_a + 16))
F.fU(tobit((v_o + 8)), v_r, v_A, v_s)
F.fyA(tobit((v_o + 8)))
B = tobit((v_o + 400))
do return v_s end
end

F.ftA = function(v_A)
local v_r, v_e, v_n, v_t, v_o, v_f, v_a = 0, 0, 0, 0, 0, 0, 0
v_e = 0
v_n = 0
v_t = 0
v_o = 0
v_f = 0
v_a = 0
do
v_r = tobit((B - 16))
B = v_r
v_o = I32[arshift(v_A, 2)]
I32[arshift((v_r + 4), 2)] = tobit(0)
v_f = 1
v_n = lshift(v_o, 1)
I32[arshift(v_r, 2)] = tobit(v_n)
v_e = v_n
while true do
v_a = v_t
if not (v_e ~= 0) then goto B208 end
do
v_e = band(v_e, (v_e - 1))
v_t = tobit((v_t + 1))
end
::C208::
end
end
::B208::
do
do
do
local t268 = (1 == bor(0, v_a))
if t268 then
v_e = F.fOA(v_n, 16)
I32[arshift((v_r + 8), 2)] = tobit(v_e)
t268 = (v_e ~= 0)
end
if t268 then
if (v_o ~= 0) then
do
v_n = 0
while true do
do
v_e = tobit((I32[arshift((v_A + 8), 2)] + lshift(v_n, 4)))
if (I32[arshift((v_e + 8), 2)] ~= 0) then
v_f = I32[arshift((v_e + 12), 2)]
v_a = I32[arshift((v_e + 4), 2)]
v_o = I32[arshift(v_e, 2)]
do
do
while true do
do
if (F.fG(v_r, v_o, v_a, tobit((v_r + 12))) ~= 0) then
goto L211
end
if (F.ftA(v_r) ~= 0) then
goto B212
end
end
::C212::
end
end
::B212::
v_f = 1
goto L209
end
::L211::
v_t = tobit((I32[arshift((v_r + 8), 2)] + lshift(I32[arshift((v_r + 12), 2)], 4)))
I32[arshift((v_t + 4), 2)] = tobit(v_a)
I32[arshift(v_t, 2)] = tobit(v_o)
I32[arshift((v_t + 12), 2)] = tobit(v_f)
if not (I32[arshift((v_t + 8), 2)] ~= 0) then
I32[arshift((v_t + 8), 2)] = tobit(1)
I32[arshift((v_r + 4), 2)] = tobit((I32[arshift((v_r + 4), 2)] + 1))
end
I32[arshift(v_e, 2)] = tobit(0)
I32[arshift((v_e + 4), 2)] = tobit(0)
I32[arshift((v_e + 8), 2)] = tobit(0)
I32[arshift((v_e + 12), 2)] = tobit(0)
I32[arshift((v_A + 4), 2)] = tobit((I32[arshift((v_A + 4), 2)] - 1))
v_o = I32[arshift(v_A, 2)]
end
v_n = tobit((v_n + 1))
if (not ((tobit(v_n) % 4294967296) < (tobit(v_o) % 4294967296))) then
goto B210
end
end
::C210::
end
end
::B210::
end
F.fL(I32[arshift((v_A + 8), 2)])
I32[arshift((v_A + 8), 2)] = tobit(I32[arshift((v_r + 8), 2)])
v_e = I32[arshift((v_r + 4), 2)]
I32[arshift(v_A, 2)] = tobit(I32[arshift(v_r, 2)])
I32[arshift((v_A + 4), 2)] = tobit(v_e)
v_f = 0
end
end
end
::L209::
end
B = tobit((v_r + 16))
do return v_f end
end

F.foA = function(v_A, v_r, v_e, v_t)

do
if (not ((tobit(v_r) % 4294967296) > 20)) then
do
local sw214 = tobit((v_r - 9))
if sw214 == 0 then goto K214_0
elseif sw214 == 1 then goto K214_1
elseif sw214 == 2 then goto K214_2
elseif sw214 == 3 then goto K214_3
elseif sw214 == 4 then goto K214_4
elseif sw214 == 5 then goto K214_5
elseif sw214 == 6 then goto K214_6
elseif sw214 == 7 then goto K214_7
elseif sw214 == 8 then goto K214_8
elseif sw214 == 9 then goto K214_9
else goto K214_10 end
::K214_0::
do
v_r = I32[arshift(v_e, 2)]
I32[arshift(v_e, 2)] = tobit((v_r + 4))
I32[arshift(v_A, 2)] = tobit(I32[arshift(v_r, 2)])
do return end
end
::K214_1::
do
v_r = I32[arshift(v_e, 2)]
I32[arshift(v_e, 2)] = tobit((v_r + 4))
v_r = I32[arshift(v_r, 2)]
I32[arshift(v_A, 2)] = tobit(v_r)
I32[arshift((v_A + 4), 2)] = tobit(arshift(v_r, 31))
do return end
end
::K214_2::
do
v_r = I32[arshift(v_e, 2)]
I32[arshift(v_e, 2)] = tobit((v_r + 4))
I32[arshift(v_A, 2)] = tobit(I32[arshift(v_r, 2)])
I32[arshift((v_A + 4), 2)] = tobit(0)
do return end
end
::K214_3::
do
v_r = band((I32[arshift(v_e, 2)] + 7), (-8))
I32[arshift(v_e, 2)] = tobit((v_r + 8))
v_e = I32[arshift((v_r + 4), 2)]
I32[arshift(v_A, 2)] = tobit(I32[arshift(v_r, 2)])
I32[arshift((v_A + 4), 2)] = tobit(v_e)
do return end
end
::K214_4::
do
v_r = I32[arshift(v_e, 2)]
I32[arshift(v_e, 2)] = tobit((v_r + 4))
v_r = I16[arshift(v_r, 1)]
I32[arshift(v_A, 2)] = tobit(v_r)
I32[arshift((v_A + 4), 2)] = tobit(arshift(v_r, 31))
do return end
end
::K214_5::
do
v_r = I32[arshift(v_e, 2)]
I32[arshift(v_e, 2)] = tobit((v_r + 4))
I32[arshift(v_A, 2)] = tobit(U16[arshift(v_r, 1)])
I32[arshift((v_A + 4), 2)] = tobit(0)
do return end
end
::K214_6::
do
v_r = I32[arshift(v_e, 2)]
I32[arshift(v_e, 2)] = tobit((v_r + 4))
v_r = I8[bor(0, v_r)]
I32[arshift(v_A, 2)] = tobit(v_r)
I32[arshift((v_A + 4), 2)] = tobit(arshift(v_r, 31))
do return end
end
::K214_7::
do
v_r = I32[arshift(v_e, 2)]
I32[arshift(v_e, 2)] = tobit((v_r + 4))
I32[arshift(v_A, 2)] = tobit(U8[bor(0, v_r)])
I32[arshift((v_A + 4), 2)] = tobit(0)
do return end
end
::K214_8::
do
v_r = band((I32[arshift(v_e, 2)] + 7), (-8))
I32[arshift(v_e, 2)] = tobit((v_r + 8))
F64[arshift(v_A, 3)] = F64[arshift(v_r, 3)]
do return end
end
::K214_9::
do
goto S214
end
::K214_10::
do
goto L213
end
end
::S214::
YA[bor(0, v_t)](v_A, v_e)
end
end
::L213::
end

F.fiA = function(v_A, v_r, v_e)
local v_t, v_o, v_a, v_u = 0, 0, 0, 0
v_t = 0
v_o = 0
v_a = 0
v_u = 0
do
if (not (band(32, U8[bor(0, v_A)]) ~= 0)) then
do
do
do
v_o = v_r
v_r = v_e
do
do
do
v_t = v_A
v_A = I32[arshift((v_t + 16), 2)]
if (not (v_A ~= 0)) then
v_A = U8[tobit((v_t + 74))]
I8[tobit((v_t + 74))] = tobit(bor((v_A - 1), v_A))
v_A = I32[arshift(v_t, 2)]
if (band(8, v_A) ~= 0) then
I32[arshift(v_t, 2)] = tobit(bor(32, v_A))
v_A = (-1)
else
I32[arshift((v_t + 4), 2)] = tobit(0)
I32[arshift((v_t + 8), 2)] = tobit(0)
v_A = I32[arshift((v_t + 44), 2)]
I32[arshift((v_t + 28), 2)] = tobit(v_A)
I32[arshift((v_t + 20), 2)] = tobit(v_A)
I32[arshift((v_t + 16), 2)] = tobit((v_A + I32[arshift((v_t + 48), 2)]))
v_A = 0
end
if (v_A ~= 0) then
goto L216
end
v_A = I32[arshift((v_t + 16), 2)]
end
do
local t269 = v_A
v_u = I32[arshift((v_t + 20), 2)]
if ((tobit((t269 - v_u)) % 4294967296) < (tobit(v_r) % 4294967296)) then
YA[I32[arshift((v_t + 36), 2)]](v_t, v_o, v_e)
goto L215
end
end
do
do
do
if (I8[tobit((v_t + 75))] > (-1)) then
do
do
do
v_A = v_e
while true do
do
do
v_r = v_A
v_a = v_e
if (not (v_A ~= 0)) then
goto L217
end
do
local t270 = v_o
v_A = tobit((v_r - 1))
if (10 == U8[tobit((t270 + v_A))]) then
goto B218
end
end
end
end
::C218::
end
end
::B218::
end
if ((tobit(YA[I32[arshift((v_t + 36), 2)]](v_t, v_o, v_r)) % 4294967296) < (tobit(v_r) % 4294967296)) then
goto L216
end
v_o = tobit((v_r + v_o))
v_u = I32[arshift((v_t + 20), 2)]
v_a = tobit((v_e - v_r))
end
else
v_a = v_e
end
end
end
::L217::
end
do
local t271 = v_u
local t272 = v_o
v_r = v_a
F.fTA(t271, t272, v_r)
I32[arshift((v_t + 20), 2)] = tobit((v_r + I32[arshift((v_t + 20), 2)]))
end
end
end
::L216::
end
end
end
::L215::
end
end
end
end

F.ffA = function(v_A, v_r, v_e, v_t, v_o)
local v_f, v_a = 0, 0
v_a = 0
v_f = tobit((B - 208))
B = v_f
I32[arshift((v_f + 204), 2)] = tobit(v_e)
F.fPA(tobit((v_f + 160)), 0, 40)
I32[arshift((v_f + 200), 2)] = tobit(I32[arshift((v_f + 204), 2)])
if not (bor(0, F.fO(0, v_r, tobit((v_f + 200)), tobit((v_f + 80)), tobit((v_f + 160)), v_t, v_o)) < 0) then
v_e = I32[arshift(v_A, 2)]
if (I8[tobit((v_A + 74))] <= 0) then
I32[arshift(v_A, 2)] = tobit(band((-33), v_e))
end
v_a = band(32, v_e)
if (I32[arshift((v_A + 48), 2)] ~= 0) then
F.fO(v_A, v_r, tobit((v_f + 200)), tobit((v_f + 80)), tobit((v_f + 160)), v_t, v_o)
else
I32[arshift((v_A + 48), 2)] = tobit(80)
I32[arshift((v_A + 16), 2)] = tobit((v_f + 80))
I32[arshift((v_A + 28), 2)] = tobit(v_f)
I32[arshift((v_A + 20), 2)] = tobit(v_f)
v_e = I32[arshift((v_A + 44), 2)]
I32[arshift((v_A + 44), 2)] = tobit(v_f)
F.fO(v_A, v_r, tobit((v_f + 200)), tobit((v_f + 80)), tobit((v_f + 160)), v_t, v_o)
if (v_e ~= 0) then
YA[I32[arshift((v_A + 36), 2)]](v_A, 0, 0)
I32[arshift((v_A + 48), 2)] = tobit(0)
I32[arshift((v_A + 44), 2)] = tobit(v_e)
I32[arshift((v_A + 28), 2)] = tobit(0)
I32[arshift((v_A + 16), 2)] = tobit(0)
I32[arshift((v_A + 20), 2)] = tobit(0)
end
end
I32[arshift(v_A, 2)] = tobit(bor(I32[arshift(v_A, 2)], v_a))
end
B = tobit((v_f + 208))
end

F.faA = function(v_A, v_r)

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
goto L220
end
do
if (I32[arshift(I32[3447], 2)] ~= 0) then
do
if ((tobit(v_r) % 4294967296) <= 2047) then
I8[tobit((v_A + 1))] = tobit(bor(band(63, v_r), 128))
I8[bor(0, v_A)] = tobit(bor((rshift(v_r, 6) % 4294967296), 192))
v_A = 2
goto L219
end
do
local t273 = ((57344 ~= band((-8192), v_r)) and 1 or 0)
if t273 ~= 0 then
t273 = (((tobit(v_r) % 4294967296) >= 55296) and 1 or 0)
end
if (not (t273 ~= 0)) then
I8[tobit((v_A + 2))] = tobit(bor(band(63, v_r), 128))
I8[bor(0, v_A)] = tobit(bor((rshift(v_r, 12) % 4294967296), 224))
I8[tobit((v_A + 1))] = tobit(bor(band((rshift(v_r, 6) % 4294967296), 63), 128))
v_A = 3
goto L219
end
end
if ((tobit((v_r - 65536)) % 4294967296) <= 1048575) then
I8[tobit((v_A + 3))] = tobit(bor(band(63, v_r), 128))
I8[bor(0, v_A)] = tobit(bor((rshift(v_r, 18) % 4294967296), 240))
I8[tobit((v_A + 2))] = tobit(bor(band((rshift(v_r, 6) % 4294967296), 63), 128))
I8[tobit((v_A + 1))] = tobit(bor(band((rshift(v_r, 12) % 4294967296), 63), 128))
v_A = 4
goto L219
end
end
else
if (57216 == band((-128), v_r)) then
goto L220
end
end
end
I32[5680] = tobit(25)
v_A = (-1)
end
else
v_A = 1
end
end
goto L219
end
end
::L220::
end
I8[bor(0, v_A)] = tobit(v_r)
v_A = 1
end
end
::L219::
end
do return v_A end
end

F.fuA = function(v_A, v_r, v_e, v_n, v_t)
local v_o, v_a, v_u = 0, 0, 0
v_a = 0
v_u = 0
v_o = tobit((B - 288))
B = v_o
v_a = tobit((v_r + 1))
v_a = F.fPA(F.fm(v_a), 0, v_a)
F.fLA(tobit((v_o + 8)))
F.fZ(tobit((v_o + 8)), v_n, 256)
F.fR(tobit((v_o + 8)), 0, v_r, v_e, v_A, v_a)
F.fhA(tobit((v_o + 8)))
do
do
do
if (not (bor(band(15, v_r), (((tobit(v_r) % 4294967296) < 16) and 1 or 0)) ~= 0)) then
do
local t274 = v_a
v_A = tobit((v_r - 1))
v_e = U8[tobit((t274 + v_A))]
if ((tobit(band((v_e - 1), 255)) % 4294967296) > 15) then
v_u = v_r
else
do
if (not ((tobit(v_r) % 4294967296) <= (tobit(v_e) % 4294967296))) then
do
v_r = 2
if ((tobit(v_e) % 4294967296) < 2) then
v_u = v_A
else
do
do
do
while true do
do
do
do
local t276 = bor(0, v_e)
local t275 = v_a
v_A = tobit((v_A - 1))
if (t276 ~= U8[tobit((t275 + v_A))]) then
goto L221
end
end
if (not ((tobit(band(255, v_r)) % 4294967296) < (tobit(v_e) % 4294967296))) then
goto B222
end
v_r = tobit((v_r + 1))
end
end
::C222::
end
end
::B222::
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
::L221::
end
if (v_t ~= 0) then
I32[arshift(v_t, 2)] = tobit(v_u)
end
v_A = F.fm(tobit((v_u + 1)))
F.fPA(tobit((v_A + v_u)), 0, (((-1) ~= bor(0, v_u)) and 1 or 0))
v_A = F.fTA(v_A, v_a, v_u)
F.fL(v_a)
B = tobit((v_o + 288))
do return v_A end
end

F.fcA = function(v_A, v_r, v_e, v_n, v_t)
local v_o, v_a, v_u = 0, 0, 0
v_a = 0
v_u = 0
v_o = tobit((B - 128))
B = v_o
v_a = tobit((v_r + 1))
v_a = F.fPA(F.fm(v_a), 0, v_a)
F.fFA(v_o)
F.frA(v_o, v_n)
F.fX(v_o, 0, v_r, v_e, v_A, v_a)
F.fq(v_o)
do
do
do
if (not (bor(band(7, v_r), (((tobit(v_r) % 4294967296) < 8) and 1 or 0)) ~= 0)) then
do
local t277 = v_a
v_A = tobit((v_r - 1))
v_e = U8[tobit((t277 + v_A))]
if ((tobit(band((v_e - 1), 255)) % 4294967296) > 7) then
v_u = v_r
else
do
if (not ((tobit(v_r) % 4294967296) <= (tobit(v_e) % 4294967296))) then
do
v_r = 2
if ((tobit(v_e) % 4294967296) < 2) then
v_u = v_A
else
do
do
do
while true do
do
do
do
local t279 = bor(0, v_e)
local t278 = v_a
v_A = tobit((v_A - 1))
if (t279 ~= U8[tobit((t278 + v_A))]) then
goto L223
end
end
if (not ((tobit(band(255, v_r)) % 4294967296) < (tobit(v_e) % 4294967296))) then
goto B224
end
v_r = tobit((v_r + 1))
end
end
::C224::
end
end
::B224::
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
::L223::
end
if (v_t ~= 0) then
I32[arshift(v_t, 2)] = tobit(v_u)
end
v_A = F.fm(tobit((v_u + 1)))
F.fPA(tobit((v_A + v_u)), 0, (((-1) ~= bor(0, v_u)) and 1 or 0))
v_A = F.fTA(v_A, v_a, v_u)
F.fL(v_a)
B = tobit((v_o + 128))
do return v_A end
end

F.fsA = function(v_A, v_r)
local v_e, v_t = 0, 0
v_e = 0
v_t = 0
do
do
do
do
v_t = v_A
if (not (band(3, bxor(v_t, v_r)) ~= 0)) then
do
if (band(3, v_r) ~= 0) then
do
while true do
do
v_e = U8[bor(0, v_r)]
I8[bor(0, v_t)] = tobit(v_e)
if (not (v_e ~= 0)) then
goto L225
end
v_t = tobit((v_t + 1))
v_r = tobit((v_r + 1))
if (not (band(3, v_r) ~= 0)) then
goto B226
end
end
::C226::
end
end
::B226::
end
do
local t280 = (-1)
v_e = I32[arshift(v_r, 2)]
if (not (band(band(bxor(t280, v_e), (v_e - 16843009)), (-2139062144)) ~= 0)) then
do
while true do
I32[arshift(v_t, 2)] = tobit(v_e)
v_e = I32[arshift((v_r + 4), 2)]
v_t = tobit((v_t + 4))
v_r = tobit((v_r + 4))
if not (not (band(band((v_e - 16843009), bxor((-1), v_e)), (-2139062144)) ~= 0)) then goto B227 end
do
end
::C227::
end
end
::B227::
end
end
end
end
end
v_e = U8[bor(0, v_r)]
I8[bor(0, v_t)] = tobit(v_e)
if (v_e ~= 0) then
do
while true do
v_e = U8[tobit((v_r + 1))]
I8[tobit((v_t + 1))] = tobit(v_e)
v_t = tobit((v_t + 1))
v_r = tobit((v_r + 1))
if not (v_e ~= 0) then goto B228 end
do
end
::C228::
end
end
::B228::
end
end
end
::L225::
end
do return v_A end
end

F.flA = function(v_A, v_r)
local v_e = 0
v_e = 0
v_e = (-24832)
if (not (bor(((not (v_r ~= 0)) and 1 or 0), ((not (v_A ~= 0)) and 1 or 0)) ~= 0)) then
v_e = v_A
I32[arshift(v_e, 2)] = tobit(0)
I32[arshift((v_e + 4), 2)] = tobit(0)
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
v_e = bor(0, YA[I32[arshift((I32[arshift((v_r + 28), 2)] + 32), 2)]]())
I32[arshift((v_A + 60), 2)] = tobit(v_e)
if (not (v_e ~= 0)) then
do return (-24960) end
end
I32[arshift(v_A, 2)] = tobit(v_r)
v_e = 0
if (2 == I32[arshift((v_r + 4), 2)]) then
I32[arshift((v_A + 16), 2)] = tobit(50)
I32[arshift((v_A + 12), 2)] = tobit(51)
end
end
do return v_e end
end

F.fbA = function(v_A, v_r, v_e)
local v_n, v_t = 0, 0
v_n = 0
v_t = 0
do
F.fJ(v_A, v_e)
F.fJ(tobit((v_r + 128)), tobit((v_e + 8)))
F.fJ(tobit((v_A + 256)), tobit((v_e + 16)))
v_e = 0
while true do
v_n = lshift(v_e, 2)
v_t = tobit((v_n + v_r))
I32[arshift(v_t, 2)] = tobit(I32[arshift((lshift((94 - v_e), 2) + v_A), 2)])
I32[arshift((bor(4, v_n) + v_r), 2)] = tobit(I32[arshift((lshift((95 - v_e), 2) + v_A), 2)])
v_n = tobit((v_A + v_n))
I32[arshift((128 + v_n), 2)] = tobit(I32[arshift((lshift((62 - v_e), 2) + v_r), 2)])
I32[arshift((v_n + 132), 2)] = tobit(I32[arshift((lshift((63 - v_e), 2) + v_r), 2)])
I32[arshift((v_t + 256), 2)] = tobit(I32[arshift((lshift((30 - v_e), 2) + v_A), 2)])
I32[arshift((v_t + 260), 2)] = tobit(I32[arshift((lshift((31 - v_e), 2) + v_A), 2)])
v_n = (((tobit(v_e) % 4294967296) < 30) and 1 or 0)
v_e = tobit((v_e + 2))
if not (v_n ~= 0) then goto B229 end
do
end
::C229::
end
end
::B229::
end

F.fvA = function(v_A)
local v_r, v_e, v_t, v_o, v_i = 0, 0, 0, 0, 0
do
v_r = 0
v_e = 0
v_t = 0
v_o = 0
v_i = 0
while true do
v_r = v_A
v_A = tobit((v_r + 1))
if not (F.fRA(I8[bor(0, v_r)]) ~= 0) then goto B230 end
do
end
::C230::
end
end
::B230::
do
do
v_e = I8[bor(0, v_r)]
do
local sw233 = tobit((v_e - 43))
if sw233 == 0 then goto K233_0
elseif sw233 == 2 then goto K233_1
else goto K233_2 end
::K233_0::
do
goto L232
end
::K233_1::
do
goto S233
end
::K233_2::
do
goto L231
end
end
::S233::
v_o = 1
end
::L232::
v_e = I8[bor(0, v_A)]
v_r = v_A
v_i = v_o
end
::L231::
do
if (F.fDA(v_e) ~= 0) then
do
v_A = 0
while true do
do
v_t = tobit((48 + tobit((v_A - I8[bor(0, v_r)]))))
if (not (F.fDA(I8[tobit((v_r + 1))]) ~= 0)) then
goto L234
end
v_r = tobit((v_r + 1))
v_A = imul(v_t, 10)
end
::C235::
end
end
::B235::
end
end
::L234::
do return ((v_i ~= 0) and v_t or tobit((0 - v_t))) end
end

F.fgA = function(v_A, v_r, v_e)
local v_t, v_o, v_f = 0, 0, 0
v_f = 0
v_o = tobit((B - 16))
B = v_o
I32[arshift((v_o + 12), 2)] = tobit(v_e)
v_t = tobit((B - 160))
B = v_t
F.fTA(tobit((v_t + 8)), 12304, 144)
I32[arshift((v_t + 52), 2)] = tobit(v_A)
I32[arshift((v_t + 28), 2)] = tobit(v_A)
v_f = tobit(((-2) - v_A))
v_f = (((tobit(v_f) % 4294967296) < 2147483647) and v_f or 2147483647)
I32[arshift((v_t + 56), 2)] = tobit(v_f)
v_A = tobit((v_A + v_f))
I32[arshift((v_t + 36), 2)] = tobit(v_A)
I32[arshift((v_t + 24), 2)] = tobit(v_A)
F.ffA(tobit((v_t + 8)), v_r, v_e, 0, 0)
if (v_f ~= 0) then
v_A = I32[arshift((v_t + 28), 2)]
I8[tobit((v_A - ((bor(0, v_A) == I32[arshift((v_t + 24), 2)]) and 1 or 0)))] = tobit(0)
end
B = tobit((v_t + 160))
B = tobit((v_o + 16))
end

F.fpA = function(v_A)
local v_r, v_e, v_n = 0, 0, 0
v_r = 0
v_e = 0
v_n = 0
do
do
do
v_r = v_A
if (band(3, v_r) ~= 0) then
do
while true do
do
if (not (U8[bor(0, v_r)] ~= 0)) then
goto L236
end
v_r = tobit((v_r + 1))
if (not (band(3, v_r) ~= 0)) then
goto B237
end
end
::C237::
end
end
::B237::
end
do
do
while true do
do
v_e = v_r
v_r = tobit((v_r + 4))
local t281 = (-1)
v_n = I32[arshift(v_e, 2)]
if not (not (band(band(bxor(t281, v_n), (v_n - 16843009)), (-2139062144)) ~= 0)) then goto B238 end
end
do
end
::C238::
end
end
::B238::
end
if (not (band(255, v_n) ~= 0)) then
do return tobit((v_e - v_A)) end
end
do
while true do
v_n = U8[tobit((v_e + 1))]
v_r = tobit((v_e + 1))
v_e = v_r
if not (v_n ~= 0) then goto B239 end
do
end
::C239::
end
end
::B239::
end
end
::L236::
end
do return tobit((v_r - v_A)) end
end

F.fdA = function(v_A, v_r, v_e)
local v_t, v_o, v_i = 0, 0, 0
v_t = 0
v_o = 0
v_i = 0
if ((tobit(v_r) % 4294967296) < 1) then
v_t = v_A
else
do
while true do
v_t = F.fS_(v_A, v_r, 10)
v_o = Iv
v_i = v_o
v_o = F.fCA(v_t, v_o, 10, 0)
v_e = tobit((v_e - 1))
I8[bor(0, v_e)] = tobit(bor((v_A - v_o), 48))
v_o = (((tobit(v_r) % 4294967296) > 9) and 1 or 0)
v_A = v_t
v_r = v_i
if not (v_o ~= 0) then goto B240 end
do
end
::C240::
end
end
::B240::
end
if (v_t ~= 0) then
do
while true do
v_A = tobit(toint(((tobit(v_t) % 4294967296) / 10)))
v_e = tobit((v_e - 1))
I8[bor(0, v_e)] = tobit(bor((v_t - imul(v_A, 10)), 48))
v_r = (((tobit(v_t) % 4294967296) > 9) and 1 or 0)
v_t = v_A
if not (v_r ~= 0) then goto B241 end
do
end
::C241::
end
end
::B241::
end
do return v_e end
end

F.fhA = function(v_A)
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
goto L242
end
v_A = tobit((v_A + 14))
v_r = tobit((v_r - 14))
end
::C243::
end
end
::B243::
end
end
::L242::
end

F.fkA = function(v_A, v_r)
local v_e, v_n, v_t = 0, 0, 0
v_t = 0
rf_s(v_A)
v_t = bor(0, rf_a(1))
v_e = bor(0, rf_a(0))
v_n = v_t
v_t = band((rshift(v_t, 20) % 4294967296), 2047)
if (2047 ~= bor(0, v_t)) then
if (not (v_t ~= 0)) then
v_t = v_r
if (0 == v_A) then
v_r = 0
else
v_A = F.fkA((18446744073709552000 * v_A), v_r)
v_r = tobit((I32[arshift(v_r, 2)] + (-64)))
end
I32[arshift(v_t, 2)] = tobit(v_r)
do return v_A end
end
I32[arshift(v_r, 2)] = tobit((v_t - 1022))
rf_u(0, bor(0, v_e))
rf_u(1, bor(band((-2146435073), v_n), 1071644672))
v_A = rf_c()
end
do return v_A end
end

F.fyA = function(v_A)
local v_r = 0
v_r = 0
do
F.fAA(v_A)
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
if not (v_r ~= 0) then goto B244 end
do
v_A = tobit((v_A + 14))
v_r = tobit((v_r - 14))
end
::C244::
end
end
::B244::
end

F.fwA = function(v_A, v_r, v_e)
local v_n, v_t = 0, 0
v_n = 0
v_t = 0
if (not (v_e ~= 0)) then
do return 0 end
end
do
v_n = U8[bor(0, v_A)]
if (v_n ~= 0) then
do
while true do
do
v_t = U8[bor(0, v_r)]
if (not (v_t ~= 0)) then
goto L245
end
v_e = tobit((v_e - 1))
if (not (v_e ~= 0)) then
goto L245
end
if (bor(0, v_n) ~= bor(0, v_t)) then
goto L245
end
v_r = tobit((v_r + 1))
v_n = U8[tobit((v_A + 1))]
v_A = tobit((v_A + 1))
if (not (v_n ~= 0)) then
goto B246
end
end
::C246::
end
end
::B246::
end
v_n = 0
end
::L245::
do return tobit((v_n - U8[bor(0, v_r)])) end
end

F.fCA = function(v_A, v_r, v_e, v_n)
local v_t, v_o, v_i, v_f, v_a, v_u = 0, 0, 0, 0, 0, 0
v_a = 0
v_u = 0
do
v_a = tobit((rshift(v_e, 16) % 4294967296))
local t282 = v_a
v_u = tobit((rshift(v_A, 16) % 4294967296))
v_f = imul(t282, v_u)
v_t = band(65535, v_e)
local t283 = v_t
v_o = band(65535, v_A)
v_i = imul(t283, v_o)
v_u = tobit((tobit((rshift(v_i, 16) % 4294967296)) + imul(v_u, v_t)))
v_a = tobit((band(65535, v_u) + imul(v_a, v_o)))
Iv = tobit((((tobit((imul(v_r, v_e) + v_f)) + imul(v_A, v_n)) + (rshift(v_u, 16) % 4294967296)) + (rshift(v_a, 16) % 4294967296)))
do return bor(band(65535, v_i), lshift(v_a, 16)) end
end
end

F.fEA = function(v_A, v_r, v_e, v_n, v_t)
local v_o = 0
do
v_o = tobit((B - 256))
B = v_o
if (not (bor(band(73728, v_t), ((bor(0, v_e) <= bor(0, v_n)) and 1 or 0)) ~= 0)) then
do
do
local t284 = v_o
local t285 = band(255, v_r)
v_e = tobit((v_e - v_n))
v_n = (((tobit(v_e) % 4294967296) < 256) and 1 or 0)
F.fPA(t284, t285, ((v_n ~= 0) and v_e or 256))
if (not (v_n ~= 0)) then
do
while true do
F.fiA(v_A, v_o, 256)
v_e = tobit((v_e - 256))
if not ((tobit(v_e) % 4294967296) > 255) then goto B247 end
do
end
::C247::
end
end
::B247::
end
end
F.fiA(v_A, v_o, v_e)
end
end
end
B = tobit((v_o + 256))
end

F.fBA = function(v_A, v_r)
local v_e, v_n, v_t = 0, 0, 0
v_e = 0
v_n = 0
v_t = 0
v_n = 10112
do
do
do
do
v_e = I32[2529]
if (v_e ~= 0) then
do
do
while true do
do
do
do
v_t = v_n
local t286 = ((1 ~= I32[arshift((v_e + 4), 2)]) and 1 or 0)
if t286 == 0 then
t286 = bor(((I32[arshift(I32[arshift((v_e + 28), 2)], 2)] ~= bor(0, v_A)) and 1 or 0), ((I32[arshift((v_e + 8), 2)] ~= bor(0, v_r)) and 1 or 0))
end
if (not (t286 ~= 0)) then
goto L248
end
end
v_n = tobit((v_t + 8))
v_e = I32[arshift((v_t + 12), 2)]
if (not (v_e ~= 0)) then
goto B249
end
end
end
::C249::
end
end
::B249::
end
end
end
v_e = 0
end
end
::L248::
end
do return v_e end
end

F.fIA = function(v_A, v_r, v_e)
local v_n, v_t = 0, 0
v_n = 0
v_t = 0
do
v_t = (-24832)
if (v_A ~= 0) then
v_n = I32[arshift(v_A, 2)]
local t288 = (not (v_n ~= 0))
local t287 = ((I32[arshift((v_n + 8), 2)] == bor(0, v_e)) and 1 or 0)
if t287 == 0 then
t287 = band(2, U8[tobit((v_n + 20))])
end
if not (bor((t288 and 1 or 0), ((not (t287 ~= 0)) and 1 or 0)) ~= 0) then
I32[arshift((v_A + 8), 2)] = tobit(1)
I32[arshift((v_A + 4), 2)] = tobit(v_e)
v_t = bor(0, YA[I32[arshift((I32[arshift((v_n + 28), 2)] + 24), 2)]](I32[arshift((v_A + 60), 2)], v_r, v_e))
end
end
do return v_t end
end
end

F.fmA = function(v_A)
local v_r, v_n = 0, 0
do
v_r = I32[3403]
local t289 = v_r
v_n = band((v_A + 3), (-4))
v_A = tobit((t289 + v_n))
local t290
if ((((tobit(v_A) % 4294967296) <= (tobit(v_r) % 4294967296)) and (v_n ~= 0)) or (((tobit(v_A) % 4294967296) > (tobit(lshift(tobit(toint((16777216 / 65536))), 16)) % 4294967296)) and (not (bor(0, imp_f(bor(0, v_A))) ~= 0)))) then
I32[5680] = tobit(48)
t290 = (-1)
else
I32[3403] = tobit(v_A)
t290 = v_r
end
do return t290 end
end
end

F.fQA = function(v_A)
local v_r, v_e, v_t = 0, 0, 0
v_r = 0
v_e = 0
v_t = 0
do
if (F.fDA(I8[I32[arshift(v_A, 2)]]) ~= 0) then
do
while true do
do
v_e = I32[arshift(v_A, 2)]
v_t = I8[bor(0, v_e)]
I32[arshift(v_A, 2)] = tobit((v_e + 1))
v_r = tobit((tobit((v_r + v_t)) - 48))
if (not (F.fDA(I8[tobit((v_e + 1))]) ~= 0)) then
goto L250
end
v_r = imul(v_r, 10)
end
::C251::
end
end
::B251::
end
end
::L250::
do return v_r end
end

F.fOA = function(v_A, v_r)
local v_e, v_n = 0, 0
v_e = 0
v_n = 0
v_e = 0
if (v_A ~= 0) then
v_n = F.fCA(v_A, 0, v_r, 0)
v_e = v_n
if not ((tobit(bor(v_A, v_r)) % 4294967296) < 65536) then
v_e = ((Iv ~= 0) and (-1) or v_n)
end
end
v_r = v_e
v_A = F.fm(v_r)
if not (bor(((not (v_A ~= 0)) and 1 or 0), ((not (band(3, U8[tobit((v_A - 4))]) ~= 0)) and 1 or 0)) ~= 0) then
F.fPA(v_A, 0, v_r)
end
do return v_A end
end

F.fSA = function(v_A, v_r, v_e)
local v_n, v_t, v_o = 0, 0, 0
v_n = 0
v_t = 0
v_o = 0
do
do
do
if (v_e ~= 0) then
do
do
do
while true do
do
do
do
v_n = U8[bor(0, v_A)]
local t291 = bor(0, v_n)
v_t = U8[bor(0, v_r)]
if (t291 == bor(0, v_t)) then
v_r = tobit((v_r + 1))
v_A = tobit((v_A + 1))
v_e = tobit((v_e - 1))
if (v_e ~= 0) then
goto C253
end
goto L252
end
end
goto B253
end
end
::C253::
end
end
::B253::
end
v_o = tobit((v_n - v_t))
end
end
end
end
::L252::
end
do return v_o end
end

F.fMA = function()
local v_A, v_r = 0, 0
v_r = 0
v_A = tobit((F.fCA(I32[8018], I32[8019], 1284865837, 1481765933) + 1))
v_r = Iv
v_r = (((tobit(v_A) % 4294967296) < 1) and tobit((v_r + 1)) or v_r)
I32[8018] = tobit(v_A)
I32[8019] = tobit(v_r)
do return tobit((rshift(v_r, 1) % 4294967296)) end
end

F.fxA = function(v_A, v_r, v_e, v_n)
local v_t = 0
v_t = 0
v_t = (-13)
v_r = F.fBA(v_r, v_n)
if not (bor(((not (v_r ~= 0)) and 1 or 0), ((16 ~= I32[arshift((v_r + 24), 2)]) and 1 or 0)) ~= 0) then
F.fAA(v_A)
v_t = F.flA(v_A, v_r)
if not (v_t ~= 0) then
v_t = F.fIA(v_A, v_e, v_n)
end
end
do return v_t end
end

F.fjA = function(v_A)

I32[arshift((v_A + 8), 2)] = tobit(1732584193)
I32[arshift((v_A + 12), 2)] = tobit((-271733879))
I32[arshift(v_A, 2)] = tobit(0)
I32[arshift((v_A + 4), 2)] = tobit(0)
I32[arshift((v_A + 16), 2)] = tobit((-1732584194))
I32[arshift((v_A + 20), 2)] = tobit(271733878)
end

F.fTA = function(v_A, v_r, v_e)
local v_t = 0
v_t = 0
if (v_e ~= 0) then
do
v_t = v_A
while true do
I8[bor(0, v_t)] = tobit(U8[bor(0, v_r)])
v_t = tobit((v_t + 1))
v_r = tobit((v_r + 1))
v_e = tobit((v_e - 1))
if not (v_e ~= 0) then goto B254 end
do
end
::C254::
end
end
::B254::
end
do return v_A end
end

F.fPA = function(v_A, v_r, v_e)
local v_t = 0
v_t = 0
if (v_e ~= 0) then
do
v_t = v_A
while true do
I8[bor(0, v_t)] = tobit(v_r)
v_t = tobit((v_t + 1))
v_e = tobit((v_e - 1))
if not (v_e ~= 0) then goto B255 end
do
end
::C255::
end
end
::B255::
end
do return v_A end
end

F.fKA = function(v_A, v_r)
local v_e = 0
v_e = 0
do
local t292 = (-1)
v_e = band(31, v_r)
local t295 = lshift(band((rshift(t292, v_e) % 4294967296), v_A), v_e)
v_e = v_A
local t294 = v_e
local t293 = (-1)
v_A = band((0 - v_r), 31)
do return bor(t295, (rshift(band(t294, lshift(t293, v_A)), v_A) % 4294967296)) end
end
end

F.fRA = function(v_A)

do return bor(((32 == bor(0, v_A)) and 1 or 0), (((tobit((v_A - 9)) % 4294967296) < 5) and 1 or 0)) end
end

F.fDA = function(v_A)

do return (((tobit((v_A - 48)) % 4294967296) < 10) and 1 or 0) end
end

F.fLA = function(v_A)

F.fPA(v_A, 0, 280)
end

F.fFA = function(v_A)

F.fPA(v_A, 0, 128)
end

F.fHA = function(v_A)

F.fPA(v_A, 0, 392)
end

F.fNA = function(v_A)

F.fPA(v_A, 0, 88)
end

UA[1] = function(v_A, v_r, v_e, v_n)

v_A = tobit(v_A)
v_e = tobit(v_e)
v_n = tobit(v_n)
v_r = tobit(v_r)
if (1 ~= bor(0, v_r)) then
F.fj(v_A, v_e, v_n)
else
F.fT(v_A, v_e, v_n)
end
do return 0 end
end
UA[2] = function(v_A, v_r, v_e, v_n, v_t, v_o)

do
v_A = tobit(v_A)
local t296 = v_A
v_r = tobit(v_r)
local t297 = v_r
v_e = tobit(v_e)
local t298 = v_e
v_n = tobit(v_n)
local t299 = v_n
v_t = tobit(v_t)
local t300 = v_t
v_o = tobit(v_o)
do return bor(0, F.fR(t296, t297, t298, t299, t300, v_o)) end
end
end
UA[3] = function(v_A, v_r, v_e, v_t, v_o, v_a, v_u)
local v_c, v_s = 0, 0
v_A = tobit(v_A)
v_r = tobit(v_r)
v_e = tobit(v_e)
v_o = tobit(v_o)
v_a = tobit(v_a)
v_u = tobit(v_u)
v_c = 0
v_s = 0
v_t = tobit(v_t)
v_c = I32[arshift(v_t, 2)]
do
if (v_r ~= 0) then
if (not (v_e ~= 0)) then
goto L256
end
do
while true do
v_e = tobit((v_e - 1))
if not (v_c ~= 0) then
F.fT(v_A, v_o, v_o)
end
v_r = tobit((v_o + v_c))
v_s = bxor(U8[bor(0, v_a)], U8[bor(0, v_r)])
I8[bor(0, v_u)] = tobit(v_s)
I8[bor(0, v_r)] = tobit(v_s)
v_u = tobit((v_u + 1))
v_a = tobit((v_a + 1))
v_c = band((v_c + 1), 15)
if not (v_e ~= 0) then goto B257 end
do
end
::C257::
end
end
::B257::
else
if (v_e ~= 0) then
do
while true do
v_e = tobit((v_e - 1))
if not (v_c ~= 0) then
F.fT(v_A, v_o, v_o)
end
v_s = U8[bor(0, v_a)]
v_r = tobit((v_o + v_c))
I8[bor(0, v_u)] = tobit(bxor(v_s, U8[bor(0, v_r)]))
I8[bor(0, v_r)] = tobit(v_s)
v_u = tobit((v_u + 1))
v_a = tobit((v_a + 1))
v_c = band((v_c + 1), 15)
if not (v_e ~= 0) then goto B258 end
do
end
::C258::
end
end
::B258::
end
end
end
::L256::
I32[arshift(v_t, 2)] = tobit(v_c)
do return 0 end
end
UA[4] = function(v_A, v_r, v_e, v_t, v_o, v_a, v_u)
local v_c, v_s, v_l, v_b = 0, 0, 0, 0
v_A = tobit(v_A)
v_r = tobit(v_r)
v_t = tobit(v_t)
v_o = tobit(v_o)
v_a = tobit(v_a)
v_u = tobit(v_u)
v_c = 0
v_s = 0
v_l = 0
v_b = 0
v_e = tobit(v_e)
v_c = I32[arshift(v_e, 2)]
if (v_r ~= 0) then
do
while true do
do
v_r = tobit((v_r - 1))
do
if (not (v_c ~= 0)) then
do
F.fT(v_A, v_t, v_o)
v_s = 16
while true do
do
if (not (v_s ~= 0)) then
goto L260
end
v_s = tobit((v_s - 1))
v_b = tobit((v_s + v_t))
v_l = tobit((U8[bor(0, v_b)] + 1))
I8[bor(0, v_b)] = tobit(v_l)
if (bor(0, v_l) == band(255, v_l)) then
goto B261
end
end
::C261::
end
end
::B261::
end
end
::L260::
I8[bor(0, v_u)] = tobit(bxor(U8[tobit((v_o + v_c))], U8[bor(0, v_a)]))
v_u = tobit((v_u + 1))
v_a = tobit((v_a + 1))
v_c = band((v_c + 1), 15)
if (not (v_r ~= 0)) then
goto B259
end
end
::C259::
end
end
::B259::
end
I32[arshift(v_e, 2)] = tobit(v_c)
do return 0 end
end
UA[5] = function(v_A, v_r, v_e)

do
v_A = tobit(v_A)
local t301 = v_A
v_r = tobit(v_r)
local t302 = v_r
v_e = tobit(v_e)
do return bor(0, F.fM(t301, t302, v_e)) end
end
end
UA[6] = function(v_A, v_r, v_e)

do
v_A = tobit(v_A)
local t303 = v_A
v_r = tobit(v_r)
local t304 = v_r
v_e = tobit(v_e)
do return bor(0, F.fZ(t303, t304, v_e)) end
end
end
UA[7] = function()
local v_A = 0
v_A = F.fOA(1, 280)
if (v_A ~= 0) then
F.fLA(v_A)
end
do return bor(0, v_A) end
end
UA[8] = function(v_A)

v_A = tobit(v_A)
F.fhA(v_A)
F.fL(v_A)
end
UA[9] = function(v_A, v_r, v_e)

do
v_A = tobit(v_A)
local t305 = v_A
v_r = tobit(v_r)
local t306 = v_r
v_e = tobit(v_e)
do return bor(0, F.fN(t305, 2, t306, v_e)) end
end
end
UA[10] = function()
local v_A = 0
v_A = F.fOA(1, 392)
if (v_A ~= 0) then
F.fHA(v_A)
end
do return bor(0, v_A) end
end
UA[11] = function(v_A)

v_A = tobit(v_A)
F.fyA(v_A)
F.fL(v_A)
end
UA[12] = function(v_A, v_r, v_e)

do
v_A = tobit(v_A)
local t307 = v_A
v_r = tobit(v_r)
local t308 = v_r
v_e = tobit(v_e)
do return bor(0, F.fxA(t307, 2, t308, v_e)) end
end
end
UA[13] = function()
local v_A, v_r = 0, 0
v_r = 0
v_A = F.fOA(1, 64)
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
UA[14] = function(v_A)

v_A = tobit(v_A)
F.fAA(v_A)
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
F.fL(v_A)
end
UA[15] = function(v_A, v_r, v_e, v_t)
local v_o, v_a, v_u, v_c, v_s, v_l, v_b, v_v = 0, 0, 0, 0, 0, 0, 0, 0
v_r = tobit(v_r)
v_e = tobit(v_e)
v_t = tobit(v_t)
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
local t309 = v_c
v_a = band((v_a + 1), 255)
v_l = tobit((t309 + v_a))
v_s = U8[bor(0, v_l)]
local t310 = v_c
v_o = band((v_s + v_o), 255)
v_b = tobit((t310 + v_o))
v_v = U8[bor(0, v_b)]
I8[bor(0, v_l)] = tobit(v_v)
I8[bor(0, v_b)] = tobit(v_s)
I8[tobit((v_t + v_u))] = tobit(bxor(U8[tobit((band((v_s + v_v), 255) + v_c))], U8[tobit((v_e + v_u))]))
v_u = tobit((v_u + 1))
if not (bor(0, v_u) ~= bor(0, v_r)) then goto B262 end
end
do
end
::C262::
end
end
::B262::
end
end
end
I32[arshift((v_A + 4), 2)] = tobit(v_o)
I32[arshift(v_A, 2)] = tobit(v_a)
do return 0 end
end
UA[16] = function(v_A, v_r, v_e)
local v_t, v_o, v_a, v_u, v_c, v_s = 0, 0, 0, 0, 0, 0
v_A = tobit(v_A)
v_r = tobit(v_r)
v_t = 0
v_o = 0
v_a = 0
v_u = 0
v_c = 0
v_s = 0
do
v_e = tobit(v_e)
if (band(7, v_e) ~= 0) then
v_A = (-24832)
else
do
do
do
v_s = tobit((rshift(v_e, 3) % 4294967296))
v_e = 0
I32[arshift(v_A, 2)] = tobit(0)
I32[arshift((v_A + 4), 2)] = tobit(0)
while true do
do
v_o = tobit((v_A + 8))
I8[tobit((v_o + v_e))] = tobit(v_e)
v_t = bor(1, v_e)
I8[tobit((v_t + v_o))] = tobit(v_t)
v_t = bor(2, v_e)
I8[tobit((v_t + v_o))] = tobit(v_t)
v_t = bor(3, v_e)
I8[tobit((v_t + v_o))] = tobit(v_t)
v_t = bor(4, v_e)
I8[tobit((v_t + v_o))] = tobit(v_t)
v_t = bor(5, v_e)
I8[tobit((v_t + v_o))] = tobit(v_t)
v_t = bor(6, v_e)
I8[tobit((v_t + v_o))] = tobit(v_t)
v_t = v_o
local t311 = v_t
v_o = bor(7, v_e)
I8[tobit((t311 + v_o))] = tobit(v_o)
v_e = tobit((v_e + 8))
if not (256 ~= bor(0, v_e)) then goto B263 end
end
do
end
::C263::
end
end
::B263::
end
do
do
v_A = tobit((v_A + 8))
v_e = 0
v_o = 0
while true do
do
v_t = (((tobit(v_e) % 4294967296) < (tobit(v_s) % 4294967296)) and v_e or 0)
v_u = tobit((v_A + v_a))
v_c = U8[bor(0, v_u)]
local t312 = v_A
v_o = band((U8[tobit((v_t + v_r))] + tobit((v_c + v_o))), 255)
v_e = tobit((t312 + v_o))
I8[bor(0, v_u)] = tobit(U8[bor(0, v_e)])
I8[bor(0, v_e)] = tobit(v_c)
v_e = tobit((v_t + 1))
v_a = tobit((v_a + 1))
if not (256 ~= bor(0, v_a)) then goto B264 end
end
do
end
::C264::
end
end
::B264::
end
v_A = 0
end
end
end
do return bor(0, v_A) end
end
UA[17] = function()
local v_A = 0
v_A = F.fOA(1, 264)
if (v_A ~= 0) then
F.fPA(v_A, 0, 264)
end
do return bor(0, v_A) end
end
UA[18] = function(v_A)
local v_r, v_e = 0, 0
v_r = 0
v_e = 0
do
v_A = tobit(v_A)
v_r = v_A
if (v_r ~= 0) then
do
v_e = 252
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
if (not (v_e ~= 0)) then
goto L265
end
v_r = tobit((v_r + 12))
v_e = tobit((v_e - 12))
end
::C266::
end
end
::B266::
end
end
::L265::
F.fL(v_A)
end
UA[19] = function(v_A, v_r, v_e, v_n)

do
v_A = tobit(v_A)
local t313 = v_A
v_r = tobit(v_r)
local t314 = v_r
v_e = tobit(v_e)
local t315 = v_e
v_n = tobit(v_n)
do return bor(0, F.feA(t313, t314, t315, v_n)) end
end
end
UA[20] = function(v_A, v_r, v_e, v_t, v_o, v_i)
local v_a, v_u, v_c = 0, 0, 0
v_A = tobit(v_A)
v_r = tobit(v_r)
v_t = tobit(v_t)
v_o = tobit(v_o)
v_i = tobit(v_i)
v_a = 0
v_u = 0
v_c = 0
v_c = (-24)
do
v_e = tobit(v_e)
if (not (band(7, v_e) ~= 0)) then
if (v_r ~= 0) then
v_c = 0
if (not (v_e ~= 0)) then
goto L267
end
do
v_a = U8[bor(0, v_t)]
while true do
I8[bor(0, v_i)] = tobit(bxor(U8[bor(0, v_o)], v_a))
I8[tobit((v_i + 1))] = tobit(bxor(U8[tobit((v_t + 1))], U8[tobit((v_o + 1))]))
I8[tobit((v_i + 2))] = tobit(bxor(U8[tobit((v_t + 2))], U8[tobit((v_o + 2))]))
I8[tobit((v_i + 3))] = tobit(bxor(U8[tobit((v_t + 3))], U8[tobit((v_o + 3))]))
I8[tobit((v_i + 4))] = tobit(bxor(U8[tobit((v_t + 4))], U8[tobit((v_o + 4))]))
I8[tobit((v_i + 5))] = tobit(bxor(U8[tobit((v_t + 5))], U8[tobit((v_o + 5))]))
I8[tobit((v_i + 6))] = tobit(bxor(U8[tobit((v_t + 6))], U8[tobit((v_o + 6))]))
I8[tobit((v_i + 7))] = tobit(bxor(U8[tobit((v_t + 7))], U8[tobit((v_o + 7))]))
F.feA(v_A, v_r, v_i, v_i)
v_u = bor(bor(bor(U8[tobit((v_i + 4))], lshift(U8[tobit((v_i + 5))], 8)), lshift(U8[tobit((v_i + 6))], 16)), lshift(U8[tobit((v_i + 7))], 24))
v_a = bor(bor(bor(U8[bor(0, v_i)], lshift(U8[tobit((v_i + 1))], 8)), lshift(U8[tobit((v_i + 2))], 16)), lshift(U8[tobit((v_i + 3))], 24))
I8[bor(0, v_t)] = tobit(v_a)
I8[tobit((v_t + 1))] = tobit((rshift(v_a, 8) % 4294967296))
I8[tobit((v_t + 2))] = tobit((rshift(v_a, 16) % 4294967296))
I8[tobit((v_t + 3))] = tobit((rshift(v_a, 24) % 4294967296))
I8[tobit((v_t + 4))] = tobit(v_u)
I8[tobit((v_t + 5))] = tobit((rshift(v_u, 8) % 4294967296))
I8[tobit((v_t + 6))] = tobit((rshift(v_u, 16) % 4294967296))
I8[tobit((v_t + 7))] = tobit((rshift(v_u, 24) % 4294967296))
v_i = tobit((v_i + 8))
v_o = tobit((v_o + 8))
v_e = tobit((v_e - 8))
if not (v_e ~= 0) then goto B268 end
do
end
::C268::
end
end
::B268::
else
v_c = 0
if (v_e ~= 0) then
do
while true do
v_a = bor(bor(bor(U8[tobit((v_o + 4))], lshift(U8[tobit((v_o + 5))], 8)), lshift(U8[tobit((v_o + 6))], 16)), lshift(U8[tobit((v_o + 7))], 24))
v_r = bor(bor(bor(U8[bor(0, v_o)], lshift(U8[tobit((v_o + 1))], 8)), lshift(U8[tobit((v_o + 2))], 16)), lshift(U8[tobit((v_o + 3))], 24))
F.feA(v_A, 0, v_o, v_i)
I8[bor(0, v_i)] = tobit(bxor(U8[bor(0, v_t)], U8[bor(0, v_i)]))
I8[tobit((v_i + 1))] = tobit(bxor(U8[tobit((v_t + 1))], U8[tobit((v_i + 1))]))
I8[tobit((v_i + 2))] = tobit(bxor(U8[tobit((v_t + 2))], U8[tobit((v_i + 2))]))
I8[tobit((v_i + 3))] = tobit(bxor(U8[tobit((v_t + 3))], U8[tobit((v_i + 3))]))
I8[tobit((v_i + 4))] = tobit(bxor(U8[tobit((v_t + 4))], U8[tobit((v_i + 4))]))
I8[tobit((v_i + 5))] = tobit(bxor(U8[tobit((v_t + 5))], U8[tobit((v_i + 5))]))
I8[tobit((v_i + 6))] = tobit(bxor(U8[tobit((v_t + 6))], U8[tobit((v_i + 6))]))
I8[tobit((v_i + 7))] = tobit(bxor(U8[tobit((v_t + 7))], U8[tobit((v_i + 7))]))
I8[bor(0, v_t)] = tobit(v_r)
I8[tobit((v_t + 1))] = tobit((rshift(v_r, 8) % 4294967296))
I8[tobit((v_t + 2))] = tobit((rshift(v_r, 16) % 4294967296))
I8[tobit((v_t + 3))] = tobit((rshift(v_r, 24) % 4294967296))
I8[tobit((v_t + 4))] = tobit(v_a)
I8[tobit((v_t + 5))] = tobit((rshift(v_a, 8) % 4294967296))
I8[tobit((v_t + 6))] = tobit((rshift(v_a, 16) % 4294967296))
I8[tobit((v_t + 7))] = tobit((rshift(v_a, 24) % 4294967296))
v_i = tobit((v_i + 8))
v_o = tobit((v_o + 8))
v_e = tobit((v_e - 8))
if not (v_e ~= 0) then goto B269 end
do
end
::C269::
end
end
::B269::
end
end
end
end
::L267::
do return bor(0, v_c) end
end
UA[21] = function(v_A, v_r, v_e, v_t, v_o, v_a, v_u)
local v_c, v_s = 0, 0
v_A = tobit(v_A)
v_r = tobit(v_r)
v_e = tobit(v_e)
v_o = tobit(v_o)
v_a = tobit(v_a)
v_u = tobit(v_u)
v_c = 0
v_s = 0
v_t = tobit(v_t)
v_c = I32[arshift(v_t, 2)]
do
if (v_r ~= 0) then
if (not (v_e ~= 0)) then
goto L270
end
do
while true do
v_e = tobit((v_e - 1))
if not (v_c ~= 0) then
F.feA(v_A, 1, v_o, v_o)
end
v_r = tobit((v_o + v_c))
v_s = bxor(U8[bor(0, v_a)], U8[bor(0, v_r)])
I8[bor(0, v_u)] = tobit(v_s)
I8[bor(0, v_r)] = tobit(v_s)
v_u = tobit((v_u + 1))
v_a = tobit((v_a + 1))
v_c = band((v_c + 1), 7)
if not (v_e ~= 0) then goto B271 end
do
end
::C271::
end
end
::B271::
else
if (v_e ~= 0) then
do
while true do
v_e = tobit((v_e - 1))
if not (v_c ~= 0) then
F.feA(v_A, 1, v_o, v_o)
end
v_s = U8[bor(0, v_a)]
v_r = tobit((v_o + v_c))
I8[bor(0, v_u)] = tobit(bxor(v_s, U8[bor(0, v_r)]))
I8[bor(0, v_r)] = tobit(v_s)
v_u = tobit((v_u + 1))
v_a = tobit((v_a + 1))
v_c = band((v_c + 1), 7)
if not (v_e ~= 0) then goto B272 end
do
end
::C272::
end
end
::B272::
end
end
end
::L270::
I32[arshift(v_t, 2)] = tobit(v_c)
do return 0 end
end
UA[22] = function(v_A, v_r, v_e, v_t, v_o, v_a, v_u)
local v_c, v_s, v_l, v_b = 0, 0, 0, 0
v_A = tobit(v_A)
v_r = tobit(v_r)
v_t = tobit(v_t)
v_o = tobit(v_o)
v_a = tobit(v_a)
v_u = tobit(v_u)
v_c = 0
v_s = 0
v_l = 0
v_b = 0
v_e = tobit(v_e)
v_c = I32[arshift(v_e, 2)]
if (v_r ~= 0) then
do
while true do
do
v_r = tobit((v_r - 1))
do
if (not (v_c ~= 0)) then
do
F.feA(v_A, 1, v_t, v_o)
v_s = 8
while true do
do
if (not (v_s ~= 0)) then
goto L274
end
v_s = tobit((v_s - 1))
v_b = tobit((v_s + v_t))
v_l = tobit((U8[bor(0, v_b)] + 1))
I8[bor(0, v_b)] = tobit(v_l)
if (bor(0, v_l) == band(255, v_l)) then
goto B275
end
end
::C275::
end
end
::B275::
end
end
::L274::
I8[bor(0, v_u)] = tobit(bxor(U8[tobit((v_o + v_c))], U8[bor(0, v_a)]))
v_u = tobit((v_u + 1))
v_a = tobit((v_a + 1))
v_c = band((v_c + 1), 7)
if (not (v_r ~= 0)) then
goto B273
end
end
::C273::
end
end
::B273::
end
I32[arshift(v_e, 2)] = tobit(v_c)
do return 0 end
end
UA[23] = function(v_A, v_r, v_e)
local v_n, v_t, v_o, v_a, v_u, v_c, v_s = 0, 0, 0, 0, 0, 0, 0
v_t = 0
v_o = 0
v_a = 0
v_u = 0
v_c = 0
v_s = 0
do
v_A = tobit(v_A)
v_n = v_A
v_r = tobit(v_r)
v_A = v_r
v_e = tobit(v_e)
if (bor(band(7, v_e), (((tobit((v_e - 32)) % 4294967296) > 416) and 1 or 0)) ~= 0) then
v_A = (-22)
else
do
do
do
F.fTA(tobit((v_n + 72)), 3200, 4096)
v_e = tobit((rshift(v_e, 3) % 4294967296))
v_r = 0
while true do
do
local t318 = (tobit(v_e) % 4294967296)
local t317 = (tobit(v_e) % 4294967296)
local t316 = (tobit(v_e) % 4294967296)
v_t = tobit((v_r + 1))
v_a = ((t316 > (tobit(v_t) % 4294967296)) and v_t or 0)
v_t = tobit((v_a + 1))
v_u = ((t317 > (tobit(v_t) % 4294967296)) and v_t or 0)
v_t = tobit((v_u + 1))
v_t = ((t318 > (tobit(v_t) % 4294967296)) and v_t or 0)
v_s = lshift(v_o, 2)
I32[arshift((v_s + v_n), 2)] = tobit(bxor(I32[arshift((v_s + 7296), 2)], bor(U8[tobit((v_A + v_t))], lshift(bor(bor(U8[tobit((v_A + v_u))], lshift(U8[tobit((v_A + v_r))], 16)), lshift(U8[tobit((v_A + v_a))], 8)), 8))))
v_r = tobit((v_t + 1))
v_r = (((tobit(v_r) % 4294967296) < (tobit(v_e) % 4294967296)) and v_r or 0)
v_o = tobit((v_o + 1))
if not (18 ~= bor(0, v_o)) then goto B276 end
end
do
end
::C276::
end
end
::B276::
end
do
v_e = 0
v_a = tobit((v_n + 72))
v_t = 0
v_A = 0
while true do
do
do
v_o = 0
while true do
v_r = v_t
v_t = bxor(I32[arshift((lshift(v_o, 2) + v_n), 2)], v_A)
v_A = bxor(v_r, (bxor((I32[arshift((1024 + tobit((v_a + band((rshift(v_t, 14) % 4294967296), 1020)))), 2)] + I32[arshift((v_a + band((rshift(v_t, 22) % 4294967296), 1020)), 2)]), I32[arshift((2048 + tobit((v_a + band((rshift(v_t, 6) % 4294967296), 1020)))), 2)]) + I32[arshift((3072 + tobit((v_a + lshift(band(255, v_t), 2)))), 2)]))
v_o = tobit((v_o + 1))
if not (16 ~= bor(0, v_o)) then goto B278 end
do
end
::C278::
end
end
::B278::
v_o = I32[arshift((v_n + 64), 2)]
v_u = lshift(v_e, 2)
v_r = bxor(I32[arshift((v_n + 68), 2)], v_t)
I32[arshift((v_u + v_n), 2)] = tobit(v_r)
v_t = bxor(v_A, v_o)
I32[arshift((bor(4, v_u) + v_n), 2)] = tobit(v_t)
v_o = (((tobit(v_e) % 4294967296) < 16) and 1 or 0)
v_e = tobit((v_e + 2))
v_A = v_r
if (not (v_o ~= 0)) then
goto B277
end
end
::C277::
end
end
::B277::
do
v_u = I32[arshift((v_n + 68), 2)]
v_s = I32[arshift((v_n + 64), 2)]
v_e = 0
v_a = tobit((v_n + 72))
while true do
do
do
v_o = 0
while true do
v_A = v_t
v_t = bxor(I32[arshift((lshift(v_o, 2) + v_n), 2)], v_r)
v_r = bxor(v_A, (bxor((I32[arshift((1024 + tobit((v_a + band((rshift(v_t, 14) % 4294967296), 1020)))), 2)] + I32[arshift((v_a + band((rshift(v_t, 22) % 4294967296), 1020)), 2)]), I32[arshift((2048 + tobit((v_a + band((rshift(v_t, 6) % 4294967296), 1020)))), 2)]) + I32[arshift((3072 + tobit((v_a + lshift(band(255, v_t), 2)))), 2)]))
v_o = tobit((v_o + 1))
if not (16 ~= bor(0, v_o)) then goto B280 end
do
end
::C280::
end
end
::B280::
v_A = bxor(v_t, v_u)
v_o = lshift(v_e, 2)
I32[arshift((v_o + v_a), 2)] = tobit(v_A)
v_t = bxor(v_r, v_s)
I32[arshift((v_a + bor(4, v_o)), 2)] = tobit(v_t)
v_o = (((tobit(v_e) % 4294967296) < 254) and 1 or 0)
v_e = tobit((v_e + 2))
v_r = v_A
if (not (v_o ~= 0)) then
goto B279
end
end
::C279::
end
end
::B279::
do
v_e = 0
v_a = tobit((v_n + 72))
v_c = tobit((v_n + 1096))
while true do
do
do
v_o = 0
while true do
v_r = v_t
v_t = bxor(I32[arshift((lshift(v_o, 2) + v_n), 2)], v_A)
v_A = bxor(v_r, (bxor((I32[arshift((1024 + tobit((v_a + band((rshift(v_t, 14) % 4294967296), 1020)))), 2)] + I32[arshift((v_a + band((rshift(v_t, 22) % 4294967296), 1020)), 2)]), I32[arshift((2048 + tobit((v_a + band((rshift(v_t, 6) % 4294967296), 1020)))), 2)]) + I32[arshift((3072 + tobit((v_a + lshift(band(255, v_t), 2)))), 2)]))
v_o = tobit((v_o + 1))
if not (16 ~= bor(0, v_o)) then goto B282 end
do
end
::C282::
end
end
::B282::
v_r = bxor(v_t, v_u)
v_o = lshift(v_e, 2)
I32[arshift((v_o + v_c), 2)] = tobit(v_r)
v_t = bxor(v_A, v_s)
I32[arshift((v_c + bor(4, v_o)), 2)] = tobit(v_t)
v_o = (((tobit(v_e) % 4294967296) < 254) and 1 or 0)
v_e = tobit((v_e + 2))
v_A = v_r
if (not (v_o ~= 0)) then
goto B281
end
end
::C281::
end
end
::B281::
do
v_e = 0
v_a = tobit((v_n + 72))
v_c = tobit((v_n + 2120))
while true do
do
do
v_o = 0
while true do
v_A = v_t
v_t = bxor(I32[arshift((lshift(v_o, 2) + v_n), 2)], v_r)
v_r = bxor(v_A, (bxor((I32[arshift((1024 + tobit((v_a + band((rshift(v_t, 14) % 4294967296), 1020)))), 2)] + I32[arshift((v_a + band((rshift(v_t, 22) % 4294967296), 1020)), 2)]), I32[arshift((2048 + tobit((v_a + band((rshift(v_t, 6) % 4294967296), 1020)))), 2)]) + I32[arshift((3072 + tobit((v_a + lshift(band(255, v_t), 2)))), 2)]))
v_o = tobit((v_o + 1))
if not (16 ~= bor(0, v_o)) then goto B284 end
do
end
::C284::
end
end
::B284::
v_A = bxor(v_t, v_u)
v_o = lshift(v_e, 2)
I32[arshift((v_o + v_c), 2)] = tobit(v_A)
v_t = bxor(v_r, v_s)
I32[arshift((v_c + bor(4, v_o)), 2)] = tobit(v_t)
v_o = (((tobit(v_e) % 4294967296) < 254) and 1 or 0)
v_e = tobit((v_e + 2))
v_r = v_A
if (not (v_o ~= 0)) then
goto B283
end
end
::C283::
end
end
::B283::
do
v_r = 0
v_a = tobit((v_n + 72))
v_c = tobit((v_n + 3144))
while true do
do
do
v_o = 0
while true do
v_e = v_t
v_t = bxor(I32[arshift((lshift(v_o, 2) + v_n), 2)], v_A)
v_A = bxor(v_e, (bxor((I32[arshift((1024 + tobit((v_a + band((rshift(v_t, 14) % 4294967296), 1020)))), 2)] + I32[arshift((v_a + band((rshift(v_t, 22) % 4294967296), 1020)), 2)]), I32[arshift((2048 + tobit((v_a + band((rshift(v_t, 6) % 4294967296), 1020)))), 2)]) + I32[arshift((3072 + tobit((v_a + lshift(band(255, v_t), 2)))), 2)]))
v_o = tobit((v_o + 1))
if not (16 ~= bor(0, v_o)) then goto B286 end
do
end
::C286::
end
end
::B286::
v_e = bxor(v_t, v_u)
v_o = lshift(v_r, 2)
I32[arshift((v_o + v_c), 2)] = tobit(v_e)
v_t = bxor(v_A, v_s)
I32[arshift((v_c + bor(4, v_o)), 2)] = tobit(v_t)
v_o = (((tobit(v_r) % 4294967296) < 254) and 1 or 0)
v_r = tobit((v_r + 2))
v_A = v_e
if (not (v_o ~= 0)) then
goto B285
end
end
::C285::
end
end
::B285::
v_A = 0
end
end
end
do return bor(0, v_A) end
end
UA[24] = function()
local v_A = 0
v_A = F.fOA(1, 4168)
if (v_A ~= 0) then
F.fPA(v_A, 0, 4168)
end
do return bor(0, v_A) end
end
UA[25] = function(v_A)
local v_r, v_e = 0, 0
v_r = 0
v_e = 0
do
v_A = tobit(v_A)
v_r = v_A
if (v_r ~= 0) then
do
v_e = 4160
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
if (not (v_e ~= 0)) then
goto L287
end
v_r = tobit((v_r + 8))
v_e = tobit((v_e - 8))
end
::C288::
end
end
::B288::
end
end
::L287::
F.fL(v_A)
end
UA[26] = function(v_A, v_r, v_e, v_n)

do
v_A = tobit(v_A)
local t319 = v_A
v_e = tobit(v_e)
local t320 = v_e
v_n = tobit(v_n)
do return bor(0, F.fF(t319, t320, v_n)) end
end
end
UA[27] = function(v_A, v_r, v_e, v_t, v_o, v_a)
local v_u, v_c, v_s = 0, 0, 0
v_A = tobit(v_A)
v_r = tobit(v_r)
v_t = tobit(v_t)
v_o = tobit(v_o)
v_a = tobit(v_a)
v_c = 0
v_s = 0
v_u = tobit((B - 16))
B = v_u
v_s = (-38)
do
v_e = tobit(v_e)
if (not (band(15, v_e) ~= 0)) then
if (v_r ~= 0) then
v_s = 0
if (not (v_e ~= 0)) then
goto L289
end
do
while true do
I8[bor(0, v_a)] = tobit(bxor(U8[bor(0, v_t)], U8[bor(0, v_o)]))
I8[tobit((v_a + 1))] = tobit(bxor(U8[tobit((v_t + 1))], U8[tobit((v_o + 1))]))
I8[tobit((v_a + 2))] = tobit(bxor(U8[tobit((v_t + 2))], U8[tobit((v_o + 2))]))
I8[tobit((v_a + 3))] = tobit(bxor(U8[tobit((v_t + 3))], U8[tobit((v_o + 3))]))
I8[tobit((v_a + 4))] = tobit(bxor(U8[tobit((v_t + 4))], U8[tobit((v_o + 4))]))
I8[tobit((v_a + 5))] = tobit(bxor(U8[tobit((v_t + 5))], U8[tobit((v_o + 5))]))
I8[tobit((v_a + 6))] = tobit(bxor(U8[tobit((v_t + 6))], U8[tobit((v_o + 6))]))
I8[tobit((v_a + 7))] = tobit(bxor(U8[tobit((v_t + 7))], U8[tobit((v_o + 7))]))
I8[tobit((v_a + 8))] = tobit(bxor(U8[tobit((v_t + 8))], U8[tobit((v_o + 8))]))
I8[tobit((v_a + 9))] = tobit(bxor(U8[tobit((v_t + 9))], U8[tobit((v_o + 9))]))
I8[tobit((v_a + 10))] = tobit(bxor(U8[tobit((v_t + 10))], U8[tobit((v_o + 10))]))
I8[tobit((v_a + 11))] = tobit(bxor(U8[tobit((v_t + 11))], U8[tobit((v_o + 11))]))
I8[tobit((v_a + 12))] = tobit(bxor(U8[tobit((v_t + 12))], U8[tobit((v_o + 12))]))
I8[tobit((v_a + 13))] = tobit(bxor(U8[tobit((v_t + 13))], U8[tobit((v_o + 13))]))
I8[tobit((v_a + 14))] = tobit(bxor(U8[tobit((v_t + 14))], U8[tobit((v_o + 14))]))
I8[tobit((v_a + 15))] = tobit(bxor(U8[tobit((v_t + 15))], U8[tobit((v_o + 15))]))
F.fF(v_A, v_a, v_a)
v_r = bor(bor(bor(U8[tobit((v_a + 12))], lshift(U8[tobit((v_a + 13))], 8)), lshift(U8[tobit((v_a + 14))], 16)), lshift(U8[tobit((v_a + 15))], 24))
v_c = bor(bor(bor(U8[tobit((v_a + 8))], lshift(U8[tobit((v_a + 9))], 8)), lshift(U8[tobit((v_a + 10))], 16)), lshift(U8[tobit((v_a + 11))], 24))
I8[tobit((v_t + 8))] = tobit(v_c)
I8[tobit((v_t + 9))] = tobit((rshift(v_c, 8) % 4294967296))
I8[tobit((v_t + 10))] = tobit((rshift(v_c, 16) % 4294967296))
I8[tobit((v_t + 11))] = tobit((rshift(v_c, 24) % 4294967296))
I8[tobit((v_t + 12))] = tobit(v_r)
I8[tobit((v_t + 13))] = tobit((rshift(v_r, 8) % 4294967296))
I8[tobit((v_t + 14))] = tobit((rshift(v_r, 16) % 4294967296))
I8[tobit((v_t + 15))] = tobit((rshift(v_r, 24) % 4294967296))
v_r = bor(bor(bor(U8[tobit((v_a + 4))], lshift(U8[tobit((v_a + 5))], 8)), lshift(U8[tobit((v_a + 6))], 16)), lshift(U8[tobit((v_a + 7))], 24))
v_c = bor(bor(bor(U8[bor(0, v_a)], lshift(U8[tobit((v_a + 1))], 8)), lshift(U8[tobit((v_a + 2))], 16)), lshift(U8[tobit((v_a + 3))], 24))
I8[bor(0, v_t)] = tobit(v_c)
I8[tobit((v_t + 1))] = tobit((rshift(v_c, 8) % 4294967296))
I8[tobit((v_t + 2))] = tobit((rshift(v_c, 16) % 4294967296))
I8[tobit((v_t + 3))] = tobit((rshift(v_c, 24) % 4294967296))
I8[tobit((v_t + 4))] = tobit(v_r)
I8[tobit((v_t + 5))] = tobit((rshift(v_r, 8) % 4294967296))
I8[tobit((v_t + 6))] = tobit((rshift(v_r, 16) % 4294967296))
I8[tobit((v_t + 7))] = tobit((rshift(v_r, 24) % 4294967296))
v_a = tobit((v_a + 16))
v_o = tobit((v_o + 16))
v_e = tobit((v_e - 16))
if not (v_e ~= 0) then goto B290 end
do
end
::C290::
end
end
::B290::
else
v_s = 0
if (v_e ~= 0) then
do
while true do
v_r = bor(bor(bor(U8[tobit((v_o + 4))], lshift(U8[tobit((v_o + 5))], 8)), lshift(U8[tobit((v_o + 6))], 16)), lshift(U8[tobit((v_o + 7))], 24))
I32[arshift(v_u, 2)] = tobit(bor(bor(bor(U8[bor(0, v_o)], lshift(U8[tobit((v_o + 1))], 8)), lshift(U8[tobit((v_o + 2))], 16)), lshift(U8[tobit((v_o + 3))], 24)))
I32[arshift((v_u + 4), 2)] = tobit(v_r)
v_r = bor(bor(bor(U8[tobit((v_o + 12))], lshift(U8[tobit((v_o + 13))], 8)), lshift(U8[tobit((v_o + 14))], 16)), lshift(U8[tobit((v_o + 15))], 24))
I32[arshift((v_u + 8), 2)] = tobit(bor(bor(bor(U8[tobit((v_o + 8))], lshift(U8[tobit((v_o + 9))], 8)), lshift(U8[tobit((v_o + 10))], 16)), lshift(U8[tobit((v_o + 11))], 24)))
I32[arshift((v_u + 12), 2)] = tobit(v_r)
F.fF(v_A, v_o, v_a)
I8[bor(0, v_a)] = tobit(bxor(U8[bor(0, v_t)], U8[bor(0, v_a)]))
I8[tobit((v_a + 1))] = tobit(bxor(U8[tobit((v_t + 1))], U8[tobit((v_a + 1))]))
I8[tobit((v_a + 2))] = tobit(bxor(U8[tobit((v_t + 2))], U8[tobit((v_a + 2))]))
I8[tobit((v_a + 3))] = tobit(bxor(U8[tobit((v_t + 3))], U8[tobit((v_a + 3))]))
I8[tobit((v_a + 4))] = tobit(bxor(U8[tobit((v_t + 4))], U8[tobit((v_a + 4))]))
I8[tobit((v_a + 5))] = tobit(bxor(U8[tobit((v_t + 5))], U8[tobit((v_a + 5))]))
I8[tobit((v_a + 6))] = tobit(bxor(U8[tobit((v_t + 6))], U8[tobit((v_a + 6))]))
I8[tobit((v_a + 7))] = tobit(bxor(U8[tobit((v_t + 7))], U8[tobit((v_a + 7))]))
I8[tobit((v_a + 8))] = tobit(bxor(U8[tobit((v_t + 8))], U8[tobit((v_a + 8))]))
I8[tobit((v_a + 9))] = tobit(bxor(U8[tobit((v_t + 9))], U8[tobit((v_a + 9))]))
I8[tobit((v_a + 10))] = tobit(bxor(U8[tobit((v_t + 10))], U8[tobit((v_a + 10))]))
I8[tobit((v_a + 11))] = tobit(bxor(U8[tobit((v_t + 11))], U8[tobit((v_a + 11))]))
I8[tobit((v_a + 12))] = tobit(bxor(U8[tobit((v_t + 12))], U8[tobit((v_a + 12))]))
I8[tobit((v_a + 13))] = tobit(bxor(U8[tobit((v_t + 13))], U8[tobit((v_a + 13))]))
I8[tobit((v_a + 14))] = tobit(bxor(U8[tobit((v_t + 14))], U8[tobit((v_a + 14))]))
I8[tobit((v_a + 15))] = tobit(bxor(U8[tobit((v_t + 15))], U8[tobit((v_a + 15))]))
v_r = I32[arshift((v_u + 12), 2)]
v_c = I32[arshift((v_u + 8), 2)]
I8[tobit((v_t + 8))] = tobit(v_c)
I8[tobit((v_t + 9))] = tobit((rshift(v_c, 8) % 4294967296))
I8[tobit((v_t + 10))] = tobit((rshift(v_c, 16) % 4294967296))
I8[tobit((v_t + 11))] = tobit((rshift(v_c, 24) % 4294967296))
I8[tobit((v_t + 12))] = tobit(v_r)
I8[tobit((v_t + 13))] = tobit((rshift(v_r, 8) % 4294967296))
I8[tobit((v_t + 14))] = tobit((rshift(v_r, 16) % 4294967296))
I8[tobit((v_t + 15))] = tobit((rshift(v_r, 24) % 4294967296))
v_r = I32[arshift((v_u + 4), 2)]
v_c = I32[arshift(v_u, 2)]
I8[bor(0, v_t)] = tobit(v_c)
I8[tobit((v_t + 1))] = tobit((rshift(v_c, 8) % 4294967296))
I8[tobit((v_t + 2))] = tobit((rshift(v_c, 16) % 4294967296))
I8[tobit((v_t + 3))] = tobit((rshift(v_c, 24) % 4294967296))
I8[tobit((v_t + 4))] = tobit(v_r)
I8[tobit((v_t + 5))] = tobit((rshift(v_r, 8) % 4294967296))
I8[tobit((v_t + 6))] = tobit((rshift(v_r, 16) % 4294967296))
I8[tobit((v_t + 7))] = tobit((rshift(v_r, 24) % 4294967296))
v_a = tobit((v_a + 16))
v_o = tobit((v_o + 16))
v_e = tobit((v_e - 16))
if not (v_e ~= 0) then goto B291 end
do
end
::C291::
end
end
::B291::
end
end
end
end
::L289::
B = tobit((v_u + 16))
do return bor(0, v_s) end
end
UA[28] = function(v_A, v_r, v_e, v_t, v_o, v_a, v_u)
local v_c, v_s = 0, 0
v_A = tobit(v_A)
v_r = tobit(v_r)
v_e = tobit(v_e)
v_o = tobit(v_o)
v_a = tobit(v_a)
v_u = tobit(v_u)
v_c = 0
v_s = 0
v_t = tobit(v_t)
v_c = I32[arshift(v_t, 2)]
do
if (v_r ~= 0) then
if (not (v_e ~= 0)) then
goto L292
end
do
while true do
v_e = tobit((v_e - 1))
if not (v_c ~= 0) then
F.fF(v_A, v_o, v_o)
end
v_r = tobit((v_o + v_c))
v_s = bxor(U8[bor(0, v_a)], U8[bor(0, v_r)])
I8[bor(0, v_u)] = tobit(v_s)
I8[bor(0, v_r)] = tobit(v_s)
v_u = tobit((v_u + 1))
v_a = tobit((v_a + 1))
v_c = band((v_c + 1), 15)
if not (v_e ~= 0) then goto B293 end
do
end
::C293::
end
end
::B293::
else
if (v_e ~= 0) then
do
while true do
v_e = tobit((v_e - 1))
if not (v_c ~= 0) then
F.fF(v_A, v_o, v_o)
end
v_s = U8[bor(0, v_a)]
v_r = tobit((v_o + v_c))
I8[bor(0, v_u)] = tobit(bxor(v_s, U8[bor(0, v_r)]))
I8[bor(0, v_r)] = tobit(v_s)
v_u = tobit((v_u + 1))
v_a = tobit((v_a + 1))
v_c = band((v_c + 1), 15)
if not (v_e ~= 0) then goto B294 end
do
end
::C294::
end
end
::B294::
end
end
end
::L292::
I32[arshift(v_t, 2)] = tobit(v_c)
do return 0 end
end
UA[29] = function(v_A, v_r, v_e, v_t, v_o, v_a, v_u)
local v_c, v_s, v_l, v_b = 0, 0, 0, 0
v_A = tobit(v_A)
v_r = tobit(v_r)
v_t = tobit(v_t)
v_o = tobit(v_o)
v_a = tobit(v_a)
v_u = tobit(v_u)
v_c = 0
v_s = 0
v_l = 0
v_b = 0
v_e = tobit(v_e)
v_c = I32[arshift(v_e, 2)]
if (v_r ~= 0) then
do
while true do
do
v_r = tobit((v_r - 1))
do
if (not (v_c ~= 0)) then
do
F.fF(v_A, v_t, v_o)
v_s = 16
while true do
do
if (not (v_s ~= 0)) then
goto L296
end
v_s = tobit((v_s - 1))
v_b = tobit((v_s + v_t))
v_l = tobit((U8[bor(0, v_b)] + 1))
I8[bor(0, v_b)] = tobit(v_l)
if (bor(0, v_l) == band(255, v_l)) then
goto B297
end
end
::C297::
end
end
::B297::
end
end
::L296::
I8[bor(0, v_u)] = tobit(bxor(U8[tobit((v_o + v_c))], U8[bor(0, v_a)]))
v_u = tobit((v_u + 1))
v_a = tobit((v_a + 1))
v_c = band((v_c + 1), 15)
if (not (v_r ~= 0)) then
goto B295
end
end
::C295::
end
end
::B295::
end
I32[arshift(v_e, 2)] = tobit(v_c)
do return 0 end
end
UA[30] = function(v_A, v_r, v_e)

do
v_A = tobit(v_A)
local t321 = v_A
v_r = tobit(v_r)
local t322 = v_r
v_e = tobit(v_e)
do return bor(0, F.fQ(t321, t322, v_e)) end
end
end
UA[31] = function(v_A, v_r, v_e)
local v_t, v_o, v_f, v_a = 0, 0, 0, 0
v_A = tobit(v_A)
v_r = tobit(v_r)
v_e = tobit(v_e)
v_f = 0
v_a = 0
do
v_t = tobit((B - 288))
B = v_t
F.fPA(tobit((v_t + 8)), 0, 276)
v_o = F.fQ(tobit((v_t + 8)), v_r, v_e)
if (not (v_o ~= 0)) then
do
do
do
v_r = I32[arshift((v_t + 8), 2)]
I32[arshift(v_A, 2)] = tobit(v_r)
local t323 = tobit((v_t + 8))
v_f = ((4 == bor(0, v_r)) and 1 or 0)
v_e = tobit((t323 + lshift(v_f, 6)))
I32[arshift((v_A + 4), 2)] = tobit(I32[arshift((v_e + 196), 2)])
I32[arshift((v_A + 8), 2)] = tobit(I32[arshift((v_e + 200), 2)])
I32[arshift((v_A + 12), 2)] = tobit(I32[arshift((v_e + 204), 2)])
I32[arshift((v_A + 16), 2)] = tobit(I32[arshift((v_e + 208), 2)])
v_r = tobit((v_A + 20))
v_f = bor(lshift(v_f, 3), 22)
v_e = tobit((v_e + 188))
v_A = 1
end
while true do
do
I32[arshift(v_r, 2)] = tobit(I32[arshift(v_e, 2)])
I32[arshift((v_r + 4), 2)] = tobit(I32[arshift((v_e + 4), 2)])
v_e = tobit((v_e - 8))
v_f = tobit((v_f - 1))
v_r = tobit((v_r + 8))
if (not (v_A ~= 0)) then
do
while true do
v_A = v_r
I32[arshift(v_A, 2)] = tobit(I32[arshift(v_e, 2)])
I32[arshift((v_A + 4), 2)] = tobit(I32[arshift((v_e + 4), 2)])
I32[arshift((v_A + 8), 2)] = tobit(I32[arshift((v_e - 8), 2)])
I32[arshift((v_A + 12), 2)] = tobit(I32[arshift((v_e - 4), 2)])
I32[arshift((v_A + 16), 2)] = tobit(I32[arshift((v_e - 16), 2)])
I32[arshift((v_A + 20), 2)] = tobit(I32[arshift((v_e - 12), 2)])
v_a = tobit((v_e - 24))
I32[arshift((v_A + 24), 2)] = tobit(I32[arshift(v_a, 2)])
I32[arshift((v_A + 28), 2)] = tobit(I32[arshift((v_e - 20), 2)])
v_e = tobit((v_e - 32))
v_r = tobit((v_A + 32))
v_f = tobit((v_f - 4))
if not (v_f ~= 0) then goto B299 end
do
end
::C299::
end
end
::B299::
I32[arshift((v_A + 32), 2)] = tobit(I32[arshift((v_a - 16), 2)])
I32[arshift((v_A + 36), 2)] = tobit(I32[arshift((v_a - 12), 2)])
I32[arshift((v_A + 40), 2)] = tobit(I32[arshift(v_e, 2)])
I32[arshift((v_A + 44), 2)] = tobit(I32[arshift((v_a - 4), 2)])
goto B298
end
v_A = tobit((v_A - 1))
end
::C298::
end
end
::B298::
end
end
end
do
v_A = 264
v_e = tobit((v_t + 8))
while true do
I8[bor(0, v_e)] = tobit(0)
I8[tobit((v_e + 1))] = tobit(0)
I8[tobit((v_e + 2))] = tobit(0)
I8[tobit((v_e + 3))] = tobit(0)
I8[tobit((v_e + 4))] = tobit(0)
I8[tobit((v_e + 5))] = tobit(0)
I8[tobit((v_e + 6))] = tobit(0)
I8[tobit((v_e + 7))] = tobit(0)
I8[tobit((v_e + 8))] = tobit(0)
I8[tobit((v_e + 9))] = tobit(0)
I8[tobit((v_e + 10))] = tobit(0)
I8[tobit((v_e + 11))] = tobit(0)
if not (v_A ~= 0) then goto B300 end
do
v_e = tobit((v_e + 12))
v_A = tobit((v_A - 12))
end
::C300::
end
end
::B300::
B = tobit((v_t + 288))
do return bor(0, v_o) end
end
UA[32] = function()
local v_A = 0
v_A = F.fOA(1, 276)
if (v_A ~= 0) then
F.fPA(v_A, 0, 276)
end
do return bor(0, v_A) end
end
UA[33] = function(v_A)
local v_r, v_e = 0, 0
v_r = 0
v_e = 0
do
v_A = tobit(v_A)
v_r = v_A
if (v_r ~= 0) then
do
v_e = 264
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
if (not (v_e ~= 0)) then
goto L301
end
v_r = tobit((v_r + 12))
v_e = tobit((v_e - 12))
end
::C302::
end
end
::B302::
end
end
::L301::
F.fL(v_A)
end
UA[34] = function(v_A, v_r, v_e)

do
v_A = tobit(v_A)
local t324 = v_A
v_r = tobit(v_r)
local t325 = v_r
v_e = tobit(v_e)
do return bor(0, F.fN(t324, 5, t325, v_e)) end
end
end
UA[35] = function(v_A, v_r, v_e)

do
v_A = tobit(v_A)
local t326 = v_A
v_r = tobit(v_r)
local t327 = v_r
v_e = tobit(v_e)
do return bor(0, F.fxA(t326, 5, t327, v_e)) end
end
end
UA[36] = function(v_A, v_r, v_e, v_n)

do
v_A = tobit(v_A)
local t328 = v_A
v_e = tobit(v_e)
local t329 = v_e
v_n = tobit(v_n)
do return bor(0, F.fz(t328, t329, v_n)) end
end
end
UA[37] = function(v_A, v_r, v_e, v_n, v_t, v_o)

do
v_A = tobit(v_A)
local t330 = v_A
v_r = tobit(v_r)
local t331 = v_r
v_e = tobit(v_e)
local t332 = v_e
v_n = tobit(v_n)
local t333 = v_n
v_t = tobit(v_t)
local t334 = v_t
v_o = tobit(v_o)
do return bor(0, F.fX(t330, t331, t332, t333, t334, v_o)) end
end
end
UA[38] = function(v_A, v_r, v_e)

do
v_A = tobit(v_A)
local t335 = v_A
v_r = tobit(v_r)
F.fJ(t335, v_r)
do return 0 end
end
end
UA[39] = function(v_A, v_r, v_e)

do
v_A = tobit(v_A)
local t336 = v_A
v_r = tobit(v_r)
do return bor(0, F.frA(t336, v_r)) end
end
end
UA[40] = function()
local v_A = 0
v_A = F.fOA(1, 128)
if (v_A ~= 0) then
F.fFA(v_A)
end
do return bor(0, v_A) end
end
UA[41] = function(v_A)

v_A = tobit(v_A)
F.fq(v_A)
F.fL(v_A)
end
UA[42] = function(v_A, v_r, v_e, v_n)

do
v_A = tobit(v_A)
local t337 = v_A
v_e = tobit(v_e)
local t338 = v_e
v_n = tobit(v_n)
do return bor(0, F.fH(t337, t338, v_n)) end
end
end
UA[43] = function(v_A, v_r, v_e, v_t, v_o, v_i)
local v_a, v_u = 0, 0
v_A = tobit(v_A)
v_r = tobit(v_r)
v_t = tobit(v_t)
v_o = tobit(v_o)
v_i = tobit(v_i)
v_a = 0
v_u = 0
v_u = (-50)
do
v_e = tobit(v_e)
if (not (band(7, v_e) ~= 0)) then
if (1 == bor(0, v_r)) then
v_u = 0
if (v_e ~= 0) then
do
v_r = U8[bor(0, v_t)]
while true do
I8[bor(0, v_i)] = tobit(bxor(U8[bor(0, v_o)], v_r))
I8[tobit((v_i + 1))] = tobit(bxor(U8[tobit((v_t + 1))], U8[tobit((v_o + 1))]))
I8[tobit((v_i + 2))] = tobit(bxor(U8[tobit((v_t + 2))], U8[tobit((v_o + 2))]))
I8[tobit((v_i + 3))] = tobit(bxor(U8[tobit((v_t + 3))], U8[tobit((v_o + 3))]))
I8[tobit((v_i + 4))] = tobit(bxor(U8[tobit((v_t + 4))], U8[tobit((v_o + 4))]))
I8[tobit((v_i + 5))] = tobit(bxor(U8[tobit((v_t + 5))], U8[tobit((v_o + 5))]))
I8[tobit((v_i + 6))] = tobit(bxor(U8[tobit((v_t + 6))], U8[tobit((v_o + 6))]))
I8[tobit((v_i + 7))] = tobit(bxor(U8[tobit((v_t + 7))], U8[tobit((v_o + 7))]))
F.fH(v_A, v_i, v_i)
v_a = bor(bor(bor(U8[tobit((v_i + 4))], lshift(U8[tobit((v_i + 5))], 8)), lshift(U8[tobit((v_i + 6))], 16)), lshift(U8[tobit((v_i + 7))], 24))
v_r = bor(bor(bor(U8[bor(0, v_i)], lshift(U8[tobit((v_i + 1))], 8)), lshift(U8[tobit((v_i + 2))], 16)), lshift(U8[tobit((v_i + 3))], 24))
I8[bor(0, v_t)] = tobit(v_r)
I8[tobit((v_t + 1))] = tobit((rshift(v_r, 8) % 4294967296))
I8[tobit((v_t + 2))] = tobit((rshift(v_r, 16) % 4294967296))
I8[tobit((v_t + 3))] = tobit((rshift(v_r, 24) % 4294967296))
I8[tobit((v_t + 4))] = tobit(v_a)
I8[tobit((v_t + 5))] = tobit((rshift(v_a, 8) % 4294967296))
I8[tobit((v_t + 6))] = tobit((rshift(v_a, 16) % 4294967296))
I8[tobit((v_t + 7))] = tobit((rshift(v_a, 24) % 4294967296))
v_i = tobit((v_i + 8))
v_o = tobit((v_o + 8))
v_e = tobit((v_e - 8))
if not (v_e ~= 0) then goto B304 end
do
end
::C304::
end
end
::B304::
end
else
v_u = 0
if (not (v_e ~= 0)) then
goto L303
end
do
while true do
v_a = bor(bor(bor(U8[tobit((v_o + 4))], lshift(U8[tobit((v_o + 5))], 8)), lshift(U8[tobit((v_o + 6))], 16)), lshift(U8[tobit((v_o + 7))], 24))
v_r = bor(bor(bor(U8[bor(0, v_o)], lshift(U8[tobit((v_o + 1))], 8)), lshift(U8[tobit((v_o + 2))], 16)), lshift(U8[tobit((v_o + 3))], 24))
F.fH(v_A, v_o, v_i)
I8[bor(0, v_i)] = tobit(bxor(U8[bor(0, v_t)], U8[bor(0, v_i)]))
I8[tobit((v_i + 1))] = tobit(bxor(U8[tobit((v_t + 1))], U8[tobit((v_i + 1))]))
I8[tobit((v_i + 2))] = tobit(bxor(U8[tobit((v_t + 2))], U8[tobit((v_i + 2))]))
I8[tobit((v_i + 3))] = tobit(bxor(U8[tobit((v_t + 3))], U8[tobit((v_i + 3))]))
I8[tobit((v_i + 4))] = tobit(bxor(U8[tobit((v_t + 4))], U8[tobit((v_i + 4))]))
I8[tobit((v_i + 5))] = tobit(bxor(U8[tobit((v_t + 5))], U8[tobit((v_i + 5))]))
I8[tobit((v_i + 6))] = tobit(bxor(U8[tobit((v_t + 6))], U8[tobit((v_i + 6))]))
I8[tobit((v_i + 7))] = tobit(bxor(U8[tobit((v_t + 7))], U8[tobit((v_i + 7))]))
I8[bor(0, v_t)] = tobit(v_r)
I8[tobit((v_t + 1))] = tobit((rshift(v_r, 8) % 4294967296))
I8[tobit((v_t + 2))] = tobit((rshift(v_r, 16) % 4294967296))
I8[tobit((v_t + 3))] = tobit((rshift(v_r, 24) % 4294967296))
I8[tobit((v_t + 4))] = tobit(v_a)
I8[tobit((v_t + 5))] = tobit((rshift(v_a, 8) % 4294967296))
I8[tobit((v_t + 6))] = tobit((rshift(v_a, 16) % 4294967296))
I8[tobit((v_t + 7))] = tobit((rshift(v_a, 24) % 4294967296))
v_i = tobit((v_i + 8))
v_o = tobit((v_o + 8))
v_e = tobit((v_e - 8))
if not (v_e ~= 0) then goto B305 end
do
end
::C305::
end
end
::B305::
end
end
end
::L303::
do return bor(0, v_u) end
end
UA[44] = function(v_A, v_r, v_e)
local v_t, v_o, v_f, v_a, v_u, v_c = 0, 0, 0, 0, 0, 0
v_e = tobit(v_e)
v_t = 0
v_o = 0
v_f = 0
v_a = 0
v_u = 0
v_c = 0
do
do
do
v_e = tobit((B - 384))
B = v_e
v_A = tobit(v_A)
local t339 = v_A
v_r = tobit(v_r)
F.fJ(t339, v_r)
F.fJ(tobit((v_e + 128)), tobit((v_r + 8)))
v_r = 0
end
while true do
v_t = lshift(v_r, 2)
v_f = I32[arshift((lshift((30 - v_r), 2) + v_A), 2)]
I32[arshift((v_t + v_e), 2)] = tobit(v_f)
v_a = bor(4, v_t)
v_u = I32[arshift((lshift((31 - v_r), 2) + v_A), 2)]
I32[arshift((v_a + v_e), 2)] = tobit(v_u)
v_o = tobit((v_A + v_t))
I32[arshift((128 + v_o), 2)] = tobit(I32[arshift((lshift((62 - v_r), 2) + v_e), 2)])
I32[arshift((v_o + 132), 2)] = tobit(I32[arshift((lshift((63 - v_r), 2) + v_e), 2)])
v_c = tobit((v_t + 256))
I32[arshift((v_c + v_A), 2)] = tobit(I32[arshift(v_o, 2)])
v_t = tobit((v_t + 260))
I32[arshift((v_t + v_A), 2)] = tobit(I32[arshift((v_A + v_a), 2)])
I32[arshift((v_e + v_t), 2)] = tobit(v_u)
I32[arshift((v_e + v_c), 2)] = tobit(v_f)
v_t = (((tobit(v_r) % 4294967296) < 30) and 1 or 0)
v_r = tobit((v_r + 2))
if not (v_t ~= 0) then goto B306 end
do
end
::C306::
end
end
::B306::
end
do
v_A = 372
v_r = v_e
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
if not (v_A ~= 0) then goto B307 end
do
v_r = tobit((v_r + 12))
v_A = tobit((v_A - 12))
end
::C307::
end
end
::B307::
B = tobit((v_e + 384))
do return 0 end
end
UA[45] = function(v_A, v_r, v_e)
local v_t, v_o, v_f, v_a, v_u, v_c = 0, 0, 0, 0, 0, 0
v_A = tobit(v_A)
v_e = tobit(v_e)
v_t = 0
v_o = 0
v_f = 0
v_a = 0
v_u = 0
v_c = 0
do
do
do
v_e = tobit((B - 384))
B = v_e
local t340 = v_e
v_r = tobit(v_r)
F.fJ(t340, v_r)
F.fJ(tobit((v_A + 128)), tobit((v_r + 8)))
v_r = 0
end
while true do
v_t = lshift(v_r, 2)
v_f = I32[arshift((lshift((30 - v_r), 2) + v_e), 2)]
I32[arshift((v_t + v_A), 2)] = tobit(v_f)
v_a = bor(4, v_t)
v_u = I32[arshift((lshift((31 - v_r), 2) + v_e), 2)]
I32[arshift((v_a + v_A), 2)] = tobit(v_u)
v_o = tobit((v_e + v_t))
I32[arshift((128 + v_o), 2)] = tobit(I32[arshift((lshift((62 - v_r), 2) + v_A), 2)])
I32[arshift((v_o + 132), 2)] = tobit(I32[arshift((lshift((63 - v_r), 2) + v_A), 2)])
v_c = tobit((v_t + 256))
I32[arshift((v_c + v_e), 2)] = tobit(I32[arshift(v_o, 2)])
v_t = tobit((v_t + 260))
I32[arshift((v_t + v_e), 2)] = tobit(I32[arshift((v_e + v_a), 2)])
I32[arshift((v_A + v_t), 2)] = tobit(v_u)
I32[arshift((v_A + v_c), 2)] = tobit(v_f)
v_t = (((tobit(v_r) % 4294967296) < 30) and 1 or 0)
v_r = tobit((v_r + 2))
if not (v_t ~= 0) then goto B308 end
do
end
::C308::
end
end
::B308::
end
do
v_A = 372
v_r = v_e
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
if not (v_A ~= 0) then goto B309 end
do
v_r = tobit((v_r + 12))
v_A = tobit((v_A - 12))
end
::C309::
end
end
::B309::
B = tobit((v_e + 384))
do return 0 end
end
UA[46] = function()
local v_A = 0
v_A = F.fOA(1, 384)
if (v_A ~= 0) then
F.fPA(v_A, 0, 384)
end
do return bor(0, v_A) end
end
UA[47] = function(v_A)
local v_r, v_e = 0, 0
v_r = 0
v_e = 0
do
v_A = tobit(v_A)
v_r = v_A
if (v_r ~= 0) then
do
v_e = 372
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
if (not (v_e ~= 0)) then
goto L310
end
v_r = tobit((v_r + 12))
v_e = tobit((v_e - 12))
end
::C311::
end
end
::B311::
end
end
::L310::
F.fL(v_A)
end
UA[48] = function(v_A, v_r, v_e)

do
do
do
v_e = tobit(v_e)
v_e = tobit((B - 384))
B = v_e
v_A = tobit(v_A)
local t341 = v_A
local t342 = v_e
v_r = tobit(v_r)
F.fbA(t341, t342, v_r)
v_r = 372
v_A = v_e
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
if not (v_r ~= 0) then goto B312 end
do
v_A = tobit((v_A + 12))
v_r = tobit((v_r - 12))
end
::C312::
end
end
::B312::
end
B = tobit((v_e + 384))
do return 0 end
end
UA[49] = function(v_A, v_r, v_e)

do
do
do
v_e = tobit(v_e)
v_e = tobit((B - 384))
B = v_e
local t343 = v_e
v_A = tobit(v_A)
local t344 = v_A
v_r = tobit(v_r)
F.fbA(t343, t344, v_r)
v_r = 372
v_A = v_e
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
if not (v_r ~= 0) then goto B313 end
do
v_A = tobit((v_A + 12))
v_r = tobit((v_r - 12))
end
::C313::
end
end
::B313::
end
B = tobit((v_e + 384))
do return 0 end
end
UA[50] = function(v_A, v_r, v_e)
local v_n, v_t, v_o, v_a, v_u = 0, 0, 0, 0, 0
v_r = tobit(v_r)
v_n = 0
v_t = 0
v_o = 0
v_a = 0
v_u = 0
do
v_A = tobit(v_A)
local t345 = (not (v_A ~= 0))
v_e = tobit(v_e)
if (bor((t345 and 1 or 0), ((not (v_e ~= 0)) and 1 or 0)) ~= 0) then
v_A = (-24832)
else
do
do
local t346 = v_r
v_n = U8[tobit((tobit((v_A + v_r)) - 1))]
v_t = tobit((t346 - v_n))
I32[arshift(v_e, 2)] = tobit(v_t)
v_e = bor(((not (v_n ~= 0)) and 1 or 0), (((tobit(v_r) % 4294967296) < (tobit(v_n) % 4294967296)) and 1 or 0))
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
v_o = bor((((tobit(v_r) % 4294967296) < (tobit(v_t) % 4294967296)) and 0 or bxor(v_n, U8[tobit((v_A + v_r))])), v_e)
local t347 = v_o
v_e = bor(1, v_r)
v_o = bor(t347, (((tobit(v_e) % 4294967296) < (tobit(v_t) % 4294967296)) and 0 or bxor(v_n, U8[tobit((v_e + v_A))])))
local t348 = v_o
v_e = bor(2, v_r)
v_o = bor(t348, (((tobit(v_e) % 4294967296) < (tobit(v_t) % 4294967296)) and 0 or bxor(v_n, U8[tobit((v_e + v_A))])))
local t349 = v_o
v_e = bor(3, v_r)
v_e = bor(t349, (((tobit(v_e) % 4294967296) < (tobit(v_t) % 4294967296)) and 0 or bxor(v_n, U8[tobit((v_e + v_A))])))
v_r = tobit((v_r + 4))
v_u = tobit((v_u - 4))
if not (v_u ~= 0) then goto B314 end
end
do
end
::C314::
end
end
::B314::
end
end
end
if (v_a ~= 0) then
do
while true do
v_e = bor((((tobit(v_r) % 4294967296) < (tobit(v_t) % 4294967296)) and 0 or bxor(v_n, U8[tobit((v_A + v_r))])), v_e)
v_r = tobit((v_r + 1))
v_a = tobit((v_a - 1))
if not (v_a ~= 0) then goto B315 end
do
end
::C315::
end
end
::B315::
end
end
end
end
v_A = ((band(255, v_e) ~= 0) and (-25088) or 0)
end
end
end
do return bor(0, v_A) end
end
UA[51] = function(v_A, v_r, v_e)
local v_t, v_o = 0, 0
v_A = tobit(v_A)
v_t = 0
v_o = 0
do
do
do
v_r = tobit(v_r)
local t350 = v_r
v_e = tobit(v_e)
v_o = tobit((t350 - v_e))
if (v_o ~= 0) then
do
v_r = 1
v_t = v_e
while true do
do
I8[tobit((v_A + v_t))] = tobit(v_o)
v_t = band(255, v_r)
if ((tobit(v_t) % 4294967296) >= (tobit(v_o) % 4294967296)) then
goto L316
end
v_r = tobit((v_r + 1))
v_t = tobit((v_e + v_t))
end
::C317::
end
end
::B317::
end
end
end
::L316::
end
end
UA[52] = function(v_A, v_r, v_e, v_t, v_o, v_u)
local v_c, v_l, v_b, v_v, v_d, v_h, v_k, v_y, v_w, v_C, v_E, v_m, v_Q, v_O, v_S, v_M, v_x, v_j, v_T, v_P, v_K = 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
v_A = tobit(v_A)
v_r = v_r
v_e = tobit(v_e)
v_t = tobit(v_t)
v_o = tobit(v_o)
v_u = tobit(v_u)
v_l = 0
v_b = 0
v_v = 0
v_d = 0
v_h = 0
v_k = 0
v_y = 0
v_w = 0
v_C = 0
v_E = 0
v_m = 0
v_Q = 0
v_O = 0
v_S = 0
v_M = 0
v_x = 0
v_j = 0
v_T = 0
v_P = 0
v_K = 0
v_c = tobit((B - 560))
B = v_c
I32[arshift((v_c + 44), 2)] = tobit(0)
rf_s(v_r)
v_k = bor(0, rf_a(1))
rf_a(0)
if ((bor(0, v_k) < (-1)) or (bor(0, v_k) <= (-1))) then
v_S = 1
v_M = 10511
v_r = (-v_r)
rf_s(v_r)
v_k = bor(0, rf_a(1))
rf_a(0)
else
if (band(2048, v_o) ~= 0) then
v_S = 1
v_M = 10514
else
v_S = band(1, v_o)
v_M = ((v_S ~= 0) and 10517 or 10512)
v_K = ((not (v_S ~= 0)) and 1 or 0)
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
v_r = F.fkA(v_r, tobit((v_c + 44)))
v_r = (v_r + v_r)
if (0 ~= v_r) then
v_l = I32[arshift((v_c + 44), 2)]
I32[arshift((v_c + 44), 2)] = tobit((v_l - 1))
v_x = bor(32, v_u)
if (97 ~= bor(0, v_x)) then
goto L321
end
goto L319
end
v_x = bor(32, v_u)
if (97 == bor(0, v_x)) then
goto L319
end
v_w = I32[arshift((v_c + 44), 2)]
v_h = ((bor(0, v_t) < 0) and 6 or v_t)
goto L320
end
::L321::
v_w = tobit((v_l - 29))
I32[arshift((v_c + 44), 2)] = tobit(v_w)
v_r = (v_r * 268435456)
v_h = ((bor(0, v_t) < 0) and 6 or v_t)
end
::L320::
do
v_E = ((bor(0, v_w) < 0) and tobit((v_c + 48)) or tobit((v_c + 336)))
v_b = v_E
while true do
v_l = ((band(((v_r < 4294967296) and 1 or 0), ((v_r >= 0) and 1 or 0)) ~= 0) and (tobit(bnot(bnot(v_r))) % 4294967296) or 0)
v_t = v_b
I32[arshift(v_t, 2)] = tobit(v_l)
v_b = tobit((v_b + 4))
v_r = (1000000000 * (v_r - (tobit(v_l) % 4294967296)))
if not (0 ~= v_r) then goto B322 end
do
end
::C322::
end
end
::B322::
do
if (bor(0, v_w) < 1) then
v_t = v_w
v_l = v_b
v_v = v_E
else
do
do
v_v = v_E
v_t = v_w
while true do
do
do
do
v_y = ((bor(0, v_t) < 29) and v_t or 29)
local t351 = (tobit(v_v) % 4294967296)
v_l = tobit((v_b - 4))
if (not (t351 > (tobit(v_l) % 4294967296))) then
do
do
do
v_d = v_y
v_t = 0
v_k = 0
while true do
do
v_m = v_l
v_P = I32[arshift(v_l, 2)]
v_C = band(31, v_d)
if ((tobit(band(63, v_d)) % 4294967296) >= 32) then
v_T = lshift(v_P, v_C)
v_C = 0
else
v_T = band((lshift(1, v_C) - 1), (rshift(v_P, (32 - v_C)) % 4294967296))
v_C = lshift(v_P, v_C)
end
v_T = tobit((v_k + v_T))
v_C = tobit((v_C + v_t))
v_k = v_C
v_t = F.fS_(v_k, (((tobit(v_t) % 4294967296) > (tobit(v_k) % 4294967296)) and tobit((v_T + 1)) or v_T), 1000000000)
v_C = F.fCA(v_t, Iv, 1000000000, 0)
I32[arshift(v_m, 2)] = tobit((v_k - v_C))
local t352 = (tobit(v_v) % 4294967296)
v_l = tobit((v_l - 4))
if not (t352 <= (tobit(v_l) % 4294967296)) then goto B324 end
end
do
v_k = 0
end
::C324::
end
end
::B324::
end
if (v_t ~= 0) then
v_v = tobit((v_v - 4))
I32[arshift(v_v, 2)] = tobit(v_t)
end
end
end
end
do
do
while true do
do
local t353 = (tobit(v_v) % 4294967296)
v_l = v_b
local t354 = (t353 < (tobit(v_l) % 4294967296))
if t354 then
v_b = tobit((v_l - 4))
t354 = (not (I32[arshift(v_b, 2)] ~= 0))
end
if not t354 then goto B325 end
end
do
end
::C325::
end
end
::B325::
end
v_t = tobit((I32[arshift((v_c + 44), 2)] - v_y))
I32[arshift((v_c + 44), 2)] = tobit(v_t)
v_b = v_l
if (not (bor(0, v_t) > 0)) then
goto B323
end
end
end
::C323::
end
end
::B323::
end
end
end
do
v_b = tobit(toint((tobit((v_h + 25)) / 9)))
if (bor(0, v_t) <= (-1)) then
do
do
v_C = tobit((v_b + 1))
v_j = ((102 == bor(0, v_x)) and 1 or 0)
while true do
do
do
v_m = ((bor(0, v_t) < (-9)) and 9 or tobit((0 - v_t)))
do
if ((tobit(v_l) % 4294967296) > (tobit(v_v) % 4294967296)) then
do
v_k = tobit((rshift(1000000000, v_m) % 4294967296))
v_d = bxor(lshift((-1), v_m), (-1))
v_t = 0
v_b = v_v
while true do
v_y = v_t
v_t = I32[arshift(v_b, 2)]
I32[arshift(v_b, 2)] = tobit((v_y + tobit((rshift(v_t, v_m) % 4294967296))))
v_t = imul(v_k, band(v_t, v_d))
v_b = tobit((v_b + 4))
if not ((tobit(v_b) % 4294967296) < (tobit(v_l) % 4294967296)) then goto B328 end
do
end
::C328::
end
end
::B328::
v_v = ((I32[arshift(v_v, 2)] ~= 0) and v_v or tobit((v_v + 4)))
if (not (v_t ~= 0)) then
goto L327
end
I32[arshift(v_l, 2)] = tobit(v_t)
v_l = tobit((v_l + 4))
else
v_v = ((I32[arshift(v_v, 2)] ~= 0) and v_v or tobit((v_v + 4)))
end
end
::L327::
do
v_t = tobit((I32[arshift((v_c + 44), 2)] + v_m))
I32[arshift((v_c + 44), 2)] = tobit(v_t)
local t356 = bor(0, v_C)
local t355 = v_l
v_b = ((v_j ~= 0) and v_E or v_v)
v_l = ((t356 < arshift((t355 - v_b), 2)) and tobit((v_b + lshift(v_C, 2))) or v_l)
if (not (bor(0, v_t) < 0)) then
goto B326
end
end
end
end
::C326::
end
end
::B326::
end
end
end
v_b = 0
do
do
do
local t357 = (((tobit(v_l) % 4294967296) <= (tobit(v_v) % 4294967296)) and 1 or 0)
if t357 == 0 then
v_b = imul(arshift((v_E - v_v), 2), 9)
v_d = I32[arshift(v_v, 2)]
t357 = (((tobit(v_d) % 4294967296) < 10) and 1 or 0)
end
if (not (t357 ~= 0)) then
do
v_t = 100
while true do
do
v_b = tobit((v_b + 1))
if ((tobit(v_t) % 4294967296) > (tobit(v_d) % 4294967296)) then
goto L329
end
v_t = imul(v_t, 10)
end
::C330::
end
end
::B330::
end
end
end
::L329::
end
do
v_t = tobit((tobit((v_h - ((102 == bor(0, v_x)) and 0 or v_b))) - band(((103 == bor(0, v_x)) and 1 or 0), ((0 ~= bor(0, v_h)) and 1 or 0))))
if (bor(0, v_t) < tobit((imul(arshift((v_l - v_E), 2), 9) - 9))) then
do
v_k = tobit((v_t + 9216))
v_d = tobit(toint((bor(0, v_k) / 9)))
v_y = tobit((tobit((lshift(v_d, 2) + ((bor(0, v_w) < 0) and bor((v_c + 48), 4) or tobit((v_c + 340))))) - 4096))
v_t = 10
do
v_d = tobit((v_k - imul(v_d, 9)))
if (not (bor(0, v_d) > 7)) then
do
v_t = 100
while true do
do
v_d = tobit((v_d + 1))
if (8 == bor(0, v_d)) then
goto L331
end
v_t = imul(v_t, 10)
end
::C332::
end
end
::B332::
end
end
::L331::
do
do
do
v_k = I32[arshift(v_y, 2)]
local t359 = v_k
local t358 = v_t
v_w = tobit(toint(((tobit(v_k) % 4294967296) / (tobit(v_t) % 4294967296))))
v_C = tobit((t359 - imul(t358, v_w)))
v_d = tobit((v_y + 4))
local t360 = ((bor(0, v_d) ~= bor(0, v_l)) and 1 or 0)
if t360 == 0 then
t360 = v_C
end
local t361 = t360
if t361 ~= 0 then
v_r = ((bor(0, v_l) == bor(0, v_d)) and 1 or 1.5)
v_d = tobit((rshift(v_t, 1) % 4294967296))
v_O = (((tobit(v_d) % 4294967296) > (tobit(v_C) % 4294967296)) and 0.5 or ((bor(0, v_d) == bor(0, v_C)) and v_r or 1.5))
v_r = ((band(1, v_w) ~= 0) and 9007199254740994 or 9007199254740992)
if not (bor(((45 ~= U8[bor(0, v_M)]) and 1 or 0), v_K) ~= 0) then
v_O = (-v_O)
v_r = (-v_r)
end
v_d = tobit((v_k - v_C))
I32[arshift(v_y, 2)] = tobit(v_d)
t361 = (((v_r + v_O) ~= v_r) and 1 or 0)
end
if (t361 ~= 0) then
v_t = tobit((v_t + v_d))
I32[arshift(v_y, 2)] = tobit(v_t)
if ((tobit(v_t) % 4294967296) >= 1000000000) then
do
while true do
I32[arshift(v_y, 2)] = tobit(0)
v_y = tobit((v_y - 4))
if ((tobit(v_y) % 4294967296) < (tobit(v_v) % 4294967296)) then
v_v = tobit((v_v - 4))
I32[arshift(v_v, 2)] = tobit(0)
end
v_t = tobit((I32[arshift(v_y, 2)] + 1))
I32[arshift(v_y, 2)] = tobit(v_t)
if not ((tobit(v_t) % 4294967296) > 999999999) then goto B334 end
do
end
::C334::
end
end
::B334::
end
v_b = imul(arshift((v_E - v_v), 2), 9)
v_d = I32[arshift(v_v, 2)]
if (not ((tobit(v_d) % 4294967296) < 10)) then
do
v_t = 100
while true do
do
v_b = tobit((v_b + 1))
if ((tobit(v_t) % 4294967296) > (tobit(v_d) % 4294967296)) then
goto L333
end
v_t = imul(v_t, 10)
end
::C335::
end
end
::B335::
end
end
end
end
::L333::
end
v_t = tobit((v_y + 4))
v_l = (((tobit(v_t) % 4294967296) < (tobit(v_l) % 4294967296)) and v_t or v_l)
end
end
end
do
do
while true do
do
v_w = v_l
v_d = (((tobit(v_l) % 4294967296) <= (tobit(v_v) % 4294967296)) and 1 or 0)
local t362 = ((not (v_d ~= 0)) and 1 or 0)
if t362 ~= 0 then
v_l = tobit((v_w - 4))
t362 = ((not (I32[arshift(v_l, 2)] ~= 0)) and 1 or 0)
end
if not (t362 ~= 0) then goto B336 end
end
do
end
::C336::
end
end
::B336::
end
do
if (103 == bor(0, v_x)) then
do
do
local t363 = v_h
if t363 == 0 then
t363 = 1
end
v_l = t363
v_t = band(((bor(0, v_l) > bor(0, v_b)) and 1 or 0), ((bor(0, v_b) > (-5)) and 1 or 0))
v_h = tobit((((v_t ~= 0) and bxor((-1), v_b) or (-1)) + v_l))
v_u = tobit((((v_t ~= 0) and (-1) or (-2)) + v_u))
v_m = band(8, v_o)
if (not (v_m ~= 0)) then
do
do
v_l = (-9)
local t364 = ((not (v_d ~= 0)) and 1 or 0)
if t364 ~= 0 then
v_t = I32[arshift((v_w - 4), 2)]
t364 = v_t
end
local t365 = t364
if t365 ~= 0 then
v_l = 0
t365 = ((not (tobit(fmod((tobit(v_t) % 4294967296), 10)) ~= 0)) and 1 or 0)
end
if (t365 ~= 0) then
do
v_d = 0
v_l = 100
while true do
if not (not (tobit(fmod((tobit(v_t) % 4294967296), (tobit(v_l) % 4294967296))) ~= 0)) then goto B337 end
do
v_d = tobit((v_d + 1))
v_l = imul(v_l, 10)
end
::C337::
end
end
::B337::
v_l = bxor((-1), v_d)
end
end
v_t = imul(arshift((v_w - v_E), 2), 9)
if (70 ~= band((-33), v_u)) then
v_m = 0
v_t = tobit((tobit((tobit((v_t + v_b)) + v_l)) - 9))
v_t = ((bor(0, v_t) > 0) and v_t or 0)
v_h = ((bor(0, v_t) > bor(0, v_h)) and v_h or v_t)
else
v_m = 0
v_t = tobit((tobit((v_t + v_l)) - 9))
v_t = ((bor(0, v_t) > 0) and v_t or 0)
v_h = ((bor(0, v_t) > bor(0, v_h)) and v_h or v_t)
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
v_C = ((0 ~= bor(v_h, v_m)) and 1 or 0)
v_t = v_A
v_d = v_e
v_k = band((-33), v_u)
if (70 == bor(0, v_k)) then
v_u = ((bor(0, v_b) > 0) and v_b or 0)
else
do
do
local t366 = v_Q
v_l = arshift(v_b, 31)
v_l = F.fdA(bxor((v_l + v_b), v_l), 0, v_Q)
if (tobit((t366 - v_l)) <= 1) then
do
while true do
v_l = tobit((v_l - 1))
I8[bor(0, v_l)] = tobit(48)
if not (tobit((v_Q - v_l)) < 2) then goto B338 end
do
end
::C338::
end
end
::B338::
end
end
v_j = tobit((v_l - 2))
I8[bor(0, v_j)] = tobit(v_u)
I8[tobit((v_l - 1))] = tobit(((bor(0, v_b) < 0) and 45 or 43))
v_u = tobit((v_Q - v_j))
end
end
end
do
local t367 = v_t
local t368 = v_d
v_y = tobit((1 + tobit((v_u + tobit((v_C + tobit((v_h + v_S))))))))
F.fEA(t367, 32, t368, v_y, v_o)
F.fiA(v_A, v_M, v_S)
F.fEA(v_A, 48, v_e, v_y, bxor(65536, v_o))
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
v_t = bor((v_c + 16), 8)
v_b = bor((v_c + 16), 9)
v_u = (((tobit(v_v) % 4294967296) > (tobit(v_E) % 4294967296)) and v_E or v_v)
v_v = v_u
while true do
do
do
v_l = F.fdA(I32[arshift(v_v, 2)], 0, v_b)
do
if (bor(0, v_u) == bor(0, v_v)) then
if (bor(0, v_l) == bor(0, v_b)) then
I8[tobit((v_c + 24))] = tobit(48)
v_l = v_t
end
else
if ((tobit((v_c + 16)) % 4294967296) >= (tobit(v_l) % 4294967296)) then
goto L343
end
do
while true do
v_l = tobit((v_l - 1))
I8[bor(0, v_l)] = tobit(48)
if not ((tobit((v_c + 16)) % 4294967296) < (tobit(v_l) % 4294967296)) then goto B344 end
do
end
::C344::
end
end
::B344::
end
end
::L343::
do
F.fiA(v_A, v_l, tobit((v_b - v_l)))
local t369 = (tobit(v_E) % 4294967296)
v_v = tobit((v_v + 4))
if (not (t369 >= (tobit(v_v) % 4294967296))) then
goto B342
end
end
end
end
::C342::
end
end
::B342::
end
v_l = 0
if (not (v_C ~= 0)) then
goto L340
end
F.fiA(v_A, 10655, 1)
if (bor(((bor(0, v_h) < 1) and 1 or 0), (((tobit(v_v) % 4294967296) >= (tobit(v_w) % 4294967296)) and 1 or 0)) ~= 0) then
goto L341
end
do
do
while true do
do
do
v_l = F.fdA(I32[arshift(v_v, 2)], 0, v_b)
if ((tobit(v_l) % 4294967296) > (tobit((v_c + 16)) % 4294967296)) then
do
while true do
v_l = tobit((v_l - 1))
I8[bor(0, v_l)] = tobit(48)
if not ((tobit((v_c + 16)) % 4294967296) < (tobit(v_l) % 4294967296)) then goto B346 end
do
end
::C346::
end
end
::B346::
end
do
F.fiA(v_A, v_l, ((bor(0, v_h) < 9) and v_h or 9))
v_l = tobit((v_h - 9))
local t370 = (tobit(v_w) % 4294967296)
v_v = tobit((v_v + 4))
if (t370 <= (tobit(v_v) % 4294967296)) then
goto L340
end
end
v_t = ((bor(0, v_h) > 9) and 1 or 0)
v_h = v_l
if (not (v_t ~= 0)) then
goto B345
end
end
end
::C345::
end
end
::B345::
end
goto L340
end
end
end
do
do
do
if (not (bor(0, v_h) < 0)) then
do
do
v_u = (((tobit(v_v) % 4294967296) < (tobit(v_w) % 4294967296)) and v_w or tobit((v_v + 4)))
v_d = bor((v_c + 16), 9)
v_t = bor((v_c + 16), 8)
v_b = v_v
while true do
do
do
do
local t371 = bor(0, v_d)
v_l = F.fdA(I32[arshift(v_b, 2)], 0, v_d)
if (t371 == bor(0, v_l)) then
I8[tobit((v_c + 24))] = tobit(48)
v_l = v_t
end
end
do
if (bor(0, v_b) == bor(0, v_v)) then
F.fiA(v_A, v_l, 1)
v_l = tobit((v_l + 1))
if not ((not (v_m ~= 0)) and (bor(0, v_h) <= 0)) then
F.fiA(v_A, 10655, 1)
end
else
if ((tobit((v_c + 16)) % 4294967296) >= (tobit(v_l) % 4294967296)) then
goto L349
end
do
while true do
v_l = tobit((v_l - 1))
I8[bor(0, v_l)] = tobit(48)
if not ((tobit((v_c + 16)) % 4294967296) < (tobit(v_l) % 4294967296)) then goto B350 end
do
end
::C350::
end
end
::B350::
end
end
::L349::
do
local t372 = v_A
v_w = v_l
local t373 = v_w
v_l = tobit((v_d - v_l))
F.fiA(t372, t373, ((bor(0, v_l) < bor(0, v_h)) and v_l or v_h))
v_h = tobit((v_h - v_l))
local t374 = (tobit(v_u) % 4294967296)
v_b = tobit((v_b + 4))
if (t374 <= (tobit(v_b) % 4294967296)) then
goto L347
end
end
if (not (bor(0, v_h) > (-1))) then
goto B348
end
end
end
::C348::
end
end
::B348::
end
end
end
end
::L347::
end
F.fEA(v_A, 48, tobit((v_h + 18)), 18, 0)
F.fiA(v_A, v_j, tobit((v_Q - v_j)))
goto L339
end
end
::L341::
end
v_l = v_h
end
end
::L340::
end
F.fEA(v_A, 48, tobit((v_l + 9)), 9, 0)
end
end
::L339::
end
goto L318
end
end
::L319::
end
do
v_h = band(32, v_u)
v_w = ((v_h ~= 0) and tobit((v_M + 9)) or v_M)
local t375 = ((not ((tobit(v_t) % 4294967296) > 11)) and 1 or 0)
if t375 ~= 0 then
v_l = tobit((12 - v_t))
t375 = v_l
end
if (t375 ~= 0) then
do
v_O = 8
while true do
v_O = (v_O * 16)
v_l = tobit((v_l - 1))
if not (v_l ~= 0) then goto B351 end
do
end
::C351::
end
end
::B351::
v_r = ((45 ~= U8[bor(0, v_w)]) and ((v_r + v_O) - v_O) or (-(v_O + ((-v_r) - v_O))))
end
end
do
do
do
local t376 = bor(0, v_Q)
v_l = I32[arshift((v_c + 44), 2)]
v_b = arshift(v_l, 31)
v_l = F.fdA(bxor(v_b, (v_l + v_b)), 0, v_Q)
if (t376 == bor(0, v_l)) then
I8[tobit((v_c + 15))] = tobit(48)
v_l = tobit((v_c + 15))
end
v_d = bor(2, v_S)
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
v_E = v_h
v_b = ((math.abs(v_r) < 2147483648) and bnot(bnot(v_r)) or (-2147483648))
I8[bor(0, v_v)] = tobit(bor(v_E, U8[tobit((v_b + 12288))]))
v_r = (16 * (v_r - bor(0, v_b)))
local t377 = v_l
if t377 == 0 then
t377 = bor(((bor(0, v_t) > 0) and 1 or 0), ((0 ~= v_r) and 1 or 0))
end
local t378 = (not (t377 ~= 0))
v_v = tobit((v_u + 1))
if not (bor((t378 and 1 or 0), ((1 ~= tobit((v_v - tobit((v_c + 16))))) and 1 or 0)) ~= 0) then
I8[tobit((v_u + 1))] = tobit(46)
v_v = tobit((v_u + 2))
end
if not (0 ~= v_r) then goto B352 end
end
do
end
::C352::
end
end
::B352::
end
do
local t379 = v_A
local t380 = v_e
v_u = ((bor(((not (v_t ~= 0)) and 1 or 0), ((tobit((tobit((v_v - v_c)) - 18)) >= bor(0, v_t)) and 1 or 0)) ~= 0) and tobit((tobit((v_Q - tobit((v_k + tobit((v_c + 16)))))) + v_v)) or tobit((2 + tobit((tobit((v_t + v_Q)) - v_k)))))
v_y = tobit((v_u + v_d))
F.fEA(t379, 32, t380, v_y, v_o)
F.fiA(v_A, v_w, v_d)
F.fEA(v_A, 48, v_e, v_y, bxor(65536, v_o))
local t381 = v_A
local t382 = tobit((v_c + 16))
v_t = tobit((v_v - tobit((v_c + 16))))
F.fiA(t381, t382, v_t)
local t385 = v_A
local t384 = v_u
v_l = v_t
local t383 = v_l
v_t = tobit((v_Q - v_k))
F.fEA(t385, 48, tobit((t384 - tobit((t383 + v_t)))), 0, 0)
F.fiA(v_A, v_k, v_t)
end
end
else
do
local t386 = v_A
local t387 = v_e
v_y = tobit((v_S + 3))
F.fEA(t386, 32, t387, v_y, band((-65537), v_o))
F.fiA(v_A, v_M, v_S)
v_t = band(32, v_u)
F.fiA(v_A, ((v_r ~= v_r) and ((v_t ~= 0) and 10588 or 10640) or ((v_t ~= 0) and 10613 or 10644)), 3)
end
end
end
end
::L318::
end
F.fEA(v_A, 32, v_e, v_y, bxor(8192, v_o))
B = tobit((v_c + 560))
do return bor(0, ((bor(0, v_e) > bor(0, v_y)) and v_e or v_y)) end
end
UA[53] = function(v_A, v_r)
local v_e, v_n, v_t, v_o, v_f, v_a, v_s, v_l, v_b, v_g, v_p, v_d, v_h, v_k, v_y = 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
v_A = tobit(v_A)
v_o = 0
v_f = 0
v_a = 0
v_s = 0
v_l = 0
v_b = 0
v_g = 0
v_p = 0
v_d = 0
v_h = 0
v_k = 0
v_y = 0
v_r = tobit(v_r)
v_o = v_r
v_r = band((I32[arshift(v_r, 2)] + 15), (-16))
I32[arshift(v_o, 2)] = tobit((v_r + 16))
v_t = v_A
v_A = v_r
v_p = I32[arshift(v_A, 2)]
v_r = I32[arshift((v_A + 4), 2)]
v_s = I32[arshift((v_A + 12), 2)]
v_n = v_s
v_e = tobit((B - 32))
B = v_e
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
v_o = bor(lshift(v_n, 4), (rshift(v_o, 28) % 4294967296))
local t388 = lshift(v_s, 4)
v_A = v_r
v_s = bor(t388, (rshift(v_A, 28) % 4294967296))
v_A = band(v_A, 268435455)
v_r = v_A
if (bor(band(((134217728 == bor(0, v_A)) and 1 or 0), (((tobit(v_p) % 4294967296) >= 1) and 1 or 0)), (((tobit(v_A) % 4294967296) > 134217728) and 1 or 0)) ~= 0) then
v_A = tobit((v_o + 1073741824))
v_r = tobit((v_s + 1))
v_A = (((tobit(v_r) % 4294967296) < 1) and tobit((v_A + 1)) or v_A)
v_a = v_r
goto L353
end
end
v_a = v_s
v_A = tobit((v_o + 1073741824))
if (bor(v_p, bxor(134217728, v_r)) ~= 0) then
goto L353
end
do
v_o = v_A
v_r = band(1, v_s)
local t389 = (tobit(v_r) % 4294967296)
v_s = tobit((v_r + v_a))
v_a = v_s
v_A = ((t389 > (tobit(v_a) % 4294967296)) and tobit((v_o + 1)) or v_o)
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
v_f = bor(band(65535, v_n), 65536)
v_s = v_f
v_d = v_o
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
v_h = band(31, v_o)
if ((tobit(band(63, v_o)) % 4294967296) >= 32) then
v_o = lshift(v_l, v_h)
v_l = 0
else
v_o = bor(band((lshift(1, v_h) - 1), (rshift(v_l, (32 - v_h)) % 4294967296)), lshift(v_f, v_h))
v_l = lshift(v_l, v_h)
end
v_f = v_o
v_y = v_l
v_l = v_A
v_h = v_a
v_o = tobit((64 - v_b))
v_b = band(31, v_o)
if ((tobit(band(63, v_o)) % 4294967296) >= 32) then
v_o = 0
v_l = tobit((rshift(v_l, v_b) % 4294967296))
else
v_o = tobit((rshift(v_l, v_b) % 4294967296))
v_l = bor(lshift(band((lshift(1, v_b) - 1), v_l), (32 - v_b)), (rshift(v_h, v_b) % 4294967296))
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
I32[arshift((v_e + 16), 2)] = tobit(v_a)
I32[arshift((v_e + 20), 2)] = tobit(v_A)
I32[arshift((v_e + 24), 2)] = tobit(v_l)
I32[arshift((v_e + 28), 2)] = tobit(v_f)
v_o = tobit((15361 - v_k))
if (band(64, v_o) ~= 0) then
v_r = v_d
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
v_d = 0
v_s = 0
else
if (v_o ~= 0) then
v_A = v_s
v_a = v_d
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
v_o = v_d
v_f = band(31, v_A)
if ((tobit(band(63, v_A)) % 4294967296) >= 32) then
v_A = 0
v_d = tobit((rshift(v_s, v_f) % 4294967296))
else
v_A = tobit((rshift(v_s, v_f) % 4294967296))
v_d = bor(lshift(band((lshift(1, v_f) - 1), v_s), (32 - v_f)), (rshift(v_o, v_f) % 4294967296))
end
v_s = v_A
end
end
I32[arshift(v_e, 2)] = tobit(v_p)
I32[arshift((v_e + 4), 2)] = tobit(v_r)
I32[arshift((v_e + 8), 2)] = tobit(v_d)
I32[arshift((v_e + 12), 2)] = tobit(v_s)
v_f = I32[arshift((v_e + 4), 2)]
v_r = I32[arshift((v_e + 8), 2)]
v_a = bor(lshift(v_r, 4), (rshift(v_f, 28) % 4294967296))
v_A = bor(lshift(I32[arshift((v_e + 12), 2)], 4), (rshift(v_r, 28) % 4294967296))
v_f = band(v_f, 268435455)
v_s = v_f
local t390 = (134217728 == bor(0, v_f))
v_r = bor(bor(I32[arshift(v_e, 2)], ((0 ~= bor(I32[arshift((v_e + 16), 2)], I32[arshift((v_e + 24), 2)])) and 1 or 0)), ((0 ~= bor(I32[arshift((v_e + 20), 2)], I32[arshift((v_e + 28), 2)])) and 1 or 0))
if (bor(band((t390 and 1 or 0), (((tobit(v_r) % 4294967296) >= 1) and 1 or 0)), (((tobit(v_f) % 4294967296) > 134217728) and 1 or 0)) ~= 0) then
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
v_o = bor(lshift(v_n, 4), (rshift(v_o, 28) % 4294967296))
v_A = bor(band(524287, v_o), 2146959360)
end
end
end
end
end
::L353::
end
B = tobit((v_e + 32))
rf_u(0, bor(0, v_a))
rf_u(1, bor(band((-2147483648), v_n), v_A))
F64[arshift(v_t, 3)] = rf_c()
end
UA[54] = function(v_A, v_r, v_e)
local v_n, v_t = 0, 0
v_r = tobit(v_r)
v_e = tobit(v_e)
v_t = 0
do
v_A = tobit(v_A)
v_n = I32[arshift((20 + v_A), 2)]
local t392 = v_n
local t393 = v_r
local t391 = (tobit(v_e) % 4294967296)
v_t = tobit((I32[arshift((v_A + 16), 2)] - v_n))
v_t = ((t391 < (tobit(v_t) % 4294967296)) and v_e or v_t)
F.fTA(t392, t393, v_t)
I32[arshift((v_A + 20), 2)] = tobit((v_t + I32[arshift((v_A + 20), 2)]))
do return bor(0, v_e) end
end
end
UA[55] = function(v_A, v_r, v_e, v_t, v_a, v_u, v_c)
local v_s, v_b, v_v, v_p, v_d, v_h, v_k, v_y, v_w, v_C, v_E, v_I = 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
v_A = tobit(v_A)
v_r = tobit(v_r)
v_e = tobit(v_e)
v_t = tobit(v_t)
v_a = tobit(v_a)
v_u = tobit(v_u)
v_c = tobit(v_c)
v_b = 0
v_v = 0
v_p = 0
v_d = 0
v_h = 0
v_k = 0
v_y = 0
v_w = 0
v_C = 0
v_E = 0
v_I = 0
do
v_s = tobit((B - 528))
B = v_s
v_k = (-3)
v_b = I32[8012]
if (not (bor(((not (v_b ~= 0)) and 1 or 0), ((not (U8[bor(0, v_b)] ~= 0)) and 1 or 0)) ~= 0)) then
do
if (I32[8014] ~= 0) then
do
do
v_k = (-1)
local t394 = ((not ((tobit(v_r) % 4294967296) < 256)) and 1 or 0)
if t394 ~= 0 then
I8[tobit((v_s + 480))] = tobit(0)
F.fTA(tobit((v_s + 224)), v_A, 256)
I8[tobit((v_s + 192))] = tobit(0)
v_b = F.fY()
v_y = F.fD(v_b)
F.fL(v_b)
v_b = v_y
v_v = bor(bor(bor(U8[tobit((v_b + 12))], lshift(U8[tobit((v_b + 13))], 8)), lshift(U8[tobit((v_b + 14))], 16)), lshift(U8[tobit((v_b + 15))], 24))
I32[arshift((v_s + 504), 2)] = tobit(bor(bor(bor(U8[tobit((v_b + 8))], lshift(U8[tobit((v_b + 9))], 8)), lshift(U8[tobit((v_b + 10))], 16)), lshift(U8[tobit((v_b + 11))], 24)))
I32[arshift((v_s + 508), 2)] = tobit(v_v)
v_v = bor(bor(bor(U8[tobit((v_b + 4))], lshift(U8[tobit((v_b + 5))], 8)), lshift(U8[tobit((v_b + 6))], 16)), lshift(U8[tobit((v_b + 7))], 24))
I32[arshift((v_s + 496), 2)] = tobit(bor(bor(bor(U8[bor(0, v_b)], lshift(U8[tobit((v_b + 1))], 8)), lshift(U8[tobit((v_b + 2))], 16)), lshift(U8[tobit((v_b + 3))], 24)))
I32[arshift((v_s + 500), 2)] = tobit(v_v)
v_d = tobit((B - 288))
B = v_d
v_v = F.fPA(F.fm(257), 0, 257)
F.fLA(tobit((v_d + 8)))
F.fZ(tobit((v_d + 8)), v_b, 256)
F.fR(tobit((v_d + 8)), 0, 256, tobit((v_s + 496)), tobit((v_s + 224)), v_v)
F.fhA(tobit((v_d + 8)))
B = tobit((v_d + 288))
t394 = v_v
end
if (t394 ~= 0) then
do
do
v_b = v_v
v_v = bor(bor(bor(U8[tobit((v_b + 8))], lshift(U8[tobit((v_b + 9))], 8)), lshift(U8[tobit((v_b + 10))], 16)), lshift(U8[tobit((v_b + 11))], 24))
v_d = bor(bor(bor(U8[tobit((v_b + 12))], lshift(U8[tobit((v_b + 13))], 8)), lshift(U8[tobit((v_b + 14))], 16)), lshift(U8[tobit((v_b + 15))], 24))
v_k = bor(bor(bor(U8[bor(0, v_b)], lshift(U8[tobit((v_b + 1))], 8)), lshift(U8[tobit((v_b + 2))], 16)), lshift(U8[tobit((v_b + 3))], 24))
v_p = bor(bor(bor(U8[tobit((v_b + 4))], lshift(U8[tobit((v_b + 5))], 8)), lshift(U8[tobit((v_b + 6))], 16)), lshift(U8[tobit((v_b + 7))], 24))
v_w = bor(bor(bor(U8[tobit((v_b + 20))], lshift(U8[tobit((v_b + 21))], 8)), lshift(U8[tobit((v_b + 22))], 16)), lshift(U8[tobit((v_b + 23))], 24))
I32[arshift((v_s + 208), 2)] = tobit(bor(bor(bor(U8[tobit((v_b + 16))], lshift(U8[tobit((v_b + 17))], 8)), lshift(U8[tobit((v_b + 18))], 16)), lshift(U8[tobit((v_b + 19))], 24)))
I32[arshift((v_s + 212), 2)] = tobit(v_w)
I16[arshift((v_s + 216), 1)] = tobit(bor(U8[tobit((v_b + 24))], lshift(U8[tobit((v_b + 25))], 8)))
v_w = U8[tobit((v_b + 26))]
F.fTA(tobit((v_s - (-64))), tobit((v_b + 128)), 128)
F.fL(v_y)
F.fL(v_b)
I32[arshift((v_s + 48), 2)] = tobit(v_k)
I32[arshift((v_s + 52), 2)] = tobit(v_p)
I8[tobit((v_s + 56))] = tobit(0)
v_y = F.fvA(tobit((v_s + 48)))
I32[arshift((v_s + 48), 2)] = tobit(v_v)
I32[arshift((v_s + 52), 2)] = tobit(v_d)
v_I = F.fvA(tobit((v_s + 48)))
I16[arshift((v_s + 40), 1)] = tobit(U16[arshift((v_s + 216), 1)])
I8[tobit((v_s + 42))] = tobit(0)
v_b = I32[arshift((v_s + 212), 2)]
I32[arshift((v_s + 32), 2)] = tobit(I32[arshift((v_s + 208), 2)])
I32[arshift((v_s + 36), 2)] = tobit(v_b)
I32[arshift(v_s, 2)] = tobit(F.fvA(tobit((v_s + 32))))
v_d = tobit((B - 16))
B = v_d
I32[arshift((v_d + 12), 2)] = tobit(v_s)
v_b = tobit((B - 160))
B = v_b
F.fTA(tobit((v_b + 8)), 12304, 144)
v_v = tobit((v_s + 32))
I32[arshift((v_b + 52), 2)] = tobit(v_v)
I32[arshift((v_b + 28), 2)] = tobit(v_v)
v_k = tobit(((-2) - v_v))
v_k = (((tobit(v_k) % 4294967296) < 11) and v_k or 11)
I32[arshift((v_b + 56), 2)] = tobit(v_k)
v_v = tobit((v_v + v_k))
I32[arshift((v_b + 36), 2)] = tobit(v_v)
I32[arshift((v_b + 24), 2)] = tobit(v_v)
F.ffA(tobit((v_b + 8)), 10633, v_s, 52, 53)
if (v_k ~= 0) then
v_v = I32[arshift((v_b + 28), 2)]
I8[tobit((v_v - ((bor(0, v_v) == I32[arshift((v_b + 24), 2)]) and 1 or 0)))] = tobit(0)
end
B = tobit((v_b + 160))
B = tobit((v_d + 16))
v_k = (-2)
v_v = I32[8014]
v_d = tobit((v_s + 32))
v_b = 0
v_p = 10
while true do
v_h = bxor(I32[arshift((12512 + lshift(bxor(U8[tobit((v_b + v_d))], band(255, v_h)), 2)), 2)], (rshift(v_h, 8) % 4294967296))
v_h = bxor(I32[arshift((12512 + lshift(bxor(U8[tobit((v_d + bor(1, v_b)))], band(255, v_h)), 2)), 2)], (rshift(v_h, 8) % 4294967296))
v_b = tobit((v_b + 2))
v_p = tobit((v_p - 2))
if not (v_p ~= 0) then goto B354 end
do
end
::C354::
end
end
::B354::
v_b = imul(v_h, 4097)
v_b = imul(bxor((rshift(v_b, 22) % 4294967296), v_b), 17)
v_b = imul(bxor((rshift(v_b, 9) % 4294967296), v_b), 1025)
v_b = imul(bxor((rshift(v_b, 2) % 4294967296), v_b), 129)
v_h = I32[arshift(v_v, 2)]
v_b = tobit(fmod((tobit(imul(bxor((rshift(v_b, 15) % 4294967296), (rshift(v_b, 3) % 4294967296)), (-1640531535))) % 4294967296), (tobit(v_h) % 4294967296)))
v_v = I32[arshift((v_v + 8), 2)]
do
do
do
do
v_p = tobit((lshift(v_b, 4) + v_v))
local t397 = ((bor(((not (I32[arshift((8 + v_p), 2)] ~= 0)) and 1 or 0), ((10 ~= I32[arshift((v_p + 4), 2)]) and 1 or 0)) ~= 0) or (F.fSA(I32[arshift((v_v + lshift(v_b, 4)), 2)], v_d, 10) ~= 0))
if t397 then
local t395 = v_v
v_b = tobit(fmod((tobit((v_b + 1)) % 4294967296), (tobit(v_h) % 4294967296)))
local t396 = (not (I32[arshift((8 + tobit((t395 + lshift(v_b, 4)))), 2)] ~= 0))
if not t396 then
v_p = tobit((v_v + lshift(v_b, 4)))
t396 = (10 ~= I32[arshift((4 + v_p), 2)])
end
t397 = (t396 or (F.fSA(I32[arshift(v_p, 2)], v_d, 10) ~= 0))
end
local t399 = t397
if t399 then
local t398 = v_v
v_b = tobit(fmod((tobit((v_b + 1)) % 4294967296), (tobit(v_h) % 4294967296)))
v_p = tobit((t398 + lshift(v_b, 4)))
t399 = ((bor(((not (I32[arshift((8 + v_p), 2)] ~= 0)) and 1 or 0), ((10 ~= I32[arshift((v_p + 4), 2)]) and 1 or 0)) ~= 0) or (F.fSA(I32[arshift((v_v + lshift(v_b, 4)), 2)], v_d, 10) ~= 0))
end
local t402 = t399
if t402 then
local t400 = v_v
v_b = tobit(fmod((tobit((v_b + 1)) % 4294967296), (tobit(v_h) % 4294967296)))
local t401 = (not (I32[arshift((8 + tobit((t400 + lshift(v_b, 4)))), 2)] ~= 0))
if not t401 then
v_p = tobit((v_v + lshift(v_b, 4)))
t401 = (10 ~= I32[arshift((4 + v_p), 2)])
end
t402 = (t401 or (F.fSA(I32[arshift(v_p, 2)], v_d, 10) ~= 0))
end
local t404 = t402
if t404 then
local t403 = v_v
v_b = tobit(fmod((tobit((v_b + 1)) % 4294967296), (tobit(v_h) % 4294967296)))
v_p = tobit((t403 + lshift(v_b, 4)))
t404 = ((bor(((not (I32[arshift((8 + v_p), 2)] ~= 0)) and 1 or 0), ((10 ~= I32[arshift((v_p + 4), 2)]) and 1 or 0)) ~= 0) or (F.fSA(I32[arshift((v_v + lshift(v_b, 4)), 2)], v_d, 10) ~= 0))
end
local t407 = t404
if t407 then
local t405 = v_v
v_b = tobit(fmod((tobit((v_b + 1)) % 4294967296), (tobit(v_h) % 4294967296)))
local t406 = (not (I32[arshift((8 + tobit((t405 + lshift(v_b, 4)))), 2)] ~= 0))
if not t406 then
v_p = tobit((v_v + lshift(v_b, 4)))
t406 = (10 ~= I32[arshift((4 + v_p), 2)])
end
t407 = (t406 or (F.fSA(I32[arshift(v_p, 2)], v_d, 10) ~= 0))
end
local t409 = t407
if t409 then
local t408 = v_v
v_b = tobit(fmod((tobit((v_b + 1)) % 4294967296), (tobit(v_h) % 4294967296)))
v_p = tobit((t408 + lshift(v_b, 4)))
t409 = ((bor(((not (I32[arshift((8 + v_p), 2)] ~= 0)) and 1 or 0), ((10 ~= I32[arshift((v_p + 4), 2)]) and 1 or 0)) ~= 0) or (F.fSA(I32[arshift((v_v + lshift(v_b, 4)), 2)], v_d, 10) ~= 0))
end
if t409 then
do
do
v_p = 0
local t410 = v_v
v_b = tobit(fmod((tobit((v_b + 1)) % 4294967296), (tobit(v_h) % 4294967296)))
if (not (I32[arshift((8 + tobit((t410 + lshift(v_b, 4)))), 2)] ~= 0)) then
goto L355
end
end
v_h = tobit((v_v + lshift(v_b, 4)))
if (10 ~= I32[arshift((4 + v_h), 2)]) then
goto L355
end
if (F.fSA(I32[arshift(v_h, 2)], v_d, 10) ~= 0) then
goto L355
end
end
end
end
v_p = I32[arshift((12 + tobit((v_v + lshift(v_b, 4)))), 2)]
end
end
::L355::
end
do
if (not (bor(((not (v_p ~= 0)) and 1 or 0), ((not (I32[arshift((v_p + 8), 2)] ~= 0)) and 1 or 0)) ~= 0)) then
do
do
if (v_a ~= 0) then
I32[arshift(v_a, 2)] = tobit(((1 == bor(0, v_w)) and 1 or 0))
end
v_a = tobit((v_A + 128))
v_b = F.fTA(v_a, tobit((v_s - (-64))), 128)
if (U8[tobit((v_s + 64))] ~= 0) then
v_A = tobit((v_r - 128))
else
v_a = tobit((v_A + 256))
v_A = F.fSA(tobit((v_s - (-64))), bor((v_s - (-64)), 1), 127)
v_a = ((v_A ~= 0) and v_b or v_a)
v_A = tobit((((v_A ~= 0) and (-128) or (-256)) + v_r))
end
v_b = I32[arshift((v_p + 4), 2)]
v_v = I32[arshift((v_p + 8), 2)]
v_d = tobit((B - 48))
B = v_d
v_C = F.fY()
v_E = F.fD(v_C)
v_r = v_E
v_h = bor(bor(bor(U8[tobit((v_r + 12))], lshift(U8[tobit((v_r + 13))], 8)), lshift(U8[tobit((v_r + 14))], 16)), lshift(U8[tobit((v_r + 15))], 24))
I32[arshift((v_d + 24), 2)] = tobit(bor(bor(bor(U8[tobit((v_r + 8))], lshift(U8[tobit((v_r + 9))], 8)), lshift(U8[tobit((v_r + 10))], 16)), lshift(U8[tobit((v_r + 11))], 24)))
I32[arshift((v_d + 28), 2)] = tobit(v_h)
v_h = bor(bor(bor(U8[tobit((v_r + 4))], lshift(U8[tobit((v_r + 5))], 8)), lshift(U8[tobit((v_r + 6))], 16)), lshift(U8[tobit((v_r + 7))], 24))
I32[arshift((v_d + 16), 2)] = tobit(bor(bor(bor(U8[bor(0, v_r)], lshift(U8[tobit((v_r + 1))], 8)), lshift(U8[tobit((v_r + 2))], 16)), lshift(U8[tobit((v_r + 3))], 24)))
I32[arshift((v_d + 20), 2)] = tobit(v_h)
v_p = F.fuA(v_b, v_v, tobit((v_d + 16)), v_r, tobit((v_d + 12)))
v_w = I32[8013]
local t411 = v_d
v_r = tobit((v_w + v_t))
v_b = tobit((t411 - band((32 + v_r), (-16))))
B = v_b
v_b = F.fPA(v_b, 0, tobit((v_r + 17)))
v_r = v_b
v_v = tobit((v_p + imul(v_I, 17)))
v_h = bor(bor(bor(U8[tobit((v_v + 12))], lshift(U8[tobit((v_v + 13))], 8)), lshift(U8[tobit((v_v + 14))], 16)), lshift(U8[tobit((v_v + 15))], 24))
v_k = bor(bor(bor(U8[tobit((v_v + 8))], lshift(U8[tobit((v_v + 9))], 8)), lshift(U8[tobit((v_v + 10))], 16)), lshift(U8[tobit((v_v + 11))], 24))
I8[tobit((v_r + 8))] = tobit(v_k)
I8[tobit((v_r + 9))] = tobit((rshift(v_k, 8) % 4294967296))
I8[tobit((v_r + 10))] = tobit((rshift(v_k, 16) % 4294967296))
I8[tobit((v_r + 11))] = tobit((rshift(v_k, 24) % 4294967296))
I8[tobit((v_r + 12))] = tobit(v_h)
I8[tobit((v_r + 13))] = tobit((rshift(v_h, 8) % 4294967296))
I8[tobit((v_r + 14))] = tobit((rshift(v_h, 16) % 4294967296))
I8[tobit((v_r + 15))] = tobit((rshift(v_h, 24) % 4294967296))
v_h = bor(bor(bor(U8[tobit((v_v + 4))], lshift(U8[tobit((v_v + 5))], 8)), lshift(U8[tobit((v_v + 6))], 16)), lshift(U8[tobit((v_v + 7))], 24))
v_v = bor(bor(bor(U8[bor(0, v_v)], lshift(U8[tobit((v_v + 1))], 8)), lshift(U8[tobit((v_v + 2))], 16)), lshift(U8[tobit((v_v + 3))], 24))
I8[bor(0, v_r)] = tobit(v_v)
I8[tobit((v_r + 1))] = tobit((rshift(v_v, 8) % 4294967296))
I8[tobit((v_r + 2))] = tobit((rshift(v_v, 16) % 4294967296))
I8[tobit((v_r + 3))] = tobit((rshift(v_v, 24) % 4294967296))
I8[tobit((v_r + 4))] = tobit(v_h)
I8[tobit((v_r + 5))] = tobit((rshift(v_h, 8) % 4294967296))
I8[tobit((v_r + 6))] = tobit((rshift(v_h, 16) % 4294967296))
I8[tobit((v_r + 7))] = tobit((rshift(v_h, 24) % 4294967296))
v_r = F.fTA(tobit((v_r + 16)), I32[8012], v_w)
if (v_t ~= 0) then
F.fTA(tobit((v_r + v_w)), v_e, v_t)
end
v_r = F.fD(v_b)
F.fL(v_C)
F.fL(v_E)
F.fL(v_p)
B = tobit((v_d + 48))
end
do
do
do
do
do
do
if (bor(0, v_y) <= 31344422) then
if (bor(0, v_y) <= 29344483) then
if (21123123 == bor(0, v_y)) then
goto L361
end
if (21132184 ~= bor(0, v_y)) then
goto L356
end
I8[tobit((v_s + 16))] = tobit(0)
I32[arshift((v_s + 8), 2)] = tobit(0)
I32[arshift((v_s + 12), 2)] = tobit(0)
v_e = bor(bor(bor(U8[tobit((v_r + 4))], lshift(U8[tobit((v_r + 5))], 8)), lshift(U8[tobit((v_r + 6))], 16)), lshift(U8[tobit((v_r + 7))], 24))
I32[arshift((v_s + 8), 2)] = tobit(bor(bor(bor(U8[bor(0, v_r)], lshift(U8[tobit((v_r + 1))], 8)), lshift(U8[tobit((v_r + 2))], 16)), lshift(U8[tobit((v_r + 3))], 24)))
I32[arshift((v_s + 12), 2)] = tobit(v_e)
v_A = F.fcA(v_a, v_A, tobit((v_s + 8)), tobit((v_s + 8)), tobit((v_s + 28)))
I8[tobit((v_s + 512))] = tobit(0)
I32[arshift((v_s + 504), 2)] = tobit(0)
I32[arshift((v_s + 508), 2)] = tobit(0)
I32[arshift((v_s + 496), 2)] = tobit(0)
I32[arshift((v_s + 500), 2)] = tobit(0)
v_e = bor(bor(bor(U8[tobit((v_r + 4))], lshift(U8[tobit((v_r + 5))], 8)), lshift(U8[tobit((v_r + 6))], 16)), lshift(U8[tobit((v_r + 7))], 24))
I32[arshift((v_s + 496), 2)] = tobit(bor(bor(bor(U8[bor(0, v_r)], lshift(U8[tobit((v_r + 1))], 8)), lshift(U8[tobit((v_r + 2))], 16)), lshift(U8[tobit((v_r + 3))], 24)))
I32[arshift((v_s + 500), 2)] = tobit(v_e)
v_e = bor(bor(bor(U8[tobit((v_r + 12))], lshift(U8[tobit((v_r + 13))], 8)), lshift(U8[tobit((v_r + 14))], 16)), lshift(U8[tobit((v_r + 15))], 24))
I32[arshift((v_s + 504), 2)] = tobit(bor(bor(bor(U8[tobit((v_r + 8))], lshift(U8[tobit((v_r + 9))], 8)), lshift(U8[tobit((v_r + 10))], 16)), lshift(U8[tobit((v_r + 11))], 24)))
I32[arshift((v_s + 508), 2)] = tobit(v_e)
I32[arshift(v_u, 2)] = tobit(F.fuA(v_A, I32[arshift((v_s + 28), 2)], tobit((v_s + 496)), v_r, v_c))
F.fL(v_A)
goto L356
end
if (29344484 == bor(0, v_y)) then
goto L358
end
if (29859828 ~= bor(0, v_y)) then
goto L356
end
I8[tobit((v_s + 512))] = tobit(0)
I32[arshift((v_s + 504), 2)] = tobit(0)
I32[arshift((v_s + 508), 2)] = tobit(0)
I32[arshift((v_s + 496), 2)] = tobit(0)
I32[arshift((v_s + 500), 2)] = tobit(0)
v_e = bor(bor(bor(U8[tobit((v_r + 4))], lshift(U8[tobit((v_r + 5))], 8)), lshift(U8[tobit((v_r + 6))], 16)), lshift(U8[tobit((v_r + 7))], 24))
I32[arshift((v_s + 496), 2)] = tobit(bor(bor(bor(U8[bor(0, v_r)], lshift(U8[tobit((v_r + 1))], 8)), lshift(U8[tobit((v_r + 2))], 16)), lshift(U8[tobit((v_r + 3))], 24)))
I32[arshift((v_s + 500), 2)] = tobit(v_e)
v_e = bor(bor(bor(U8[tobit((v_r + 12))], lshift(U8[tobit((v_r + 13))], 8)), lshift(U8[tobit((v_r + 14))], 16)), lshift(U8[tobit((v_r + 15))], 24))
I32[arshift((v_s + 504), 2)] = tobit(bor(bor(bor(U8[tobit((v_r + 8))], lshift(U8[tobit((v_r + 9))], 8)), lshift(U8[tobit((v_r + 10))], 16)), lshift(U8[tobit((v_r + 11))], 24)))
I32[arshift((v_s + 508), 2)] = tobit(v_e)
v_A = F.fuA(v_a, v_A, tobit((v_s + 496)), v_r, tobit((v_s + 28)))
I8[tobit((v_s + 13))] = tobit(0)
I8[tobit((v_s + 14))] = tobit(0)
I8[tobit((v_s + 15))] = tobit(0)
I8[tobit((v_s + 16))] = tobit(0)
I8[tobit((v_s + 17))] = tobit(0)
I8[tobit((v_s + 18))] = tobit(0)
I8[tobit((v_s + 19))] = tobit(0)
I8[tobit((v_s + 20))] = tobit(0)
I32[arshift((v_s + 8), 2)] = tobit(0)
I32[arshift((v_s + 12), 2)] = tobit(0)
I32[arshift((v_s + 16), 2)] = tobit(bor(bor(bor(U8[tobit((v_r + 8))], lshift(U8[tobit((v_r + 9))], 8)), lshift(U8[tobit((v_r + 10))], 16)), lshift(U8[tobit((v_r + 11))], 24)))
v_e = bor(bor(bor(U8[tobit((v_r + 4))], lshift(U8[tobit((v_r + 5))], 8)), lshift(U8[tobit((v_r + 6))], 16)), lshift(U8[tobit((v_r + 7))], 24))
I32[arshift((v_s + 8), 2)] = tobit(bor(bor(bor(U8[bor(0, v_r)], lshift(U8[tobit((v_r + 1))], 8)), lshift(U8[tobit((v_r + 2))], 16)), lshift(U8[tobit((v_r + 3))], 24)))
I32[arshift((v_s + 12), 2)] = tobit(v_e)
I32[arshift(v_u, 2)] = tobit(F.fnA(v_A, I32[arshift((v_s + 28), 2)], tobit((v_s + 8)), v_r))
if (v_c ~= 0) then
I32[arshift(v_c, 2)] = tobit(I32[arshift((v_s + 28), 2)])
end
F.fL(v_A)
goto L356
end
if (bor(0, v_y) <= 34232880) then
if (31344423 == bor(0, v_y)) then
goto L357
end
if (31932881 ~= bor(0, v_y)) then
goto L356
end
I8[tobit((v_s + 512))] = tobit(0)
I32[arshift((v_s + 504), 2)] = tobit(0)
I32[arshift((v_s + 508), 2)] = tobit(0)
I32[arshift((v_s + 496), 2)] = tobit(0)
I32[arshift((v_s + 500), 2)] = tobit(0)
v_e = bor(bor(bor(U8[tobit((v_r + 4))], lshift(U8[tobit((v_r + 5))], 8)), lshift(U8[tobit((v_r + 6))], 16)), lshift(U8[tobit((v_r + 7))], 24))
I32[arshift((v_s + 496), 2)] = tobit(bor(bor(bor(U8[bor(0, v_r)], lshift(U8[tobit((v_r + 1))], 8)), lshift(U8[tobit((v_r + 2))], 16)), lshift(U8[tobit((v_r + 3))], 24)))
I32[arshift((v_s + 500), 2)] = tobit(v_e)
v_e = bor(bor(bor(U8[tobit((v_r + 12))], lshift(U8[tobit((v_r + 13))], 8)), lshift(U8[tobit((v_r + 14))], 16)), lshift(U8[tobit((v_r + 15))], 24))
I32[arshift((v_s + 504), 2)] = tobit(bor(bor(bor(U8[tobit((v_r + 8))], lshift(U8[tobit((v_r + 9))], 8)), lshift(U8[tobit((v_r + 10))], 16)), lshift(U8[tobit((v_r + 11))], 24)))
I32[arshift((v_s + 508), 2)] = tobit(v_e)
v_A = F.fuA(v_a, v_A, tobit((v_s + 496)), v_r, tobit((v_s + 28)))
I8[tobit((v_s + 16))] = tobit(0)
I32[arshift((v_s + 8), 2)] = tobit(0)
I32[arshift((v_s + 12), 2)] = tobit(0)
v_e = bor(bor(bor(U8[tobit((v_r + 4))], lshift(U8[tobit((v_r + 5))], 8)), lshift(U8[tobit((v_r + 6))], 16)), lshift(U8[tobit((v_r + 7))], 24))
I32[arshift((v_s + 8), 2)] = tobit(bor(bor(bor(U8[bor(0, v_r)], lshift(U8[tobit((v_r + 1))], 8)), lshift(U8[tobit((v_r + 2))], 16)), lshift(U8[tobit((v_r + 3))], 24)))
I32[arshift((v_s + 12), 2)] = tobit(v_e)
I32[arshift(v_u, 2)] = tobit(F.fcA(v_A, I32[arshift((v_s + 28), 2)], tobit((v_s + 8)), tobit((v_s + 8)), v_c))
F.fL(v_A)
goto L356
end
if (34232881 == bor(0, v_y)) then
goto L359
end
if (34941028 == bor(0, v_y)) then
goto L360
end
if (94859123 ~= bor(0, v_y)) then
goto L356
end
I8[tobit((v_s + 13))] = tobit(0)
I8[tobit((v_s + 14))] = tobit(0)
I8[tobit((v_s + 15))] = tobit(0)
I8[tobit((v_s + 16))] = tobit(0)
I8[tobit((v_s + 17))] = tobit(0)
I8[tobit((v_s + 18))] = tobit(0)
I8[tobit((v_s + 19))] = tobit(0)
I8[tobit((v_s + 20))] = tobit(0)
I32[arshift((v_s + 8), 2)] = tobit(0)
I32[arshift((v_s + 12), 2)] = tobit(0)
I32[arshift((v_s + 16), 2)] = tobit(bor(bor(bor(U8[tobit((v_r + 8))], lshift(U8[tobit((v_r + 9))], 8)), lshift(U8[tobit((v_r + 10))], 16)), lshift(U8[tobit((v_r + 11))], 24)))
v_e = bor(bor(bor(U8[tobit((v_r + 4))], lshift(U8[tobit((v_r + 5))], 8)), lshift(U8[tobit((v_r + 6))], 16)), lshift(U8[tobit((v_r + 7))], 24))
I32[arshift((v_s + 8), 2)] = tobit(bor(bor(bor(U8[bor(0, v_r)], lshift(U8[tobit((v_r + 1))], 8)), lshift(U8[tobit((v_r + 2))], 16)), lshift(U8[tobit((v_r + 3))], 24)))
I32[arshift((v_s + 12), 2)] = tobit(v_e)
v_e = F.fnA(v_a, v_A, tobit((v_s + 8)), v_r)
I8[tobit((v_s + 512))] = tobit(0)
I32[arshift((v_s + 504), 2)] = tobit(0)
I32[arshift((v_s + 508), 2)] = tobit(0)
I32[arshift((v_s + 496), 2)] = tobit(0)
I32[arshift((v_s + 500), 2)] = tobit(0)
v_t = bor(bor(bor(U8[tobit((v_r + 4))], lshift(U8[tobit((v_r + 5))], 8)), lshift(U8[tobit((v_r + 6))], 16)), lshift(U8[tobit((v_r + 7))], 24))
I32[arshift((v_s + 496), 2)] = tobit(bor(bor(bor(U8[bor(0, v_r)], lshift(U8[tobit((v_r + 1))], 8)), lshift(U8[tobit((v_r + 2))], 16)), lshift(U8[tobit((v_r + 3))], 24)))
I32[arshift((v_s + 500), 2)] = tobit(v_t)
v_t = bor(bor(bor(U8[tobit((v_r + 12))], lshift(U8[tobit((v_r + 13))], 8)), lshift(U8[tobit((v_r + 14))], 16)), lshift(U8[tobit((v_r + 15))], 24))
I32[arshift((v_s + 504), 2)] = tobit(bor(bor(bor(U8[tobit((v_r + 8))], lshift(U8[tobit((v_r + 9))], 8)), lshift(U8[tobit((v_r + 10))], 16)), lshift(U8[tobit((v_r + 11))], 24)))
I32[arshift((v_s + 508), 2)] = tobit(v_t)
I32[arshift(v_u, 2)] = tobit(F.fuA(v_e, v_A, tobit((v_s + 496)), v_r, v_c))
F.fL(v_e)
goto L356
end
::L361::
I8[tobit((v_s + 512))] = tobit(0)
I32[arshift((v_s + 504), 2)] = tobit(0)
I32[arshift((v_s + 508), 2)] = tobit(0)
I32[arshift((v_s + 496), 2)] = tobit(0)
I32[arshift((v_s + 500), 2)] = tobit(0)
v_e = bor(bor(bor(U8[tobit((v_r + 4))], lshift(U8[tobit((v_r + 5))], 8)), lshift(U8[tobit((v_r + 6))], 16)), lshift(U8[tobit((v_r + 7))], 24))
I32[arshift((v_s + 496), 2)] = tobit(bor(bor(bor(U8[bor(0, v_r)], lshift(U8[tobit((v_r + 1))], 8)), lshift(U8[tobit((v_r + 2))], 16)), lshift(U8[tobit((v_r + 3))], 24)))
I32[arshift((v_s + 500), 2)] = tobit(v_e)
v_e = bor(bor(bor(U8[tobit((v_r + 12))], lshift(U8[tobit((v_r + 13))], 8)), lshift(U8[tobit((v_r + 14))], 16)), lshift(U8[tobit((v_r + 15))], 24))
I32[arshift((v_s + 504), 2)] = tobit(bor(bor(bor(U8[tobit((v_r + 8))], lshift(U8[tobit((v_r + 9))], 8)), lshift(U8[tobit((v_r + 10))], 16)), lshift(U8[tobit((v_r + 11))], 24)))
I32[arshift((v_s + 508), 2)] = tobit(v_e)
v_A = F.fuA(v_a, v_A, tobit((v_s + 496)), v_r, tobit((v_s + 8)))
I8[tobit((v_s + 512))] = tobit(0)
I32[arshift((v_s + 504), 2)] = tobit(0)
I32[arshift((v_s + 508), 2)] = tobit(0)
I32[arshift((v_s + 496), 2)] = tobit(0)
I32[arshift((v_s + 500), 2)] = tobit(0)
v_e = bor(bor(bor(U8[tobit((v_r + 4))], lshift(U8[tobit((v_r + 5))], 8)), lshift(U8[tobit((v_r + 6))], 16)), lshift(U8[tobit((v_r + 7))], 24))
I32[arshift((v_s + 496), 2)] = tobit(bor(bor(bor(U8[bor(0, v_r)], lshift(U8[tobit((v_r + 1))], 8)), lshift(U8[tobit((v_r + 2))], 16)), lshift(U8[tobit((v_r + 3))], 24)))
I32[arshift((v_s + 500), 2)] = tobit(v_e)
v_e = bor(bor(bor(U8[tobit((v_r + 12))], lshift(U8[tobit((v_r + 13))], 8)), lshift(U8[tobit((v_r + 14))], 16)), lshift(U8[tobit((v_r + 15))], 24))
I32[arshift((v_s + 504), 2)] = tobit(bor(bor(bor(U8[tobit((v_r + 8))], lshift(U8[tobit((v_r + 9))], 8)), lshift(U8[tobit((v_r + 10))], 16)), lshift(U8[tobit((v_r + 11))], 24)))
I32[arshift((v_s + 508), 2)] = tobit(v_e)
I32[arshift(v_u, 2)] = tobit(F.fuA(v_A, I32[arshift((v_s + 8), 2)], tobit((v_s + 496)), v_r, v_c))
F.fL(v_A)
goto L356
end
::L360::
I8[tobit((v_s + 504))] = tobit(0)
I32[arshift((v_s + 496), 2)] = tobit(0)
I32[arshift((v_s + 500), 2)] = tobit(0)
v_e = bor(bor(bor(U8[tobit((v_r + 4))], lshift(U8[tobit((v_r + 5))], 8)), lshift(U8[tobit((v_r + 6))], 16)), lshift(U8[tobit((v_r + 7))], 24))
v_t = bor(bor(bor(U8[bor(0, v_r)], lshift(U8[tobit((v_r + 1))], 8)), lshift(U8[tobit((v_r + 2))], 16)), lshift(U8[tobit((v_r + 3))], 24))
I32[arshift((v_s + 496), 2)] = tobit(v_t)
I32[arshift((v_s + 500), 2)] = tobit(v_e)
I32[arshift((v_s + 8), 2)] = tobit(v_t)
I32[arshift((v_s + 12), 2)] = tobit(v_e)
I8[tobit((v_s + 16))] = tobit(0)
v_A = F.fcA(v_a, v_A, tobit((v_s + 8)), tobit((v_s + 496)), tobit((v_s + 28)))
I8[tobit((v_s + 16))] = tobit(0)
v_e = I32[arshift((v_s + 500), 2)]
I32[arshift((v_s + 8), 2)] = tobit(I32[arshift((v_s + 496), 2)])
I32[arshift((v_s + 12), 2)] = tobit(v_e)
I32[arshift(v_u, 2)] = tobit(F.fcA(v_A, I32[arshift((v_s + 28), 2)], tobit((v_s + 8)), tobit((v_s + 496)), v_c))
F.fL(v_A)
goto L356
end
::L359::
I8[tobit((v_s + 501))] = tobit(0)
I8[tobit((v_s + 502))] = tobit(0)
I8[tobit((v_s + 503))] = tobit(0)
I8[tobit((v_s + 504))] = tobit(0)
I8[tobit((v_s + 505))] = tobit(0)
I8[tobit((v_s + 506))] = tobit(0)
I8[tobit((v_s + 507))] = tobit(0)
I8[tobit((v_s + 508))] = tobit(0)
I32[arshift((v_s + 496), 2)] = tobit(0)
I32[arshift((v_s + 500), 2)] = tobit(0)
I32[arshift((v_s + 504), 2)] = tobit(bor(bor(bor(U8[tobit((v_r + 8))], lshift(U8[tobit((v_r + 9))], 8)), lshift(U8[tobit((v_r + 10))], 16)), lshift(U8[tobit((v_r + 11))], 24)))
v_e = bor(bor(bor(U8[tobit((v_r + 4))], lshift(U8[tobit((v_r + 5))], 8)), lshift(U8[tobit((v_r + 6))], 16)), lshift(U8[tobit((v_r + 7))], 24))
I32[arshift((v_s + 496), 2)] = tobit(bor(bor(bor(U8[bor(0, v_r)], lshift(U8[tobit((v_r + 1))], 8)), lshift(U8[tobit((v_r + 2))], 16)), lshift(U8[tobit((v_r + 3))], 24)))
I32[arshift((v_s + 500), 2)] = tobit(v_e)
v_e = F.fnA(v_a, v_A, tobit((v_s + 496)), v_r)
I8[tobit((v_s + 501))] = tobit(0)
I8[tobit((v_s + 502))] = tobit(0)
I8[tobit((v_s + 503))] = tobit(0)
I8[tobit((v_s + 504))] = tobit(0)
I8[tobit((v_s + 505))] = tobit(0)
I8[tobit((v_s + 506))] = tobit(0)
I8[tobit((v_s + 507))] = tobit(0)
I8[tobit((v_s + 508))] = tobit(0)
I32[arshift((v_s + 496), 2)] = tobit(0)
I32[arshift((v_s + 500), 2)] = tobit(0)
I32[arshift((v_s + 504), 2)] = tobit(bor(bor(bor(U8[tobit((v_r + 8))], lshift(U8[tobit((v_r + 9))], 8)), lshift(U8[tobit((v_r + 10))], 16)), lshift(U8[tobit((v_r + 11))], 24)))
v_t = bor(bor(bor(U8[tobit((v_r + 4))], lshift(U8[tobit((v_r + 5))], 8)), lshift(U8[tobit((v_r + 6))], 16)), lshift(U8[tobit((v_r + 7))], 24))
I32[arshift((v_s + 496), 2)] = tobit(bor(bor(bor(U8[bor(0, v_r)], lshift(U8[tobit((v_r + 1))], 8)), lshift(U8[tobit((v_r + 2))], 16)), lshift(U8[tobit((v_r + 3))], 24)))
I32[arshift((v_s + 500), 2)] = tobit(v_t)
I32[arshift(v_u, 2)] = tobit(F.fnA(v_e, v_A, tobit((v_s + 496)), v_r))
if (v_c ~= 0) then
I32[arshift(v_c, 2)] = tobit(v_A)
end
F.fL(v_e)
goto L356
end
::L358::
I8[tobit((v_s + 501))] = tobit(0)
I8[tobit((v_s + 502))] = tobit(0)
I8[tobit((v_s + 503))] = tobit(0)
I8[tobit((v_s + 504))] = tobit(0)
I8[tobit((v_s + 505))] = tobit(0)
I8[tobit((v_s + 506))] = tobit(0)
I8[tobit((v_s + 507))] = tobit(0)
I8[tobit((v_s + 508))] = tobit(0)
I32[arshift((v_s + 496), 2)] = tobit(0)
I32[arshift((v_s + 500), 2)] = tobit(0)
I32[arshift((v_s + 504), 2)] = tobit(bor(bor(bor(U8[tobit((v_r + 8))], lshift(U8[tobit((v_r + 9))], 8)), lshift(U8[tobit((v_r + 10))], 16)), lshift(U8[tobit((v_r + 11))], 24)))
v_e = bor(bor(bor(U8[tobit((v_r + 4))], lshift(U8[tobit((v_r + 5))], 8)), lshift(U8[tobit((v_r + 6))], 16)), lshift(U8[tobit((v_r + 7))], 24))
I32[arshift((v_s + 496), 2)] = tobit(bor(bor(bor(U8[bor(0, v_r)], lshift(U8[tobit((v_r + 1))], 8)), lshift(U8[tobit((v_r + 2))], 16)), lshift(U8[tobit((v_r + 3))], 24)))
I32[arshift((v_s + 500), 2)] = tobit(v_e)
v_e = F.fnA(v_a, v_A, tobit((v_s + 496)), v_r)
I8[tobit((v_s + 16))] = tobit(0)
I32[arshift((v_s + 8), 2)] = tobit(0)
I32[arshift((v_s + 12), 2)] = tobit(0)
v_t = bor(bor(bor(U8[tobit((v_r + 4))], lshift(U8[tobit((v_r + 5))], 8)), lshift(U8[tobit((v_r + 6))], 16)), lshift(U8[tobit((v_r + 7))], 24))
I32[arshift((v_s + 8), 2)] = tobit(bor(bor(bor(U8[bor(0, v_r)], lshift(U8[tobit((v_r + 1))], 8)), lshift(U8[tobit((v_r + 2))], 16)), lshift(U8[tobit((v_r + 3))], 24)))
I32[arshift((v_s + 12), 2)] = tobit(v_t)
I32[arshift(v_u, 2)] = tobit(F.fcA(v_e, v_A, tobit((v_s + 8)), tobit((v_s + 8)), v_c))
F.fL(v_e)
goto L356
end
::L357::
I8[tobit((v_s + 16))] = tobit(0)
I32[arshift((v_s + 8), 2)] = tobit(0)
I32[arshift((v_s + 12), 2)] = tobit(0)
v_e = bor(bor(bor(U8[tobit((v_r + 4))], lshift(U8[tobit((v_r + 5))], 8)), lshift(U8[tobit((v_r + 6))], 16)), lshift(U8[tobit((v_r + 7))], 24))
I32[arshift((v_s + 8), 2)] = tobit(bor(bor(bor(U8[bor(0, v_r)], lshift(U8[tobit((v_r + 1))], 8)), lshift(U8[tobit((v_r + 2))], 16)), lshift(U8[tobit((v_r + 3))], 24)))
I32[arshift((v_s + 12), 2)] = tobit(v_e)
v_A = F.fcA(v_a, v_A, tobit((v_s + 8)), tobit((v_s + 8)), tobit((v_s + 28)))
I8[tobit((v_s + 501))] = tobit(0)
I8[tobit((v_s + 502))] = tobit(0)
I8[tobit((v_s + 503))] = tobit(0)
I8[tobit((v_s + 504))] = tobit(0)
I8[tobit((v_s + 505))] = tobit(0)
I8[tobit((v_s + 506))] = tobit(0)
I8[tobit((v_s + 507))] = tobit(0)
I8[tobit((v_s + 508))] = tobit(0)
I32[arshift((v_s + 496), 2)] = tobit(0)
I32[arshift((v_s + 500), 2)] = tobit(0)
I32[arshift((v_s + 504), 2)] = tobit(bor(bor(bor(U8[tobit((v_r + 8))], lshift(U8[tobit((v_r + 9))], 8)), lshift(U8[tobit((v_r + 10))], 16)), lshift(U8[tobit((v_r + 11))], 24)))
v_e = bor(bor(bor(U8[tobit((v_r + 4))], lshift(U8[tobit((v_r + 5))], 8)), lshift(U8[tobit((v_r + 6))], 16)), lshift(U8[tobit((v_r + 7))], 24))
I32[arshift((v_s + 496), 2)] = tobit(bor(bor(bor(U8[bor(0, v_r)], lshift(U8[tobit((v_r + 1))], 8)), lshift(U8[tobit((v_r + 2))], 16)), lshift(U8[tobit((v_r + 3))], 24)))
I32[arshift((v_s + 500), 2)] = tobit(v_e)
I32[arshift(v_u, 2)] = tobit(F.fnA(v_A, I32[arshift((v_s + 28), 2)], tobit((v_s + 496)), v_r))
if (v_c ~= 0) then
I32[arshift(v_c, 2)] = tobit(I32[arshift((v_s + 28), 2)])
end
F.fL(v_A)
end
::L356::
F.fL(v_r)
v_k = ((I32[arshift(v_u, 2)] ~= 0) and 0 or (-1))
end
end
end
end
end
end
end
else
v_k = (-2)
end
end
end
end
B = tobit((v_s + 528))
do return bor(0, v_k) end
end
UA[56] = function(v_A, v_r, v_e)
local v_t, v_a, v_u, v_c = 0, 0, 0, 0
v_A = tobit(v_A)
v_r = tobit(v_r)
v_e = tobit(v_e)
v_a = 0
v_u = 0
v_c = 0
do
v_t = tobit((B - 96))
B = v_t
F.fPA(tobit((v_t + 8)), 0, 84)
v_a = v_t
I32[arshift((v_a + 8), 2)] = tobit(0)
I32[arshift((v_a + 12), 2)] = tobit(0)
I32[arshift((v_a + 72), 2)] = tobit(0)
I32[arshift((v_a + 76), 2)] = tobit(0)
I16[arshift((v_a + 62), 1)] = tobit(0)
I16[arshift((v_a + 64), 1)] = tobit(0)
I16[arshift((v_a + 66), 1)] = tobit(0)
I16[arshift((v_a + 68), 1)] = tobit(0)
I32[arshift((v_a + 56), 2)] = tobit(0)
I32[arshift((v_a + 60), 2)] = tobit(0)
I32[arshift((v_a + 48), 2)] = tobit(0)
I32[arshift((v_a + 52), 2)] = tobit(0)
I32[arshift((v_a + 40), 2)] = tobit(0)
I32[arshift((v_a + 44), 2)] = tobit(0)
I32[arshift((v_a + 32), 2)] = tobit(0)
I32[arshift((v_a + 36), 2)] = tobit(0)
I32[arshift((v_a + 24), 2)] = tobit(0)
I32[arshift((v_a + 28), 2)] = tobit(0)
I32[arshift((v_a + 16), 2)] = tobit(0)
I32[arshift((v_a + 20), 2)] = tobit(0)
I32[arshift((v_a + 80), 2)] = tobit(0)
I32[arshift((v_a + 84), 2)] = tobit(0)
I32[arshift((v_a + 88), 2)] = tobit(0)
v_a = tobit((v_a + 8))
if (v_r ~= 0) then
do
do
while true do
do
local t412 = v_a
v_c = I32[arshift((v_a + 80), 2)]
local t414 = tobit((tobit((t412 + v_c)) - (-64)))
local t415 = v_A
local t413 = (tobit(v_r) % 4294967296)
v_u = tobit((16 - v_c))
v_u = ((t413 > (tobit(v_u) % 4294967296)) and v_u or v_r)
F.fTA(t414, t415, v_u)
v_c = tobit((v_u + I32[arshift((v_a + 80), 2)]))
I32[arshift((v_a + 80), 2)] = tobit(v_c)
v_r = tobit((v_r - v_u))
if (16 == bor(0, v_c)) then
I32[arshift((v_a + 80), 2)] = tobit(0)
F.fS(v_a)
end
v_A = tobit((v_A + v_u))
if not (v_r ~= 0) then goto B362 end
end
do
end
::C362::
end
end
::B362::
end
end
end
do
v_A = tobit((v_t + 8))
v_r = I32[arshift((80 + v_A), 2)]
if ((tobit(v_r) % 4294967296) <= 15) then
v_a = tobit((tobit((v_A + v_r)) - (-64)))
local t416 = v_a
v_r = tobit((16 - v_r))
F.fPA(t416, v_r, v_r)
end
F.fS(v_A)
v_r = I32[arshift((v_A + 12), 2)]
I32[arshift((v_A + 72), 2)] = tobit(I32[arshift((v_A + 8), 2)])
I32[arshift((v_A + 76), 2)] = tobit(v_r)
v_r = I32[arshift((v_A + 4), 2)]
I32[arshift((v_A + 64), 2)] = tobit(I32[arshift(v_A, 2)])
I32[arshift((v_A + 68), 2)] = tobit(v_r)
F.fS(v_A)
v_r = bor(bor(bor(U8[tobit((v_A + 28))], lshift(U8[tobit((v_A + 29))], 8)), lshift(U8[tobit((v_A + 30))], 16)), lshift(U8[tobit((v_A + 31))], 24))
v_a = bor(bor(bor(U8[tobit((v_A + 24))], lshift(U8[tobit((v_A + 25))], 8)), lshift(U8[tobit((v_A + 26))], 16)), lshift(U8[tobit((v_A + 27))], 24))
I8[tobit((v_e + 8))] = tobit(v_a)
I8[tobit((v_e + 9))] = tobit((rshift(v_a, 8) % 4294967296))
I8[tobit((v_e + 10))] = tobit((rshift(v_a, 16) % 4294967296))
I8[tobit((v_e + 11))] = tobit((rshift(v_a, 24) % 4294967296))
I8[tobit((v_e + 12))] = tobit(v_r)
I8[tobit((v_e + 13))] = tobit((rshift(v_r, 8) % 4294967296))
I8[tobit((v_e + 14))] = tobit((rshift(v_r, 16) % 4294967296))
I8[tobit((v_e + 15))] = tobit((rshift(v_r, 24) % 4294967296))
v_r = bor(bor(bor(U8[tobit((v_A + 20))], lshift(U8[tobit((v_A + 21))], 8)), lshift(U8[tobit((v_A + 22))], 16)), lshift(U8[tobit((v_A + 23))], 24))
v_A = bor(bor(bor(U8[tobit((v_A + 16))], lshift(U8[tobit((v_A + 17))], 8)), lshift(U8[tobit((v_A + 18))], 16)), lshift(U8[tobit((v_A + 19))], 24))
I8[bor(0, v_e)] = tobit(v_A)
I8[tobit((v_e + 1))] = tobit((rshift(v_A, 8) % 4294967296))
I8[tobit((v_e + 2))] = tobit((rshift(v_A, 16) % 4294967296))
I8[tobit((v_e + 3))] = tobit((rshift(v_A, 24) % 4294967296))
I8[tobit((v_e + 4))] = tobit(v_r)
I8[tobit((v_e + 5))] = tobit((rshift(v_r, 8) % 4294967296))
I8[tobit((v_e + 6))] = tobit((rshift(v_r, 16) % 4294967296))
I8[tobit((v_e + 7))] = tobit((rshift(v_r, 24) % 4294967296))
v_A = tobit((v_t + 8))
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
end
B = tobit((v_t + 96))
end
end
UA[57] = function(v_A, v_r, v_e)
local v_t, v_o, v_a, v_u, v_c, v_s = 0, 0, 0, 0, 0, 0
v_A = tobit(v_A)
v_r = tobit(v_r)
v_e = tobit(v_e)
v_o = 0
v_a = 0
v_u = 0
v_c = 0
v_s = 0
do
v_t = tobit((B - 96))
B = v_t
F.fNA(tobit((v_t + 8)))
F.fjA(tobit((v_t + 8)))
v_u = tobit((v_t + 8))
if (v_r ~= 0) then
do
do
v_o = I32[arshift(v_u, 2)]
v_a = tobit((v_o + v_r))
I32[arshift(v_u, 2)] = tobit(v_a)
if ((tobit(v_o) % 4294967296) > (tobit(v_a) % 4294967296)) then
I32[arshift((v_u + 4), 2)] = tobit((I32[arshift((v_u + 4), 2)] + 1))
end
v_a = 0
v_o = band(v_o, 63)
if (v_o ~= 0) then
v_c = tobit((64 - v_o))
if ((tobit(v_c) % 4294967296) > (tobit(v_r) % 4294967296)) then
v_a = v_o
else
local t417 = v_o
v_o = tobit((v_u + 24))
F.fTA(tobit((t417 + v_o)), v_A, v_c)
F.fK(v_u, v_o)
v_r = tobit((v_r - v_c))
v_A = tobit((v_A + v_c))
end
end
if ((tobit(v_r) % 4294967296) >= 64) then
do
while true do
F.fK(v_u, v_A)
v_A = tobit((v_A - (-64)))
v_r = tobit((v_r + (-64)))
if not ((tobit(v_r) % 4294967296) > 63) then goto B363 end
do
end
::C363::
end
end
::B363::
end
end
if (v_r ~= 0) then
F.fTA(tobit((24 + tobit((v_u + v_a)))), v_A, v_r)
end
end
end
end
do
v_u = tobit((B - 16))
B = v_u
v_o = tobit((v_t + 8))
v_r = I32[arshift(v_o, 2)]
v_c = I32[arshift((v_o + 4), 2)]
I8[tobit((v_u + 15))] = tobit((rshift(v_c, 21) % 4294967296))
I8[tobit((v_u + 14))] = tobit((rshift(v_c, 13) % 4294967296))
I8[tobit((v_u + 13))] = tobit((rshift(v_c, 5) % 4294967296))
I8[tobit((v_u + 11))] = tobit((rshift(v_r, 21) % 4294967296))
I8[tobit((v_u + 10))] = tobit((rshift(v_r, 13) % 4294967296))
I8[tobit((v_u + 9))] = tobit((rshift(v_r, 5) % 4294967296))
I8[tobit((v_u + 8))] = tobit(lshift(v_r, 3))
I8[tobit((v_u + 12))] = tobit(bor(lshift(v_c, 3), (rshift(v_r, 29) % 4294967296)))
v_A = band(63, v_r)
v_a = tobit(((((tobit(v_A) % 4294967296) < 56) and 56 or 120) - v_A))
if (v_a ~= 0) then
do
do
v_r = tobit((v_r + v_a))
I32[arshift(v_o, 2)] = tobit(v_r)
if ((tobit(v_r) % 4294967296) < (tobit(v_a) % 4294967296)) then
I32[arshift((v_o + 4), 2)] = tobit((v_c + 1))
end
v_r = 0
v_c = 11760
if (v_A ~= 0) then
v_s = tobit((64 - v_A))
if ((tobit(v_s) % 4294967296) > (tobit(v_a) % 4294967296)) then
v_r = v_A
else
local t418 = v_A
v_A = tobit((v_o + 24))
F.fTA(tobit((t418 + v_A)), 11760, v_s)
F.fK(v_o, v_A)
v_a = tobit((v_a - v_s))
v_c = tobit((v_s + 11760))
end
end
if ((tobit(v_a) % 4294967296) >= 64) then
do
while true do
F.fK(v_o, v_c)
v_c = tobit((v_c - (-64)))
v_a = tobit((v_a + (-64)))
if not ((tobit(v_a) % 4294967296) > 63) then goto B364 end
do
end
::C364::
end
end
::B364::
end
end
if (v_a ~= 0) then
F.fTA(tobit((24 + tobit((v_r + v_o)))), v_c, v_a)
end
end
end
end
v_A = I32[arshift(v_o, 2)]
I32[arshift(v_o, 2)] = tobit((v_A + 8))
if ((tobit(v_A) % 4294967296) >= 4294967288) then
I32[arshift((v_o + 4), 2)] = tobit((I32[arshift((v_o + 4), 2)] + 1))
end
do
do
do
do
v_A = band(v_A, 63)
if (v_A ~= 0) then
do
if ((tobit(v_A) % 4294967296) <= 55) then
v_a = tobit((24 + tobit((v_A + v_o))))
v_c = 8
v_A = tobit((v_u + 8))
else
do
do
local t419 = v_A
v_a = tobit((v_o + 24))
local t420 = tobit((t419 + v_a))
local t421 = tobit((v_u + 8))
v_r = tobit((64 - v_A))
F.fTA(t420, t421, v_r)
F.fK(v_o, v_a)
v_c = tobit((v_A - 56))
if (not (v_c ~= 0)) then
goto L365
end
end
v_A = tobit((v_r + tobit((v_u + 8))))
end
end
end
else
v_a = tobit((v_o + 24))
v_c = 8
v_A = tobit((v_u + 8))
end
end
F.fTA(v_a, v_A, v_c)
end
end
::L365::
end
I8[bor(0, v_e)] = tobit(I32[arshift((v_o + 8), 2)])
I8[tobit((v_e + 1))] = tobit((rshift(I32[arshift((v_o + 8), 2)], 8) % 4294967296))
I8[tobit((v_e + 2))] = tobit(U16[arshift((v_o + 10), 1)])
I8[tobit((v_e + 3))] = tobit(U8[tobit((v_o + 11))])
I8[tobit((v_e + 4))] = tobit(I32[arshift((v_o + 12), 2)])
I8[tobit((v_e + 5))] = tobit((rshift(I32[arshift((v_o + 12), 2)], 8) % 4294967296))
I8[tobit((v_e + 6))] = tobit(U16[arshift((v_o + 14), 1)])
I8[tobit((v_e + 7))] = tobit(U8[tobit((v_o + 15))])
I8[tobit((v_e + 8))] = tobit(I32[arshift((v_o + 16), 2)])
I8[tobit((v_e + 9))] = tobit((rshift(I32[arshift((v_o + 16), 2)], 8) % 4294967296))
I8[tobit((v_e + 10))] = tobit(U16[arshift((v_o + 18), 1)])
I8[tobit((v_e + 11))] = tobit(U8[tobit((v_o + 19))])
I8[tobit((v_e + 12))] = tobit(I32[arshift((v_o + 20), 2)])
I8[tobit((v_e + 13))] = tobit((rshift(I32[arshift((v_o + 20), 2)], 8) % 4294967296))
I8[tobit((v_e + 14))] = tobit(U16[arshift((v_o + 22), 1)])
I8[tobit((v_e + 15))] = tobit(U8[tobit((v_o + 23))])
B = tobit((v_u + 16))
F.f_(tobit((v_t + 8)))
B = tobit((v_t + 96))
end
UA[58] = function(v_A, v_r, v_e)
local v_t, v_o, v_a, v_u, v_c, v_s = 0, 0, 0, 0, 0, 0
v_A = tobit(v_A)
v_r = tobit(v_r)
v_e = tobit(v_e)
v_o = 0
v_a = 0
v_u = 0
v_c = 0
v_s = 0
do
v_t = tobit((B - 96))
B = v_t
F.fNA(tobit((v_t + 8)))
F.fjA(tobit((v_t + 8)))
v_u = tobit((v_t + 8))
if (v_r ~= 0) then
do
do
v_o = I32[arshift(v_u, 2)]
v_a = tobit((v_o + v_r))
I32[arshift(v_u, 2)] = tobit(v_a)
if ((tobit(v_o) % 4294967296) > (tobit(v_a) % 4294967296)) then
I32[arshift((v_u + 4), 2)] = tobit((I32[arshift((v_u + 4), 2)] + 1))
end
v_a = 0
v_o = band(v_o, 63)
if (v_o ~= 0) then
v_c = tobit((64 - v_o))
if ((tobit(v_c) % 4294967296) > (tobit(v_r) % 4294967296)) then
v_a = v_o
else
local t422 = v_o
v_s = tobit((v_u + 24))
F.fTA(tobit((t422 + v_s)), v_A, v_c)
F.fx(v_u, v_s)
v_r = tobit((v_r - v_c))
v_A = tobit((v_A + v_c))
end
end
if ((tobit(v_r) % 4294967296) >= 64) then
do
while true do
F.fx(v_u, v_A)
v_A = tobit((v_A - (-64)))
v_r = tobit((v_r + (-64)))
if not ((tobit(v_r) % 4294967296) > 63) then goto B366 end
do
end
::C366::
end
end
::B366::
end
end
if (v_r ~= 0) then
F.fTA(tobit((24 + tobit((v_a + v_u)))), v_A, v_r)
end
end
end
end
do
v_A = tobit((v_t + 8))
v_r = tobit((24 + v_A))
v_o = I32[arshift(v_A, 2)]
local t423 = v_r
v_a = band(63, v_o)
I8[tobit((t423 + v_a))] = tobit(128)
v_u = tobit((v_a + 1))
if ((tobit(v_a) % 4294967296) <= 55) then
F.fPA(tobit((24 + tobit((v_A + v_u)))), 0, tobit((55 - v_a)))
else
F.fPA(tobit((24 + tobit((v_A + v_u)))), 0, bxor(63, v_a))
F.fx(v_A, v_r)
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
I32[arshift(v_r, 2)] = tobit(0)
I32[arshift((v_r + 4), 2)] = tobit(0)
v_o = I32[arshift(v_A, 2)]
end
I8[tobit((v_A + 83))] = tobit((rshift(v_o, 21) % 4294967296))
I8[tobit((v_A + 82))] = tobit((rshift(v_o, 13) % 4294967296))
I8[tobit((v_A + 81))] = tobit((rshift(v_o, 5) % 4294967296))
I8[tobit((v_A + 80))] = tobit(lshift(v_o, 3))
v_a = I32[arshift((v_A + 4), 2)]
I8[tobit((v_A + 87))] = tobit((rshift(v_a, 21) % 4294967296))
I8[tobit((v_A + 86))] = tobit((rshift(v_a, 13) % 4294967296))
I8[tobit((v_A + 85))] = tobit((rshift(v_a, 5) % 4294967296))
I8[tobit((v_A + 84))] = tobit(bor(lshift(v_a, 3), (rshift(v_o, 29) % 4294967296)))
F.fx(v_A, v_r)
I8[bor(0, v_e)] = tobit(I32[arshift((v_A + 8), 2)])
I8[tobit((v_e + 1))] = tobit((rshift(I32[arshift((v_A + 8), 2)], 8) % 4294967296))
I8[tobit((v_e + 2))] = tobit(U16[arshift((v_A + 10), 1)])
I8[tobit((v_e + 3))] = tobit(U8[tobit((v_A + 11))])
I8[tobit((v_e + 4))] = tobit(I32[arshift((v_A + 12), 2)])
I8[tobit((v_e + 5))] = tobit((rshift(I32[arshift((v_A + 12), 2)], 8) % 4294967296))
I8[tobit((v_e + 6))] = tobit(U16[arshift((v_A + 14), 1)])
I8[tobit((v_e + 7))] = tobit(U8[tobit((v_A + 15))])
I8[tobit((v_e + 8))] = tobit(I32[arshift((v_A + 16), 2)])
I8[tobit((v_e + 9))] = tobit((rshift(I32[arshift((v_A + 16), 2)], 8) % 4294967296))
I8[tobit((v_e + 10))] = tobit(U16[arshift((v_A + 18), 1)])
I8[tobit((v_e + 11))] = tobit(U8[tobit((v_A + 19))])
I8[tobit((v_e + 12))] = tobit(I32[arshift((v_A + 20), 2)])
I8[tobit((v_e + 13))] = tobit((rshift(I32[arshift((v_A + 20), 2)], 8) % 4294967296))
I8[tobit((v_e + 14))] = tobit(U16[arshift((v_A + 22), 1)])
I8[tobit((v_e + 15))] = tobit(U8[tobit((v_A + 23))])
F.f_(tobit((v_t + 8)))
B = tobit((v_t + 96))
end
end
UA[59] = function()
local v_A, v_r, v_e, v_t, v_o, v_a, v_u, v_c = 0, 0, 0, 0, 0, 0, 0, 0
v_e = 0
v_t = 0
v_o = 0
v_a = 0
v_u = 0
v_c = 0
do
v_r = tobit((B - 544))
v_A = v_r
B = v_A
if (not (I32[8020] ~= 0)) then
do
F.fLA(tobit((v_A + 264)))
I8[tobit((v_A + 256))] = tobit(118)
I8[tobit((v_A + 257))] = tobit(56)
I8[tobit((v_A + 258))] = tobit(48)
I8[tobit((v_A + 259))] = tobit(107)
I8[tobit((v_A + 260))] = tobit(103)
I8[tobit((v_A + 261))] = tobit(50)
I8[tobit((v_A + 262))] = tobit(104)
I8[tobit((v_A + 263))] = tobit(54)
I8[tobit((v_A + 248))] = tobit(120)
I8[tobit((v_A + 249))] = tobit(119)
I8[tobit((v_A + 250))] = tobit(110)
I8[tobit((v_A + 251))] = tobit(101)
I8[tobit((v_A + 252))] = tobit(49)
I8[tobit((v_A + 253))] = tobit(53)
I8[tobit((v_A + 254))] = tobit(116)
I8[tobit((v_A + 255))] = tobit(105)
F.fZ(tobit((v_A + 264)), tobit((v_A + 248)), 128)
I8[tobit((v_A + 240))] = tobit(111)
I8[tobit((v_A + 241))] = tobit(100)
I8[tobit((v_A + 242))] = tobit(114)
I8[tobit((v_A + 243))] = tobit(104)
I8[tobit((v_A + 244))] = tobit(54)
I8[tobit((v_A + 245))] = tobit(115)
I8[tobit((v_A + 246))] = tobit(99)
I8[tobit((v_A + 247))] = tobit(101)
I8[tobit((v_A + 232))] = tobit(98)
I8[tobit((v_A + 233))] = tobit(106)
I8[tobit((v_A + 234))] = tobit(49)
I8[tobit((v_A + 235))] = tobit(113)
I8[tobit((v_A + 236))] = tobit(103)
I8[tobit((v_A + 237))] = tobit(121)
I8[tobit((v_A + 238))] = tobit(97)
I8[tobit((v_A + 239))] = tobit(50)
I8[tobit((v_A + 224))] = tobit(203)
I8[tobit((v_A + 225))] = tobit(57)
I8[tobit((v_A + 226))] = tobit(201)
I8[tobit((v_A + 227))] = tobit(73)
I8[tobit((v_A + 228))] = tobit(31)
I8[tobit((v_A + 229))] = tobit(230)
I8[tobit((v_A + 230))] = tobit(245)
I8[tobit((v_A + 231))] = tobit(193)
I8[tobit((v_A + 216))] = tobit(6)
I8[tobit((v_A + 217))] = tobit(118)
I8[tobit((v_A + 218))] = tobit(195)
I8[tobit((v_A + 219))] = tobit(164)
I8[tobit((v_A + 220))] = tobit(197)
I8[tobit((v_A + 221))] = tobit(116)
I8[tobit((v_A + 222))] = tobit(203)
I8[tobit((v_A + 223))] = tobit(88)
v_e = 16
F.fR(tobit((v_A + 264)), 0, 16, tobit((v_A + 232)), tobit((v_A + 216)), tobit((v_A + 176)))
F.fhA(tobit((v_A + 264)))
do
do
do
v_t = U8[tobit((v_A + 191))]
local t424 = bor(bor((((tobit(v_t) % 4294967296) > 16) and 1 or 0), ((not (v_t ~= 0)) and 1 or 0)), ((16 == bor(0, v_t)) and 1 or 0))
if t424 == 0 then
v_a = 2
v_e = 15
t424 = (((tobit(v_t) % 4294967296) < 2) and 1 or 0)
end
if (not (t424 ~= 0)) then
do
v_e = 14
while true do
do
if (bor(((bor(0, v_t) ~= U8[tobit((tobit((v_A + 176)) + v_e))]) and 1 or 0), (((tobit(v_t) % 4294967296) <= (tobit(band(255, v_a)) % 4294967296)) and 1 or 0)) ~= 0) then
goto L367
end
v_a = tobit((v_a + 1))
v_e = tobit((v_e - 1))
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
v_t = F.fm(tobit((v_e + 1)))
F.fPA(tobit((v_t + v_e)), 0, (((-1) ~= bor(0, v_e)) and 1 or 0))
I32[8020] = tobit(F.fTA(v_t, tobit((v_A + 176)), v_e))
end
end
end
do
if (not (I32[8021] ~= 0)) then
do
F.fLA(tobit((v_A + 264)))
I8[tobit((v_A + 168))] = tobit(116)
I8[tobit((v_A + 169))] = tobit(48)
I8[tobit((v_A + 170))] = tobit(56)
I8[tobit((v_A + 171))] = tobit(98)
I8[tobit((v_A + 172))] = tobit(101)
I8[tobit((v_A + 173))] = tobit(97)
I8[tobit((v_A + 174))] = tobit(100)
I8[tobit((v_A + 175))] = tobit(51)
I8[tobit((v_A + 160))] = tobit(120)
I8[tobit((v_A + 161))] = tobit(103)
I8[tobit((v_A + 162))] = tobit(119)
I8[tobit((v_A + 163))] = tobit(50)
I8[tobit((v_A + 164))] = tobit(52)
I8[tobit((v_A + 165))] = tobit(105)
I8[tobit((v_A + 166))] = tobit(113)
I8[tobit((v_A + 167))] = tobit(106)
F.fZ(tobit((v_A + 264)), tobit((v_A + 160)), 128)
v_e = bor(bor(bor(U8[13592], lshift(U8[13593], 8)), lshift(U8[13594], 16)), lshift(U8[13595], 24))
I32[arshift((v_A + 120), 2)] = tobit(bor(bor(bor(U8[13588], lshift(U8[13589], 8)), lshift(U8[13590], 16)), lshift(U8[13591], 24)))
I32[arshift((v_A + 124), 2)] = tobit(v_e)
v_e = bor(bor(bor(U8[13600], lshift(U8[13601], 8)), lshift(U8[13602], 16)), lshift(U8[13603], 24))
I32[arshift((v_A + 128), 2)] = tobit(bor(bor(bor(U8[13596], lshift(U8[13597], 8)), lshift(U8[13598], 16)), lshift(U8[13599], 24)))
I32[arshift((v_A + 132), 2)] = tobit(v_e)
v_e = bor(bor(bor(U8[13608], lshift(U8[13609], 8)), lshift(U8[13610], 16)), lshift(U8[13611], 24))
I32[arshift((v_A + 136), 2)] = tobit(bor(bor(bor(U8[13604], lshift(U8[13605], 8)), lshift(U8[13606], 16)), lshift(U8[13607], 24)))
I32[arshift((v_A + 140), 2)] = tobit(v_e)
I8[tobit((v_A + 152))] = tobit(100)
I8[tobit((v_A + 153))] = tobit(57)
I8[tobit((v_A + 154))] = tobit(120)
I8[tobit((v_A + 155))] = tobit(108)
I8[tobit((v_A + 156))] = tobit(117)
I8[tobit((v_A + 157))] = tobit(121)
I8[tobit((v_A + 158))] = tobit(103)
I8[tobit((v_A + 159))] = tobit(116)
I8[tobit((v_A + 144))] = tobit(122)
I8[tobit((v_A + 145))] = tobit(119)
I8[tobit((v_A + 146))] = tobit(114)
I8[tobit((v_A + 147))] = tobit(104)
I8[tobit((v_A + 148))] = tobit(105)
I8[tobit((v_A + 149))] = tobit(53)
I8[tobit((v_A + 150))] = tobit(102)
I8[tobit((v_A + 151))] = tobit(107)
v_e = bor(bor(bor(U8[13584], lshift(U8[13585], 8)), lshift(U8[13586], 16)), lshift(U8[13587], 24))
I32[arshift((v_A + 112), 2)] = tobit(bor(bor(bor(U8[13580], lshift(U8[13581], 8)), lshift(U8[13582], 16)), lshift(U8[13583], 24)))
I32[arshift((v_A + 116), 2)] = tobit(v_e)
v_e = 32
F.fR(tobit((v_A + 264)), 0, 32, tobit((v_A + 144)), tobit((v_A + 112)), tobit((v_A + 176)))
F.fhA(tobit((v_A + 264)))
do
do
do
v_a = U8[tobit((v_A + 207))]
local t425 = (((tobit(band((v_a - 1), 255)) % 4294967296) > 15) and 1 or 0)
if t425 == 0 then
v_t = 2
v_e = 31
t425 = (((tobit(v_a) % 4294967296) < 2) and 1 or 0)
end
if (not (t425 ~= 0)) then
do
v_e = 30
while true do
do
if (bor(((bor(0, v_a) ~= U8[tobit((tobit((v_A + 176)) + v_e))]) and 1 or 0), (((tobit(v_a) % 4294967296) <= (tobit(band(255, v_t)) % 4294967296)) and 1 or 0)) ~= 0) then
goto L369
end
v_t = tobit((v_t + 1))
v_e = tobit((v_e - 1))
end
::C370::
end
end
::B370::
end
end
end
::L369::
end
v_t = F.fm(tobit((v_e + 1)))
F.fPA(tobit((v_t + v_e)), 0, (((-1) ~= bor(0, v_e)) and 1 or 0))
I32[8021] = tobit(F.fTA(v_t, tobit((v_A + 176)), v_e))
end
end
end
do
v_a = 0
v_t = I32[8022]
if (not (v_t ~= 0)) then
do
F.fLA(tobit((v_A + 264)))
I8[tobit((v_A + 104))] = tobit(53)
I8[tobit((v_A + 105))] = tobit(102)
I8[tobit((v_A + 106))] = tobit(55)
I8[tobit((v_A + 107))] = tobit(56)
I8[tobit((v_A + 108))] = tobit(121)
I8[tobit((v_A + 109))] = tobit(120)
I8[tobit((v_A + 110))] = tobit(97)
I8[tobit((v_A + 111))] = tobit(52)
I8[tobit((v_A + 96))] = tobit(100)
I8[tobit((v_A + 97))] = tobit(57)
I8[tobit((v_A + 98))] = tobit(107)
I8[tobit((v_A + 99))] = tobit(98)
I8[tobit((v_A + 100))] = tobit(114)
I8[tobit((v_A + 101))] = tobit(108)
I8[tobit((v_A + 102))] = tobit(112)
I8[tobit((v_A + 103))] = tobit(109)
F.fZ(tobit((v_A + 264)), tobit((v_A + 96)), 128)
I8[tobit((v_A + 88))] = tobit(56)
I8[tobit((v_A + 89))] = tobit(104)
I8[tobit((v_A + 90))] = tobit(97)
I8[tobit((v_A + 91))] = tobit(112)
I8[tobit((v_A + 92))] = tobit(103)
I8[tobit((v_A + 93))] = tobit(100)
I8[tobit((v_A + 94))] = tobit(98)
I8[tobit((v_A + 95))] = tobit(117)
I8[tobit((v_A + 80))] = tobit(111)
I8[tobit((v_A + 81))] = tobit(51)
I8[tobit((v_A + 82))] = tobit(57)
I8[tobit((v_A + 83))] = tobit(115)
I8[tobit((v_A + 84))] = tobit(120)
I8[tobit((v_A + 85))] = tobit(108)
I8[tobit((v_A + 86))] = tobit(49)
I8[tobit((v_A + 87))] = tobit(105)
I8[tobit((v_A + 72))] = tobit(162)
I8[tobit((v_A + 73))] = tobit(195)
I8[tobit((v_A + 74))] = tobit(242)
I8[tobit((v_A + 75))] = tobit(203)
I8[tobit((v_A + 76))] = tobit(143)
I8[tobit((v_A + 77))] = tobit(118)
I8[tobit((v_A + 78))] = tobit(228)
I8[tobit((v_A + 79))] = tobit(164)
I8[tobit((v_A + 64))] = tobit(203)
I8[tobit((v_A + 65))] = tobit(114)
I8[tobit((v_A + 66))] = tobit(130)
I8[tobit((v_A + 67))] = tobit(158)
I8[tobit((v_A + 68))] = tobit(29)
I8[tobit((v_A + 69))] = tobit(195)
I8[tobit((v_A + 70))] = tobit(182)
I8[tobit((v_A + 71))] = tobit(183)
v_e = 16
F.fR(tobit((v_A + 264)), 0, 16, tobit((v_A + 80)), tobit((v_A - (-64))), tobit((v_A + 176)))
F.fhA(tobit((v_A + 264)))
do
do
do
v_o = U8[tobit((v_A + 191))]
local t426 = bor(bor((((tobit(v_o) % 4294967296) > 16) and 1 or 0), ((not (v_o ~= 0)) and 1 or 0)), ((16 == bor(0, v_o)) and 1 or 0))
if t426 == 0 then
v_t = 2
v_e = 15
t426 = (((tobit(v_o) % 4294967296) < 2) and 1 or 0)
end
if (not (t426 ~= 0)) then
do
v_e = 14
while true do
do
if (bor(((bor(0, v_o) ~= U8[tobit((tobit((v_A + 176)) + v_e))]) and 1 or 0), (((tobit(v_o) % 4294967296) <= (tobit(band(255, v_t)) % 4294967296)) and 1 or 0)) ~= 0) then
goto L371
end
v_t = tobit((v_t + 1))
v_e = tobit((v_e - 1))
end
::C372::
end
end
::B372::
end
end
end
::L371::
end
v_t = F.fm(tobit((v_e + 1)))
F.fPA(tobit((v_t + v_e)), 0, (((-1) ~= bor(0, v_e)) and 1 or 0))
I32[8022] = tobit(F.fTA(v_t, tobit((v_A + 176)), v_e))
end
end
end
do
I8[tobit((v_A + 63))] = tobit(0)
I8[tobit((v_A + 61))] = tobit(105)
I8[tobit((v_A + 62))] = tobit(105)
I32[arshift((v_A + 32), 2)] = tobit(10560)
I32[arshift((v_A + 36), 2)] = tobit(v_t)
local t427 = bor(0, imp_b(14394, tobit((v_A + 61)), tobit((v_A + 32))))
if t427 == 0 then
I8[tobit((v_A + 57))] = tobit(105)
I8[tobit((v_A + 58))] = tobit(105)
I8[tobit((v_A + 59))] = tobit(105)
I8[tobit((v_A + 60))] = tobit(0)
I32[arshift((v_A + 16), 2)] = tobit(10617)
I32[arshift((v_A + 20), 2)] = tobit(10536)
I32[arshift((v_A + 24), 2)] = tobit(10548)
local t428 = bor(0, imp_b(14449, tobit((v_A + 57)), tobit((v_A + 16))))
if t428 == 0 then
I8[tobit((v_A + 55))] = tobit(105)
I8[tobit((v_A + 56))] = tobit(0)
I32[arshift(v_A, 2)] = tobit(10636)
t428 = bor(0, imp_b(14875, tobit((v_A + 55)), bor(0, v_A)))
end
t427 = t428
end
if (not (t427 ~= 0)) then
do
v_c = bor(0, imp_e(I32[8022]))
v_t = v_c
v_e = U8[bor(0, v_t)]
v_o = I32[8020]
do
do
do
local t429 = (not (v_e ~= 0))
v_u = U8[bor(0, v_o)]
if (not (bor((t429 and 1 or 0), ((bor(0, v_u) ~= bor(0, v_e)) and 1 or 0)) ~= 0)) then
do
while true do
do
v_u = U8[tobit((v_o + 1))]
v_e = U8[tobit((v_t + 1))]
if (not (v_e ~= 0)) then
goto L373
end
v_o = tobit((v_o + 1))
v_t = tobit((v_t + 1))
if (bor(0, v_e) ~= bor(0, v_u)) then
goto B374
end
end
::C374::
end
end
::B374::
end
end
end
::L373::
end
do
local t432 = (not (tobit((v_e - v_u)) ~= 0))
if t432 then
F.fL(v_c)
v_e = bor(0, imp_c(10579, 10624))
v_t = bor(0, imp_c(10579, 10592))
local t430 = v_t
if t430 ~= 0 then
v_o = F.fpA(v_t)
local t431 = (((tobit(v_o) % 4294967296) < 6) and 1 or 0)
if t431 == 0 then
t431 = F.fwA(tobit((tobit((v_t + v_o)) - 6)), 10648, 6)
end
t430 = ((not (t431 ~= 0)) and 1 or 0)
end
t432 = (t430 ~= 0)
end
if t432 then
do
do
F.fL(v_t)
local t433 = v_r
v_t = I32[8021]
v_o = tobit((t433 - band((F.fpA(v_t) + 16), (-16))))
B = v_o
end
do
do
do
do
do
do
v_t = F.fV(F.fsA(v_o, v_t))
if (v_t ~= 0) then
do
if (not (v_e ~= 0)) then
do
while true do
do
if (not (F.fV(0) ~= 0)) then
goto L376
end
end
::C377::
end
end
::B377::
end
do
do
while true do
do
do
do
v_u = F.fpA(v_e)
local t434 = (tobit(v_u) % 4294967296)
v_o = F.fpA(v_t)
local t435 = ((t434 < (tobit(v_o) % 4294967296)) and 1 or 0)
if t435 == 0 then
t435 = F.fwA(tobit((tobit((v_e + v_u)) - v_o)), v_t, v_o)
end
if (not (t435 ~= 0)) then
F.fL(v_e)
v_a = 1
goto L375
end
end
v_t = F.fV(0)
if (not (v_t ~= 0)) then
goto B378
end
end
end
::C378::
end
end
::B378::
end
end
end
end
end
::L376::
end
F.fL(v_e)
end
end
::L375::
end
end
end
end
end
end
end
B = tobit((v_A + 544))
do return bor(0, v_a) end
end
UA[60] = function(v_A, v_r, v_e, v_t)
local v_o = 0
v_A = tobit(v_A)
v_r = tobit(v_r)
v_e = tobit(v_e)
v_t = tobit(v_t)
v_o = tobit((B - 32))
B = v_o
v_A = bor(0, YA[bxor(32060, I32[8015])](v_A, v_r, v_e, v_t, 0, tobit((v_o + 28)), tobit((v_o + 24))))
I8[tobit((v_o + 20))] = tobit(105)
I8[tobit((v_o + 21))] = tobit(105)
I8[tobit((v_o + 22))] = tobit(105)
I8[tobit((v_o + 23))] = tobit(0)
I32[arshift(v_o, 2)] = tobit(v_A)
I32[arshift((v_o + 4), 2)] = tobit(I32[arshift((v_o + 28), 2)])
I32[arshift((v_o + 8), 2)] = tobit(I32[arshift((v_o + 24), 2)])
imp_b(22685, tobit((v_o + 20)), bor(0, v_o))
if not (v_A ~= 0) then
F.fL(I32[arshift((v_o + 28), 2)])
end
B = tobit((v_o + 32))
end

local DATA = {
    { 1028, "AQAAAAABAAABAQAAAAABAAEAAQAAAQEAAQEBAAAAAAEBAAABAAEAAQEBAAEAAAEBAQABAQABAQEBAQEBAAAAAAAAAAEAAAEAAAABAQABAAAAAQABAAEBAAABAQEBAAAAAQAAAQEAAQABAAEBAQEAAAEBAAEBAQEAAQEBAUAQABAAEAAAAAAEAEAQBBAAAAAQQBAAEEAAAAAAAAAQQAAEAAAABBBAEAQQABAEAAAQBBBAEAQAABAAAEAAAAAAAAQQQAAAEAAQABBAEAAAABAEAEAABABAAAQQABAEEEAQ" },
    { 1260, "QAAEEEAAABAAEAAQQBAEAAAABABAEAQAAAAEAAAQBBAAEAAAQAAAAEAABBAAEAAAQBAEAAAQABBAAAAAQAAAEAAABBBAAAQQAAAAEAAABABAEAAQAAAAAEAQBBBAAAQAQAAAEAAABBAAEAAQQBAAEAAAAABAEAQQABAEAAAQBABAEAAAQBAAAEAABAAAAAAQABAEEBAAACAAAEAgAEAAABBAQCAAAEAgEAAAABBAQCAAAEAAAEAAIBBAQAAAAEAAEAAAIBAAQAAAQAAgAAAAIBBAAAAAAAAAEABAABBAACAAQAAAAEBAABBAACAQAAAAEABAIBAAQCAAAAAAEEBAAABAQCAQQAAAAEBAAABAQCAAAAAgAEAAIBAAAAAQAEAgAEBAABBAQCAAAEAAEEAAABAAACAAAEAAAEAAIAAAACAQQAAAEAAAIBBAQCAAQEAAAABAIBBAQAAAQEAgAAAAABAAQCAQAAAAAEAAAAAAQCAQQEAAAEAAABAAQAAQQAAgAAAAAABAQCAAAAAgEABAABBAACABIIAAgSAAAIEgAACAAAAAgCCAAIEAgAABAIAAASAAAAAAAAAAIIAAACCAAIEggACBAAAAAAAAAIAAgAABAIAAAQAAAAAgAAAAAIAAASCAAIAAAAAAAIAAASAAAIAgAACBAIAAAQAAAIAgAACAAIAAACAAAIAggACBIIAAgQAAAIAAgAABAIAAACCAAIEggACB" },
    { 1821, "IIAAgCAAAIAAgACBAIAAAQAAAAEggACBIAAAgSAAAIAAAACBIIAAgQAAAAEAAAAAIAAAAQCAAAEgAACAIIAAgQCAAAEgAACAIAAAAACAAAEggACAAAAAAACAAAAgAACAIIAAIIAQgACAAIAAgAAAIIAQAAAAEAAgAAAAIAAQgCCAAIAgAACAIIAQgACAEIAAAACAAIAAgAAAEAAgAAAAIAAQgACAEAAgABAAIIAAgAAAAAAAAACAAIAAACCAEAAAABCAIAAQACAAAIAAAAAAAIAQACCAAAAAgBCAAAAQgCCAAAAAAAAAIIAQACAAEIAAABAAIIAAgAAAEIAAgBCAAIAAAAAAEIAAgACAIAAAACCAEIAggBAAIAAAAACAAAAAAACAIIAAAACAEIAAABAAIAAAgCAAEAAggACAIAAAgCAAEAAAgBAAAAAAAACAAIAggAAAAAAAgCAAEIAggBCAAIAQAAAAIAACACAEAggABAAAAAAACAAAAggABAIIIAAACCAEAgggBAAAIAAAAAAAAgAABAIAAAAAAAAEAgAgBAIIAAAACAAEAgggAAIAIAAACAAEAgAABAAAIAQACCAEAgAgAAAAIAQACAAAAggAAAIIIAQACCAAAgAAAAAAAAQACCAAAAAABAAIIAAAACAAAggABAIIAAQCACAEAgAgBAIAAAACACAAAAAABAAIAAQAACAAAAggBAIIAAACCCAAAAggBAIIAAACAAAEAgggBAAAIAQACCAAAAAAAAIAAAACCCAEAAAAAAIIIAAAACAEAAgAAAIAAAQACAAEAAgAAAIAIAAAAQAAAAEIAgAACAIAAQBCAAAIAAABAAAAAABAAAAIAgABCEAAAAgAAAEAAgABCEAAAQBCAAAIQgABCAAAAABAAAAAAgAACEAAAAhAAAAAAAABAEAAAQhCAAEIQgABAAIAAAhCAAEAQAAAAAAAAABCAAEIAgAAAAIAAABCAAEIAAAACAAAAQBCAAEAAAAAAAIAAABAAAAIAgABAEIAAQhAAAEAAgAAAEAAAAhCAAEIAgABCEAAAQAAAAAAAgAACEIAAQhCAAEIAAAAAEIAAQhCAAAIAgAAAAAAAAhAAAAAQgABCAAAAQACAAEAQAAACAAAAAAAAAAIQAABCAIAAQBACAIAAAACAggAAAAACAACCAACAAgAAAAACAICAAACAAgIAAIACAAACAgAAAgAAAIACAICCAgAAgAAAAIICAIAAAAAAAgIAAAAAAICCAACAAAAAgIAAAACCAgAAggIAgIACAIACAACAgAAAAIACAIACAgAAAAIAgIIAAIAAAAAAAgAAgIIAAAACAgAAgAIAgAAAAACAAACAggAAgAIAAAAAAACAAAIAAIACAICCAACAAgIAAAIAAIAAAAAAAAIAAIICAIACAAAAgAAAAAICAICCAgAAAAIAgIAAAICAAgAAAgAAAIICAIACAgCAAAAAAIICAICAAgAAAAIAAIIAAICAAAEAQEAAAAAAAABAAQEAQEEAAEBBAQBAAQAAAAAAAEAAAQAAAAEAQEEBAEBAAQAAAQEAAEEAAEBAAAAAQQAAAAEBAAAAAQAAQAEAAEABAEAAAQBAAAAAQEAAAEBBAQAAQQAAQAEAAABBAAAAQQAAQAAAAAABAQAAAQEAQAAAAABAAABAAQEAQEEAAAAAAABAQAEAQEAAAABAAAAAQAEAAAEAAEBAAABAAAEAQAEAAABAAQAAAQAAAAEBAABBAQBAAQEAQEEAAEAAAABAQQEAAEEAAABBAQAAAQEAQAABAEBBAQAAAAEAAEABAABAAAAAAQAAQAABAEAAAAAAAQAAQGmCzHRrLXfmNty/S+33xrQ7a/huJZ+JmpFkHy6mX8s8UeZoST3bJGz4vIBCBb8joXYIGljaU5XcaP+WKR+PZP0j3SVDVi2jnJYzYtx7koVgh2kVHu1WVrCOdUwnBNg8iojsNHF8IVgKBh5QcrvONu4sNx5jg4YOmCLDp5sPooesMF3FdcnSzG92i+veGBcYFXzJVXmlKtVqmKYSFdAFOhjajnKVbYQqyo0XMy0zuhBEa+GVKGT6XJ8ERTusyq8b2Ndxakr9jEYdBY+XM4ek4ebM7rWr1zPJGyBUzJ6d4aVKJhIjzuvuUtrG+i/xJMhKGbMCdhhkakh+2CsfEgygOxdXV2E77F1hekCIybciBtl64E+iSPFrJbT829tDzlC9IOCRAsuBCCEpErwyGlemx+eQmjGIZps6fZhnAxn8IjTq9KgUWpoL1TYKKcPlqMzUatsC+9u5Dt6E1DwO7qYKvt+HWXxoXYBrzk+WcpmiA5DghmG7oy0n29Fw6WEfb5eizvYdW/gcyDBhZ9EGkCmasFWYqrTTgZ3PzZy3/4bPQKbQiTX0DdIEgrQ0+oP25vA8UnJclMHexuZgNh51CX33uj2GlD+4ztMeba94GyXugbABLZPqcHEYJ9Awp5cXmMkahmvb/totVNsPuuyORNv7FI7H1H8bSyVMJtERYHMCb1erwTQ4779SjPeBygPZrNLLhlXqMvAD3TIRTlfC9Lb+9O5vcB5VQoyYBrGAKHWeXIsQP4ln2fMox/7+OmljvgiMtvfFnU8FWth/cgeUC+rUgWt+rU9MmCHI/1IezFTgt8APrtXXJ6gjG/KLlaHGttpF9/2qELVw/9+KMYyZ6xzVU+MsCdbachYyrtdo//hoBHwuJg9+hC4gyH9bLX8SlvT0S155FOaZUX4trxJjtKQl/tL2vLd4TN+y6RBE/ti6MbkztrKIO8BTHc2/p5+0LQf8StN2tuVmJGQrnGOreqg1ZNr0NGO0OAlx68vWzyOt5R1jvvi9o9kKxLyEriIiBzwDZCgXq1PHMOPaJHxz9GtwaizGCIvL3cXDr7+LXXqoR8Ciw/MoOXodG+11vOsGJniic7gT6i0t+AT/YE7xHzZqK3SZqJfFgV3lYAUc8yTdxQaIWUgreaG+rV39UJUx881nfsMr83roIk+e9MbQdZJfh6uLQ4lAF6zcSC7AGgir+C4V5s2ZCQeuQnwHZFjVaqm31mJQ8F4f1Na2aJbfSDFueUCdgMmg6nPlWJoGcgRQUpzTsotR7NKqRR7UgBRGxUpU5o/Vw/W5MabvHakYCsAdOaBtW+6CB/pG1dr7JbyFdkNKiFlY7a2+bnnLgU0/2RWhcVdLbBToY+fqZlHughqB4Vu6XB6S0Qps7UuCXXbIyYZxLCmbq1936dJuGDunGay7Y9xjKrs/xeaaWxSZFbhnrHCpQI2GSlMCXVAE1mgPjoY5JqYVD9lnUJb1uSPa9Y/95kHnNKh9TDo7+Y4LU3BXSXwhiDdTCbrcITG6YJjXsweAj9raAnJ77o+FBiXPKFwamuENX9ohuKgUgVTnLc3B1CqHIQHPlyu3n/sRH2OuPIWVzfaOrANDFDwBB8c8P+zAAIa9QyusnS1PFh6gyW9IQnc+ROR0fYvqXxzRzKUAUf1IoHl5Trc2sI3NHa1yKfd85pGYUSpDgPQDz7HyOxBHnWkmc044i8O6juhu4AyMbM+GDiLVE4IuW1PAw1Cb78ECvaQErgseXyXJHKweVavia+8H3ea3hAIk9kSrouzLj/P3B9yElUkcWsu5t0aUIfNhJ8YR1h6F9oIdLyan7yMfUvpOux67PodhdtmQwlj0sNkxEcYHO8I2RUyNztD3Ra6wiRDTaESUcRlKgIAlFDd5DoTnvjfcVVOMRDWd6yBmxkRX/FWNQRrx6PXOxgRPAmlJFnt5o/y+vvxlyy/up5uPBUecEXjhrFv6eoKXg6Gsyo+WhznH3f6Bj1OudxlKQ8d55nWiT6AJchmUnjJTC5qsxCcug4Vxnjq4pRTPPyl9C0KHqdO9/I9Kx02DyY5GWB5whkIpyNSthIT927+retmH8PqlUW844PIe6bRN3+xKP+MAe/dMsOlWmy+hSFYZQKYq2gPpc7uO5Uv26197yqEL25bKLYhFXBhByl1R93sEBWfYTCozBOWvWHrHv40A89jA6qQXHO1OaJwTAuentUU3qrLvIbM7qcsYmCrXKucboTzsq8ei2TK8L0ZuWkjoFC7WmUyWmhAs7QqPNXpnjH3uCHAGQtUm5mgX4d+mfeVqH09YpqIN/h3LeOXX5PtEYESaBYpiDUO1h/mx6Hf3paZulh4pYT1V2NyIhv/w4OblkbCGusKs81UMC5T5EjZjygxvG3v8utY6v/GNGHtKP5zPHzu2RRKXeO3ZOgUXRBC4BM+ILbi7kXqq6qjFU9s29BPy/pC9ELHtbtq7x07T2UFIc1Bnnke2MdNhYZqR0vkUGKBPfKhYs9GJo1boIOI/KO2x8HDJBV/knTLaQuKhEeFspJWAL9bCZ1IGa10sWIUAA6CIyqNQljq9VUMPvStHWFwPyOS8HIzQX6TjfHsX9bbOyJsWTfefGB07sun8oVAbjJ3zoSAB6aeUPgZVdjv6DWX2WGqp2mpwgYMxfyrBFrcyguALnpEnoQ0RcMFZ9X9yZ4eDtPbc9vNiFUQedpfZ0BDZ+NlNMTF2Dg+cZ74KD0g/23x5yE+FUo9sI8rn+Pm962D22haPen3QIGUHCZM9jQpaZT3IBVB99QCdi5r9LxoAKLUcSQI1Gr0IDO31LdDr2EAUC72OR5GRSSXdE8hFECIi78d/JVNr5G1ltPd9HBFL6Bm7Am8v4WXvQPQbax/BIXLMbMn65ZBOf1V5kcl2poKyqsleFAo9CkEU9qGLAr7bbbpYhTcaABpSNekwA5o7o2hJ6L+P0+MrYfoBuCMtbbW9Hp8Hs6q7F8305mjeM5CKmtANZ7+ILmF89mr1znui04SO/f6yR1WGG1LMWajJrKX4+p0+m46MkNb3ffnQWj7IHjKTvUK+5ez/tisVkBFJ5VIujo6U1WHjYMgt6lr/kuVltC8Z6hVWJoVoWMpqcwz2+GZVkoqpvklMT8cfvRefDEpkALo+P1wLycEXBW7gOMsKAVIFcGVIm3G5D8TwUjchg/H7sn5Bw8fBEGkeUdAF26IXetRXzLRwJvVj8G88mQ1EUE0eHslYJwqYKPo+N8bbGMfwrQSDp4y4QLRT2avFYHRyuCVI2vhkj4zYgskOyK5vu4OorKFmQ265owMct4o96ItRXgS0P2Ut5ViCH1k8PXM52+jSVT6SH2HJ/2dwx6NPvNBY0cKdP8umatubzo3/fj0YNwSqPjd66FM4RuZDWtu2xBVe8Y3LGdtO9RlJwTo0NzHDSnxo/8AzJIPObUL7Q9p+597Zpx9284Lz5Ggo14V2YgvE7skrVtRv3mUe+vWO3azLjk3eVkRzJfiJoAtMS70p61CaDsrasbMTHUSHPEueDdCEmrnUZK35ruhBlBj+0sYEGsa+u3KEdi9JT3Jw+HiWRZCRIYTEgpu7AzZKuqr1U5nr2RfqIbaiOm/vv7D5GRXgLydhsD38Ph7eGBNYANgRoP90bAfOPYErkV3zPw21zNrQoNxqx7wh0GAsF9eADy+V6B3JK7ovZlCRlVhLli/j/RYTqL93fI473T0wr2Jh8P5ZlN0jrPIVfJ1tLnZ/EZhJut6hN8di3kOaoTilV+RjlluRnBXtCCRVdWMTN4CyeGsC7nQBYK7SGKoEZ6pdHW2GX+3Cdyp4KEJLWYzRjLEAh9a6Iy+8AkloJlKEP5uHR09uRrfpKULD/KGoWnxaCiD2rfc/gY5V5vO4qFSf81PAV4RUPqDBqfEtQKgJ9DmDSeM+JpBhj93Bkxgw7UGqGEoehfw4Ib1wKpYYABifdww157mEWPqOCOU3cJTNBbCwlbuy7vetryQoX3863YdWc4J5AVviAF8Sz0KcjkkfJJ8X3LjhrmdTXK0W8Ea/Lie03hVVO21pfwI03w92MQPrU1e71Ae+OZhsdkUhaI8E1Fs58fVb8RO4VbOvyo2N8jG3TQymtcSgmOSjvoOZ+AAYEA3zjk6z/X60zd3wqsbLcVanmewXEI3o09AJ4LTvpu8mZ2OEdUVcw+/fhwt1nvEAMdrG4y3RZChIb6xbrK0bjZqL6tIV3lulLzSdqPGyMJJZe74D1N93o1GHQpz1cZN0EzbuzkpUEa6qegmlawE416+8NX6oZpRLWrijO9jIu6GmrjCicD2LiRDqgMepaTQ8py6YcCDTWrpm1AV5Y/WW2S6+aImKOE6OqeGlalL6WJV79PvL8fa91L3aW8EP1kK+ncVqeSAAYawh63mCZuT5T47Wv2Q6ZfXNJ7Zt/AsUYsrAjqs1ZZ9pn0B1j7P0SgtfXzPJZ8fm7jyrXK01lpM9Yhacawp4OalGeD9rLBHm/qT7Y3E0+jMVzsoKWbV+CguE3mRAV94VWB17UQOlveMXtPj1G0FFbpt9IglYaEDvfBkBRWe68OiV5A87BonlyoHOqmbbT8b9SFjHvtmnPUZ89wmKNkzdfX9VbGCNFYDuzy6ihF3USj42QrCZ1HMq1+SrcxRF+hNjtwwOGJYnTeR+SCTwpB66s57PvtkziFRMr5Pd37jtqhGPSnDaVPeSIDmE2QQCK6iJLJt3f0thWlmIQcJCkaas93ARWTP3mxYrsggHN33vltAjVgbfwHSzLvjtGt+aqLdRf9ZOkQKNT7VzbS8qM7qcruEZPquEmaNR288v2Pkm9KeXS9UG3fCrnBjTvaNDQ50VxNb53EWcvhdfVOvCMtAQMzitE5qRtI0hK8VASgEsOEdOpiVtJ+4Bkigbs6COz9vgqsgNUsdGgH4J3InsWAVYdw/k+creTq7vSVFNOE5iKBLec5Rt8kyL8m6H6B+yBzg9tHHvMMRAc/HquihSYeQGpq9T9TL3trQONoK1SrDOQNnNpHGfDH5jU8rseC3WZ73Orv1Q/8Z1fKcRdknLCKXvyr85hVx/JEPJRWUm2GT5frrnLbOWWSowtGouhJeB8G2DGoF42VQ0hBCpAPLDm7s4DvbmBa+oJhMZOl4MjKVH5/fktPgKzSg0x7ycYlBdAobjDSjSyBxvsXYMnbDjZ813y4vmZtHbwvmHfHjD1TaTOWR2Noez3lizm9+Ps1msRgWBR0s/cXSj4SZIvv2V/Mj9SN2MqYxNaiTAs3MVmKB8Ky163ValzYWbsxz0oiSYpbe0Em5gRuQUEwUVsZxvcfG5goUejIG0OFFmnvyw/1TqskAD6hi4r8lu/bSvTUFaRJxIgIEsnzPy7YrnHbNwD4RU9PjQBZgvas48K1HJZwgOLp2zkb3xaGvd2BgdSBO/suF2I3oirD5qnp+qvlMXMJIGYyK+wLkasMB+eHr1mn41JCg3lymLSUJP5/mCMIyYU63W+J3zuPfj1fmcsM6iGo/JNMIo4UuihkTRHNwAyI4CaTQMZ8pmPouCIlsTuzmIShFdxPQOM9mVL5sDOk0tymswN1QfMm11YQ/FwlHtdnVFpIb+3mJ" },
    { 7377, "AQIDCAkKCyYnJCUXFBUWG///Gv//////////////////////////BAUGBwwNDg8QERIT/xgZ/x8cHR7//////////////////////////wABAgM9Pj88/////xsYGRojICEi/////wgJCgsQERIT/////yckJSb/////DA0ODzo7ODkfHB0e/////wQFBgdBQkNAFBUWF/////8rKCkqFRYXFP////8SExARCwgJCg8MDQ4ZGhsYHR4fHBITEBH//////////wAAAAAAAAAAcIIs7LMnwOXkhVc16gyuQSPva5NFGaUh7Q5PTh1lkr2GuK+PfOsfzj4w3F9exQsapuE5ytVHXT3ZAVrWUVZsTYsNmmb7zLAtdBIrIPCxhJnfTMvCNH52BW23qTHRFwTXFFg6Yd4bERwyD5wWUxjyIv5Ez7LDtXqRJAjoqGD8aVCq0KB9oYlil1RbHpXg/2TSEMQASKP3dduKA+baCT/dlIdcgwLNSpAzc2f2851/v+JSm9gmyDfGO4GWb0sTvmMu6XmnjJ9uvI4p9fm2L/20WXiYBmrnRnG61CWrQoiijfpyB7lV+O6sCjZJKmg8OPGkQCjTe7vJQ8EV4630d8eAnuAFWNlnToHLyQuuatUYXYJG39YnijJLQtscnpw6yiV7DXFfH/jXPp18YLm+vIsWNE3DcpWrjrp6swK0raKs2JoXGjXM95lhWugkVkDhYwkzv5iXhWj87Arab1Nioy4IryiwdMK9NiI4ZB45LKYw5UT9iJ9lh2v0I0gQ0VHA+dKgVaFB+kMTxC+otjwrwf/IpSCJAJBH7+q3FQbNtRJ+uykPuAcEm5QhZubO7ec7/n/FpDexTJFujXYDLd6WJn3GXNPyTxk/3HkdUuvzbV77abLwMQzUz4zidalKV4QRRRv15A5zqvHdWRRsklTQeHDjSYBQp/Z3k4aDKsdb6e6PAT04QRZ22ZNg8nLCq5p1Blegkfe1yaKM0pD2B6cnjrJJ3kNc18c+9Y9nHxhury/ihQ1T8Jxl6qOunuyALWuoKzamxYZNM/1mWJY6CZUQeNhCzO8m5WEaPzuCttvUmOiLAusKLB2wb42IDhmHTgupDHkRfyLnWeHaPcgSBHRUMH60KFVoUL7QxDHLKq0PynD/MmkIYgAk0fu67UWBc22En+5Kwy7BAeYlSJm5s3v5zr/fcSnNbBNkm2OdwEu3pYlfsRf0vNNGzzdeR5T6/FuX/lqsPEwDNfMjuF1qktUhRFHGfTmD3Kp8d1YFG6QVNB4c+FIgFOm93eSh4Irx1nq740BPcCyzwORX6q4ja0Wl7U8dkoavfB8+3F4LpjnVXdlaUWyLmvuwdCvwhN/LNHZtqdEEFDreETKcU/L+z8N6JOhgaaqgoWJUHuBkEACjdYrmCd2Hg82Qc/adv1LYyMaBbxNj6aefvCn5L7R4Budx1KuIjXK5+Kw2KjzxQNO7QxWtd4CC7CflhTUMQe+TGSEOTmW9uI/rzjBfxRrhykc9AdZWTQ1mzC0SILGZTMJ+BbcxF9dYYRscDxYYIkSytZEIqPxQ0H2Jl1uV/9LESPfbA9o/lFwCSjNn83/imyY3O5ZLvi55jG6O9bb9WZhqRrolQqL6B1XuCkloOKQoe8nB4/THngIAAAABAAAAgAAAAKkp" },
    { 8632, "EAAAAKwpAAADAAAAAQAAAMAAAACpKQ==" },
    { 8664, "EAAAAKwpAAAEAAAAAQAAAAABAACpKQ==" },
    { 8696, "EAAAAKwpAAAFAAAAAgAAAIAAAACpKQAAEAAAAAAAAAAQAAAArCkAAAYAAAACAAAAwAAAAKkpAAAQAAAAAAAAABAAAACsKQAABwAAAAIAAAAAAQAAqSkAABAAAAAAAAAAEAAAAKwpAAAIAAAAAwAAAIAAAACpKQAAEAAAAAAAAAAQAAAArCkAAAkAAAADAAAAwAAAAKkpAAAQAAAAAAAAABAAAACsKQAACgAAAAMAAAAAAQAAqSkAABAAAAAAAAAAEAAAAKwpAAALAAAABQAAAIAAAACpKQAAEAAAAAAAAAAQAAAArCkAAAwAAAAFAAAAwAAAAKkpAAAQAAAAAAAAABAAAACsKQAADQAAAAUAAAAAAQAAqSkAABAAAAAAAAAAEAAAAKwpAAAOAAAABgAAAIAAAACpKQAADAAAAAEAAAAQAAAA1CkAAA8AAAAGAAAAwAAAAKkpAAAMAAAAAQAAABAAAADUKQAAEAAAAAYAAAAAAQAAqSkAAAwAAAABAAAAEAAAANQpAAArAAAACAAAAIAAAACpKQAADAAAAAEAAAAQAAAA/CkAACwAAAAIAAAAwAAAAKkpAAAMAAAAAQAAABAAAAD8KQAALQAAAAgAAAAAAQAAqSkAAAwAAAABAAAAEAAAAPwpAAAqAAAABwAAAIAAAACpKQ==" },
    { 9208, "AQAAACQqAAAmAAAAAQAAAIAAAACpKQAACAAAAAIAAAAIAAAATCoAACcAAAACAAAAgAAAAKkpAAAIAAAAAgAAAAgAAABMKgAAKAAAAAMAAACAAAAAqSkAAAgAAAACAAAACAAAAEwqAAApAAAABQAAAIAAAACpKQAACAAAAAIAAAAIAAAATCoAABEAAAABAAAAgAAAAKkpAAAQAAAAAAAAABAAAAB0KgAAEgAAAAEAAADAAAAAqSkAABAAAAAAAAAAEAAAAHQqAAATAAAAAQAAAAABAACpKQAAEAAAAAAAAAAQAAAAdCoAABQAAAACAAAAgAAAAKkpAAAQAAAAAAAAABAAAAB0KgAAFQAAAAIAAADAAAAAqSkAABAAAAAAAAAAEAAAAHQqAAAWAAAAAgAAAAABAACpKQAAEAAAAAAAAAAQAAAAdCoAABcAAAADAAAAgAAAAKkpAAAQAAAAAAAAABAAAAB0KgAAGAAAAAMAAADAAAAAqSkAABAAAAAAAAAAEAAAAHQqAAAZAAAAAwAAAAABAACpKQAAEAAAAAAAAAAQAAAAdCoAABoAAAAFAAAAgAAAAKkpAAAQAAAAAAAAABAAAAB0KgAAGwAAAAUAAADAAAAAqSkAABAAAAAAAAAAEAAAAHQqAAAcAAAABQAAAAABAACpKQAAEAAAAAAAAAAQAAAAdCoAAB0AAAAGAAAAgAAAAKkpAAAMAAAAAQAAABAAAACcKgAAHgAAAAYAAADAAAAAqSkAAAwAAAABAAAAEAAAAJwqAAAfAAAABgAAAAABAACpKQAADAAAAAEAAAAQAAAAnCoAAC4AAAAIAAAAgAAAAKkpAAAMAAAAAQAAABAAAADEKgAALwAAAAgAAADAAAAAqSkAAAwAAAABAAAAEAAAAMQqAAAwAAAACAAAAAABAACpKQAADAAAAAEAAAAQAAAAxCoAACAAAAABAAAAQAAAAKkpAAAIAAAAAAAAAAgAAADsKgAAIgAAAAEAAACAAAAAqSkAAAgAAAAAAAAACAAAABQrAAAkAAAAAQAAAMAAAACpKQAACAAAAAAAAAAIAAAAPCsAACEAAAACAAAAQAAAAKkpAAAIAAAAAAAAAAgAAADsKgAAIwAAAAIAAACAAAAAqSkAAAgAAAAAAAAACAAAABQrAAAlAAAAAgAAAMAAAACpKQAACAAAAAAAAAAIAAAAPCsAAAIAAACgIQAAAwAAAMAhAAAEAAAA4CEAAAUAAAAAIgAABgAAACAiAAAHAAAAQCIAAAgAAABgIgAACQAAAIAiAAAKAAAAoCIAAAsAAADAIgAADAAAAOAiAAANAAAAACMAAA4AAAAgIwAADwAAAEAjAAAQAAAAYCMAACsAAACAIwAALAAAAKAjAAAtAAAAwCMAACoAAADgIwAAJgAAAAAkAAAnAAAAICQAACgAAABAJAAAKQAAAGAkAAARAAAAgCQAABIAAACgJAAAEwAAAMAkAAAUAAAA4CQAABUAAAAAJQAAFgAAACAlAAAXAAAAQCUAABgAAABgJQAAGQAAAIAlAAAaAAAAoCUAABsAAADAJQAAHAAAAOAlAAAdAAAAACYAAB4AAAAgJgAAHwAAAEAmAAAuAAAAYCYAAC8AAACAJgAAMAAAAKAmAAAgAAAAwCYAACIAAADgJgAAJAAAAAAnAAAhAAAAICcAACMAAABAJwAAJQAAAGAn" },
    { 10496, "JTAyeAAtKyAgIDBYMHgALTBYKzBYIDBYLTB4KzB4IDB4AF8weCV4AG91dGVySGVpZ2h0AGlubmVySGVpZ2h0AG5hdmlnYXRvcgBmdW5jdGlvbgBsb2NhdGlvbgBuYW4AcHJvdG9jb2wAc2V0SW50ZXJ2YWwAaW5mAGNocm9tZQBob3N0bmFtZQAlZABjZGMATkFOAElORgBodHRwczoALgAsAChudWxsKQAAAAIAAAABAAAAAgAAAAMAAAAEAAAAAAAAAAUAAAAGAAAABwAAAAgAAAAC" },
    { 10732, "CQAAAAkAAAAKAAAACwAAAAI=" },
    { 10772, "DAAAAAwAAAANAAAADgAAAAc=" },
    { 10808, "DwAAABAAAAAQAAAAEQAAABIAAAAGAAAAEwAAABQAAAAVAAAAFgAAAAAAAAAXAAAAFwAAABgAAAAZAAAABQAAABoAAAAbAAAAHAAAAB0AAAAAAAAAHgAAAB8AAAAgAAAAIQAAAAU=" },
    { 10932, "IgAAACIAAAAKAAAACwAAAAU=" },
    { 10972, "IwAAACMAAAANAAAADgAAAAMAAAAkAAAAJQ==" },
    { 11012, "JgAAACcAAAAoAAAAKQAAAAMAAAAqAAAAKw==" },
    { 11052, "LAAAAC0AAAAuAAAALwAAAAQAAAAqAAAAKw==" },
    { 11092, "MAAAADEAAAAuAAAALw==" },
    { 11128, "IBwAAAAAAABAOAAAAAAAAGAkAAAAAAAAgHAAAAAAAACgbAAAAAAAAMBIAAAAAAAA4FQAAAAAAAAA4QAAAAAAACD9AAAAAAAAQNkAAAAAAABgxQAAAAAAAICRAAAAAAAAoI0AAAAAAADAqQAAAAAAAOC1AAAAAAAAmC+KQpFEN3HP+8C1pdu16VvCVjnxEfFZpII/ktVeHKuYqgfYAVuDEr6FMSTDfQxVdF2+cv6x3oCnBtybdPGbwcFpm+SGR77vxp3BD8yhDCRvLOktqoR0StypsFzaiPl2UlE+mG3GMajIJwOwx39Zv/ML4MZHkafVUWPKBmcpKRSFCrcnOCEbLvxtLE0TDThTVHMKZbsKanYuycKBhSxykqHov6JLZhqocItLwqNRbMcZ6JLRJAaZ1oU1DvRwoGoQFsGkGQhsNx5Md0gntbywNLMMHDlKqthOT8qcW/NvLmjugo90b2OleBR4yIQIAseM+v++kOtsUKT3o/m+8nhxxikuQ8mi2HwBPTZUoezwBhNipwXzwMdzjJiTK9m8TILKHptXPP3U4BZnQm8YihflEr5OxNbant5JoPv1jrsv7nqpaHmRFbIHP5TCEIkLIl8hgH9dmlqQMic1Psznv/eXA/8ZMLNIpbXR116SKqxWqsZPuDjSlqR9tnb8a+KcdATxRZ1wWWRxhyCGW89l5i2oAhtgJa2usLn2HEZhaTRAfg9VR6Mj3VGvOsNc+c66xeomLFMNboUohAnT3830QYFNUmrcN8hswav6JOF7CAy9sUp4iJWL42PobenL1f47AB058u+3DmZY0OSmd3L463VLCjFEULSP7R8a25mNM58RgxSA" },
    { 11824, "EQAKABEREQAAAAAFAAAAAAAACQAAAAALAAAAAAAAAAARAA8KERERAwoHAAEACQsLAAAJBgsAAAsABhEAAAARERE=" },
    { 11905, "CwAAAAAAAAAAEQAKChEREQAKAAACAAkLAAAACQALAAAL" },
    { 11963, "DA==" },
    { 11975, "DAAAAAAMAAAAAAkMAAAAAAAMAAAM" },
    { 12021, "Dg==" },
    { 12033, "DQAAAAQNAAAAAAkOAAAAAAAOAAAO" },
    { 12079, "EA==" },
    { 12091, "DwAAAAAPAAAAAAkQAAAAAAAQAAAQAAASAAAAEhIS" },
    { 12146, "EgAAABISEgAAAAAAAAk=" },
    { 12195, "Cw==" },
    { 12207, "CgAAAAAKAAAAAAkLAAAAAAALAAAL" },
    { 12253, "DA==" },
    { 12265, "DAAAAAAMAAAAAAkMAAAAAAAMAAAMAAAwMTIzNDU2Nzg5QUJDREVG" },
    { 12340, "Ng==" },
    { 12379, "//////8=" },
    { 12448, "MDEyMzQ1Njc4OWFjZGVmZ2hpamtucHFyc3R1dnd4eXpBQkNFRkdISktMTU5QUlNUVVZXWFla" },
    { 12516, "A4Nr8vdwO+H081ATH5eaxxwU8TXo56Em62TK1M9Y2YrM27J4OCjiazuriZnQz0NN00wovye/eKwkPBNeb8deEGxENeKYt2XxmzQOA3BQxNdz068lhyD/NoSjlMSgn4eaoxzsaFfvvHtUbNeJvwgdXbyLdq9IeCa8S/tNTt6OvSDdDdbSKf6GwSp97TPBGSfnwppMFTZpHAY16nf0EdZkqhJVD1jmpl9L5SU0uQ5B/m0NwpWf+THFjPqyrn6xSeMwssqIwkY52NFFurMjrt55961dEgVZrkIWWi0p5H4ROrp9klFIiWEBW4riaqlhhqB9YgXLj5b2m5yVdfBuvB17Qb+eELNLbUCgSO4rUqOK4YagCYp0VPraZ1d5sZVzRaLLcMbJOYQ1mSqHtvLYbNI4DG9RU/6bogPtmCFoH9PaJVHQWU6jJKoesCcpdULMTb+Wz87UZDs9hHc4vu+FHIL82x8Blynr8sc66HGsyAMVZhwAlg3u9GVd/ffmNg9ik8ZhYRCtk5Xj/YCWYJZyfQRcpn6HN1SKdGdHifcMta3LH+uuSHQZWrskClk4T/iyXIUssd/u3kUsvs1Gr9U/DVSYcQ7X84P6JKOQ+afIYhLDArYRQGlE5bM5V+YwUqXCDEH7wY8qCTV8eho2/xHo3ZvbPN4YsM4q6+DdKWiLL3g79oJ7uJ1wj0vNY4zIppFnrGxFZC8Ht5DcV6STXzxWt2MvCLTgRPpAExTpQ5B/G6j0tc+rd949X4SOLlwH5dwX/KiSFH/DYOCMk3PjD/iBCGsyVQvoWaf/Gwm0/JhiRtikcRjbJxrqL9RK+SxXIQvHM+vfxLCALTBD0D4zwLvMprVLoqU2IFBRxXBDUkYbsbki0WW6obqXTlLqhE3RgXZp7ZIoam752p6dqcmdHsI7dnoI73X5Yx2BCjMOgolY/MlyFbLK8X5APgIuUz2BRaHW5Y911WbkhyGVtJQiFt9mBirMOAWpp8rxWvfZ8tmcKxm9Vv8aPj0N7s1tHu1OBuzEJo3Dx6XmMTNWtiIw1d3Q27EXBNgyfPYswSzlL0JHFwt+VEkI/T+7/A5vqP+NBFoU6c6OF2qlfOOZ9W/gGp6dq+HT06hiuCFckegyXxKDwLR2SRS39SLmQwZy9UCFGQdkuQpZZzphq5PJMbiQSlpKey6Qnnit+2yMXqt/j93AjRqoMOMZK1sR7dgLAu5bYPAFP6okBrzB1vJPkcXxzPo31fDpadZzgpsigNKIIQO5espnc67J5BhcPRdITz6UI711b27zduwFAYIfVRKBnD7gavj0NGl7n8adiM/VngukJ7o3t3m5tNyLTUeMmE7E52qloC2+piNGTFLQFl9RU32tOAAAADkAAAA6AAAAWpWvv/d2f3+eJJdQhSN53bNijAzUaj1knBNuDvRNumXybgbWgAuHVAeNMEVoPZ/+6S6CjMiIJLO7py3BKxJ7XA==" },
    { 13612, "cH1Q" },
    { 13788, "GH0=" },
}

local exports = {}
exports.g = function()

I32[8015] = tobit(32011)
end
exports.h = function(v_A, v_r)
local v_e = 0
v_A = tobit(v_A)
v_r = tobit(v_r)
v_e = 0
if not (I32[8014] ~= 0) then
v_e = F.fm(12)
I32[8014] = tobit(v_e)
I32[arshift(v_e, 2)] = tobit(64)
I32[arshift((v_e + 4), 2)] = tobit(0)
I32[arshift((v_e + 8), 2)] = tobit(F.fOA(64, 16))
end
v_e = I32[8012]
if (v_e ~= 0) then
F.fL(v_e)
end
I32[8013] = tobit(v_r)
v_e = F.fm(tobit((v_r + 1)))
I32[8012] = tobit(v_e)
F.fPA(tobit((v_r + v_e)), 0, (((-1) ~= bor(0, v_r)) and 1 or 0))
F.fTA(v_e, v_A, v_r)
do return 0 end
end
exports.i = function(v_A, v_r, v_e)
local v_n, v_t, v_o, v_f = 0, 0, 0, 0
v_A = tobit(v_A)
v_r = tobit(v_r)
v_e = tobit(v_e)
v_o = 0
v_f = 0
v_n = tobit((B - 16))
B = v_n
v_o = I32[8014]
if not (v_o ~= 0) then
v_o = F.fm(12)
I32[8014] = tobit(v_o)
I32[arshift(v_o, 2)] = tobit(64)
I32[arshift((v_o + 4), 2)] = tobit(0)
I32[arshift((v_o + 8), 2)] = tobit(F.fOA(64, 16))
end
v_t = F.fm(12)
v_f = F.fm(11)
I32[arshift(v_t, 2)] = tobit(v_f)
v_e = F.fsA(v_f, v_e)
v_f = F.fm(v_r)
I32[arshift((v_t + 4), 2)] = tobit(v_f)
F.fTA(v_f, v_A, v_r)
I32[arshift((v_t + 8), 2)] = tobit(v_r)
do
do
while true do
do
if (not (F.fG(v_o, v_e, 10, tobit((v_n + 12))) ~= 0)) then
if (not (F.ftA(v_o) ~= 0)) then
goto C380
end
goto L379
end
goto B380
end
::C380::
end
end
::B380::
v_A = 0
v_r = tobit((I32[arshift((v_o + 8), 2)] + lshift(I32[arshift((v_n + 12), 2)], 4)))
v_f = I32[arshift((v_r + 8), 2)]
if (1 == bor(0, v_f)) then
v_A = I32[arshift((v_r + 12), 2)]
end
I32[arshift((v_r + 4), 2)] = tobit(10)
I32[arshift(v_r, 2)] = tobit(v_e)
I32[arshift((v_r + 12), 2)] = tobit(v_t)
if not (v_f ~= 0) then
I32[arshift((v_r + 8), 2)] = tobit(1)
I32[arshift((v_o + 4), 2)] = tobit((I32[arshift((v_o + 4), 2)] + 1))
end
if (v_A ~= 0) then
F.fL(I32[arshift(v_A, 2)])
F.fL(I32[arshift((v_A + 4), 2)])
F.fL(v_A)
end
end
::L379::
B = tobit((v_n + 16))
end
exports.j = function(v_A, v_r, v_e, v_n)

v_A = tobit(v_A)
v_r = tobit(v_r)
v_e = tobit(v_e)
v_n = tobit(v_n)
YA[bor(0, imul(bxor(32096, I32[8024]), bor(0, YA[bxor(32092, I32[8023])]())))](v_A, v_r, v_e, v_n)
end
exports.k = function(v_A, v_r)
local v_e, v_n, v_t, v_o, v_a, v_u, v_c = 0, 0, 0, 0, 0, 0, 0
v_r = tobit(v_r)
v_n = 0
v_t = 0
v_o = 0
v_a = 0
v_u = 0
v_c = 0
do
v_e = tobit((B - 304))
B = v_e
v_A = tobit(v_A)
if (not (bor(((not (v_A ~= 0)) and 1 or 0), ((not (U8[bor(0, v_A)] ~= 0)) and 1 or 0)) ~= 0)) then
do
do
v_a = v_A
v_u = v_r
v_c = tobit((v_e + 288))
if (v_r ~= 0) then
do
do
do
v_t = (-1)
while true do
do
v_t = bxor(U8[tobit((v_A + v_n))], v_t)
v_o = tobit((rshift(v_t, 1) % 4294967296))
local t436 = band((0 - band(1, v_o)), (-306674912))
v_t = tobit((rshift(bxor(v_o, band((0 - band(1, v_t)), (-306674912))), 1) % 4294967296))
v_o = tobit((rshift(bxor(t436, v_t), 1) % 4294967296))
local t437 = band((0 - band(1, v_o)), (-306674912))
v_t = tobit((rshift(bxor(v_o, band((0 - band(1, v_t)), (-306674912))), 1) % 4294967296))
v_o = tobit((rshift(bxor(t437, v_t), 1) % 4294967296))
local t438 = band((0 - band(1, v_o)), (-306674912))
v_t = tobit((rshift(bxor(v_o, band((0 - band(1, v_t)), (-306674912))), 1) % 4294967296))
v_o = tobit((rshift(bxor(t438, v_t), 1) % 4294967296))
v_t = bxor(band((0 - band(1, v_o)), (-306674912)), (rshift(bxor(v_o, band((0 - band(1, v_t)), (-306674912))), 1) % 4294967296))
v_n = tobit((v_n + 1))
if not (bor(0, v_n) ~= bor(0, v_r)) then goto B381 end
end
do
end
::C381::
end
end
::B381::
end
v_A = bxor((-1), v_t)
end
else
v_A = 0
end
end
YA[I32[arshift((13536 + lshift(fmod((tobit(v_A) % 4294967296), 3), 2)), 2)]](v_a, v_u, v_c)
v_A = I32[arshift((13536 + lshift(fmod((tobit((rshift(v_A, 8) % 4294967296)) % 4294967296), 3), 2)), 2)]
YA[bor(0, v_A)](tobit((v_e + 288)), 16, tobit((v_e + 272)))
YA[bor(0, v_A)](tobit((v_e + 272)), 16, tobit((v_e + 256)))
v_n = F.fOA(33, 1)
I32[arshift((v_e + 240), 2)] = tobit(U8[tobit((v_e + 256))])
F.fgA(v_n, 10496, tobit((v_e + 240)))
I32[arshift((v_e + 224), 2)] = tobit(U8[tobit((v_e + 257))])
F.fgA(tobit((v_n + 2)), 10496, tobit((v_e + 224)))
I32[arshift((v_e + 208), 2)] = tobit(U8[tobit((v_e + 258))])
F.fgA(tobit((v_n + 4)), 10496, tobit((v_e + 208)))
I32[arshift((v_e + 192), 2)] = tobit(U8[tobit((v_e + 259))])
F.fgA(tobit((v_n + 6)), 10496, tobit((v_e + 192)))
I32[arshift((v_e + 176), 2)] = tobit(U8[tobit((v_e + 260))])
F.fgA(tobit((v_n + 8)), 10496, tobit((v_e + 176)))
I32[arshift((v_e + 160), 2)] = tobit(U8[tobit((v_e + 261))])
F.fgA(tobit((v_n + 10)), 10496, tobit((v_e + 160)))
I32[arshift((v_e + 144), 2)] = tobit(U8[tobit((v_e + 262))])
F.fgA(tobit((v_n + 12)), 10496, tobit((v_e + 144)))
I32[arshift((v_e + 128), 2)] = tobit(U8[tobit((v_e + 263))])
F.fgA(tobit((v_n + 14)), 10496, tobit((v_e + 128)))
I32[arshift((v_e + 112), 2)] = tobit(U8[tobit((v_e + 264))])
F.fgA(tobit((v_n + 16)), 10496, tobit((v_e + 112)))
I32[arshift((v_e + 96), 2)] = tobit(U8[tobit((v_e + 265))])
F.fgA(tobit((v_n + 18)), 10496, tobit((v_e + 96)))
I32[arshift((v_e + 80), 2)] = tobit(U8[tobit((v_e + 266))])
F.fgA(tobit((v_n + 20)), 10496, tobit((v_e + 80)))
I32[arshift((v_e + 64), 2)] = tobit(U8[tobit((v_e + 267))])
F.fgA(tobit((v_n + 22)), 10496, tobit((v_e - (-64))))
I32[arshift((v_e + 48), 2)] = tobit(U8[tobit((v_e + 268))])
F.fgA(tobit((v_n + 24)), 10496, tobit((v_e + 48)))
I32[arshift((v_e + 32), 2)] = tobit(U8[tobit((v_e + 269))])
F.fgA(tobit((v_n + 26)), 10496, tobit((v_e + 32)))
I32[arshift((v_e + 16), 2)] = tobit(U8[tobit((v_e + 270))])
F.fgA(tobit((v_n + 28)), 10496, tobit((v_e + 16)))
I32[arshift(v_e, 2)] = tobit(U8[tobit((v_e + 271))])
F.fgA(tobit((v_n + 30)), 10496, v_e)
end
end
end
B = tobit((v_e + 304))
do return bor(0, v_n) end
end
exports.l = function(v_A, v_r)
local v_e, v_t, v_o, v_a, v_u, v_c, v_s, v_l, v_b, v_v, v_g, v_p, v_d, v_h, v_k = 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
v_A = tobit(v_A)
v_r = tobit(v_r)
v_t = 0
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
v_d = 0
v_h = 0
v_k = 0
v_r = F.fOA(64, 1)
v_e = v_r
v_b = tobit((B - 16))
B = v_b
v_c = v_A
do
v_s = U8[bor(0, v_A)]
if (v_s ~= 0) then
do
do
while true do
do
if (not (F.fRA(arshift(lshift(v_s, 24), 24)) ~= 0)) then
goto L383
end
v_s = U8[tobit((v_c + 1))]
v_A = tobit((v_c + 1))
v_c = v_A
if (not (v_s ~= 0)) then
goto B384
end
end
::C384::
end
end
::B384::
v_c = v_A
goto L382
end
::L383::
v_A = U8[bor(0, v_c)]
do
local sw385 = tobit((v_A - 43))
if sw385 == 0 then goto K385_0
elseif sw385 == 2 then goto K385_1
else goto K385_2 end
::K385_0::
do
end
::K385_1::
do
goto S385
end
::K385_2::
do
goto L382
end
end
::S385::
v_d = ((45 == bor(0, v_A)) and (-1) or 0)
v_c = tobit((v_c + 1))
end
end
::L382::
do
do
v_A = 0
while true do
do
do
do
do
do
v_t = I8[bor(0, v_c)]
v_s = tobit((v_t - 48))
if (not ((tobit(band(255, v_s)) % 4294967296) <= 9)) then
if ((tobit(band((v_t - 97), 255)) % 4294967296) <= 25) then
v_s = tobit((v_t - 87))
else
if ((tobit(band((v_t - 65), 255)) % 4294967296) > 25) then
goto L387
end
v_s = tobit((v_t - 55))
end
end
do
if (not (bor(0, v_s) >= 10)) then
do
do
v_t = 0
v_v = v_t
v_t = F.fCA(v_o, v_t, 0, 0)
v_l = Iv
v_k = F.fCA(v_u, 0, 10, 0)
v_g = tobit((0 + v_t))
v_t = v_l
v_l = v_g
v_g = (((tobit(v_g) % 4294967296) < 0) and tobit((v_t + 1)) or v_t)
v_a = Iv
v_t = v_a
v_v = tobit((F.fCA(v_o, v_v, 10, 0) + v_t))
v_a = Iv
v_a = (((tobit(v_t) % 4294967296) > (tobit(v_v) % 4294967296)) and tobit((v_a + 1)) or v_a)
v_t = v_g
v_p = v_l
v_l = v_a
v_a = tobit((v_p + v_a))
I32[arshift((v_b + 8), 2)] = tobit(v_a)
I32[arshift((v_b + 12), 2)] = tobit((((tobit(v_a) % 4294967296) < (tobit(v_l) % 4294967296)) and tobit((v_t + 1)) or v_t))
I32[arshift(v_b, 2)] = tobit(v_k)
I32[arshift((v_b + 4), 2)] = tobit(v_v)
v_t = 1
if not (bor(I32[arshift((v_b + 8), 2)], I32[arshift((v_b + 12), 2)]) ~= 0) then
v_v = F.fCA(v_u, v_o, 10, 0)
v_l = v_s
v_a = Iv
local t440 = bor(0, v_a)
local t439 = (-1)
v_p = arshift(v_s, 31)
v_g = bxor(t439, v_p)
if not (bor(band(((t440 == bor(0, v_g)) and 1 or 0), (((tobit(v_v) % 4294967296) > (tobit(bxor((-1), v_s)) % 4294967296)) and 1 or 0)), (((tobit(v_g) % 4294967296) < (tobit(v_a) % 4294967296)) and 1 or 0)) ~= 0) then
v_t = tobit((v_a + v_p))
v_o = tobit((v_l + v_v))
v_u = v_o
v_t = (((tobit(v_o) % 4294967296) < (tobit(v_l) % 4294967296)) and tobit((v_t + 1)) or v_t)
v_o = v_t
v_t = v_A
end
end
v_c = tobit((v_c + 1))
v_A = v_t
end
goto C386
end
end
end
end
end
::L387::
end
goto B386
end
end
::C386::
end
end
::B386::
end
do
do
do
do
if (v_A ~= 0) then
I32[5680] = tobit(68)
v_d = 0
v_u = (-1)
v_o = (-1)
else
if (bor((((-1) ~= bor(0, v_u)) and 1 or 0), (((-1) ~= bor(0, v_o)) and 1 or 0)) ~= 0) then
goto L389
end
end
if (not (bor(1, v_d) ~= 0)) then
I32[5680] = tobit(68)
v_u = (-2)
v_o = (-1)
goto L388
end
end
::L389::
do
v_A = v_d
v_t = bxor(v_A, v_u)
v_u = tobit((v_t - v_A))
v_l = v_o
local t441 = v_l
v_o = arshift(v_A, 31)
v_o = tobit((bxor(t441, v_o) - tobit(((((tobit(v_A) % 4294967296) > (tobit(v_t) % 4294967296)) and 1 or 0) + v_o))))
end
end
end
::L388::
end
B = tobit((v_b + 16))
do
do
do
if (bor(v_o, v_u) ~= 0) then
do
do
while true do
v_A = v_h
v_t = F.fS_(v_u, v_o, 54)
v_c = Iv
I8[tobit((v_e + v_A))] = tobit(U8[tobit((12448 + tobit((v_u - F.fCA(v_t, v_c, 54, 0)))))])
v_h = tobit((v_A + 1))
v_b = bor(band(((not (v_o ~= 0)) and 1 or 0), (((tobit(v_u) % 4294967296) > 53) and 1 or 0)), ((0 ~= bor(0, v_o)) and 1 or 0))
v_u = v_t
v_o = v_c
if not (v_b ~= 0) then goto B391 end
do
end
::C391::
end
end
::B391::
v_t = 0
I8[tobit((v_e + v_h))] = tobit(0)
if (not (v_A ~= 0)) then
goto L390
end
do
do
while true do
do
v_o = tobit((v_t + v_e))
v_u = U8[bor(0, v_o)]
v_l = v_o
v_o = tobit((v_A + v_e))
I8[bor(0, v_l)] = tobit(U8[bor(0, v_o)])
I8[bor(0, v_o)] = tobit(v_u)
v_A = tobit((v_A - 1))
local t442 = (tobit(v_A) % 4294967296)
v_t = tobit((v_t + 1))
if not (t442 > (tobit(v_t) % 4294967296)) then goto B392 end
end
do
end
::C392::
end
end
::B392::
end
end
else
I8[bor(0, v_e)] = tobit(97)
I8[tobit((v_e + 1))] = tobit(0)
end
end
end
::L390::
end
do return bor(0, v_r) end
end
exports.m = function(v_A, v_r)
local v_e = 0
v_A = tobit(v_A)
v_r = tobit(v_r)
v_e = 0
v_A = tobit((B - 16))
B = v_A
I8[tobit((v_A + 15))] = tobit(0)
imp_b(22294, tobit((v_A + 15)), 0)
v_r = tobit((B - 672))
B = v_r
I32[8018] = tobit((bor(0, imp_d(0)) - 1))
I32[8019] = tobit(0)
v_e = F.fMA()
I32[arshift((v_r + 464), 2)] = tobit(v_e)
F.fgA(tobit((v_r + 640)), 10530, tobit((v_r + 464)))
I8[tobit((v_r + 636))] = tobit(0)
I32[arshift((v_r + 632), 2)] = tobit(1768515945)
I32[arshift((v_r + 448), 2)] = tobit(10601)
I32[arshift((v_r + 456), 2)] = tobit(10570)
I32[arshift((v_r + 460), 2)] = tobit(500)
I32[arshift((v_r + 452), 2)] = tobit((v_r + 640))
imp_b(15204, tobit((v_r + 632)), tobit((v_r + 448)))
I8[tobit((v_r + 628))] = tobit(0)
I32[arshift((v_r + 624), 2)] = tobit(1768515945)
I32[arshift((v_r + 432), 2)] = tobit(imul(v_e, 27))
I32[arshift((v_r + 436), 2)] = tobit(imul(v_e, 517))
I32[arshift((v_r + 444), 2)] = tobit(imul(v_e, 197))
I32[arshift((v_r + 440), 2)] = tobit((v_r + 640))
imp_b(15372, tobit((v_r + 624)), tobit((v_r + 432)))
v_e = F.fMA()
I32[arshift((v_r + 416), 2)] = tobit(v_e)
F.fgA(tobit((v_r + 640)), 10530, tobit((v_r + 416)))
I8[tobit((v_r + 620))] = tobit(0)
I32[arshift((v_r + 616), 2)] = tobit(1768515945)
I32[arshift((v_r + 400), 2)] = tobit(10601)
I32[arshift((v_r + 408), 2)] = tobit(10570)
I32[arshift((v_r + 412), 2)] = tobit(500)
I32[arshift((v_r + 404), 2)] = tobit((v_r + 640))
imp_b(15913, tobit((v_r + 616)), tobit((v_r + 400)))
I8[tobit((v_r + 612))] = tobit(0)
I32[arshift((v_r + 608), 2)] = tobit(1768515945)
I32[arshift((v_r + 384), 2)] = tobit(imul(v_e, 27))
I32[arshift((v_r + 388), 2)] = tobit(imul(v_e, 517))
I32[arshift((v_r + 396), 2)] = tobit(imul(v_e, 197))
I32[arshift((v_r + 392), 2)] = tobit((v_r + 640))
imp_b(16081, tobit((v_r + 608)), tobit((v_r + 384)))
v_e = F.fMA()
I32[arshift((v_r + 368), 2)] = tobit(v_e)
F.fgA(tobit((v_r + 640)), 10530, tobit((v_r + 368)))
I8[tobit((v_r + 604))] = tobit(0)
I32[arshift((v_r + 600), 2)] = tobit(1768515945)
I32[arshift((v_r + 352), 2)] = tobit(10601)
I32[arshift((v_r + 360), 2)] = tobit(10570)
I32[arshift((v_r + 364), 2)] = tobit(500)
I32[arshift((v_r + 356), 2)] = tobit((v_r + 640))
imp_b(16622, tobit((v_r + 600)), tobit((v_r + 352)))
I8[tobit((v_r + 596))] = tobit(0)
I32[arshift((v_r + 592), 2)] = tobit(1768515945)
I32[arshift((v_r + 336), 2)] = tobit(imul(v_e, 27))
I32[arshift((v_r + 340), 2)] = tobit(imul(v_e, 517))
I32[arshift((v_r + 348), 2)] = tobit(imul(v_e, 197))
I32[arshift((v_r + 344), 2)] = tobit((v_r + 640))
imp_b(16790, tobit((v_r + 592)), tobit((v_r + 336)))
v_e = F.fMA()
I32[arshift((v_r + 320), 2)] = tobit(v_e)
F.fgA(tobit((v_r + 640)), 10530, tobit((v_r + 320)))
I8[tobit((v_r + 588))] = tobit(0)
I32[arshift((v_r + 584), 2)] = tobit(1768515945)
I32[arshift((v_r + 304), 2)] = tobit(10601)
I32[arshift((v_r + 312), 2)] = tobit(10570)
I32[arshift((v_r + 316), 2)] = tobit(500)
I32[arshift((v_r + 308), 2)] = tobit((v_r + 640))
imp_b(17331, tobit((v_r + 584)), tobit((v_r + 304)))
I8[tobit((v_r + 580))] = tobit(0)
I32[arshift((v_r + 576), 2)] = tobit(1768515945)
I32[arshift((v_r + 288), 2)] = tobit(imul(v_e, 27))
I32[arshift((v_r + 292), 2)] = tobit(imul(v_e, 517))
I32[arshift((v_r + 300), 2)] = tobit(imul(v_e, 197))
I32[arshift((v_r + 296), 2)] = tobit((v_r + 640))
imp_b(17499, tobit((v_r + 576)), tobit((v_r + 288)))
v_e = F.fMA()
I32[arshift((v_r + 272), 2)] = tobit(v_e)
F.fgA(tobit((v_r + 640)), 10530, tobit((v_r + 272)))
I8[tobit((v_r + 572))] = tobit(0)
I32[arshift((v_r + 568), 2)] = tobit(1768515945)
I32[arshift((v_r + 256), 2)] = tobit(10601)
I32[arshift((v_r + 264), 2)] = tobit(10570)
I32[arshift((v_r + 268), 2)] = tobit(500)
I32[arshift((v_r + 260), 2)] = tobit((v_r + 640))
imp_b(18040, tobit((v_r + 568)), tobit((v_r + 256)))
I8[tobit((v_r + 564))] = tobit(0)
I32[arshift((v_r + 560), 2)] = tobit(1768515945)
I32[arshift((v_r + 240), 2)] = tobit(imul(v_e, 27))
I32[arshift((v_r + 244), 2)] = tobit(imul(v_e, 517))
I32[arshift((v_r + 252), 2)] = tobit(imul(v_e, 197))
I32[arshift((v_r + 248), 2)] = tobit((v_r + 640))
imp_b(18208, tobit((v_r + 560)), tobit((v_r + 240)))
v_e = F.fMA()
I32[arshift((v_r + 224), 2)] = tobit(v_e)
F.fgA(tobit((v_r + 640)), 10530, tobit((v_r + 224)))
I8[tobit((v_r + 556))] = tobit(0)
I32[arshift((v_r + 552), 2)] = tobit(1768515945)
I32[arshift((v_r + 208), 2)] = tobit(10601)
I32[arshift((v_r + 216), 2)] = tobit(10570)
I32[arshift((v_r + 220), 2)] = tobit(500)
I32[arshift((v_r + 212), 2)] = tobit((v_r + 640))
imp_b(18749, tobit((v_r + 552)), tobit((v_r + 208)))
I8[tobit((v_r + 548))] = tobit(0)
I32[arshift((v_r + 544), 2)] = tobit(1768515945)
I32[arshift((v_r + 192), 2)] = tobit(imul(v_e, 27))
I32[arshift((v_r + 196), 2)] = tobit(imul(v_e, 517))
I32[arshift((v_r + 204), 2)] = tobit(imul(v_e, 197))
I32[arshift((v_r + 200), 2)] = tobit((v_r + 640))
imp_b(18917, tobit((v_r + 544)), tobit((v_r + 192)))
v_e = F.fMA()
I32[arshift((v_r + 176), 2)] = tobit(v_e)
F.fgA(tobit((v_r + 640)), 10530, tobit((v_r + 176)))
I8[tobit((v_r + 540))] = tobit(0)
I32[arshift((v_r + 536), 2)] = tobit(1768515945)
I32[arshift((v_r + 160), 2)] = tobit(10601)
I32[arshift((v_r + 168), 2)] = tobit(10570)
I32[arshift((v_r + 172), 2)] = tobit(500)
I32[arshift((v_r + 164), 2)] = tobit((v_r + 640))
imp_b(19458, tobit((v_r + 536)), tobit((v_r + 160)))
I8[tobit((v_r + 532))] = tobit(0)
I32[arshift((v_r + 528), 2)] = tobit(1768515945)
I32[arshift((v_r + 144), 2)] = tobit(imul(v_e, 27))
I32[arshift((v_r + 148), 2)] = tobit(imul(v_e, 517))
I32[arshift((v_r + 156), 2)] = tobit(imul(v_e, 197))
I32[arshift((v_r + 152), 2)] = tobit((v_r + 640))
imp_b(19626, tobit((v_r + 528)), tobit((v_r + 144)))
v_e = F.fMA()
I32[arshift((v_r + 128), 2)] = tobit(v_e)
F.fgA(tobit((v_r + 640)), 10530, tobit((v_r + 128)))
I8[tobit((v_r + 524))] = tobit(0)
I32[arshift((v_r + 520), 2)] = tobit(1768515945)
I32[arshift((v_r + 112), 2)] = tobit(10601)
I32[arshift((v_r + 120), 2)] = tobit(10570)
I32[arshift((v_r + 124), 2)] = tobit(500)
I32[arshift((v_r + 116), 2)] = tobit((v_r + 640))
imp_b(20167, tobit((v_r + 520)), tobit((v_r + 112)))
I8[tobit((v_r + 516))] = tobit(0)
I32[arshift((v_r + 512), 2)] = tobit(1768515945)
I32[arshift((v_r + 96), 2)] = tobit(imul(v_e, 27))
I32[arshift((v_r + 100), 2)] = tobit(imul(v_e, 517))
I32[arshift((v_r + 108), 2)] = tobit(imul(v_e, 197))
I32[arshift((v_r + 104), 2)] = tobit((v_r + 640))
imp_b(20335, tobit((v_r + 512)), tobit((v_r + 96)))
v_e = F.fMA()
I32[arshift((v_r + 80), 2)] = tobit(v_e)
F.fgA(tobit((v_r + 640)), 10530, tobit((v_r + 80)))
I8[tobit((v_r + 508))] = tobit(0)
I32[arshift((v_r + 504), 2)] = tobit(1768515945)
I32[arshift((v_r + 64), 2)] = tobit(10601)
I32[arshift((v_r + 72), 2)] = tobit(10570)
I32[arshift((v_r + 76), 2)] = tobit(500)
I32[arshift((v_r + 68), 2)] = tobit((v_r + 640))
imp_b(20876, tobit((v_r + 504)), tobit((v_r - (-64))))
I8[tobit((v_r + 500))] = tobit(0)
I32[arshift((v_r + 496), 2)] = tobit(1768515945)
I32[arshift((v_r + 48), 2)] = tobit(imul(v_e, 27))
I32[arshift((v_r + 52), 2)] = tobit(imul(v_e, 517))
I32[arshift((v_r + 60), 2)] = tobit(imul(v_e, 197))
I32[arshift((v_r + 56), 2)] = tobit((v_r + 640))
imp_b(21044, tobit((v_r + 496)), tobit((v_r + 48)))
v_e = F.fMA()
I32[arshift((v_r + 32), 2)] = tobit(v_e)
F.fgA(tobit((v_r + 640)), 10530, tobit((v_r + 32)))
I8[tobit((v_r + 492))] = tobit(0)
I32[arshift((v_r + 488), 2)] = tobit(1768515945)
I32[arshift((v_r + 16), 2)] = tobit(10601)
I32[arshift((v_r + 24), 2)] = tobit(10570)
I32[arshift((v_r + 28), 2)] = tobit(500)
I32[arshift((v_r + 20), 2)] = tobit((v_r + 640))
imp_b(21585, tobit((v_r + 488)), tobit((v_r + 16)))
I8[tobit((v_r + 484))] = tobit(0)
I32[arshift((v_r + 480), 2)] = tobit(1768515945)
I32[arshift(v_r, 2)] = tobit(imul(v_e, 27))
I32[arshift((v_r + 4), 2)] = tobit(imul(v_e, 517))
I32[arshift((v_r + 12), 2)] = tobit(imul(v_e, 197))
I32[arshift((v_r + 8), 2)] = tobit((v_r + 640))
imp_b(21753, tobit((v_r + 480)), bor(0, v_r))
B = tobit((v_r + 672))
I32[8023] = tobit(32103)
I32[8024] = tobit(32092)
B = tobit((v_A + 16))
do return 0 end
end
exports.n = function()

do return bor(0, B) end
end
exports.o = function(v_A)

v_A = tobit(v_A)
B = v_A
end
exports.p = function(v_A)

do
local t443 = B
v_A = tobit(v_A)
v_A = band((t443 - v_A), (-16))
B = v_A
do return bor(0, v_A) end
end
end
exports.q = F.fm
exports.r = YA
return exports, DATA, function(v) B = v end, function() return B end
end
