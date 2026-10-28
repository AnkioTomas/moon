--[[--
阅文系（起点 / QQ阅读 / 潇湘）Fock 章节解密的公共宿主。

三家网页端用同一段反盗版 wasm（经 wasm2js 成 asm.js）解密正文，只是各自一个构建：导出名、回调码、栈基址、
宿主探测字符串不同。`tools/gen_fock.js` 把每个构建转译成 `source/<id>/fock_wasm.lua`，本模块提供它们共用的
内存、导入函数与调用顺序（ctors + main，再 set_uid → set_key → decrypt，结果经导入 b 的回调码交回：
三个 int：状态、明文指针、明文长度），源只在 `YuewenFockBuild` 表里填自己那份差异。

解密要 16MB 内存且纯 Lua 解释执行，在主进程做会拖慢 UI、抬高 KOReader 内存峰值（设备上可被系统杀掉重启），
`Fock.jobAsync` 把它放进 fork 子进程，主进程只收结果；转译出的巨型函数会让 ARM 上的 LuaJIT 编译器段错误，
`decrypt` 期间关掉 JIT，完事开回来（之后的字形比对要靠它）。

@module source.yuewen_fock
--]]--

local ffi = require("ffi")
local Job = require("workers.job")
local Text = require("utils.text")

---@class YuewenFockBuild
---@field wasm string 转译产物模块名（`source.<id>.fock_wasm`）
---@field callback integer 导入 b 交回解密结果的回调码
---@field stack integer set_stack 的栈基址
---@field exports { ctors: string, main: string, set_uid: string, set_key: string, decrypt: string, stack_save: string, stack_restore: string, alloc: string, malloc: string } 导出名
---@field probe fun(code: integer): integer 导入 b 收到非回调码（反调试 / 定时器探测）时的返回值
---@field imports fun(env: YuewenFockEnv): table<string, function> 构建特有的导入（宿主字符串探测 c / e / f）

---@class YuewenFockEnv
---@field mem ffi.cdata* 线性内存
---@field cstr fun(ptr: integer): string 读内存里的 C 字符串
---@field malloc_str fun(s: string): integer 用导出 malloc 放一个 C 字符串，返回指针

local Fock = {}

local MEM_SIZE = 16 * 1024 * 1024

local factories = {}

--- `Fock.decrypt` 的本体，不碰 JIT 开关。
---@param build YuewenFockBuild
---@return string|nil text
---@return string|nil err
local function run(build, content, chapter_id, keypool, version, uid)
    local factory = factories[build.wasm]
    if not factory then
        factory = require(build.wasm)
        factories[build.wasm] = factory
    end
    local names = build.exports
    local mem = ffi.new("uint8_t[?]", MEM_SIZE)
    local i32 = ffi.cast("int32_t*", mem)
    local result, exp

    local function cstr(ptr)
        local stop = ptr
        while mem[stop] ~= 0 do stop = stop + 1 end
        return ffi.string(mem + ptr, stop - ptr)
    end
    local function malloc_str(s)
        local ptr = exp[names.malloc](#s + 1)
        ffi.copy(mem + ptr, s, #s)
        mem[ptr + #s] = 0
        return ptr
    end

    local imp = build.imports({ mem = mem, cstr = cstr, malloc_str = malloc_str })
    imp.abort = function() error("fock abort") end
    imp.d = function(ptr)
        local now = os.time()
        if ptr ~= 0 then i32[ptr / 4] = now end
        return now
    end
    imp.b = function(code, _sig, argptr)
        if code == build.callback then
            local args = argptr / 4
            result = { i32[args], i32[args + 1], i32[args + 2] }
            return 0
        end
        return build.probe(code)
    end

    local data, set_stack
    exp, data, set_stack = factory({ mem = mem, imp = imp })
    for _idx, seg in ipairs(data) do
        local bytes = Text.base64Decode(seg[2])
        ffi.copy(mem + seg[1], bytes, #bytes)
    end
    set_stack(build.stack)

    local function with_stack(fn)
        local sp = exp[names.stack_save]()
        local ok, err = pcall(fn)
        exp[names.stack_restore](sp)
        if not ok then error(err, 0) end
    end
    local function put_bytes(s)
        local ptr = exp[names.alloc](#s)
        ffi.copy(mem + ptr, s, #s)
        return ptr
    end
    local function put_string(s)
        local ptr = exp[names.alloc](#s + 1)
        ffi.copy(mem + ptr, s, #s)
        mem[ptr + #s] = 0
        return ptr
    end

    local ok, err = pcall(function()
        exp[names.ctors]()
        exp[names.main](0, 0)
        with_stack(function()
            exp[names.set_uid](put_bytes(uid), #uid)
        end)
        local pool = Text.base64Decode(keypool)
        with_stack(function()
            exp[names.set_key](put_bytes(pool), #pool, put_string(version))
        end)
        local cipher = Text.base64Decode(content)
        local cid = tostring(chapter_id)
        with_stack(function()
            exp[names.decrypt](put_bytes(cipher), #cipher, put_bytes(cid), #cid)
        end)
    end)
    if not ok then return nil, tostring(err) end
    if not result then return nil, "no result" end
    if result[1] ~= 0 then return nil, "code " .. result[1] end
    return ffi.string(mem + result[2], result[3])
end

---@param build YuewenFockBuild
---@param content string base64 密文
---@param chapter_id string|number
---@param keypool string base64 密钥池（fkp 里 onkeyfocus 的第一个参数）
---@param version string
---@param uid string 用户标识（ywguid / fuid）
---@return string|nil text
---@return string|nil err
function Fock.decrypt(build, content, chapter_id, keypool, version, uid)
    local jit_was_on = jit.status()
    jit.off()
    local text, err = run(build, content, chapter_id, keypool, version, uid)
    if jit_was_on then jit.on() end
    return text, err
end

--- 在子进程里跑 worker（解密 / 字体还原），结果 `{ text, err }` 经 cb(text, err) 交回主进程。
---@param name string 任务名（日志）
---@param worker fun(): { text: string|nil, err: string|nil }
---@param cb fun(text: string|nil, err: string|nil)
---@return BookJob
function Fock.jobAsync(name, worker, cb)
    return Job.run(worker, {
        name = name,
        kind = "light",
        timeout = 600,
        on_done = function(res) cb(res.text, res.err) end,
        on_failed = function(err) cb(nil, tostring(err)) end,
        on_cancelled = function() end,
    })
end

return Fock
