--[[-- source.local.client：WebDAV 双向同步与静读天下 / book 服务端共享布局互通

书目 `.Moon+/books.sync`、封面 `.Moon+/Cover/<文件名>_2.png`、进度 `.Moon+/Cache/<文件名>.po`、
统计 `.Moon+/Stats/stats.json`。WebDAV 与 db.* 都是内存假实现，语义照真实 SQL 写。
--]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")
local Json = require("support.json_stub")

package.preload["json"] = function()
    return { encode = Json.encode, decode = Json.decode, util = { InitArray = function(t) return t end } }
end
package.preload["ffi/zlib"] = function()
    return { zlib_compress = function(s) return "Z" .. s end, zlib_uncompress = function(s) return s:sub(2) end }
end
package.preload["utils.settings"] = function()
    return { ensureDeviceId = function() return "dev-A" end }
end
package.preload["utils.log"] = function()
    return { dbg = function() end, warn = function() end, info = function() end }
end

-- ── db.book：只实现本流程用到的语义（reconcile 只下架已同步行、upsertRemote 不碰脏行）──
local books = {}
local function copy(t)
    local out = {}
    for k, v in pairs(t) do out[k] = v end
    return out
end
local BookDB = {}
function BookDB.get(_, id) return books[id] and copy(books[id]) or nil end
function BookDB.getMany(_, ids)
    local out = {}
    for _, id in ipairs(ids) do if books[id] then out[id] = copy(books[id]) end end
    return out
end
function BookDB.upsertRemote(row)
    local cur = books[row.stable_id]
    if not cur then
        books[row.stable_id] = {
            stable_id = row.stable_id, title = row.title, authors = row.authors, intro = row.intro,
            category = row.category, series = row.series, deleted = row.deleted or 1, sync_status = 1,
        }
        return true
    end
    if cur.sync_status == 0 then return true end
    for _, k in ipairs({ "title", "authors", "intro", "category", "series" }) do
        if row[k] ~= nil then cur[k] = row[k] end
    end
    if row.deleted ~= nil then cur.deleted = row.deleted end
    return true
end
function BookDB.reconcile(_, rows)
    for _, b in pairs(books) do
        if b.deleted == 0 and b.sync_status == 1 then b.deleted = 1 end
    end
    for _, row in ipairs(rows) do
        local r = copy(row)
        r.deleted = 0
        BookDB.upsertRemote(r)
    end
    return true
end
function BookDB.upsertLocal(row)
    local cur = books[row.stable_id]
    for _, k in ipairs({ "title", "authors", "intro", "category", "series" }) do cur[k] = row[k] end
    return true
end
function BookDB.markSynced(_, id) books[id].sync_status = 1; return true end
function BookDB.setLibraryMembership(_, id, on_shelf)
    books[id].deleted, books[id].sync_status = on_shelf and 0 or 1, 0
    return true
end
function BookDB.libraryStableIdsBySource()
    local out = {}
    for id, b in pairs(books) do if b.deleted == 0 then out[#out + 1] = id end end
    return out
end
package.preload["db.book"] = function() return BookDB end

local progress = {}
package.preload["db.progress"] = function()
    return {
        get = function(_, id) return progress[id] end,
        upsertRemote = function(_, id, pos)
            if progress[id] and progress[id].sync_status == 0 then return true end
            local row = copy(pos)
            row.sync_status = 1
            progress[id] = row
            return true
        end,
    }
end

for _, name in ipairs({ "db.book", "db.progress", "json", "ffi/zlib", "utils.settings", "utils.log",
    "source.local.client" }) do
    package.loaded[name] = nil
end
local Client = require("source.local.client")
local Paths = require("utils.paths")

local function readFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local raw = f:read("*a")
    f:close()
    return raw
end

-- ── 内存 WebDAV：files[path] = { data, mtime }；目录由路径前缀推出 ──
local function fakeDav()
    local dav = { files = {}, calls = {} }
    function dav:put(path, data, mtime) self.files[path] = { data = data, mtime = mtime or os.time() } end
    function dav:listAsync(path, cb)
        self.calls[#self.calls + 1] = "PROPFIND " .. path
        local seen, out = {}, {}
        for p, f in pairs(self.files) do
            local rest = p:sub(1, #path + 1) == path .. "/" and p:sub(#path + 2)
            if rest then
                local head, tail = rest:match("^([^/]+)/(.+)$")
                local name = head or rest
                if not seen[name] then
                    seen[name] = true
                    out[#out + 1] = { name = name, path = path .. "/" .. name, is_dir = tail ~= nil,
                        mtime = not tail and f.mtime or nil }
                end
            end
        end
        cb(out)
    end
    function dav:getAsync(path, dest, _, cb)
        self.calls[#self.calls + 1] = "GET " .. path
        local f = self.files[path]
        if not f then return cb(nil, "HTTP 404", 404) end
        local out = assert(io.open(dest, "wb"))
        out:write(f.data)
        out:close()
        cb(true)
    end
    function dav:putFileAsync(path, local_path, cb)
        self.calls[#self.calls + 1] = "PUT " .. path
        self:put(path, readFile(local_path))
        cb(true)
    end
    function dav:ensurePathAsync(_, cb) cb(true) end
    function dav:deleteAsync(path, cb)
        self.calls[#self.calls + 1] = "DELETE " .. path
        local existed = self.files[path] ~= nil
        self.files[path] = nil
        cb(existed or nil, not existed and "HTTP 404" or nil)
    end
    function dav:count(prefix)
        local n = 0
        for _, c in ipairs(self.calls) do if c:sub(1, #prefix) == prefix then n = n + 1 end end
        return n
    end
    return dav
end

local ROOT = "Apps/Books"
local SYNC = ROOT .. "/.Moon+/books.sync"

local function client(dav)
    local c = Client.new({ webdav_url = "https://dav.example" })
    c.dav = dav
    return c
end

local function scan(c)
    local ok, err
    c:scanWebdavAsync(function(v, e) ok, err = v, e end)
    Stubs.flush()
    return ok, err
end

local function remoteEntries(dav)
    local out = {}
    for _, e in ipairs(Json.decode(dav.files[SYNC].data:sub(2))) do out[e.filename] = e end
    return out
end

local STRANGER = { -- 静读天下写出的条目：评分、分组、添加时间都不归本插件管
    filename = "局外人.epub", bookName = "局外人", author = "阿尔贝•加缪", description = "荒诞",
    favorite = "哲学", category = "<荒诞三部曲>\n#1.0#\n经典\n", rate = "5",
    addTime = "1761286619609", deviceId = "1745487877136", groupName = "",
}

-- 拉取：books.sync 按契约映射（favorite=分类、category 首部=系列）；裸文件用文件名兜底并收录进书目。
do
    local dav = fakeDav()
    dav:put(ROOT .. "/局外人.epub", "x")
    dav:put(ROOT .. "/小说/裸书 - 某人.epub", "x")
    dav:put(ROOT .. "/.hidden.epub", "x")
    dav:put(SYNC, Json.encode({ STRANGER }))
    local c = client(dav)
    Assert.is_true(scan(c))

    local stranger = books["webdav://局外人.epub"]
    Assert.eq(stranger.title, "局外人")
    Assert.eq(stranger.authors, "阿尔贝•加缪")
    Assert.eq(stranger.intro, "荒诞")
    Assert.eq(stranger.category, "哲学")
    Assert.eq(stranger.series, "荒诞三部曲")
    Assert.eq(books["webdav://小说/裸书 - 某人.epub"].title, "裸书 - 某人", "不按“作者 - 书名”猜")
    Assert.is_nil(books["webdav://.hidden.epub"], ". 前缀文件不是书")

    local entries = remoteEntries(dav)
    Assert.eq(entries["局外人.epub"].rate, "5", "保留远端字段")
    Assert.eq(entries["局外人.epub"].addTime, "1761286619609")
    Assert.eq(entries["局外人.epub"].category, "<荒诞三部曲>\n#1#\n经典")
    local bare = entries["小说/裸书 - 某人.epub"]
    Assert.eq(bare.bookName, "裸书 - 某人")
    Assert.eq(bare.author, "")
    Assert.eq(bare.deviceId, "dev-A")
    Assert.eq(bare.downloadUrl, "[WebDav]/Apps/Books/小说/裸书 - 某人.epub")
    Assert.is_nil(bare.authors, "不写契约外的 authors 键")

    -- 再同步一轮：内容没变就不回写 books.sync。
    local puts = dav:count("PUT " .. SYNC)
    Assert.is_true(scan(c))
    Assert.eq(dav:count("PUT " .. SYNC), puts)

    -- 本地编辑（脏行）推上去并清脏；远端书目不能把它覆盖回去。
    books["webdav://局外人.epub"].title = "异乡人"
    books["webdav://局外人.epub"].sync_status = 0
    Assert.is_true(scan(c))
    Assert.eq(remoteEntries(dav)["局外人.epub"].bookName, "异乡人")
    Assert.eq(books["webdav://局外人.epub"].sync_status, 1)
    Assert.eq(books["webdav://局外人.epub"].title, "异乡人")

    -- 远端删文件：下架，条目从书目里剔除。
    dav.files[ROOT .. "/小说/裸书 - 某人.epub"] = nil
    Assert.is_true(scan(c))
    Assert.eq(books["webdav://小说/裸书 - 某人.epub"].deleted, 1)
    Assert.is_nil(remoteEntries(dav)["小说/裸书 - 某人.epub"])

    -- 远端书库整个空了（目录填错 / 服务端异常）：不下架、不回写。
    dav.files[ROOT .. "/局外人.epub"] = nil
    puts = dav:count("PUT " .. SYNC)
    Assert.is_true(scan(c))
    Assert.eq(books["webdav://局外人.epub"].deleted, 0)
    Assert.eq(dav:count("PUT " .. SYNC), puts)
    books = {}
end

-- books.sync 存在却读不出来：绝不回写覆盖别的设备的书目。
do
    local dav = fakeDav()
    dav:put(ROOT .. "/a.epub", "x")
    dav:put(SYNC, "garbage")
    local c = client(dav)
    Assert.is_true(scan(c))
    Assert.eq(dav.files[SYNC].data, "garbage")
    Assert.eq(books["webdav://a.epub"].title, "a")
    books = {}
end

-- 列目录失败：整轮中止，不动书架。
do
    local dav = fakeDav()
    books["webdav://keep.epub"] = { stable_id = "webdav://keep.epub", deleted = 0, sync_status = 1 }
    function dav:listAsync(_, cb) cb(nil, "HTTP 500") end
    local ok, err = scan(client(dav))
    Assert.is_false(ok)
    Assert.eq(err, "HTTP 500")
    Assert.eq(books["webdav://keep.epub"].deleted, 0)
    books = {}
end

-- 进度：以 .po 的 mtime 为版本，只拉比本地新的；本地脏行不被覆盖。
do
    local dav = fakeDav()
    for _, name in ipairs({ "new.epub", "old.epub", "dirty.epub" }) do dav:put(ROOT .. "/" .. name, "x") end
    -- 静读天下写 .po 不更新串内时间戳：串里是很久以前，mtime 才是真实版本
    dav:put(ROOT .. "/.Moon+/Cache/new.epub.po", "1590486119266*21@0#4826:11.1%", 1800000000)
    dav:put(ROOT .. "/.Moon+/Cache/old.epub.po", "1590486119266*3@7#0:42%", 1700000000)
    dav:put(ROOT .. "/.Moon+/Cache/dirty.epub.po", "1590486119266*9:3.8%", 1800000000)
    progress["webdav://old.epub"] = { fraction = 0.5, updated_at = 1750000000, sync_status = 1 }
    progress["webdav://dirty.epub"] = { fraction = 0.9, updated_at = 1600000000, sync_status = 0 }
    Assert.is_true(scan(client(dav)))
    Assert.eq(progress["webdav://new.epub"].fraction, 0.111)
    Assert.eq(progress["webdav://new.epub"].chapter_idx, 21)
    Assert.eq(progress["webdav://new.epub"].updated_at, 1800000000)
    Assert.eq(dav:count("GET " .. ROOT .. "/.Moon+/Cache/old.epub.po"), 0, "远端不比本地新就不下载")
    Assert.eq(progress["webdav://old.epub"].fraction, 0.5)
    Assert.eq(progress["webdav://dirty.epub"].fraction, 0.9)
    books, progress = {}, {}
end

-- 进度单本拉/推：404 = 远端无记录；推送写静读天下能读的毫秒串。
do
    local dav = fakeDav()
    local c = client(dav)
    local pos, err, meta
    c:getProgressAsync("webdav://none.epub", function(p, e, m) pos, err, meta = p, e, m end)
    Stubs.flush()
    Assert.is_nil(pos)
    Assert.is_nil(err)
    Assert.is_true(meta.empty)

    local ok
    c:putProgressAsync("webdav://分类/real.epub", { updated_at = 1700000123, chapter_idx = 4, fraction = 0.4567 },
        function(v) ok = v end)
    Stubs.flush()
    Assert.is_true(ok)
    Assert.eq(dav.files[ROOT .. "/.Moon+/Cache/real.epub.po"].data, "1700000123000*4@0#0:45.7%",
        "边车按 basename 寻址")

    c:getProgressAsync("webdav://分类/real.epub", function(p) pos = p end)
    Stubs.flush()
    Assert.eq(pos.fraction, 0.457)
    Assert.eq(pos.chapter_idx, 4)
end

-- 封面：远端有、本地缺 → 下载；本地有、远端缺 → 上传；两边都有不重复传。
do
    local dav = fakeDav()
    dav:put(ROOT .. "/down.epub", "x")
    dav:put(ROOT .. "/up.epub", "x")
    dav:put(ROOT .. "/.Moon+/Cover/down.epub_2.png", "PNG-down")
    local down, up = Paths.coverPath("webdav://down.epub", "local"), Paths.coverPath("webdav://up.epub", "local")
    os.remove(down)
    Paths.ensureDir(up:match("(.+)/[^/]+$"))
    local f = assert(io.open(up, "wb"))
    f:write("PNG-up")
    f:close()
    local c = client(dav)
    Assert.is_true(scan(c))
    Assert.eq(readFile(down), "PNG-down")
    Assert.eq(dav.files[ROOT .. "/.Moon+/Cover/up.epub_2.png"].data, "PNG-up")
    local puts = dav:count("PUT " .. ROOT .. "/.Moon+/Cover/")
    Assert.is_true(scan(c))
    Assert.eq(dav:count("PUT " .. ROOT .. "/.Moon+/Cover/"), puts)
    os.remove(down)
    os.remove(up)
    books = {}
end

-- 删除：书文件和封面、进度边车一起删；边车本来没有也算成功。
do
    local dav = fakeDav()
    dav:put(ROOT .. "/分类/gone.epub", "x")
    dav:put(ROOT .. "/.Moon+/Cache/gone.epub.po", "1*0:1%")
    local ok
    client(dav):deleteWebdavAsync("webdav://分类/gone.epub", function(v) ok = v end)
    Assert.is_true(ok)
    Assert.is_nil(dav.files[ROOT .. "/分类/gone.epub"])
    Assert.is_nil(dav.files[ROOT .. "/.Moon+/Cache/gone.epub.po"])
    Assert.eq(dav:count("DELETE " .. ROOT .. "/.Moon+/Cover/gone.epub_2.png"), 1)
    Assert.eq(dav:count("DELETE " .. ROOT .. "/.Moon+/Notes/gone.epub.json"), 1)
end

-- 笔记：`.Moon+/Notes/<文件名>.json` 按设备存完整快照；推送只换本设备那份，拉取取并集。
do
    local NOTES = ROOT .. "/.Moon+/Notes/a.epub.json"
    local dav = fakeDav()
    local c = client(dav)

    -- 远端还没有笔记文件：空且非权威，不能把本地已同步笔记当“云端已删”。
    local pulled, err, meta
    c:pullNotesAsync("webdav://分类/a.epub", function(a, e, m) pulled, err, meta = a, e, m end)
    Stubs.flush()
    Assert.len(pulled, 0)
    Assert.is_nil(err)
    Assert.is_false(meta.authoritative)

    dav:put(NOTES, Json.encode({
        ["dev-B"] = {
            { page = "/body/p[1]", pos0 = "/body/p[1].0", pos1 = "/body/p[1].5", text = "旧",
              note = "B 的笔记", drawer = "lighten", datetime = "2026-01-01 10:00:00" },
            { page = "/body/p[9]", text = "书签", datetime = "2026-01-02 10:00:00" },
            { page = 3, pos0 = { x = 1, y = 2, page = 3 }, pos1 = { x = 5, y = 2, page = 3 },
              drawer = "lighten", datetime = "2026-01-03 10:00:00" },
        },
    }))
    local pushed
    c:pushNotesAsync("webdav://分类/a.epub", {
        { page = "/body/p[1]", pos0 = "/body/p[1].0", pos1 = "/body/p[1].5", text = "旧",
          note = "A 改过", drawer = "lighten", datetime = "2026-01-01 10:00:00",
          datetime_updated = "2026-02-01 10:00:00" },
        { page = 3, pos0 = { x = 1, y = 2, page = 3 }, pos1 = { x = 5, y = 2, page = 3 },
          drawer = "lighten", datetime = "2026-01-03 10:00:00" },
    }, function(v, e) pushed, err = v, e end)
    Stubs.flush()
    Assert.eq(type(pushed), "table")
    local remote = Json.decode(dav.files[NOTES].data)
    Assert.len(remote["dev-B"], 3, "别的设备快照原样保留")
    Assert.len(remote["dev-A"], 2)

    -- 同一位置只留最后修改的一条；分页文档坐标是表，也能按值去重。
    c:pullNotesAsync("webdav://分类/a.epub", function(a, e, m) pulled, err, meta = a, e, m end)
    Stubs.flush()
    Assert.is_true(meta.authoritative)
    Assert.len(pulled, 3)
    local notes = {}
    for _, item in ipairs(pulled) do notes[tostring(item.page)] = item end
    Assert.eq(notes["/body/p[1]"].note, "A 改过")
    Assert.eq(notes["/body/p[9]"].text, "书签")
    Assert.eq(notes["3"].drawer, "lighten")

    -- 本设备删光：写空快照，并集只剩别的设备的。
    c:pushNotesAsync("webdav://分类/a.epub", {}, function(v) pushed = v end)
    Stubs.flush()
    Assert.len(Json.decode(dav.files[NOTES].data)["dev-A"], 0)

    -- 远端文件损坏：推送失败，不覆盖。
    dav:put(NOTES, "{broken")
    pushed = nil
    c:pushNotesAsync("webdav://分类/a.epub", {}, function(v, e) pushed, err = v, e end)
    Stubs.flush()
    Assert.is_nil(pushed)
    Assert.eq(err, "笔记文件损坏")
    Assert.eq(dav.files[NOTES].data, "{broken")
end

-- 统计：推送与远端已有行按 设备+文件+开始时间 去重合并；WebDAV 书写相对路径。
do
    local STATS = ROOT .. "/.Moon+/Stats/stats.json"
    local dav = fakeDav()
    local c = client(dav)

    -- 远端还没有 stats.json：拉取只追加（纯数组），不带 replace 抹本地历史。
    local pulled
    c:pullStatsAsync(function(r) pulled = r end)
    Stubs.flush()
    Assert.eq(#pulled, 0)
    Assert.is_nil(pulled.replace)

    dav:put(STATS, Json.encode({
        { filename = "a.epub", device_id = "dev-B", page = 3, start_time = 100, duration = 30, total_pages = 9 },
        { filename = "/sdcard/b.epub", device_id = "dev-B", page = 1, start_time = 50, duration = 5 },
    }))
    local result
    c:pushStatsAsync({
        { stable_id = "webdav://a.epub", page = 4, start_time = 200, duration = 60, total_pages = 9 },
        { stable_id = "webdav://a.epub", page = 4, start_time = 200, duration = 60, total_pages = 9 },
        { stable_id = "/books/local.epub", page = 2, start_time = 300, duration = 10, total_pages = 5 },
    }, function(r) result = r end)
    Stubs.flush()
    Assert.eq(type(result), "table")
    Assert.is_nil(result.synced_ids, "整批确认")
    local remote = Json.decode(dav.files[STATS].data)
    Assert.len(remote, 4)
    Assert.eq(remote[3].filename, "a.epub")
    Assert.eq(remote[3].device_id, "dev-A")
    Assert.eq(remote[4].filename, "/books/local.epub")

    -- 拉取：全量快照覆盖已同步行；别的设备的非 WebDAV 书（绝对路径）不认。
    c:pullStatsAsync(function(r) pulled = r end)
    Stubs.flush()
    Assert.eq(pulled.replace.mode, "all_synced")
    local ids = {}
    for _, row in ipairs(pulled.rows) do ids[#ids + 1] = row.stable_id .. "@" .. row.start_time end
    table.sort(ids)
    Assert.eq(table.concat(ids, ","), "/books/local.epub@300,webdav://a.epub@100,webdav://a.epub@200")
    Assert.eq(pulled.rows[1].record_type, "page")

    -- 远端文件损坏：推送失败，不拿本地行覆盖掉别的设备的数据。
    dav:put(STATS, "{broken")
    local err
    c:pushStatsAsync({ { stable_id = "webdav://a.epub", start_time = 400, duration = 1 } },
        function(r, e) result, err = r, e end)
    Stubs.flush()
    Assert.is_nil(result)
    Assert.eq(err, "阅读统计文件损坏")
    Assert.eq(dav.files[STATS].data, "{broken")
end
