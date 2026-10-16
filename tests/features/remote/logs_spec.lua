--[[--
features.remote.logs：日志脱敏、收集白名单、打包（假 Writer）与文件名。

@module tests.features.remote.logs_spec
--]]

local Assert = require("support.assert")
local Logs = require("features.remote.logs")

local function has(s, sub)
    Assert.is_true(s:find(sub, 1, true) ~= nil, "expected to contain: " .. sub)
end
local function hasnt(s, sub)
    Assert.is_nil(s:find(sub, 1, true), "must not contain: " .. sub)
end

-- 脱敏
local r = Logs.redact(table.concat({
    "GET /api/list?path=/x&t=0123456789abcdef HTTP/1.1",
    "Authorization: Bearer eyJhbGciOi.payload.sig",
    '{"api_key": "sk-abcdefghijklmnop", "model": "gpt"}',
    "password=hunter2 user=bob",
    "Cookie: sid=zzz123; theme=dark",
    "access_token=AAA refresh_token=BBB",
    "wereadToken: \"XYZ\"",
    "normal line 42",
}, "\n"))
for _, secret in ipairs({ "0123456789abcdef", "eyJhbGciOi", "sk-abcdefghijklmnop", "hunter2", "zzz123", "AAA", "BBB", "XYZ" }) do
    hasnt(r, secret)
end
has(r, "path=/x")
has(r, "user=bob")
has(r, '"model": "gpt"')
has(r, "normal line 42")
has(r, "***")

-- 长词元（base64 封面、长 Cookie）不能触发 O(n²) 回溯：旧模式 16KB 要十几秒，Kindle 上打包超时成 0KB
do
    local blob = ("A"):rep(64 * 1024)
    local t0 = os.clock()
    local out = Logs.redact("img=" .. blob .. " token=SECRET\n")
    Assert.is_true(os.clock() - t0 < 1, "redact must be linear on long words")
    hasnt(out, "SECRET")
    has(out, blob)
end

-- 文件名
Assert.is_true(Logs.fileName(os.time()):match("^moon%-logs%-%d%d%d%d%d%d%d%d%-%d%d%d%d%.zip$") ~= nil, "file name")

-- 收集：只按文件名白名单，跳过目录、软链与 settings
local dir = os.tmpname()
os.remove(dir)
os.execute("mkdir -p '" .. dir .. "/sub'")
local function write(name, text)
    local f = assert(io.open(dir .. "/" .. name, "wb"))
    f:write(text)
    f:close()
