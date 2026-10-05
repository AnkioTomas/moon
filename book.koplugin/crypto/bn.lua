--[[--
奇数模上的运算。16 位肢体，乘法走 Montgomery，宽度等于模的字节数（必须是偶数）。
SM2 的域和阶是 32 字节素数。RSA 的模是合数，只能用 pow，不能用 inv
（inv 是费马小定理，只对素数模成立）。

@module koplugin.book.crypto.bn
--]]

local Bn = {}

local BASE = 65536

local function inv16(x)
    local y = 1
    for _i = 1, 6 do
        y = (y * (2 - x * y % BASE)) % BASE
    end
    return y
end

--- 建一个模 mod_be（大端，偶数个字节，奇数）上的运算。
--- 元素默认是普通代表（0 .. mod-1）。
---@param mod_be string
---@return table
function Bn.modulus(mod_be)
    if #mod_be < 2 or #mod_be % 2 ~= 0 then error("bn: bad modulus") end
    local nbytes = #mod_be
    local W = nbytes / 2

    local function zero()
        local a = {}
        for i = 1, W do a[i] = 0 end
        return a
    end

    local function copy(a)
        local b = {}
        for i = 1, W do b[i] = a[i] end
        return b
    end

    local function cmp(a, b)
        for i = W, 1, -1 do
            if a[i] ~= b[i] then
                if a[i] > b[i] then return 1 end
                return -1
            end
        end
        return 0
    end

    local function from_be(s)
        if #s ~= nbytes then error("bn: bad length") end
        local a = {}
        for i = 1, W do
            local o = nbytes + 1 - i * 2
            a[i] = s:byte(o) * 256 + s:byte(o + 1)
        end
        return a
    end

    local function to_be(a)
        local t = {}
        for i = W, 1, -1 do
            local v = a[i]
            t[#t + 1] = string.char(math.floor(v / 256), v % 256)
        end
        return table.concat(t)
    end

    local function sub_raw(a, b)
        local r, br = {}, 0
        for i = 1, W do
            local d = a[i] - b[i] - br
            if d < 0 then
                d = d + BASE
                br = 1
            else
                br = 0
            end
            r[i] = d
        end
        return r, br
    end

    local function add_raw(a, b)
        local r, c = {}, 0
        for i = 1, W do
            local s = a[i] + b[i] + c
            r[i] = s % BASE
            c = math.floor(s / BASE)
        end
        return r, c
    end

    local function reduce(a, hi, mod)
        for _step = 1, 4 do
            if hi == 0 and cmp(a, mod) < 0 then return a end
            local br
            a, br = sub_raw(a, mod)
            hi = hi - br
            if hi < 0 then error("bn: reduce") end
        end
        error("bn: not reduced")
    end

    local function add_mod(a, b, mod)
        local r, hi = add_raw(a, b)
        return reduce(r, hi, mod)
    end

    local function sub_mod(a, b, mod)
        if cmp(a, b) >= 0 then
            local r, br = sub_raw(a, b)
            if br ~= 0 then error("bn: sub") end
            return r
        end
        local diff = sub_raw(b, a)
        local r, br = sub_raw(mod, diff)
        if br ~= 0 then error("bn: sub") end
        return r
    end

    local function bitof(a, i)
        local limb = a[math.floor(i / 16) + 1]
        return math.floor(limb / 2 ^ (i % 16)) % 2
    end

    local function sub_u16(a, k)
        local r = copy(a)
        local d = r[1] - k
        if d >= 0 then
            r[1] = d
            return r
        end
        r[1] = d + BASE
        local i = 2
        while i <= W and r[i] == 0 do
            r[i] = BASE - 1
            i = i + 1
        end
        if i > W then error("bn: underflow") end
        r[i] = r[i] - 1
        return r
    end

    local mod = from_be(mod_be)
    if mod[1] % 2 == 0 then error("bn: modulus even") end
    local n0 = (BASE - inv16(mod[1])) % BASE
    local one = zero()
    one[1] = 1
    local r2 = copy(one)
    for _i = 1, nbytes * 16 do
        r2 = add_mod(r2, r2, mod)
    end

    local scratch = {}
    for i = 1, W + 2 do scratch[i] = 0 end

    local function mont_mul(a, b)
        for i = 1, W + 2 do scratch[i] = 0 end
        for i = 1, W do
            local c = 0
            for j = 1, W do
                local uv = scratch[j] + a[j] * b[i] + c
                scratch[j] = uv % BASE
                c = math.floor(uv / BASE)
            end
            local uv = scratch[W + 1] + c
            scratch[W + 1] = uv % BASE
            scratch[W + 2] = math.floor(uv / BASE)

            c = 0
            local m = (scratch[1] * n0) % BASE
            for j = 1, W do
                uv = scratch[j] + m * mod[j] + c
                scratch[j] = uv % BASE
                c = math.floor(uv / BASE)
            end
            uv = scratch[W + 1] + c
            scratch[W + 1] = uv % BASE
            scratch[W + 2] = scratch[W + 2] + math.floor(uv / BASE)
            if scratch[W + 2] >= BASE then error("bn: mont carry") end

            for j = 1, W + 1 do
                scratch[j] = scratch[j + 1]
            end
            scratch[W + 2] = 0
        end
        local r = {}
        for i = 1, W do r[i] = scratch[i] end
        return reduce(r, scratch[W + 1], mod)
    end

    local one_m = mont_mul(one, r2)
    local exp = sub_u16(mod, 2)
    local wbits = W * 16

    local M = {
        zero = zero(),
        one = one,
        one_m = one_m,
    }

    function M.is_zero(a)
        for i = 1, W do
            if a[i] ~= 0 then return false end
        end
        return true
    end

    function M.eq(a, b)
        return cmp(a, b) == 0
    end

    function M.add(a, b)
        return add_mod(a, b, mod)
    end

    function M.sub(a, b)
        return sub_mod(a, b, mod)
    end

    --- 模减一。给 Miller-Rabin 用，不经过 import（模本身不能 import）。
    function M.dec()
        return sub_u16(mod, 1)
    end

    --- 普通域元素。长度必须等于模，大于等于模则报错。
    function M.import(s)
        local a = from_be(s)
        if cmp(a, mod) >= 0 then error("bn: out of range") end
        return a
    end

    --- 普通域元素，长度等于模，再约到模下。
    function M.import_reduce(s)
        return reduce(from_be(s), 0, mod)
    end

    --- 大于等于模时返回 nil。
    function M.try_import(s)
        local a = from_be(s)
        if cmp(a, mod) >= 0 then return nil end
        return a
    end

    function M.export(a)
        return to_be(a)
    end

    function M.to_m(a)
        return mont_mul(a, r2)
    end

    function M.from_m(a)
        return mont_mul(a, one)
    end

    --- Montgomery 乘法：(a * b * R^{-1}) mod m。
    function M.mul(a, b)
        return mont_mul(a, b)
    end

    function M.muln(a, b)
        local am = mont_mul(a, r2)
        local bm = mont_mul(b, r2)
        return mont_mul(mont_mul(am, bm), one)
    end

    local function exp_m(base)
        local r = one_m
        for i = wbits - 1, 0, -1 do
            r = mont_mul(r, r)
            if bitof(exp, i) == 1 then
                r = mont_mul(r, base)
            end
        end
        return r
    end

    --- 普通域上的模幂。指数是大端，可以比模短。
    function M.pow(base, exp_be)
        if type(exp_be) ~= "string" or #exp_be == 0 or #exp_be > nbytes then
            error("bn: bad exponent")
        end
        if #exp_be < nbytes then
            exp_be = string.rep("\0", nbytes - #exp_be) .. exp_be
        end
        local e = from_be(exp_be)
        local top = -1
        for i = wbits - 1, 0, -1 do
            if bitof(e, i) == 1 then
                top = i
                break
            end
        end
        if top < 0 then return copy(one) end
        local bm = mont_mul(base, r2)
        local r = bm
        for i = top - 1, 0, -1 do
            r = mont_mul(r, r)
            if bitof(e, i) == 1 then
                r = mont_mul(r, bm)
            end
        end
        return mont_mul(r, one)
    end

    --- Montgomery 逆：给定 aR，返回 a^{-1} R。只对素数模成立。
    function M.inv(a)
        if M.is_zero(a) then error("bn: inverse of zero") end
        return exp_m(a)
    end

    function M.invn(a)
        if M.is_zero(a) then error("bn: inverse of zero") end
        return mont_mul(exp_m(mont_mul(a, r2)), one)
    end

    function M.bit(a, i)
        return bitof(a, i)
    end

    return M
end

return Bn
