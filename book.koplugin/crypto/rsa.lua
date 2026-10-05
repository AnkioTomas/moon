--[[--
RSA PKCS#1 v1.5。n、e、d 都是无符号大端，不带 ASN.1 的符号字节。
密文和签名与 n 等长。签名摘要支持 md5、sha1、sha256，默认 sha256。
e 缺省 65537。随机填充缺省读 /dev/urandom。

@module koplugin.book.crypto.rsa
--]]

local bit = require("bit")
local bor = bit.bor

local Bn = require("crypto.bn")
local Md5 = require("crypto.md5")
local Sha1 = require("crypto.sha1")
local Sha256 = require("crypto.sha256")

local Rsa = {}

local HASH = {
    md5 = Md5.hash,
    sha1 = Sha1.hash,
    sha256 = Sha256.hash,
}

-- DigestInfo 去掉末尾的散列值。
local PREFIX = {
    md5 = "\48\32\48\12\6\8\42\134\72\134\247\13\2\5\5\0\4\16",
    sha1 = "\48\33\48\9\6\5\43\14\3\2\26\5\0\4\20",
    sha256 = "\48\49\48\13\6\9\96\134\72\1\101\3\4\2\1\5\0\4\32",
}

local E_DEFAULT = "\1\0\1"

local function urandom(n)
    local f = io.open("/dev/urandom", "rb")
    if not f then error("rsa: no urandom") end
    local data = f:read(n)
    f:close()
    if not data or #data ~= n then error("rsa: urandom") end
    return data
end

local function check_n(n)
    if type(n) ~= "string" or #n < 2 or #n % 2 ~= 0 or n:byte(1) == 0 then
        error("rsa: bad modulus")
    end
end

local function hash_of(name, msg)
    local fn = HASH[name or "sha256"]
    if not fn then error("rsa: bad hash") end
    return fn(msg), name or "sha256"
end

local function emsa(digest, name, nlen)
    local info = PREFIX[name] .. digest
    local ps = nlen - #info - 3
    if ps < 8 then error("rsa: modulus too small") end
    return "\0\1" .. string.rep("\255", ps) .. "\0" .. info
end