end
write("book.log", "boot ok\ntoken=SECRET1\n")
write("book.log.1", "older\n")
write("crash.log", "crash cookie=SECRET2\n")
write("settings.lua", "return { password = 'SECRET3' }\n")
os.execute("ln -s '" .. dir .. "/settings.lua' '" .. dir .. "/crash.log.link' 2>/dev/null")
local fake_lfs = {
    dir = function(p)
        -- 与真 lfs 一致：目录不存在时抛错
        local probe = io.popen("[ -d '" .. p .. "' ] && echo y")
        local exists = probe:read("*l")
        probe:close()
        if not exists then error("cannot open " .. p) end
        local h = io.popen("ls -a '" .. p .. "'")
        local names = {}
        for n in h:lines() do names[#names + 1] = n end
        h:close()
        local i = 0
        return function() i = i + 1; return names[i] end, nil
    end,
    symlinkattributes = function(p)
        local h = io.popen("if [ -L '" .. p .. "' ]; then echo link; elif [ -d '" .. p .. "' ]; then echo directory; elif [ -f '" .. p .. "' ]; then echo file; fi")
        local mode = h:read("*l")
        h:close()
        if not mode then return nil end
        return { mode = mode, size = 10, modification = os.time() }
    end,
}
local files = Logs.collect(fake_lfs, {
    { dir = dir, prefix = "moon/", patterns = { "^book%.log" } },
    { dir = dir, prefix = "koreader/", patterns = { "^crash%.log" } },
    { dir = dir .. "/missing", prefix = "x/", patterns = { "." } },
})
local names = {}
for _, f in ipairs(files) do names[#names + 1] = f.name end
Assert.eq(table.concat(names, ","), "moon/book.log,moon/book.log.1,koreader/crash.log")

-- 打包：假 Writer 记录写入内容
local added = {}
local Writer = {}
function Writer:new() return setmetatable({}, { __index = self }) end
function Writer:open(path, fmt) self.path = path; self.fmt = fmt; return true end
function Writer:setZipCompression(m) self.comp = m; return true end
function Writer:addFileFromMemory(name, content) added[name] = content; return true end
function Writer:close() self.closed = true end
local out, err = Logs.build(dir .. "/out.zip", files, {
    plugin_version = "1.2.3", koreader_version = "v2026.07", device = "Kindle", language = "en_US",
    generated = "2026-10-14 20:00:00",
}, Writer)
Assert.eq(out, dir .. "/out.zip")
Assert.is_nil(err)
has(added["moon/book.log"], "boot ok")
hasnt(added["moon/book.log"], "SECRET1")
hasnt(added["koreader/crash.log"], "SECRET2")
Assert.is_nil(added["settings.lua"])
local info = added["info.txt"]
has(info, "plugin_version: 1.2.3")
has(info, "koreader_version: v2026.07")
has(info, "device: Kindle")
has(info, "language: en_US")
has(info, "generated: 2026-10-14 20:00:00")
has(info, "moon/book.log")

-- 体积上限：单文件只取末尾，超总量的跳过并在 info.txt 注明
local per, total = Logs.PER_FILE, Logs.TOTAL
Logs.PER_FILE, Logs.TOTAL = 8, 8
added = {}
write("book.log", "line-one\nline-two\nline-3\n")
Logs.build(dir .. "/out2.zip", files, {}, Writer)
Logs.PER_FILE, Logs.TOTAL = per, total
hasnt(added["moon/book.log"], "line-one")
has(added["info.txt"], "truncated to last part: moon/book.log")
has(added["info.txt"], "skipped (size cap)")

os.execute("rm -rf '" .. dir .. "'")

-- KOReader 相关日志：轮转件、缺失目录记 skipped、内存条目（logcat / 设置键名）
do
    local d = os.tmpname()
    os.remove(d)
    os.execute("mkdir -p '" .. d .. "'")
    for _, n in ipairs({ "crash.log", "crash.log.old", "crash.1.log", "koreader.log", "settings.reader.lua", "notes.txt" }) do
        local f = assert(io.open(d .. "/" .. n, "wb"))
        f:write(n .. " body token=LEAK\n")
        f:close()
    end
    local KO = { "^crash.*%.log$", "^crash%.log%.old$", "^reader%.log$", "^koreader.*%.log$" }
    local got, missing = Logs.collect(fake_lfs, {
        { dir = d, prefix = "koreader-data/", patterns = KO },
        { dir = d .. "/nope", prefix = "kobo/", patterns = { "%.log$" } },
    })
    local n2 = {}
    for _, f in ipairs(got) do n2[#n2 + 1] = f.name end
    Assert.eq(table.concat(n2, ","), "koreader-data/crash.1.log,koreader-data/crash.log,koreader-data/crash.log.old,koreader-data/koreader.log")
    Assert.eq(missing[1], d .. "/nope")

    local keys = Logs.settingsKeys({ language = "en", weread_token = "SECRET9", home_dir = "/x" })
    has(keys, "weread_token")
    has(keys, "language")
    hasnt(keys, "SECRET9")
    hasnt(keys, "/x")

    added = {}
    Logs.build(d .. "/o.zip", got, {}, Writer, {
        { name = "android-logcat.txt", text = "I/x: Authorization: Bearer ABCDEF\n" },
        { name = "koreader-settings-keys.txt", text = keys },
        { name = "empty.txt", text = "" },
    }, { "skipped (not found): " .. d .. "/nope" })
    hasnt(added["koreader-data/crash.log.old"], "LEAK")
    hasnt(added["android-logcat.txt"], "ABCDEF")
    has(added["koreader-settings-keys.txt"], "weread_token")
    local info2 = added["info.txt"]
    has(info2, "koreader-data/crash.log.old")
    has(info2, "android-logcat.txt")
    has(info2, "skipped (not found): " .. d .. "/nope")
    has(info2, "skipped (empty): empty.txt")
    os.execute("rm -rf '" .. d .. "'")
end

-- fixPerms：KOReader 写成十进制 0644 的外部属性，改回 0100644，别的字节不动
do
    local function u16(n) return string.char(n % 256, math.floor(n / 256) % 256) end
    local function u32(n) return u16(n % 65536) .. u16(math.floor(n / 65536)) end
    local name, data = "a.txt", "hi"
    local lfh = "PK\3\4" .. u16(20) .. u16(0) .. u16(0) .. u16(0) .. u16(0) .. u32(0)
        .. u32(#data) .. u32(#data) .. u16(#name) .. u16(0) .. name .. data
    local bad = string.char(0, 0, 0x84, 0x02) -- 1204(八进制) << 16
    local cdh = "PK\1\2" .. u16(0x031E) .. u16(20) .. u16(0) .. u16(0) .. u16(0) .. u16(0) .. u32(0)
        .. u32(#data) .. u32(#data) .. u16(#name) .. u16(0) .. u16(0) .. u16(0) .. u16(0) .. bad .. u32(0) .. name
    local eocd = "PK\5\6" .. u16(0) .. u16(0) .. u16(1) .. u16(1) .. u32(#cdh) .. u32(#lfh) .. u16(0)
    local path = os.tmpname()
    local f = io.open(path, "wb"); f:write(lfh .. cdh .. eocd); f:close()
    Assert.eq(Logs.fixPerms(path), true)
    f = io.open(path, "rb"); local out = f:read("*a"); f:close()
    os.remove(path)
    Assert.eq(#out, #lfh + #cdh + #eocd)
    local at = #lfh + 38
    Assert.eq(out:sub(at + 1, at + 4), string.char(0, 0, 0xA4, 0x81))
    Assert.eq(out:sub(1, at) .. out:sub(at + 5), (lfh .. cdh .. eocd):sub(1, at) .. (lfh .. cdh .. eocd):sub(at + 5))
    Assert.eq(Logs.fixPerms(path .. ".missing"), false)
end
