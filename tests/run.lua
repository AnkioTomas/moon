--[[--
零依赖测试运行器（LuaJIT）。

  ./tests/run.sh
  ./tests/run.sh tests/source/contract_spec.lua

递归扫描 tests/ 下全部 *_spec.lua（镜像 book.koplugin 目录）。

@module tests.run
--]]

local ROOT = arg[0]:match("(.+)/[^/]+$") or "."
if ROOT:match("/tests$") or ROOT == "tests" then
    ROOT = ROOT:gsub("/?tests$", "")
    if ROOT == "" then
        ROOT = "."
    end
end

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

require("support.stubs").install()

local Assert = require("support.assert")

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

local failed = 0
local passed = 0
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
    -- 卸载上个 spec 加载的一切模块（ffi/turbo 保留：重新 require 会 ffi.cdef 重复定义）。
    -- C 模块（libs/* lfs 等）重新 dlopen 无副作用，不保留——上个 spec 可能留了假桩。
    for k in pairs(package.loaded) do
        if base_loaded[k] == nil and not (k:match("^ffi") or k:match("^turbo%.")) then
            package.loaded[k] = nil
        end
    end
    for k, v in pairs(base_loaded) do
        if package.loaded[k] ~= v then
            package.loaded[k] = v
        end
    end
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
        end, debug.traceback)
        if not ok then
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

io.write(string.format("\n%d passed, %d failed (%d assertions)\n", passed, failed, total_asserts))
os.exit(failed == 0 and 0 or 1)
