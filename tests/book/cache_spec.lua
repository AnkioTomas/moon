--[[--
book.cache：后台分 tick 删目录（purgeAsync）与子进程用的同步遍历（walkFiles）

purge 走 nextTick 分片调度，由 Stubs.flush() 驱动；
临时目录限定在沙箱 .moon/cache/test_book_cache_spec/ 下，结束清理。

@module tests.book.cache_spec
--]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")
local Config = require("support.config")
local lfs = require("libs/libkoreader-lfs")
local ffiUtil = require("ffi/util")

local BASE = Config.dir() .. "/.moon/cache/test_book_cache_spec"
local CACHE = BASE .. "/cache"

-- ── 文件系统小工具 ──────────────────────────────────────
local function mkdirs(path)
    if lfs.attributes(path, "mode") == "directory" then
        return
    end
    local parent = path:match("(.+)/[^/]+$")
    if parent then
        mkdirs(parent)
    end
    lfs.mkdir(path)
end

local function writeFile(path, bytes)
    local parent = path:match("(.+)/[^/]+$")
    if parent then
        mkdirs(parent)
    end
    local fh = assert(io.open(path, "wb"))
    fh:write(string.rep("x", bytes))
    fh:close()
end

--- 清掉临时树（含上轮失败留下的只读目录）
local function resetTree()
    os.execute("chmod -R u+w " .. BASE .. " 2>/dev/null")
    if lfs.attributes(BASE) then
        ffiUtil.purgeDir(BASE)
    end
    mkdirs(CACHE)
end

local warnings = {}
package.preload["utils.log"] = function()
    return { info = function() end, warn = function(...) warnings[#warnings + 1] = { ... } end }
end
package.loaded["utils.log"] = nil

package.loaded["book.cache"] = nil
local Cache = require("book.cache")

-- ── walkFiles：同步递归，只回调文件 ──
do
    resetTree()
    writeFile(CACHE .. "/a/1.html", 100)
    writeFile(CACHE .. "/a/sub/2.html", 50)
    writeFile(CACHE .. "/b.png", 30)
    local total, count = 0, 0
    Cache.walkFiles(CACHE, function(_path, attr)
        total = total + attr.size
        count = count + 1
    end)
    Assert.eq(total, 180)
    Assert.eq(count, 3)
end

-- ── purgeAsync：递归删除整棵树（含根），排在 nextTick ──
do
    resetTree()
    writeFile(CACHE .. "/.trash/1-1/1.html", 10)
    writeFile(CACHE .. "/.trash/1-1/book.sdr/metadata.epub.lua", 10)
    writeFile(CACHE .. "/.trash/9-2/x.png", 10)
    Cache.purgeAsync(CACHE .. "/.trash")
    Assert.eq(lfs.attributes(CACHE .. "/.trash/1-1/1.html", "mode"), "file", "不在调用栈里同步删")
    Stubs.flush()
    Assert.is_nil(lfs.attributes(CACHE .. "/.trash"), "残留的边车与历史批次一并清掉")
    Assert.eq(lfs.attributes(CACHE, "mode"), "directory")
    Assert.len(warnings, 0)
end

-- ── purgeAsync：条目超过单步 budget，靠 nextTick 续跑 ──
do
    resetTree()
    for i = 1, 40 do
        writeFile(CACHE .. ("/.trash/many/f%02d.html"):format(i), 1)
    end
    local UIManager = require("ui/uimanager")
    local orig_nextTick = UIManager.nextTick
    local ticks = 0
    UIManager.nextTick = function(self, fn)
        ticks = ticks + 1
        return orig_nextTick(self, fn)
    end
    Cache.purgeAsync(CACHE .. "/.trash")
    Stubs.flush()
    UIManager.nextTick = orig_nextTick
    Assert.is_nil(lfs.attributes(CACHE .. "/.trash"))
    Assert.is_true(ticks >= 2)
end

-- ── purgeAsync：同一棵树两趟并发清理，被对方先删掉的路径不算失败 ──
do
    resetTree()
    for i = 1, 40 do
        writeFile(CACHE .. ("/.trash/a/f%02d.html"):format(i), 1)
        writeFile(CACHE .. ("/.trash/b/f%02d.html"):format(i), 1)
    end
    warnings = {}
    Cache.purgeAsync(CACHE .. "/.trash")
    Cache.purgeAsync(CACHE .. "/.trash")
    Stubs.flush()
    Assert.is_nil(lfs.attributes(CACHE .. "/.trash"))
    Assert.len(warnings, 0)
end

-- ── purgeAsync：删不掉（只读目录）只记日志 ──
do
    resetTree()
    writeFile(CACHE .. "/.trash/broken/x.html", 10)
    os.execute("chmod 0555 " .. CACHE .. "/.trash/broken")
    warnings = {}
    Cache.purgeAsync(CACHE .. "/.trash")
    Stubs.flush()
    os.execute("chmod -R u+w " .. BASE .. " 2>/dev/null") -- 先恢复，别污染后续用例
    Assert.len(warnings, 1)
    Assert.eq(warnings[1][1], "book cache trash purge failed")
    Assert.not_nil(warnings[1][3])
    Assert.eq(lfs.attributes(CACHE .. "/.trash/broken/x.html", "mode"), "file")
end

-- ── 收尾：清临时树 + 还原打桩，别污染后续 spec ─────────
resetTree()
if lfs.attributes(BASE) then
    ffiUtil.purgeDir(BASE)
end
for _idx, name in ipairs({
    "utils.log",
    "book.cache",
}) do
    package.preload[name] = nil
    package.loaded[name] = nil
end
