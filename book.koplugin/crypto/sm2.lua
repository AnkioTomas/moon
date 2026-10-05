--[[--
SM2 签名与公钥加密。曲线 sm2p256v1。

签名是 r||s 各 32 字节。默认用户标识 1234567812345678。
密文是 C1||C3||C2：C1 为 04||X||Y（65 字节），C3 为 32 字节 SM3。
公钥同样接受 65 字节（带 04）或 64 字节 X||Y。
随机数缺省读 /dev/urandom；测试可传入 32 字节 k。

@module koplugin.book.crypto.sm2
--]]

local bit = require("bit")
local bxor = bit.bxor

local Hex = require("crypto.hex")
local Bn = require("crypto.bn")
local Sm3 = require("crypto.sm3")

local Sm2 = {}

local DEFAULT_ID = "1234567812345678"

local P = Hex.from_hex("FFFFFFFEFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF00000000FFFFFFFFFFFFFFFF")
local A_BE = Hex.from_hex("FFFFFFFEFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF00000000FFFFFFFFFFFFFFFC")
local B_BE = Hex.from_hex("28E9FA9E9D9F5E344D5A9E4BCF6509A7F39789F515AB8F92DDBCBD414D940E93")
local N = Hex.from_hex("FFFFFFFEFFFFFFFFFFFFFFFFFFFFFFFF7203DF6B21C6052B53BBF40939D54123")
local GX_BE = Hex.from_hex("32C4AE2C1F1981195F9904466A39C9948FE30BBFF2660BE1715A4589334C74C7")
local GY_BE = Hex.from_hex("BC3736A2F4F6779C59BDCEE36B692153D0A9877CC62A474002DF32E52139F0A0")

local Fp = Bn.modulus(P)
local Fn = Bn.modulus(N)
local A_N = Fp.import(A_BE)
local B_N = Fp.import(B_BE)

local three = Fp.import(string.rep("\0", 31) .. string.char(3))
if not Fp.is_zero(Fp.add(A_N, three)) then
    error("sm2: curve a is not -3")
end

local G = {
    x = Fp.to_m(Fp.import(GX_BE)),
    y = Fp.to_m(Fp.import(GY_BE)),
}

local function dbl(x)
    return Fp.add(x, x)
end

local function tpl(x)
    return Fp.add(dbl(x), x)
end

local function jdouble(P1)
    if not P1 then return nil end
    local X, Y, Z = P1.x, P1.y, P1.z
    if Fp.is_zero(Y) then return nil end
    local delta = Fp.mul(Z, Z)
    local gamma = Fp.mul(Y, Y)
    local beta = Fp.mul(X, gamma)
    local alpha = tpl(Fp.mul(Fp.sub(X, delta), Fp.add(X, delta)))
    local X3 = Fp.sub(Fp.mul(alpha, alpha), dbl(dbl(dbl(beta))))
    local Z3 = dbl(Fp.mul(Y, Z))
    local Y3 = Fp.sub(
        Fp.mul(alpha, Fp.sub(dbl(dbl(beta)), X3)),
        dbl(dbl(dbl(Fp.mul(gamma, gamma))))
    )
    return { x = X3, y = Y3, z = Z3 }
end

--- Jacobian P1 加仿射 Q。
local function jadd(P1, Q)
    if not P1 then
        return { x = Q.x, y = Q.y, z = Fp.one_m }
    end
    local X1, Y1, Z1 = P1.x, P1.y, P1.z
    local Z1Z1 = Fp.mul(Z1, Z1)
    local U2 = Fp.mul(Q.x, Z1Z1)
    local S2 = Fp.mul(Fp.mul(Q.y, Z1), Z1Z1)
    local H = Fp.sub(U2, X1)
    local r = Fp.sub(S2, Y1)
    if Fp.is_zero(H) then
        if Fp.is_zero(r) then return jdouble(P1) end
        return nil
    end
    local HH = Fp.mul(H, H)
    local HHH = Fp.mul(H, HH)
    local V = Fp.mul(X1, HH)
    local X3 = Fp.sub(Fp.sub(Fp.mul(r, r), HHH), dbl(V))
    local Y3 = Fp.sub(Fp.mul(r, Fp.sub(V, X3)), Fp.mul(Y1, HHH))
    return { x = X3, y = Y3, z = Fp.mul(Z1, H) }
