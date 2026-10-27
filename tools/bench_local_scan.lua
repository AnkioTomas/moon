--[[--
在临时目录铺 N 本假书，跑本地源轻扫盘 + 补齐 + 再扫，打印耗时。
用法（仓库根）：
  COUNT=3000 ./tools/bench_local_scan.sh
  或：KO_HOME=… BOOKS=… luajit tools/bench_local_scan.lua

不启 KOReader；Job 同步跑（与离线测试同）；开文档用瞬时桩（量的是扫盘/入库路径，
不是 Kindle 上引擎提封面的墙钟——那个另用 ENRICH_MS 模拟每本开销）。
--]]

local ROOT = arg[0]:match("(.+)/tools/[^/]+$") or "."
local COUNT = tonumber(os.getenv("COUNT") or arg[1]) or 3000
local BOOKS = (os.getenv("BOOKS") or "/tmp/moon-bench/books"):gsub("/+$", "")
local HOME = (os.getenv("KO_HOME") or "/tmp/moon-bench/data"):gsub("/+$", "")
local ENRICH_MS = tonumber(os.getenv("ENRICH_MS") or "0") or 0 -- 每本补齐额外睡多少 ms（模拟墨水屏开书）
local SKIP_CREATE = os.getenv("SKIP_CREATE") == "1"

package.path = table.concat({
    ROOT .. "/book.koplugin/?.lua",
    ROOT .. "/book.koplugin/?/init.lua",
    ROOT .. "/tests/?.lua",
    ROOT .. "/tests/?/init.lua",
    ROOT .. "/koreader/frontend/?.lua",
    ROOT .. "/koreader/frontend/?/init.lua",
    ROOT .. "/koreader/base/?.lua",
    ROOT .. "/koreader/base/?/init.lua",
    package.path,
}, ";")

local emu = (io.popen("ls -d " .. ROOT .. "/koreader/koreader-emulator-*/koreader 2>/dev/null | sort -r") or {}):read("*l")
if emu and emu ~= "" then
    package.cpath = emu .. "/libs/lib?.so;" .. package.cpath
    package.path = table.concat({
        emu .. "/common/?.lua",
        emu .. "/common/?/init.lua",
        emu .. "/ffi/?.lua",
        package.path,
    }, ";")
    local ffi = require("ffi")
    if not ffi.loadlib then
        ffi.log = function() end
        local ok = pcall(dofile, emu .. "/ffi/loadlib.lua")
        if not ok then ffi.loadlib = function() end end
    end
end

os.execute("mkdir -p '" .. HOME .. "/.moon/settings' '" .. HOME .. "/.moon/cache' '" .. HOME .. "/settings'")
local common = HOME .. "/.moon/settings/common.lua"
if not io.open(common, "r") then
    local f = assert(io.open(common, "w"))
    f:write("-- " .. common .. "\nreturn {}\n")
    f:close()
end

_G.BOOK_TEST_ROOT = ROOT
local Stubs = require("support.stubs")
Stubs.install()
Stubs.reset()

-- 真磁盘用真 lfs；没有 so 就退回 Lua 目录遍历不够，直接报错
package.loaded["libs/libkoreader-lfs"] = nil
package.preload["libs/libkoreader-lfs"] = nil
local ok_lfs, lfs_or_err = pcall(require, "libs/libkoreader-lfs")
if not ok_lfs then
    io.stderr:write("need libkoreader-lfs from koreader emulator build: " .. tostring(lfs_or_err) .. "\n")
    os.exit(1)
end

local opened = 0
package.loaded["document/documentregistry"] = nil
package.preload["document/documentregistry"] = function()
    return {
        hasProvider = function() return true end,
        openDocument = function(_, path)
            opened = opened + 1
            if ENRICH_MS > 0 then
                local until_t = os.clock() + ENRICH_MS / 1000
                while os.clock() < until_t do end
            end
            return {
                getProps = function()
                    return { title = "T:" .. path:match("([^/]+)$"), authors = "Bench", description = "" }
                end,
                getCoverPageImage = function()
                    return {
                        getWidth = function() return 10 end,
                        getHeight = function() return 10 end,
                        writePNG = function(_, tmp)
                            local f = io.open(tmp, "wb")
                            if f then f:write("PNG") f:close() end
                            return true
                        end,
                        free = function() end,
                    }
                end,
                loadDocument = function() return true end,
                close = function() end,
            }
        end,
    }
end

-- Job：同步跑，progress 当场转 on_progress（与 client_spec 同）
package.loaded["workers.job"] = nil
package.preload["workers.job"] = function()
    return {
        run = function(worker, opts)
            opts = opts or {}
            local settled = false
            local handle = {
                cancel = function()
                    if settled then return end
                    settled = true
                    if opts.on_cancelled then
                        require("ui/uimanager"):nextTick(function() opts.on_cancelled() end)
                    end
                end,
            }
            local ok, result = pcall(worker, function(value)
                if opts.on_progress then opts.on_progress(value) end
            end)
            require("ui/uimanager"):nextTick(function()
                if settled then return end
                settled = true
                if ok then
                    if opts.on_done then opts.on_done(result) end
                elseif opts.on_failed then
                    opts.on_failed(result)
                end
            end)
            return handle
        end,
        inSubProcess = function() return false end,
    }
