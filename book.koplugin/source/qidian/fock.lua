--[[--
起点 VIP 章节正文解密（Fock）。

起点网页端用一段 wasm（经 wasm2js 成 asm.js）解密 `chapterInfo.content`。`fock_wasm.lua` 是
`tools/gen_fock.js` 把它转译成的 Lua，本模块提供它需要的内存与导入函数（宿主环境是浏览器，
这里只给出解密路径用得到的那几个常量），再按网页同样的顺序调用：
ctors + main，再 `fock_i(uid)` → `fock_a(keypool, version)` → `fock_u(content, chapterId)`。

解密要 16MB 内存且纯 Lua 解释执行，在主进程做会拖慢 UI、抬高 KOReader 内存峰值（设备上可被系统杀掉重启），
所以 `decryptAsync` 放进 fork 子进程，主进程只收明文；`decrypt` 是子进程里跑的同步实现。

@module source.qidian.fock
--]]--

local ffi = require("ffi")
local Job = require("workers.job")
local Text = require("utils.text")

local Fock = {}

local MEM_SIZE = 16 * 1024 * 1024
local HOST = {
    ["location.hostname"] = "vipreader.qidian.com",
    ["location.protocol"] = "https:",
}

local factory

local function cstr(mem, ptr)
    local stop = ptr
    while mem[stop] ~= 0 do stop = stop + 1 end
    return ffi.string(mem + ptr, stop - ptr)
end

---@param content string base64 密文
---@param chapter_id string|number
---@param keypool string base64 密钥池（fkp 里 onkeyfocus 的第一个参数）
---@param version string
---@param uid string 用户 ywguid
---@return string|nil text
---@return string|nil err
function Fock.decrypt(content, chapter_id, keypool, version, uid)
    factory = factory or require("source.qidian.fock_wasm")
    local mem = ffi.new("uint8_t[?]", MEM_SIZE)
    local i32 = ffi.cast("int32_t*", mem)
    local result, exp

    local function malloc_str(s)
        local ptr = exp.q(#s + 1)
        ffi.copy(mem + ptr, s, #s)
        mem[ptr + #s] = 0
        return ptr
    end

    local imp = {
        abort = function() error("fock abort") end,
        f = function() return 0 end,
        d = function(ptr)
            local now = os.time()
            if ptr ~= 0 then i32[ptr / 4] = now end
            return now
        end,
        c = function(a, b) return malloc_str(HOST[cstr(mem, a) .. "." .. cstr(mem, b)] or "undefined") end,
        e = function() return malloc_str("undefined") end,
        b = function(code, _sig, argptr)
            if code == 22685 then
                local args = argptr / 4
                result = { i32[args], i32[args + 1], i32[args + 2] }
                return 0
            end
            -- 其余是反调试 / 定时器探测：返回 -1（那几个会返回 indexOf 结果）或 0
            if code == 14394 or code == 14449 or code == 14875 then return 0 end
            if code % 709 == 15372 % 709 then return -1 end
            return 0
        end,
    }

    local data, set_stack
    exp, data, set_stack = factory({ mem = mem, imp = imp })
    for _idx, seg in ipairs(data) do
        local bytes = Text.base64Decode(seg[2])
        ffi.copy(mem + seg[1], bytes, #bytes)
    end
    set_stack(5274992)

    local function with_stack(fn)
        local sp = exp.n()
        local ok, err = pcall(fn)
        exp.o(sp)
        if not ok then error(err, 0) end
    end
    local function put_bytes(s)
        local ptr = exp.p(#s)
        ffi.copy(mem + ptr, s, #s)
        return ptr
    end
    local function put_string(s)
        local ptr = exp.p(#s + 1)
        ffi.copy(mem + ptr, s, #s)
        mem[ptr + #s] = 0
        return ptr
    end

    local ok, err = pcall(function()
        exp.g()
        exp.m(0, 0)
        with_stack(function()
            exp.h(put_bytes(uid), #uid)
        end)
        local pool = Text.base64Decode(keypool)
        with_stack(function()
            exp.i(put_bytes(pool), #pool, put_string(version))
        end)
        local cipher = Text.base64Decode(content)
        local cid = tostring(chapter_id)
        with_stack(function()
            exp.j(put_bytes(cipher), #cipher, put_bytes(cid), #cid)
        end)
    end)
    if not ok then return nil, tostring(err) end
    if not result then return nil, "no result" end
    if result[1] ~= 0 then return nil, "code " .. result[1] end
    return ffi.string(mem + result[2], result[3])
end

--- 在子进程里解密；回调拿明文或错误。
---@return BookJob
function Fock.decryptAsync(content, chapter_id, keypool, version, uid, cb)
    return Job.run(function()
        -- 转译出的巨型函数让 ARM 上的 LuaJIT 编译器段错误，子进程里关掉 JIT（只影响这个子进程）
        jit.off()
        local plain, err = Fock.decrypt(content, chapter_id, keypool, version, uid)
        return { text = plain, err = err }
    end, {
        name = "qidian_fock",
        kind = "light",
        timeout = 60,
        on_done = function(res) cb(res.text, res.err) end,
        on_failed = function(err) cb(nil, tostring(err)) end,
        on_cancelled = function() end,
    })
end

return Fock