end

local function jnorm(P1)
    if not P1 then return nil end
    local zinv = Fp.inv(P1.z)
    local zinv2 = Fp.mul(zinv, zinv)
    local zinv3 = Fp.mul(zinv2, zinv)
    return { x = Fp.mul(P1.x, zinv2), y = Fp.mul(P1.y, zinv3) }
end

local function mul(k, Q)
    local R = nil
    for i = 255, 0, -1 do
        if R then R = jdouble(R) end
        if Fn.bit(k, i) == 1 then
            R = jadd(R, Q)
        end
    end
    return jnorm(R)
end

local function on_curve(pt)
    local x = Fp.from_m(pt.x)
    local y = Fp.from_m(pt.y)
    local y2 = Fp.muln(y, y)
    local x3 = Fp.muln(Fp.muln(x, x), x)
    local rhs = Fp.add(Fp.add(x3, Fp.muln(A_N, x)), B_N)
    return Fp.eq(y2, rhs)
end

local function load_point(raw)
    local body
    if #raw == 65 then
        if raw:byte(1) ~= 4 then error("sm2: bad point") end
        body = raw:sub(2)
    elseif #raw == 64 then
        body = raw
    else
        error("sm2: bad point")
    end
    local xn = Fp.try_import(body:sub(1, 32))
    local yn = Fp.try_import(body:sub(33, 64))
    if not xn or not yn then error("sm2: bad point") end
    local pt = { x = Fp.to_m(xn), y = Fp.to_m(yn) }
    if not on_curve(pt) then error("sm2: point off curve") end
    return pt
end

local function encode(pt)
    return "\4" .. Fp.export(Fp.from_m(pt.x)) .. Fp.export(Fp.from_m(pt.y))
end

local function scalar(raw)
    if type(raw) ~= "string" or #raw ~= 32 then error("sm2: bad scalar") end
    local s = Fn.try_import(raw)
    if not s or Fn.is_zero(s) then error("sm2: bad scalar") end
    return s
end

local function urandom(n)
    local f = io.open("/dev/urandom", "rb")
    if not f then error("sm2: no urandom") end
    local data = f:read(n)
    f:close()
    if not data or #data ~= n then error("sm2: urandom") end
    return data
end

local function random_scalar()
    for _try = 1, 16 do
        local s = Fn.try_import(urandom(32))
        if s and not Fn.is_zero(s) then return s end
    end
    error("sm2: rng failed")
end

local function za(id, pub)
    local bits = #id * 8
    if bits > 65535 then error("sm2: id too long") end
    local entl = string.char(math.floor(bits / 256), bits % 256)
    local xa = Fp.export(Fp.from_m(pub.x))
    local ya = Fp.export(Fp.from_m(pub.y))
    return Sm3.hash(entl .. id .. A_BE .. B_BE .. GX_BE .. GY_BE .. xa .. ya)
end

local function u32be(n)
    return string.char(
        math.floor(n / 16777216) % 256,
        math.floor(n / 65536) % 256,
        math.floor(n / 256) % 256,
        n % 256
    )
end