end

local function now()
    return require("utils.perf").now()
end

local function ms(since)
    return require("utils.perf").elapsedMs(since)
end

local function flush()
    require("support.stubs").flush()
end

--- 铺假书：根目录一批 + 若干分类子目录，内容略有差异好让 md5 不同。
local function createBooks(root, n)
    os.execute("rm -rf '" .. root .. "' && mkdir -p '" .. root .. "'")
    local cats = { "文学", "历史", "科技", "漫画", "其它" }
    for _, c in ipairs(cats) do
        os.execute("mkdir -p '" .. root .. "/" .. c .. "'")
    end
    local t0 = now()
    for i = 1, n do
        local cat = cats[((i - 1) % #cats) + 1]
        local path = string.format("%s/%s/book_%05d.epub", root, cat, i)
        local f = assert(io.open(path, "wb"))
        -- 足够让 partialMD5 读几段；每本内容不同
        f:write("PK\x03\x04bench-epub-", tostring(i), "\n", string.rep(string.char(i % 256), 2048))
        f:close()
        if i % 500 == 0 then
            io.write(string.format("  create %d/%d\n", i, n))
            io.flush()
        end
    end
    return ms(t0)
end

if not SKIP_CREATE then
    io.write(string.format("== create %d books under %s\n", COUNT, BOOKS))
    io.flush()
    local create_ms = createBooks(BOOKS, COUNT)
    io.write(string.format("== create done in %.0f ms\n", create_ms))
else
    io.write(string.format("== SKIP_CREATE, reuse %s\n", BOOKS))
end

-- 配本地源路径（沙箱 settings）
do
    local path = HOME .. "/.moon/settings/local.lua"
    local f = assert(io.open(path, "w"))
    f:write(string.format("-- %s\nreturn { path = %q }\n", path, BOOKS))
    f:close()
end

-- 清掉上次扫盘库与封面缓存，强制冷启动（含补齐）
os.execute("rm -f " .. HOME .. "/.moon/*.sqlite3 " .. HOME .. "/.moon/*.sqlite3-* " .. HOME .. "/.moon/*.sqlite3*")
os.execute("rm -rf " .. HOME .. "/.moon/cache/local")

local Client = require("source.local.client")
local BookDB = require("book.books_db")
local client = Client.new(require("utils.settings").getSource("local"))

local function countShelved()
    local n = 0
    for _idx, id in ipairs(BookDB.stableIdsBySource("local")) do
        local row = BookDB.get("local", id)
        if row and row.deleted == 0 then n = n + 1 end
    end
    return n
end

local function runScan(label)
    opened = 0
    local reports = 0
    local last
    local t0 = now()
    local ok, err
    client:scanAsync(function(o, e) ok, err = o, e end, function(text, done, total)
        reports = reports + 1
        last = { text = text, done = done, total = total }
    end)
    flush()
    local elapsed = ms(t0)
    io.write(string.format(
        "== %s: ok=%s err=%s shelved=%d opened=%d reports=%d time=%.0f ms (%.1f s) last=%s %s/%s\n",
        label, tostring(ok), tostring(err), countShelved(), opened, reports, elapsed, elapsed / 1000,
        last and last.text or "-", tostring(last and last.done), tostring(last and last.total)
    ))
    io.flush()
    return elapsed, ok, err
end

io.write(string.format("== cold scan (light + enrich) COUNT=%d ENRICH_MS=%d\n", COUNT, ENRICH_MS))
local cold_ms = runScan("cold")

io.write("== warm scan (fingerprint hit, enrich idle)\n")
local warm_ms = runScan("warm")

io.write("== wipe cover cache + resetCovers, then rescan (full enrich again)\n")
os.execute("rm -rf " .. HOME .. "/.moon/cache/local")
require("source.local.scan_db").resetCovers()
local retry_ms = runScan("retry-covers")

io.write("\n== summary\n")
io.write(string.format("  books=%d cold=%.1fs warm=%.1fs retry_covers=%.1fs\n",
    COUNT, cold_ms / 1000, warm_ms / 1000, retry_ms / 1000))
io.write(string.format("  data=%s books_dir=%s\n", HOME, BOOKS))
if ENRICH_MS == 0 then
    io.write("  note: ENRICH_MS=0 → 补齐开文档是瞬时桩；Kindle 真机每本往往数百 ms～数秒。\n")
    io.write("  估 Kindle：日常热扫 ≈ warm；全量补齐 ≈ N × 单本开书（试 ENRICH_MS=200）。\n")
end
