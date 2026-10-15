--[[--
零依赖测试运行器（LuaJIT）。

  ./tests/run.sh
  ./tests/run.sh tests/source/contract_spec.lua

递归扫描 tests/ 下全部 *_spec.lua（镜像 book.koplugin 目录）。
每个 spec 在独立 luajit 进程中运行，避免跨文件卸/装 ffi 导致
ctype 表重建（CI 段错误）或 Mac 上 static const 重复 cdef 失败。

@module tests.run
--]]

local ROOT = arg[0]:match("(.+)/[^/]+$") or "."
if ROOT:match("/tests$") or ROOT == "tests" then
    ROOT = ROOT:gsub("/?tests$", "")
    if ROOT == "" then
        ROOT = "."
    end
end

local function listSpecsRecursive(dir)
    local out = {}
    local p = io.popen('find "' .. dir .. '" -type f -name "*_spec.lua" 2>/dev/null | sort')
    if p then
        for line in p:lines() do
            out[#out + 1] = line
        end
        p:close()
    end
    return out
end

local function shellQuote(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function relName(path)
    if ROOT == "." then
        return path:gsub("^%./", "")
    end
    if path:sub(1, #ROOT + 1) == ROOT .. "/" then
        return path:sub(#ROOT + 2)
    end
    return path
end

local specs = {}
if arg[1] then
    for i = 1, #arg do
        specs[#specs + 1] = arg[i]
    end
else
    specs = listSpecsRecursive(ROOT .. "/tests")
end

if #specs == 0 then
    io.stderr:write("no *_spec.lua found under tests/\n")
    os.exit(1)
end

-- 父进程：逐个拉起子进程，汇总结果（子进程设 MOON_TEST_CHILD=1）
if os.getenv("MOON_TEST_CHILD") ~= "1" then
    -- 与 tests/run.sh 一致地建沙箱：直接 `lua tests/run.lua`（含临时 worktree）时
    -- 缺 common.lua 会让依赖沙箱的 spec 全部 skip。
    local home = (os.getenv("KO_HOME") or ""):gsub("/+$", "")
    if home == "" then home = ROOT .. "/test" end
    os.execute("mkdir -p " .. shellQuote(home .. "/.moon/settings") .. " "
        .. shellQuote(home .. "/.moon/cache") .. " " .. shellQuote(home .. "/settings"))
    local common = home .. "/.moon/settings/common.lua"
    local probe = io.open(common, "r")
    if probe then
        probe:close()
    else
        local f = io.open(common, "w")
        if f then
            f:write("-- " .. common .. "\nreturn {}\n")
            f:close()
        end
    end
    local passed, skipped, failed, total_asserts = 0, 0, 0, 0
    local self = arg[0]
    for _, path in ipairs(specs) do
        local cmd = table.concat({
            "MOON_TEST_CHILD=1",
            "luajit",
            shellQuote(self),
            shellQuote(path),
            "2>&1",
        }, " ")
        local pipe = io.popen(cmd)
        local out = pipe and pipe:read("*a") or ""
        if pipe then
            pipe:close()
        end
        -- 转发子进程输出，去掉它自己的汇总行（父进程统一打印）
        for line in (out .. "\n"):gmatch("(.-)\n") do
            if not line:match("^%d+ passed, %d+ skipped, %d+ failed") then
                io.write(line .. "\n")
            end
        end
        local p, s, f, a = out:match(
            "(%d+) passed, (%d+) skipped, (%d+) failed %((%d+) assertions%)"
        )
        if not p then
            io.stderr:write("  FAIL: child produced no summary for " .. relName(path) .. "\n")
            failed = failed + 1
        else
            passed = passed + tonumber(p)
            skipped = skipped + tonumber(s)
            failed = failed + tonumber(f)
            total_asserts = total_asserts + tonumber(a)
        end
    end
    io.write(string.format(
        "\n%d passed, %d skipped, %d failed (%d assertions)\n",
        passed, skipped, failed, total_asserts
    ))
    os.exit(failed == 0 and 0 or 1)
end

-- 子进程：只跑本进程收到的 spec（通常一个）
_G.BOOK_TEST_ROOT = ROOT

package.path = table.concat({
    ROOT .. "/book.koplugin/?.lua",
    ROOT .. "/book.koplugin/?/init.lua",
    ROOT .. "/tests/?.lua",
    ROOT .. "/tests/?/init.lua",
    package.path,
}, ";")

local ko = ROOT .. "/koreader"
local f = io.open(ko .. "/frontend/ui/uimanager.lua", "r")
if f then
    f:close()
    package.path = table.concat({
        ko .. "/frontend/?.lua",
        ko .. "/frontend/?/init.lua",
        ko .. "/base/?.lua",
        ko .. "/base/?/init.lua",
        package.path,
    }, ";")
end

-- 模拟器构建（git 忽略）里的 lua-ljsqlite3 + ffi.loadlib：有就让 sqlite spec 真跑。
do
    local probe = io.popen("ls -d " .. shellQuote(ko) .. "/koreader-emulator-*/koreader 2>/dev/null | sort -r")
    local emu = probe and probe:read("*l")
    if probe then probe:close() end
    local lib = emu and io.open(emu .. "/common/lua-ljsqlite3/init.lua", "r")
    if lib then
        lib:close()
        local ffi = require("ffi")
        if not ffi.loadlib then
            ffi.log = function() end
            dofile(emu .. "/ffi/loadlib.lua")
        end
        -- 只放出 sqlite 一个模块：整个 common/ 进 path 会让真 turbo/ssl 顶掉测试桩。
        package.preload["lua-ljsqlite3/init"] = function()
            return dofile(emu .. "/common/lua-ljsqlite3/init.lua")
        end
    end
end

require("support.stubs").install()

local Assert = require("support.assert")

local failed = 0
local passed = 0
local skipped = 0
local total_asserts = 0

-- 环境基线：stubs 首次安装后的干净状态。每个 spec 前恢复到基线，
-- 堵住跨文件泄漏（残留的 package.preload 桩、被替换的 os/io 全局函数等）。
local function snapshot(t)
    local s = {}
    for k, v in pairs(t) do
        s[k] = v
    end
    return s
end

local base_preload = snapshot(package.preload)
local base_loaded = snapshot(package.loaded)
local base_os = snapshot(os)
local base_io = snapshot(io)
local base_reader_settings = _G.G_reader_settings

local function restoreTable(t, base)
    for k in pairs(t) do
        if base[k] == nil then
            t[k] = nil
        end
    end
    for k, v in pairs(base) do
        if t[k] ~= v then
            t[k] = v
        end
    end
end

local function restoreEnv()
    restoreTable(package.preload, base_preload)
    restoreTable(os, base_os)
    restoreTable(io, base_io)
    _G.G_reader_settings = base_reader_settings
    -- 卸载上个 spec 加载的一切非基线模块。同名 cdef 重复定义 LuaJIT 是放行的
    -- （实测 ffi/sha2 重 require 无错），保留例外反而会让假桩（如 spec 桩的
    -- ffi/util）漏给后续文件。
    for k in pairs(package.loaded) do
        if base_loaded[k] == nil then
            package.loaded[k] = nil
        end
    end
    for k, v in pairs(base_loaded) do
        if package.loaded[k] ~= v then
            package.loaded[k] = v
        end
    end
end

for _, path in ipairs(specs) do
    local name = relName(path)
    io.write("→ " .. name .. "\n")
    local chunk, err = loadfile(path)
    if not chunk then
        io.stderr:write("  LOAD FAIL: " .. tostring(err) .. "\n")
        failed = failed + 1
    else
        restoreEnv()
        local Stubs = require("support.stubs")
        Stubs.reset()
        Stubs.install()

        Assert.reset_count()
        local ok, boom = xpcall(function()
            chunk(Assert)
        end, function(err)
            if type(err) == "string" and err:sub(1, #Assert.SKIP_PREFIX) == Assert.SKIP_PREFIX then
                return err
            end
            return debug.traceback(err)
        end)
        if not ok and type(boom) == "string"
            and boom:sub(1, #Assert.SKIP_PREFIX) == Assert.SKIP_PREFIX then
            io.write("  skip (" .. boom:sub(#Assert.SKIP_PREFIX + 1) .. ")\n")
            skipped = skipped + 1
        elseif not ok then
            io.stderr:write("  FAIL\n" .. tostring(boom) .. "\n")
            failed = failed + 1
        elseif Assert.count == 0 then
            -- 0 断言 = 假绿（借鉴 koassistant：nil return 被 harness 当 PASS 的教训）
            io.stderr:write("  FAIL: no assertions (false green)\n")
            failed = failed + 1
        else
            io.write("  ok (" .. Assert.count .. " assertions)\n")
            passed = passed + 1
            total_asserts = total_asserts + Assert.count
        end
    end
end

-- 子进程不加前导空行，避免父进程剥掉汇总后规格之间多空行
io.write(string.format(
    "%d passed, %d skipped, %d failed (%d assertions)\n",
    passed, skipped, failed, total_asserts
))
os.exit(failed == 0 and 0 or 1)