local function kdf(z, klen)
    if klen == 0 then return "" end
    local parts = {}
    local ct, got = 1, 0
    while got < klen do
        parts[#parts + 1] = Sm3.hash(z .. u32be(ct))
        got = got + 32
        ct = ct + 1
    end
    local t = table.concat(parts):sub(1, klen)
    for i = 1, #t do
        if t:byte(i) ~= 0 then return t end
    end
    error("sm2: kdf zero")
end

local function xor_bytes(a, b)
    local t = {}
    for i = 1, #a do
        t[i] = string.char(bxor(a:byte(i), b:byte(i)))
    end
    return table.concat(t)
end

local function aff_add(P1, Q)
    if not P1 then return Q end
    if not Q then return P1 end
    return jnorm(jadd({ x = P1.x, y = P1.y, z = Fp.one_m }, Q))
end

---@param d string 32 字节私钥
---@return string 65 字节公钥，04||X||Y
function Sm2.public_key(d)
    local point = mul(scalar(d), G)
    if not point then error("sm2: bad scalar") end
    return encode(point)
end

---@return string d, string pub
function Sm2.keypair()
    local d = random_scalar()
    local point = mul(d, G)
    if not point then error("sm2: rng failed") end
    return Fn.export(d), encode(point)
end

---@param msg string
---@param d string 32 字节私钥
---@param id string|nil
---@param k string|nil 32 字节，缺省则随机
---@return string 64 字节 r||s
function Sm2.sign(msg, d, id, k)
    if type(msg) ~= "string" then error("sm2: bad message") end
    id = id or DEFAULT_ID
    local priv = scalar(d)
    local pub = mul(priv, G)
    if not pub then error("sm2: bad scalar") end
    local nonce = k and scalar(k) or random_scalar()
    local e = Fn.import_reduce(Sm3.hash(za(id, pub) .. msg))
    local kg = mul(nonce, G)
    if not kg then error("sm2: bad k") end
    local x1 = Fn.import_reduce(Fp.export(Fp.from_m(kg.x)))
    local r = Fn.add(e, x1)
    if Fn.is_zero(r) or Fn.is_zero(Fn.add(r, nonce)) then error("sm2: bad k") end
    local s = Fn.muln(Fn.invn(Fn.add(Fn.one, priv)), Fn.sub(nonce, Fn.muln(r, priv)))
    if Fn.is_zero(s) then error("sm2: bad k") end
    return Fn.export(r) .. Fn.export(s)
end

---@param msg string
---@param sig string 64 字节
---@param pub string
---@param id string|nil
---@return boolean
function Sm2.verify(msg, sig, pub, id)
    if type(msg) ~= "string" or type(sig) ~= "string" or #sig ~= 64 then
        error("sm2: bad signature")
    end
    id = id or DEFAULT_ID
    local r = Fn.try_import(sig:sub(1, 32))
    local s = Fn.try_import(sig:sub(33, 64))
    if not r or not s or Fn.is_zero(r) or Fn.is_zero(s) then return false end
    local point = load_point(pub)
    local t = Fn.add(r, s)
    if Fn.is_zero(t) then return false end
    local left = aff_add(mul(s, G), mul(t, point))
    if not left then return false end
    local e = Fn.import_reduce(Sm3.hash(za(id, point) .. msg))
    local x1 = Fn.import_reduce(Fp.export(Fp.from_m(left.x)))
    return Fn.eq(Fn.add(e, x1), r)
end

---@param msg string
---@param pub string
---@param k string|nil
---@return string C1||C3||C2
function Sm2.encrypt(msg, pub, k)
    if type(msg) ~= "string" then error("sm2: bad message") end
    local point = load_point(pub)
    local nonce = k and scalar(k) or random_scalar()
    local c1 = mul(nonce, G)
    local shared = mul(nonce, point)
    if not c1 or not shared then error("sm2: bad k") end
    local x2 = Fp.export(Fp.from_m(shared.x))
    local y2 = Fp.export(Fp.from_m(shared.y))
    local c2 = xor_bytes(msg, kdf(x2 .. y2, #msg))
    local c3 = Sm3.hash(x2 .. msg .. y2)
    return encode(c1) .. c3 .. c2
end

---@param ct string
---@param d string
---@return string
function Sm2.decrypt(ct, d)
    if type(ct) ~= "string" or #ct < 97 or ct:byte(1) ~= 4 then
        error("sm2: bad ciphertext")
    end
    local c1 = load_point(ct:sub(1, 65))
    local c3 = ct:sub(66, 97)
    local c2 = ct:sub(98)
    local shared = mul(scalar(d), c1)
    if not shared then error("sm2: bad ciphertext") end
    local x2 = Fp.export(Fp.from_m(shared.x))
    local y2 = Fp.export(Fp.from_m(shared.y))
    local msg = xor_bytes(c2, kdf(x2 .. y2, #c2))
    if Sm3.hash(x2 .. msg .. y2) ~= c3 then error("sm2: bad ciphertext") end
    return msg
end

return Sm2
