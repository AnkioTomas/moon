--[[--
零依赖测试运行器（LuaJIT）。

  ./tests/run.sh
  ./tests/run.sh tests/contract_spec.lua

不启 KOReader；需要宿主模块的用例靠 tests/support/stubs.lua 顶替。

真配置：仓库根 `config` 软链；DataStorage → config/；
读配置用 moon.settings（见 tests/support/config.lua），不要 loadfile。

@module tests.run
--]]

local ROOT = arg[0]:match("(.+)/[^/]+$") or "."
-- arg[0] 可能是 tests/run.lua；仓库根是上一级
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

-- 若本机有 koreader 树，挂上 frontend + base（ffi/sha2 等）
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

local function listSpecs(dir)
    local out = {}
    local p = io.popen('ls "' .. dir .. '"/*_spec.lua 2>/dev/null')
    if p then
        for line in p:lines() do
            out[#out + 1] = line
        end
        p:close()
    end
    table.sort(out)
    return out
end

local specs = {}
if arg[1] then
    for i = 1, #arg do
        specs[#specs + 1] = arg[i]
    end
else
    specs = listSpecs(ROOT .. "/tests")
end

if #specs == 0 then
    io.stderr:write("no *_spec.lua found under tests/\n")
    os.exit(1)
end

local failed = 0
local passed = 0

for _, path in ipairs(specs) do
    local name = path:match("([^/]+)$") or path
    io.write("→ " .. name .. "\n")
    local chunk, err = loadfile(path)
    if not chunk then
        io.stderr:write("  LOAD FAIL: " .. tostring(err) .. "\n")
        failed = failed + 1
    else
        local ok, boom = xpcall(function()
            chunk(Assert)
        end, debug.traceback)
        if not ok then
            io.stderr:write("  FAIL\n" .. tostring(boom) .. "\n")
            failed = failed + 1
        else
            io.write("  ok\n")
            passed = passed + 1
        end
    end
end

io.write(string.format("\n%d passed, %d failed\n", passed, failed))
os.exit(failed == 0 and 0 or 1)
