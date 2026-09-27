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
function BookDB.touchPath(_, id, path)
    books[id] = books[id] or { stable_id = id, deleted = 1, sync_status = 1 }
    books[id].path = path
    return true
end
function BookDB.markDeleted(_, id)
    books[id].deleted, books[id].sync_status, books[id].path = 1, 0, nil
    return true
end
function BookDB.adoptStableId(_, old, new, path)
    if books[new] and books[new].deleted == 1 then books[new] = nil end
    if not books[new] then
        books[new] = books[old]
        books[new].stable_id = new
    end
    books[old] = nil
    books[new].path = path
    return true
end
function BookDB.unsynced()
    local out = {}
    for _, b in pairs(books) do if b.sync_status == 0 then out[#out + 1] = copy(b) end end
    return out
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

-- 子进程任务（本地目录扫描）就地同步跑，结果经 nextTick 回交保持异步语义。
package.preload["workers.job"] = function()
    return {
        run = function(worker, opts)
            local ok, result = pcall(worker, {})
            require("ui/uimanager"):nextTick(function()
                if ok then opts.on_done(result) else opts.on_failed(result) end
            end)
            return { cancel = function() end }
        end,
    }
end

for _, name in ipairs({ "db.book", "db.progress", "json", "ffi/zlib", "utils.settings", "utils.log",
    "workers.job", "source.local.client" }) do
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
        cb(existed or nil, not existed and "HTTP 404" or nil, not existed and 404 or nil)
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

local function run(c, opts)
    local ok, err
    c:scanWebdavAsync(function(v, e) ok, err = v, e end, opts)
    Stubs.flush()
    return ok, err
end
--- 日常同步：只认 books.sync。
local function scan(c) return run(c) end
--- 刷新按钮：另扫远端文件与本地目录合并。
local function refresh(c) return run(c, { refresh = true }) end

local function remoteEntries(dav)
    local out = {}
    for _, e in ipairs(Json.decode(dav.files[SYNC].data:sub(2))) do out[e.filename] = e end
    return out
end
local function putSync(dav, list) dav:put(SYNC, "Z" .. Json.encode(list)) end

local STRANGER = { -- 静读天下写出的条目：评分、分组、添加时间都不归本插件管
    filename = "局外人.epub", bookName = "局外人", author = "阿尔贝•加缪", description = "荒诞",
    favorite = "哲学", category = "<荒诞三部曲>\n#1.0#\n经典\n", rate = "5",
    addTime = "1761286619609", deviceId = "1745487877136", groupName = "",
}

-- 书架只靠 books.sync：日常同步不列目录；刷新才把书目外的远端文件补进来。
do
    local dav = fakeDav()
    dav:put(ROOT .. "/局外人.epub", "x")
    dav:put(ROOT .. "/小说/裸书 - 某人.epub", "x")
    dav:put(ROOT .. "/.hidden.epub", "x")
    putSync(dav, { STRANGER })
    local c = client(dav)
    Assert.is_true(scan(c))
    local stranger = books["webdav://局外人.epub"]
    Assert.eq(stranger.title, "局外人")
    Assert.eq(stranger.authors, "阿尔贝•加缪")
    Assert.eq(stranger.intro, "荒诞")
    Assert.eq(stranger.category, "哲学")
    Assert.eq(stranger.series, "荒诞三部曲")
    Assert.is_nil(books["webdav://小说/裸书 - 某人.epub"], "日常同步不扫远端目录")
    Assert.eq(dav:count("PROPFIND " .. ROOT .. "/小说"), 0)

    Assert.is_true(refresh(c))
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

    local puts = dav:count("PUT " .. SYNC)
    Assert.is_true(scan(c))
    Assert.eq(dav:count("PUT " .. SYNC), puts, "内容没变就不回写")

    -- 本地编辑（脏行）推上去并清脏；远端书目不能把它覆盖回去。
    books["webdav://局外人.epub"].title = "异乡人"
    books["webdav://局外人.epub"].sync_status = 0
    Assert.is_true(scan(c))
    Assert.eq(remoteEntries(dav)["局外人.epub"].bookName, "异乡人")
    Assert.eq(books["webdav://局外人.epub"].sync_status, 1)
    Assert.eq(books["webdav://局外人.epub"].title, "异乡人")

    -- 远端文件没了但书目还在：日常同步照旧在书架；刷新才剔掉（本地也没有）。
    dav.files[ROOT .. "/小说/裸书 - 某人.epub"] = nil
    Assert.is_true(scan(c))
    Assert.eq(books["webdav://小说/裸书 - 某人.epub"].deleted, 0)
    Assert.is_true(refresh(c))
    Assert.eq(books["webdav://小说/裸书 - 某人.epub"].deleted, 1)
    Assert.is_nil(remoteEntries(dav)["小说/裸书 - 某人.epub"])

    -- 别的设备把书从书目里删了：日常同步即下架（文件还在也不算）。
    books["webdav://别的.epub"] = { stable_id = "webdav://别的.epub", deleted = 0, sync_status = 1 }
    putSync(dav, { { filename = "别的.epub", bookName = "别的" } })
    Assert.is_true(scan(c))
    Assert.eq(books["webdav://局外人.epub"].deleted, 1)
    Assert.eq(books["webdav://别的.epub"].deleted, 0)

    -- 书目整个空了（目录填错 / 服务端异常）：不下架、不回写。
    putSync(dav, {})
    puts = dav:count("PUT " .. SYNC)
    Assert.is_true(scan(c))
    Assert.eq(books["webdav://别的.epub"].deleted, 0)
    Assert.eq(dav:count("PUT " .. SYNC), puts)
    books = {}
end

-- books.sync 存在却读不出来：不 reconcile、绝不回写覆盖别的设备的书目。
do
    local dav = fakeDav()
    dav:put(ROOT .. "/a.epub", "x")
    dav:put(SYNC, "garbage")
    books["webdav://keep.epub"] = { stable_id = "webdav://keep.epub", deleted = 0, sync_status = 1 }
    local c = client(dav)
    Assert.is_true(scan(c))
    Assert.is_true(refresh(c))
    Assert.eq(dav.files[SYNC].data, "garbage")
    Assert.eq(books["webdav://keep.epub"].deleted, 0)
    books = {}
end

-- 刷新时列目录失败：整轮中止，不动书架。
do
    local dav = fakeDav()
    books["webdav://keep.epub"] = { stable_id = "webdav://keep.epub", deleted = 0, sync_status = 1 }
    function dav:listAsync(_, cb) cb(nil, "HTTP 500") end
    local ok, err = refresh(client(dav))
    Assert.is_false(ok)
    Assert.eq(err, "HTTP 500")
    Assert.eq(books["webdav://keep.epub"].deleted, 0)
    books = {}
end

-- 进度：以 .po 的 mtime 为版本，只拉比本地新的；本地脏行不被覆盖。
do
    local dav = fakeDav()
    putSync(dav, { { filename = "new.epub" }, { filename = "old.epub" }, { filename = "dirty.epub" } })
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

-- 封面：远端有、本地缺 → 下载；刷新时本地有、远端缺 → 上传；两边都有不重复传。
do
    local dav = fakeDav()
    dav:put(ROOT .. "/down.epub", "x")
    dav:put(ROOT .. "/up.epub", "x")
    putSync(dav, { { filename = "down.epub" }, { filename = "up.epub" } })
    dav:put(ROOT .. "/.Moon+/Cover/down.epub_2.png", "PNG-down")
    local down, up = Paths.coverPath("webdav://down.epub", "local"), Paths.coverPath("webdav://up.epub", "local")
    os.remove(down)
    Paths.ensureDir(up:match("(.+)/[^/]+$"))
    local f = assert(io.open(up, "wb"))
    f:write("PNG-up")
    f:close()
    local c = client(dav)
    Assert.is_true(refresh(c))
    Assert.eq(readFile(down), "PNG-down")
    Assert.eq(dav.files[ROOT .. "/.Moon+/Cover/up.epub_2.png"].data, "PNG-up")
    local puts = dav:count("PUT " .. ROOT .. "/.Moon+/Cover/")
    Assert.is_true(refresh(c))
    Assert.eq(dav:count("PUT " .. ROOT .. "/.Moon+/Cover/"), puts)
    os.remove(down)
    os.remove(up)
    books = {}
end

-- 本地书库目录：刷新时合并（本地新书上传进书目、收编绝对路径身份）；远端书按需下载到这里。
do
    local L = require("support.config").dir() .. "/webdav-mirror"
    local function put(rel, data)
        Paths.ensureDir((L .. "/" .. rel):match("(.+)/[^/]+$"))
        local f = assert(io.open(L .. "/" .. rel, "wb"))
        f:write(data)
        f:close()
    end
    local function exists(rel) return readFile(L .. "/" .. rel) ~= nil end
    for _, rel in ipairs({ "both.epub", "新书.epub", "分类/旧.epub", "远端.epub", "A/B/深.txt", "恢复.epub" }) do
        os.remove(L .. "/" .. rel)
    end
    put("both.epub", "both")
    put("新书.epub", "new")
    put("分类/旧.epub", "old")
    put("A/B/深.txt", "deep")
    put("恢复.epub", "restore")
    -- 以前按绝对路径登记过（扫盘/从文件管理器打开）且改过书名；远端曾删过同名书（墓碑）。
    books[L .. "/分类/旧.epub"] = { stable_id = L .. "/分类/旧.epub", title = "旧书", deleted = 0, sync_status = 0 }
    books["webdav://分类/旧.epub"] = { stable_id = "webdav://分类/旧.epub", title = "旧", deleted = 1, sync_status = 1 }
    local dav = fakeDav()
    dav:put(ROOT .. "/both.epub", "both")
    dav:put(ROOT .. "/远端.epub", "remote")
    putSync(dav, {
        { filename = "both.epub", bookName = "both" },
        { filename = "远端.epub", bookName = "远端" },
        { filename = "恢复.epub", bookName = "恢复" }, -- 书目有、远端文件丢了、本地还有
        { filename = "失踪.epub", bookName = "失踪" }, -- 书目有、两边都没有文件
    })
    local c = Client.new({ webdav_url = "https://dav.example", path = L })
    c.dav = dav

    -- 日常同步：只对齐书目，不扫本地、不上传。
    Assert.is_true(scan(c))
    Assert.is_nil(dav.files[ROOT .. "/新书.epub"])
    Assert.eq(books["webdav://失踪.epub"].deleted, 0, "书目是唯一依据")

    Assert.is_true(refresh(c))
    Assert.eq(dav.files[ROOT .. "/新书.epub"].data, "new", "本地新书 → 上传")
    Assert.eq(dav.files[ROOT .. "/分类/旧.epub"].data, "old", "墓碑 + 本地仍有 = 用户重新放进来 → 上传")
    Assert.eq(dav.files[ROOT .. "/A/B/深.txt"].data, "deep", "相对路径原样，不压平目录")
    Assert.eq(dav.files[ROOT .. "/恢复.epub"].data, "restore", "书目条目的文件丢了，本地有就补传")
    Assert.is_false(exists("远端.epub"), "远端书不自动下载")
    Assert.eq(books["webdav://失踪.epub"].deleted, 1)
    local entries = remoteEntries(dav)
    Assert.is_nil(entries["失踪.epub"], "两边都没文件的条目剔除")
    for _, rel in ipairs({ "both.epub", "远端.epub", "恢复.epub", "新书.epub", "分类/旧.epub", "A/B/深.txt" }) do
        Assert.not_nil(entries[rel], rel)
    end
    Assert.eq(entries["分类/旧.epub"].bookName, "旧书")
    Assert.is_nil(books[L .. "/分类/旧.epub"], "绝对路径身份被收编")
    Assert.eq(books["webdav://分类/旧.epub"].deleted, 0)
    for _, rel in ipairs({ "both.epub", "新书.epub", "分类/旧.epub", "A/B/深.txt", "恢复.epub" }) do
        Assert.eq(books["webdav://" .. rel].path, L .. "/" .. rel, rel)
    end

    -- 打开远端书：按需下载到本地目录（book.open 随后 Store.touch 登记 path）。
    local opened
    c:openWebdavAsync("webdav://远端.epub", function(p) opened = p end)
    Stubs.flush()
    Assert.eq(opened, L .. "/远端.epub")
    Assert.eq(readFile(opened), "remote")

    -- 别的设备删了新书（书目条目 + 文件）：日常同步下架，本地已下载的那份跟着删，刷新也不会传回去。
    local list = {}
    for rel, e in pairs(remoteEntries(dav)) do if rel ~= "新书.epub" then list[#list + 1] = e end end
    putSync(dav, list)
    dav.files[ROOT .. "/新书.epub"] = nil
    Assert.is_true(scan(c))
    Assert.eq(books["webdav://新书.epub"].deleted, 1)
    Assert.is_false(exists("新书.epub"))
    Assert.is_true(refresh(c))
    Assert.is_nil(remoteEntries(dav)["新书.epub"])
    Assert.is_nil(dav.files[ROOT .. "/新书.epub"])

    -- 在 KOReader 里删书：远端文件、本地文件、书目条目一起删。
    local ok, listed
    c:deleteWebdavAsync("webdav://both.epub", function(v, _, l) ok, listed = v, l end)
    Assert.is_true(ok)
    Assert.is_true(listed)
    Assert.is_nil(dav.files[ROOT .. "/both.epub"])
    Assert.is_false(exists("both.epub"))
    Assert.is_nil(remoteEntries(dav)["both.epub"])
    Assert.not_nil(remoteEntries(dav)["远端.epub"])
    books = {}
end

-- 删除：书文件、封面/进度/笔记边车、书目条目一起删；书文件本来就没了（404）也算删成功。
do
    local dav = fakeDav()
    dav:put(ROOT .. "/分类/gone.epub", "x")
    dav:put(ROOT .. "/.Moon+/Cache/gone.epub.po", "1*0:1%")
    putSync(dav, { { filename = "分类/gone.epub" }, { filename = "ghost.epub" }, { filename = "keep.epub" } })
    local c = client(dav)
    local ok, listed
    c:deleteWebdavAsync("webdav://分类/gone.epub", function(v, _, l) ok, listed = v, l end)
    Assert.is_true(ok)
    Assert.is_true(listed)
    Assert.is_nil(dav.files[ROOT .. "/分类/gone.epub"])
    Assert.is_nil(dav.files[ROOT .. "/.Moon+/Cache/gone.epub.po"])
    Assert.eq(dav:count("DELETE " .. ROOT .. "/.Moon+/Cover/gone.epub_2.png"), 1)
    Assert.eq(dav:count("DELETE " .. ROOT .. "/.Moon+/Notes/gone.epub.json"), 1)
    Assert.is_nil(remoteEntries(dav)["分类/gone.epub"])

    c:deleteWebdavAsync("webdav://ghost.epub", function(v, _, l) ok, listed = v, l end)
    Assert.is_true(ok, "只剩书目条目的书也删得掉")
    Assert.is_true(listed)
    Assert.is_nil(remoteEntries(dav)["ghost.epub"])
    Assert.not_nil(remoteEntries(dav)["keep.epub"])

    -- 书目写失败：删除仍算成功但 listed=false；调用方留脏墓碑，下一轮同步把条目剔掉并清脏。
    dav:put(ROOT .. "/keep.epub", "x")
    local put = dav.putFileAsync
    function dav:putFileAsync(path, local_path, cb)
        if path == SYNC then return cb(nil, "HTTP 507") end
        return put(self, path, local_path, cb)
    end
    c:deleteWebdavAsync("webdav://keep.epub", function(v, _, l) ok, listed = v, l end)
    Assert.is_true(ok)
    Assert.is_false(listed)
    Assert.not_nil(remoteEntries(dav)["keep.epub"])
    dav.putFileAsync = put
    books["webdav://keep.epub"] = { stable_id = "webdav://keep.epub", deleted = 1, sync_status = 0 }
    Assert.is_true(scan(c))
    Assert.is_nil(remoteEntries(dav)["keep.epub"])
    Assert.eq(books["webdav://keep.epub"].sync_status, 1)
    Assert.eq(books["webdav://keep.epub"].deleted, 1, "脏墓碑不被远端旧条目复活")
    books = {}
end

-- 编辑 / 刮削后单本上行：条目原位改（静读天下字段保留）、换过的封面覆盖远端、写成才清脏。
do
    local dav = fakeDav()
    local stranger = copy(STRANGER)
    putSync(dav, { { filename = "other.epub", bookName = "别的" }, stranger })
    dav:put(ROOT .. "/.Moon+/Cover/局外人.epub_2.png", "old-cover")
    local id = "webdav://局外人.epub"
    books[id] = { stable_id = id, title = "局外人（刮削）", authors = "加缪", intro = "新简介",
        category = "小说", deleted = 0, sync_status = 1 }
    Paths.ensureLayout("local")
    local cover = Paths.coverPath(id, "local")
    local f = assert(io.open(cover, "wb"))
    f:write("new-cover")
    f:close()
    local c = client(dav)

    local ok
    c:pushBookAsync(id, true, function(v) ok = v end)
    Stubs.flush()
    Assert.is_true(ok)
    Assert.eq(dav.files[ROOT .. "/.Moon+/Cover/局外人.epub_2.png"].data, "new-cover")
    local entries = remoteEntries(dav)
    Assert.eq(entries["局外人.epub"].bookName, "局外人（刮削）")
    Assert.eq(entries["局外人.epub"].favorite, "小说")
    Assert.eq(entries["局外人.epub"].rate, "5", "静读天下字段原样保留")
    Assert.eq(entries["other.epub"].bookName, "别的", "其它条目不动")
    Assert.eq(books[id].sync_status, 1)

    -- 刮削删了旧封面、新图没下成：远端旧封面也删，否则下一轮 pullCovers 拉回旧图。
    os.remove(cover)
    c:pushBookAsync(id, true, function(v) ok = v end)
    Stubs.flush()
    Assert.is_true(ok)
    Assert.is_nil(dav.files[ROOT .. "/.Moon+/Cover/局外人.epub_2.png"])

    -- 只改元数据不碰封面；书目写失败保留脏标记，下一轮 pushBooksSync 重试。
    local put = dav.putFileAsync
    function dav:putFileAsync(path, local_path, cb)
        if path == SYNC then return cb(nil, "HTTP 507") end
        return put(self, path, local_path, cb)
    end
    local covers_before = dav:count("PUT " .. ROOT .. "/.Moon+/Cover/")
    books[id].title = "再改"
    c:pushBookAsync(id, false, function(v) ok = v end)
    Stubs.flush()
    dav.putFileAsync = put
    Assert.is_false(ok)
    Assert.eq(dav:count("PUT " .. ROOT .. "/.Moon+/Cover/"), covers_before)
    Assert.eq(books[id].sync_status, 0)
    Assert.eq(books[id].title, "再改")
    Assert.is_true(scan(c))
    Assert.eq(remoteEntries(dav)["局外人.epub"].bookName, "再改", "脏行不被远端书目盖回")
    Assert.eq(books[id].sync_status, 1)

    -- 纯本地身份没有远端：直接成功，不发请求、不标脏。
    local calls = #dav.calls
    books["/books/x.epub"] = { stable_id = "/books/x.epub", deleted = 0, sync_status = 1 }
    c:pushBookAsync("/books/x.epub", true, function(v) ok = v end)
    Stubs.flush()
    Assert.is_true(ok)
    Assert.eq(#dav.calls, calls)
    Assert.eq(books["/books/x.epub"].sync_status, 1)
    books = {}
end

-- 已下载的裸文件：阅读时已补过封面，书名还只是文件名，同步照样解析一次补书名。
do
    local L = require("support.config").dir() .. "/webdav-enrich"
    Paths.ensureDir(L)
    local f = assert(io.open(L .. "/裸.epub", "wb"))
    f:write("x")
    f:close()
    Paths.ensureLayout("local")
    local cover = Paths.coverPath("webdav://裸.epub", "local")
    f = assert(io.open(cover, "wb"))
    f:write("png")
    f:close()
    local opened = 0
    package.preload["document/documentregistry"] = function()
        return {
            hasProvider = function() return true end,
            openDocument = function()
                opened = opened + 1
                return { getProps = function() return { title = "真书名", authors = "某人" } end,
                    getCoverPageImage = function() return nil end, close = function() end }
            end,
        }
    end
    package.loaded["document/documentregistry"] = nil
    local dav = fakeDav()
    dav:put(ROOT .. "/裸.epub", "x")
    putSync(dav, { { filename = "裸.epub" } })
    local c = Client.new({ webdav_url = "https://dav.example", path = L })
    c.dav = dav
    Assert.is_true(scan(c))
    Assert.eq(opened, 1)
    Assert.eq(books["webdav://裸.epub"].title, "真书名")
    Assert.eq(remoteEntries(dav)["裸.epub"].bookName, "真书名")
    Assert.is_true(scan(c))
    Assert.eq(opened, 1, "解析过的书不再打开")
    package.preload["document/documentregistry"] = nil
    package.loaded["document/documentregistry"] = nil
    os.remove(cover)
    os.remove(L .. "/裸.epub")
    books = {}
end

-- 排版替换：新 EPUB 传到同目录，书目条目原位改名（其余字段保留），本地文件/身份/.sdr 跟着换，
-- 远端原书与边车删掉。书目写成之前失败，撤掉已传的新文件，两边保持原样。
do
    local L = require("support.config").dir() .. "/webdav-reflow"
    local function write(path, data)
        Paths.ensureDir(path:match("(.+)/[^/]+$"))
        local f = assert(io.open(path, "wb"))
        f:write(data)
        f:close()
    end
    local old_path, new_path, temp = L .. "/A/书.txt", L .. "/A/书.epub", L .. "/A/书.epub.moon-reflow"
    for _, p in ipairs({ old_path, new_path, temp, old_path .. ".sdr/meta.lua", new_path .. ".sdr/meta.lua",
        old_path .. ".sdr", new_path .. ".sdr" }) do
        os.remove(p)
    end
    write(old_path, "txt")
    write(old_path .. ".sdr/meta.lua", "return {}")
    local function reset(dav)
        books = { ["webdav://A/书.txt"] = { stable_id = "webdav://A/书.txt", title = "书", deleted = 0,
            sync_status = 1, path = old_path } }
        dav:put(ROOT .. "/A/书.txt", "txt")
        dav:put(ROOT .. "/.Moon+/Cache/书.txt.po", "1*0:1%")
        putSync(dav, {
            { filename = "A/书.txt", bookName = "书", rate = "5", downloadUrl = "[WebDav]/" .. ROOT .. "/A/书.txt" },
            { filename = "other.epub", bookName = "other" },
        })
        write(temp, "epub")
    end
    local dav = fakeDav()
    local c = Client.new({ webdav_url = "https://dav.example", path = L })
    c.dav = dav
    local function replace()
        local p, e
        c:replaceBookAsync(temp, "webdav://A/书.txt", function(v, err) p, e = v, err end)
        Stubs.flush()
        return p, e
    end

    -- 远端已有同名 EPUB：拒绝，不动任何东西。
    reset(dav)
    dav:put(ROOT .. "/A/书.epub", "someone")
    local p, e = replace()
    Assert.is_nil(p)
    Assert.matches(e, "书%.epub")
    Assert.eq(dav.files[ROOT .. "/A/书.epub"].data, "someone")
    Assert.eq(readFile(temp), "epub")
    dav.files[ROOT .. "/A/书.epub"] = nil

    -- 书目写失败：撤掉已传的新文件，本地与身份不动。
    local put = dav.putFileAsync
    function dav:putFileAsync(path, local_path, cb)
        if path == SYNC then return cb(nil, "HTTP 507") end
        return put(self, path, local_path, cb)
    end
    p, e = replace()
    dav.putFileAsync = put
    Assert.is_nil(p)
    Assert.eq(e, "更新书目失败")
    Assert.is_nil(dav.files[ROOT .. "/A/书.epub"])
    Assert.eq(dav.files[ROOT .. "/A/书.txt"].data, "txt")
    Assert.eq(readFile(old_path), "txt")
    Assert.not_nil(books["webdav://A/书.txt"])

    -- 正常替换。
    reset(dav)
    p, e = replace()
    Assert.is_nil(e)
    Assert.eq(p, new_path)
    Assert.eq(readFile(new_path), "epub")
    Assert.is_nil(readFile(old_path))
    Assert.is_nil(readFile(temp))
    Assert.eq(readFile(new_path .. ".sdr/meta.lua"), "return {}", ".sdr 跟着新文件走")
    Assert.eq(dav.files[ROOT .. "/A/书.epub"].data, "epub")
    Assert.is_nil(dav.files[ROOT .. "/A/书.txt"])
    Assert.is_nil(dav.files[ROOT .. "/.Moon+/Cache/书.txt.po"])
    local list = Json.decode(dav.files[SYNC].data:sub(2))
    Assert.len(list, 2)
    Assert.eq(list[1].filename, "A/书.epub", "条目原位改名")
    Assert.eq(list[1].rate, "5")
    Assert.eq(list[1].downloadUrl, "[WebDav]/" .. ROOT .. "/A/书.epub")
    Assert.eq(list[2].filename, "other.epub")
    Assert.is_nil(books["webdav://A/书.txt"])
    Assert.eq(books["webdav://A/书.epub"].path, new_path)
    Assert.eq(books["webdav://A/书.epub"].title, "书")
    Assert.eq(books["webdav://A/书.epub"].deleted, 0)

    -- 下一轮刷新不会把书拆成两本。
    Assert.is_true(refresh(c))
    local entries = remoteEntries(dav)
    Assert.not_nil(entries["A/书.epub"])
    Assert.is_nil(entries["A/书.txt"])
    Assert.eq(books["webdav://A/书.epub"].deleted, 0)
    books = {}
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
