--[[--
QQ阅读已购 VIP 章节正文解密（Fock）。

和起点同一套反盗版 wasm（经 wasm2js 成 asm.js），但是另一个构建：导出名、导入表、宿主探测都不同，
所以单独一份转译产物 `fock_wasm.lua`（`tools/gen_fock.js` 生成），宿主环境（内存与导入）在这里提供。
调用顺序与网页相同：ctors + main，再 `fock_i(fuid)` → `fock_a(keypool, version)` → `fock_u(content, chapterId)`，
结果经导入 b 的回调码 21795 交回（三个 int：状态、明文指针、明文长度）。

解密要 16MB 内存且纯 Lua 解释执行，放进 fork 子进程，主进程只收明文；`decrypt` 是子进程里跑的同步实现。

@module source.qqreader.fock
--]]--

local ffi = require("ffi")
local FontRestore = require("source.yuewen_fonts")
local Job = require("workers.job")
local Text = require("utils.text")

local Fock = {}

local MEM_SIZE = 16 * 1024 * 1024
local CALLBACK = 21795
local HOST = {
    ["window.location.hostname"] = "book.qq.com",
    ["location.hostname"] = "book.qq.com",
}

local factory

local function cstr(mem, ptr)
    local stop = ptr
    while mem[stop] ~= 0 do stop = stop + 1 end
    return ffi.string(mem + ptr, stop - ptr)
end

---@param content string base64 密文
---@param chapter_id string|number
---@param keypool string base64 密钥池（piracy 接口 fkp 里 onkeyfocus 的第一个参数）
---@param version string
---@param fuid string piracy 接口给的用户标识
---@return string|nil text
---@return string|nil err
function Fock.decrypt(content, chapter_id, keypool, version, fuid)
    factory = factory or require("source.qqreader.fock_wasm")
    local mem = ffi.new("uint8_t[?]", MEM_SIZE)
    local i32 = ffi.cast("int32_t*", mem)
    local result, exp

    local imp = {
        abort = function() error("fock abort") end,
        b = function(code, _sig, argptr)
            if code == CALLBACK then
                local args = argptr / 4
                result = { i32[args], i32[args + 1], i32[args + 2] }
                return 0
            end
            if code % 709 == 8 then return -1 end
            return 0
        end,
        c = function(ptr)
            local src = cstr(mem, ptr)
            local out = HOST[src] or "undefined"
            local dst = exp.n(#out + 1)
            ffi.copy(mem + dst, out, #out)
            mem[dst + #out] = 0
            return dst
        end,
        d = function(ptr)
            local now = os.time()
            if ptr ~= 0 then i32[ptr / 4] = now end
            return now
        end,
        e = function() return 0 end,
    }

    local data, set_stack
    exp, data, set_stack = factory({ mem = mem, imp = imp })
    for _idx, seg in ipairs(data) do
        local bytes = Text.base64Decode(seg[2])
        ffi.copy(mem + seg[1], bytes, #bytes)
    end
    set_stack(5274112)

    local function with_stack(fn)
        local sp = exp.k()
        local ok, err = pcall(fn)
        exp.l(sp)
        if not ok then error(err, 0) end
    end
    local function put_bytes(s)
        local ptr = exp.m(#s)
        ffi.copy(mem + ptr, s, #s)
        return ptr
    end
    local function put_string(s)
        local ptr = exp.m(#s + 1)
        ffi.copy(mem + ptr, s, #s)
        mem[ptr + #s] = 0
        return ptr
    end

    local ok, err = pcall(function()
        exp.f()
        exp.j(0, 0)
        with_stack(function()
            exp.g(put_bytes(fuid), #fuid)
        end)
        local pool = Text.base64Decode(keypool)
        with_stack(function()
            exp.h(put_bytes(pool), #pool, put_string(version))
        end)
        local cipher = Text.base64Decode(content)
        local cid = tostring(chapter_id)
        with_stack(function()
            exp.i(put_bytes(cipher), #cipher, put_bytes(cid), #cid)
        end)
    end)
    if not ok then return nil, tostring(err) end
    if not result then return nil, "no result" end
    if result[1] ~= 0 then return nil, "code " .. result[1] end
    return ffi.string(mem + result[2], result[3])
end

--- 解出的 HTML 段落还原成纯文本：把乱序码位 / 互换字形按下发字体认回真字。
--- 起点、潇湘同一套字体反盗版，共用 `source.yuewen_fonts`。
---@param plain string Fock 解出的正文
---@param font table fontResponse（css、randomFont）
---@param fixed_font string|nil fontResponse.fixedFontTtf 下载下来的字节；没有字体加密的章为 nil，不还原字形
---@return string
function Fock.restore(plain, font, fixed_font)
    return FontRestore.restore(plain, font, fixed_font)
end

--- 在子进程里解密并还原乱序，回调拿正文纯文本或错误。
---@param info table /book/read 的 data（content、fontResponse）
---@param fixed_font string|nil fontResponse.fixedFontTtf 下载下来的字节；没有字体加密的章为 nil，不还原字形
---@param chapter_id string|number
---@return BookJob
function Fock.chapterAsync(info, fixed_font, chapter_id, keypool, version, fuid, cb)
    return Job.run(function()
        -- 转译出的巨型函数让 ARM 上的 LuaJIT 编译器段错误：解密时关掉 JIT（只影响这个子进程），之后字形比对要开回来
        jit.off()
        local plain, err = Fock.decrypt(info.content, chapter_id, keypool, version, fuid)
        jit.on()
        if not plain then return { err = err } end
        local font = type(info.fontResponse) == "table" and info.fontResponse or {}
        return { text = Fock.restore(plain, font, fixed_font) }
    end, {
        name = "qqreader_fock",
        kind = "light",
        timeout = 600,
        on_done = function(res) cb(res.text, res.err) end,
        on_failed = function(err) cb(nil, tostring(err)) end,
        on_cancelled = function() end,
    })
end

return Fock
