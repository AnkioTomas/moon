--[[--
features.remote.backup 离线测试：打包范围（不含日志 / 缓存 / wal）、恢复校验与整体替换、路由。

@module tests.features.remote.backup_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, inject-field

local Assert = require("support.assert")
local Config = require("support.config")
local Stubs = require("support.stubs")
local lfs = require("libs/libkoreader-lfs")

local Backup = require("features.remote.backup")

local base = Config.dir() .. "/backup_spec_root"
local root = base .. "/.moon"

local function sh(cmd) assert(os.execute(cmd)) end
local function write(path, text)
    sh("mkdir -p '" .. path:match("^(.*)/[^/]+$") .. "'")
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
end
local function read(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local text = f:read("*a")
    f:close()
    return text
end
local function fresh()
    sh("rm -rf '" .. base .. "'")
    sh("mkdir -p '" .. root .. "'")
end

-- ── 打包范围 ───────────────────────────────────────────
fresh()
write(root .. "/book.sqlite3", "DB")
write(root .. "/book.sqlite3-wal", "WAL")
write(root .. "/book.sqlite3-shm", "SHM")
write(root .. "/book.log", "log")
write(root .. "/book.log.1", "log1")
write(root .. "/settings/ui.lua", "return {}")
write(root .. "/settings/wechat.lua", "return {cookie='x'}")
write(root .. "/screensaver/custom.png", "PNG")
write(root .. "/cache/wechat/book/a/1.html", "html")
write(root .. "/backups/patches/x/orig.lua", "orig")
write(root .. "/restore.part/stale", "stale")

local names = {}
for _idx, file in ipairs(Backup.collect(lfs, root)) do names[#names + 1] = file.name end
Assert.eq(table.concat(names, ","), "book.sqlite3,screensaver/custom.png,settings/ui.lua,settings/wechat.lua",
    "含库与全部配置，不含日志 / 缓存 / 补丁备份 / wal / 暂存")

local added, memory = {}, {}
local Writer = {}
Writer.__index = Writer
function Writer:new() return setmetatable({}, Writer) end
function Writer:open() return true end
function Writer:setZipCompression() end
function Writer:addFileFromMemory(name, text) memory[name] = text; return true end
function Writer:addPath(name, path) added[#added + 1] = name .. "=" .. read(path); return false end -- 真实现正常结束也返回 false
function Writer:close() end

local out = base .. "/out.zip"
write(out, "")
Assert.eq(Backup.build(out, root, Writer, lfs), out)
Assert.is_true(memory[Backup.MARKER]:find("moon-backup", 1, true) ~= nil, "带标记文件")
Assert.eq(added[1], "book.sqlite3=DB")
Assert.eq(#added, 4)

local failing = setmetatable({}, { __index = Writer })
failing.__index = failing
function failing:new() return setmetatable({ err = "disk full" }, failing) end
function failing:addPath() return false end
write(out, "x")
local built, err = Backup.build(out, root, failing, lfs)
Assert.is_nil(built)
Assert.eq(err, "disk full")
Assert.is_nil(read(out), "失败不留半成品")

-- ── 恢复 ───────────────────────────────────────────────
--- 条目表 → Reader：extractToPath 真写文件。
local function reader(entries)
    local R = {}
    R.__index = R
    function R:new() return setmetatable({}, R) end
    function R:open() return not entries.unreadable end
    function R:iterate()
        local i = 0
        return function()
            i = i + 1
            return entries[i] and { path = entries[i].path, mode = entries[i].mode or "file" }
        end
    end
    function R:extractToPath(path, dest)
        for _idx, entry in ipairs(entries) do
            if entry.path == path then
                if entry.mode == "directory" then sh("mkdir -p '" .. dest .. "'") else write(dest, entry.text or "") end
            end
        end
        return true
    end
    function R:close() end
    return R
end

local function seed()
    fresh()
    write(root .. "/book.sqlite3", "OLD")
    write(root .. "/book.sqlite3-wal", "OLDWAL")
    write(root .. "/book.sqlite3-shm", "OLDSHM")
    write(root .. "/book.log", "keep-log")
    write(root .. "/settings/old.lua", "return {}")
    write(root .. "/cache/keep.txt", "keep-cache")
end

seed()
local restored, rerr = Backup.restore("ignored.zip", root, reader({
    { path = Backup.MARKER, text = "moon-backup 1" },
    { path = "book.sqlite3", text = "NEW" },
    { path = "settings", mode = "directory" },
    { path = "settings/wechat.lua", text = "return {cookie='x'}" },
    { path = "cache/evil.txt", text = "ignored" },
}), lfs)
Assert.is_nil(rerr)
Assert.eq(table.concat(restored, ","), "book.sqlite3,settings")
Assert.eq(read(root .. "/book.sqlite3"), "NEW")
Assert.is_nil(read(root .. "/book.sqlite3-wal"), "旧 WAL 不能套到新库")
Assert.is_nil(read(root .. "/book.sqlite3-shm"))
Assert.is_nil(read(root .. "/settings/old.lua"), "settings 整体替换，备份里没有的分区被清掉")
Assert.eq(read(root .. "/settings/wechat.lua"), "return {cookie='x'}")
Assert.eq(read(root .. "/book.log"), "keep-log", "日志不动")
Assert.eq(read(root .. "/cache/keep.txt"), "keep-cache", "缓存不动")
Assert.is_nil(read(root .. "/cache/evil.txt"), "备份里的缓存条目被忽略")
Assert.is_nil(lfs.attributes(root .. "/" .. Backup.STAGING), "暂存目录清掉")
Assert.is_nil(read(root .. "/" .. Backup.MARKER))

-- 字体被主进程 mmap：已有文件不删不换，只补缺
seed()
write(root .. "/fonts/a.ttf", "MAPPED")
Backup.restore("ignored.zip", root, reader({
    { path = Backup.MARKER, text = "moon-backup 1" },
    { path = "fonts", mode = "directory" },
    { path = "fonts/a.ttf", text = "FROM-BACKUP" },
    { path = "fonts/b.ttf", text = "NEW-FONT" },
}), lfs)
Assert.eq(read(root .. "/fonts/a.ttf"), "MAPPED", "已有字体不能被删或换")
Assert.eq(read(root .. "/fonts/b.ttf"), "NEW-FONT", "备份里多出来的字体补上")

-- 非法备份：现有数据原封不动
local function rejected(entries, expect)
    seed()
    local ok, e = Backup.restore("ignored.zip", root, reader(entries), lfs)
    Assert.is_nil(ok)
    Assert.eq(e, expect)
    Assert.eq(read(root .. "/book.sqlite3"), "OLD", expect .. "：失败不动现有数据")
    Assert.is_nil(lfs.attributes(root .. "/" .. Backup.STAGING), expect .. "：暂存清掉")
end
rejected({ { path = "book.sqlite3", text = "NEW" } }, "not a moon backup")
rejected({ unreadable = true }, "not a moon backup")
rejected({ { path = Backup.MARKER }, { path = "../evil", text = "x" } }, "unsafe archive path")
rejected({ { path = Backup.MARKER }, { path = "/abs", text = "x" } }, "unsafe archive path")
rejected({ { path = Backup.MARKER }, { path = "a/../../b", text = "x" } }, "unsafe archive path")
rejected({ { path = Backup.MARKER }, { path = "link", mode = "link" } }, "unsupported archive entry")
rejected({ { path = Backup.MARKER }, { path = "cache/only.txt", text = "x" } }, "backup is empty")

-- 落位阶段失败（主进程在中间重建了 settings/，rename 报 ENOTEMPTY）：旧数据挪回来，不留 .old
do
    seed()
    local real_rename = os.rename
    local tripped = false
    os.rename = function(from, to)
        if not tripped and to == root .. "/settings" and from:find(Backup.STAGING, 1, true) then
            tripped = true
            sh("mkdir -p '" .. root .. "/settings' && echo relived > '" .. root .. "/settings/x.lua'")
        end
        return real_rename(from, to)
    end
    local ok, e = Backup.restore("ignored.zip", root, reader({
        { path = Backup.MARKER, text = "moon-backup 1" },
        { path = "book.sqlite3", text = "NEW" },
        { path = "settings", mode = "directory" },
        { path = "settings/wechat.lua", text = "return {cookie='x'}" },
    }), lfs)
    os.rename = real_rename
    Assert.is_nil(ok)
    Assert.is_true(tripped)
    Assert.is_true(e ~= nil)
    Assert.eq(read(root .. "/settings/old.lua"), "return {}", "落位失败旧 settings 挪回来")
    Assert.is_nil(read(root .. "/settings/wechat.lua"))
    Assert.is_nil(lfs.attributes(root .. "/settings.old"), "不留 .old")
    Assert.is_nil(lfs.attributes(root .. "/" .. Backup.STAGING))
end

-- 库换新：旧库连 WAL / SHM 一起换掉，成功后不留 .old
do
    seed()
    local ok = Backup.restore("ignored.zip", root, reader({
        { path = Backup.MARKER, text = "moon-backup 1" },
        { path = "book.sqlite3", text = "NEW" },
    }), lfs)
    Assert.is_true(ok ~= nil)
    Assert.eq(read(root .. "/book.sqlite3"), "NEW")
    Assert.is_nil(lfs.attributes(root .. "/book.sqlite3.old"))
    Assert.is_nil(lfs.attributes(root .. "/book.sqlite3-wal.old"))
    Assert.is_nil(lfs.attributes(root .. "/book.sqlite3-wal"))
end

-- ── 路由 ───────────────────────────────────────────────
local sent, failed
local server = {
    handlers = {
        backup_zip = function() end,
        restore_backup = function(temp, cb) cb(temp == "T", temp == "T" and nil or "not a moon backup") end,
    },
    errorResp = function(code, msg) return { code = code, msg = msg } end,
    jsonResp = function(code, body) return { code = code, body = body } end,
    _sendBuiltZip = function(_self, _conn, build, name) sent = { build = build, name = name } end,
    _fail = function(_self, _conn, code) failed = code end,
    _acceptFile = function(_self, _conn, _headers, limit, commit)
        local resp
        commit("T", function(r) resp = r end)
        commit("bad", function(r) resp = { first = resp, second = r } end)
        return limit, resp
    end,
}
Backup.route(server, {}, "GET", {})
Assert.eq(sent.build, server.handlers.backup_zip)
Assert.matches(sent.name, "^moon%-backup%-%d+%-%d+%.zip$")
Backup.route(server, {}, "DELETE", {})
Assert.eq(failed, 405)
local _limit, resp = Backup.route(server, {}, "POST", {})
Assert.eq(_limit, Backup.MAX_BYTES)
Assert.eq(resp.first.code, 200)
Assert.eq(resp.second.code, 400, "校验失败映射 400")

-- ── 清除配置 ───────────────────────────────────────────
fresh()
write(root .. "/book.sqlite3", "DB")
write(root .. "/settings/a.lua", "A")
write(root .. "/settings/sub/b.lua", "B")
write(base .. "/crash.log", "CRASH")
Assert.is_true(Backup.clearConfig(lfs, root .. "/settings", { base .. "/crash.log", base .. "/crash.log.old" }))
Assert.is_nil(lfs.attributes(root .. "/settings"), "settings 整棵删掉")
Assert.is_nil(read(base .. "/crash.log"))
Assert.eq(read(root .. "/book.sqlite3"), "DB", "书库不动")

local reset_resp
server.handlers.reset_config = function(cb) cb(true) end
server._json = function(_self, _conn, code, body) reset_resp = code .. body end
Backup.reset(server, {}, "POST")
Assert.eq(reset_resp, '200{"ok":true}')
server.handlers.reset_config = function(cb) cb(false, "boom") end
Backup.reset(server, {}, "POST")
Assert.eq(failed, 500)
Backup.reset(server, {}, "GET")
Assert.eq(failed, 405)

sh("rm -rf '" .. base .. "'")
Stubs.flush()