local function nonzero(n, rng)
    if rng then
        local s = rng(n)
        if type(s) ~= "string" or #s ~= n then error("rsa: bad rng") end
        for i = 1, n do
            if s:byte(i) == 0 then error("rsa: bad rng") end
        end
        return s
    end
    local t = {}
    while #t < n do
        local block = urandom(n)
        for i = 1, #block do
            local b = block:byte(i)
            if b ~= 0 then
                t[#t + 1] = string.char(b)
                if #t == n then break end
            end
        end
    end
    return table.concat(t)
end

local function modexp(n, base, exp)
    local N = Bn.modulus(n)
    local m = N.import(base)
    return N.export(N.pow(m, exp))
end

---@param msg string
---@param n string
---@param e string|nil 默认 65537
---@param rng (fun(n: integer): string)|nil 恰好 n 个非 0 字节
---@return string
function Rsa.encrypt(msg, n, e, rng)
    check_n(n)
    if type(msg) ~= "string" then error("rsa: bad message") end
    e = e or E_DEFAULT
    local ps = #n - #msg - 3
    if ps < 8 then error("rsa: message too long") end
    local em = "\0\2" .. nonzero(ps, rng) .. "\0" .. msg
    return modexp(n, em, e)
end

---@param ct string
---@param n string
---@param d string
---@return string
function Rsa.decrypt(ct, n, d)
    check_n(n)
    if type(ct) ~= "string" or #ct ~= #n or type(d) ~= "string" then
        error("rsa: bad ciphertext")
    end
    local em = modexp(n, ct, d)
    if em:byte(1) ~= 0 or em:byte(2) ~= 2 then error("rsa: bad padding") end
    local i, ps = 3, 0
    while i <= #em and em:byte(i) ~= 0 do
        i = i + 1
        ps = ps + 1
    end
    if ps < 8 or i > #em then error("rsa: bad padding") end
    return em:sub(i + 1)
end

---@param msg string
---@param n string
---@param d string
---@param hash string|nil md5 / sha1 / sha256
---@return string
function Rsa.sign(msg, n, d, hash)
    check_n(n)
    if type(msg) ~= "string" or type(d) ~= "string" then error("rsa: bad message") end
    local digest, name = hash_of(hash, msg)
    return modexp(n, emsa(digest, name, #n), d)
end

---@param msg string
---@param sig string
---@param n string
---@param e string|nil
---@param hash string|nil
---@return boolean
function Rsa.verify(msg, sig, n, e, hash)
    check_n(n)
    if type(msg) ~= "string" or type(sig) ~= "string" or #sig ~= #n then
        error("rsa: bad signature")
    end
    local digest, name = hash_of(hash, msg)
    local em = modexp(n, sig, e or E_DEFAULT)
    return em == emsa(digest, name, #n)
end

-- 密钥生成用的可变长大整数。只做乘、除和扩展欧几里得，不进 Montgomery。

local function norm(a)
    local i = #a
    while i > 1 and a[i] == 0 do
        a[i] = nil
        i = i - 1
    end
    return a
end

local function zzero()
    return { 0 }
end

local function is_zero(a)
    return #a == 1 and a[1] == 0
end

local function zcmp(a, b)
    if #a ~= #b then
        if #a > #b then return 1 end
        return -1
    end
    for i = #a, 1, -1 do
        if a[i] ~= b[i] then
            if a[i] > b[i] then return 1 end
            return -1
        end
    end
    return 0
end

local function zadd(a, b)
    local n = math.max(#a, #b)
    local r, c = {}, 0
    for i = 1, n do
        local s = (a[i] or 0) + (b[i] or 0) + c
        r[i] = s % 65536
        c = math.floor(s / 65536)
    end
    if c ~= 0 then r[n + 1] = c end
    return r
end

local function zsub(a, b)
    local r, br = {}, 0
    for i = 1, #a do
        local d = a[i] - (b[i] or 0) - br
        if d < 0 then
            d = d + 65536
            br = 1
        else
            br = 0
        end
        r[i] = d
    end
    if br ~= 0 then error("rsa: sub") end
    return norm(r)
end

local function zmul(a, b)
    if is_zero(a) or is_zero(b) then return zzero() end
    local r = {}
    for i = 1, #a + #b do r[i] = 0 end
    for i = 1, #a do
        local c = 0
        for j = 1, #b do
            local s = r[i + j - 1] + a[i] * b[j] + c
            r[i + j - 1] = s % 65536
            c = math.floor(s / 65536)
        end
        r[i + #b] = r[i + #b] + c
    end
    return norm(r)
end

local function zbitlen(a)
    if is_zero(a) then return 0 end
    local top = a[#a]
    local n = (#a - 1) * 16
    while top > 0 do
        n = n + 1
        top = math.floor(top / 2)
    end
    return n
end

local function zget(a, i)
    local limb = a[math.floor(i / 16) + 1] or 0
    return math.floor(limb / 2 ^ (i % 16)) % 2
end

local function zset(a, i)
    local idx = math.floor(i / 16) + 1
    while #a < idx do a[#a + 1] = 0 end
    local bitv = 2 ^ (i % 16)
    if math.floor(a[idx] / bitv) % 2 == 0 then
        a[idx] = a[idx] + bitv
    end
    return a
end

local function zshl1(a)
    if is_zero(a) then return zzero() end
    local r, c = {}, 0
    for i = 1, #a do
        local s = a[i] * 2 + c
        r[i] = s % 65536
        c = math.floor(s / 65536)
    end
    if c ~= 0 then r[#a + 1] = c end
    return r
end

local function divmod(u, v)
    if is_zero(v) then error("rsa: div0") end
    if zcmp(u, v) < 0 then return zzero(), u end
    local q = zzero()
    local r = zzero()
    for i = zbitlen(u) - 1, 0, -1 do
        r = zshl1(r)
        if zget(u, i) == 1 then r = zadd(r, { 1 }) end
        if zcmp(r, v) >= 0 then
            r = zsub(r, v)
            zset(q, i)
        end
    end
    return norm(q), norm(r)
end

local function zfrom(s)
    if #s == 0 then return zzero() end
    if #s % 2 == 1 then s = "\0" .. s end
    local a = {}
    local limbs = #s / 2
    for i = 1, limbs do
        local o = #s + 1 - i * 2
        a[i] = s:byte(o) * 256 + s:byte(o + 1)
    end
    return norm(a)
end

local function zto(a, nbytes)
    local t = {}
    for i = nbytes, 1, -1 do
        local bit_i = i - 1
        local limb = a[math.floor(bit_i / 2) + 1] or 0
        local byte
        if bit_i % 2 == 0 then
            byte = limb % 256
        else
            byte = math.floor(limb / 256)
        end
        t[#t + 1] = string.char(byte)
    end
    return table.concat(t)
end

local function sadd(a, b)
    if a.neg == b.neg then
        return { neg = a.neg, v = zadd(a.v, b.v) }
    end
    if zcmp(a.v, b.v) >= 0 then
        return { neg = a.neg and not is_zero(zsub(a.v, b.v)), v = zsub(a.v, b.v) }
    end
    local v = zsub(b.v, a.v)
    return { neg = b.neg and not is_zero(v), v = v }
end

local function smul(a, b)
    local v = zmul(a.v, b.v)
    return { neg = a.neg ~= b.neg and not is_zero(v), v = v }
end

local function egcd(a, b)
    local old_r, r = a, b
    local old_s = { neg = false, v = { 1 } }
    local s = { neg = false, v = zzero() }
    while not is_zero(r) do
        local q, rem = divmod(old_r, r)
        old_r, r = r, rem
        old_s, s = s, sadd(old_s, smul({ neg = true, v = q }, s))
    end
    return old_r, old_s
end

local function modinv(a, m)
    local g, x = egcd(a, m)
    if #g ~= 1 or g[1] ~= 1 then return nil end
    if x.neg then
        local _, rem = divmod(x.v, m)
        if is_zero(rem) then return zzero() end
        return zsub(m, rem)
    end
    local _, rem = divmod(x.v, m)
    return rem
end

local SMALL = {}
do
    local mark = {}
    for n = 2, 2000 do
        if not mark[n] then
            SMALL[#SMALL + 1] = n
            for j = n * n, 2000, n do mark[j] = true end
        end
    end
end

local function mod_small(raw, p)
    local r = 0
    for i = 1, #raw do
        r = (r * 256 + raw:byte(i)) % p
    end
    return r
end

local function shr1(a)
    local r, carry = {}, 0
    for i = #a, 1, -1 do
        local v = a[i] + carry * 65536
        r[i] = math.floor(v / 2)
        carry = v % 2
    end
    return r
end

local function probable_prime(raw)
    if raw:byte(1) == 0 then return false end
    for i = 1, #SMALL do
        if mod_small(raw, SMALL[i]) == 0 then return false end
    end
    local N = Bn.modulus(raw)
    local nm1 = N.dec()
    local d = {}
    for i = 1, #nm1 do d[i] = nm1[i] end
    local s = 0
    while d[1] % 2 == 0 do
        d = shr1(d)
        s = s + 1
    end
    local d_be = N.export(d)
    for _round = 1, 8 do
        local a
        for _try = 1, 32 do
            local cand = N.try_import(urandom(#raw))
            if cand and not N.is_zero(cand) and not N.eq(cand, N.one) then
                a = N.export(cand)
                break
            end
        end
        if not a then error("rsa: rng failed") end
        local x = N.pow(N.import(a), d_be)
        if not N.eq(x, N.one) and not N.eq(x, nm1) then
            local hit = false
            for _r = 1, s - 1 do
                x = N.pow(x, "\2")
                if N.eq(x, nm1) then
                    hit = true
                    break
                end
            end
            if not hit then return false end
        end
    end
    return true
end

local function random_prime(nbytes)
    while true do
        local raw = urandom(nbytes)
        local top = bor(raw:byte(1), 0x80)
        local bot = bor(raw:byte(nbytes), 0x01)
        raw = string.char(top) .. raw:sub(2, nbytes - 1) .. string.char(bot)
        if probable_prime(raw) then return raw end
    end
end

---@param bits integer 32 的倍数，512 到 4096
---@param e string|nil
---@return string n
---@return string e
---@return string d
function Rsa.keypair(bits, e)
    if type(bits) ~= "number" or bits % 32 ~= 0 or bits < 512 or bits > 4096 then
        error("rsa: bad bits")
    end
    e = e or E_DEFAULT
    local el = zfrom(e)
    local half = bits / 16
    while true do
        local p = random_prime(half)
        local q = random_prime(half)
        if p ~= q then
            local pp, qq = zfrom(p), zfrom(q)
            local n = zmul(pp, qq)
            local phi = zmul(zsub(pp, { 1 }), zsub(qq, { 1 }))
            local d = modinv(el, phi)
            if d then
                local nb = bits / 8
                local raw_n = zto(n, nb)
                if raw_n:byte(1) ~= 0 then
                    return raw_n, e, zto(d, nb)
                end
            end
        end
    end
end

return Rsa
