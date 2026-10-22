--[[-- source.local.client：WebDAV 双向同步与静读天下 / book 服务端共享布局互通

书目 `.Moon+/books.sync`、封面 `.Moon+/Cover/<文件名>_2.png`、进度 `.Moon+/Cache/<文件名>.po`、
统计 `.Moon+/Stats/index.json` + `Stats/books/<md5>.json`。WebDAV 与 db.* 都是内存假实现，语义照真实 SQL 写。
--]]
---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

local Assert = require("support.assert")
local Stubs = require("support.stubs")
local Json = require("support.json_stub")

package.preload["json"] = function()
    return { encode = Json.encode, decode = Json.decode, util = { InitArray = function(t) return t end } }
end
package.preload["ffi/zlib"] = function()
    return { zlib_compress = function(s) return "Z" .. s end, zlib_uncompress = function(s) return s:sub(2) end }
end
local device_id = "dev-A" -- 多设备场景里切换
package.preload["utils.device_id"] = function()
    return { ensure = function() return device_id end }
end
local warns = {}
package.preload["utils.log"] = function()
    return { dbg = function() end, warn = function(msg) warns[#warns + 1] = msg end, info = function() end }
end

-- ── book.books_db：只实现本流程用到的语义（reconcile 只下架已同步行、upsertRemote 不碰脏行）──
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
function BookDB.stableIdsBySource()
    local out = {}
    for id in pairs(books) do out[#out + 1] = id end
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
function BookDB.pendingDeleteIds()
    local out = {}
    for id, b in pairs(books) do if b.deleted == 1 and b.sync_status == 0 then out[#out + 1] = id end end
    table.sort(out)
    return out
end
function BookDB.remove(_, id)
    if books[id] and books[id].deleted == 1 then books[id] = nil end
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
package.preload["book.books_db"] = function() return BookDB end

local progress = {}
package.preload["book.progress_db"] = function()
    return {
        get = function(_, id) return progress[id] end,
        upsertRemote = function(_, id, pos)
            if progress[id] and progress[id].sync_status == 0 then return true end
            local row = copy(pos)
            row.sync_status = 1
            progress[id] = row
            return true
        end,
        upsert = function(_, id, pos)
            local row = copy(pos)
            row.sync_status = 0
            progress[id] = row
            return true
        end,
    }
end

local notes = {}
package.preload["book.note_db"] = function()
    return {
        get = function(_, id) return notes[id] end,
        upsert = function(_, id, _idx, payload, updated_at)
            notes[id] = { payload = payload, updated_at = updated_at, sync_status = 0 }
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

for _, name in ipairs({ "book.books_db", "book.progress_db", "book.note_db", "json", "ffi/zlib", "utils.settings", "utils.log",
    "workers.job", "source.local.client" }) do
    package.loaded[name] = nil
end
local Client = require("source.local.client")
local Paths = require("utils.paths")

-- 本地入库（子进程解析）换成假实现：登记绝对路径身份、留脏行，记下被入库的路径。
local indexed, index_title = {}, nil
function Client.indexOneAsync(_, path, cb)
    indexed[#indexed + 1] = path
    books[path] = { stable_id = path, title = index_title or path:match("([^/]+)%.[^.]+$"), deleted = 0, sync_status = 0 }
    require("ui/uimanager"):nextTick(function() cb(true) end)
    return { cancel = function() end }
end

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
                        mtime = not tail and f.mtime or nil, size = not tail and #f.data or nil }
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
    local ok, err, push_error
    c:scanWebdavAsync(function(v, e, p) ok, err, push_error = v, e, p end, opts)
    Stubs.flush()
    return ok, err, push_error
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

-- books.sync 的 filename 会拼进本地路径：越界 / 绝对 / 反斜杠 / 空段的条目丢弃，不进书架。
do
    local dav = fakeDav()
    putSync(dav, {
        { filename = "../escape.epub", bookName = "x" },
        { filename = "a/../../escape.epub", bookName = "x" },
        { filename = "/abs.epub", bookName = "x" },
        { filename = "a\\b.epub", bookName = "x" },
        { filename = "a//b.epub", bookName = "x" },
        { filename = "./dot.epub", bookName = "x" },
        { filename = "ok/书.epub", bookName = "好书" },
    })
    Assert.is_true(scan(client(dav)))
    local ids = {}
    for id in pairs(books) do ids[#ids + 1] = id end
    Assert.eq(table.concat(ids, ","), "webdav://ok/书.epub")
    Assert.is_false(Client.isRemote("webdav://../escape.epub"))
    Assert.is_false(Client.isRemote("webdav://a/./b.epub"))
    Assert.is_true(Client.isRemote("webdav://ok/书.epub"))
    books = {}
end

-- 刷新列远端目录与本地 scanFiles 同一层级：根 / 分类 / 系列，更深的不收、也不下钻。
do
    local dav = fakeDav()
    dav:put(ROOT .. "/分类/系列/书.epub", "x")
    dav:put(ROOT .. "/分类/系列/更深/书.epub", "x")
    Assert.is_true(refresh(client(dav)))
    Assert.not_nil(books["webdav://分类/系列/书.epub"])
    Assert.is_nil(books["webdav://分类/系列/更深/书.epub"])
    Assert.eq(dav:count("PROPFIND " .. ROOT .. "/分类/系列/更深"), 0)
    books = {}
end

-- 没有 books.sync（404，目录填错 / 被删）且本地有未推的编辑：不下架已同步的书。
do
    local dav = fakeDav()
    books["webdav://keep.epub"] = { stable_id = "webdav://keep.epub", deleted = 0, sync_status = 1 }
    books["webdav://edited.epub"] = { stable_id = "webdav://edited.epub", deleted = 0, sync_status = 0 }
    Assert.is_true(scan(client(dav)))
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

-- 日常 / 推脏拉书目就被拒（密码错、没权限、连不上）：整轮中止并报原因，不当成书目损坏继续跑、不上传。
do
    for _, opts in ipairs({ {}, { dirty_only = true } }) do
        local dav = fakeDav()
        putSync(dav, { { filename = "keep.epub" } })
        books["webdav://keep.epub"] = { stable_id = "webdav://keep.epub", deleted = 0, sync_status = 0 }
        local get = dav.getAsync
        function dav:getAsync(path, dest, o, cb)
            if path == SYNC then return cb(nil, "WebDAV 认证失败：用户名或密码错误", 401) end
            return get(self, path, dest, o, cb)
        end
        local ok, err = run(client(dav), opts)
        Assert.is_false(ok)
        Assert.eq(err, "WebDAV 认证失败：用户名或密码错误")
        Assert.eq(dav:count("PUT"), 0)
        Assert.eq(books["webdav://keep.epub"].sync_status, 0, "脏行留着等下一轮")
        books = {}
    end
end

-- 书目写不上（如只读账号）：整轮算完成，但把原因放进 push_error 报上去，脏行保留。
do
    local dav = fakeDav()
    putSync(dav, { { filename = "改.epub", bookName = "旧名" } })
    books["webdav://改.epub"] = { stable_id = "webdav://改.epub", title = "新名", deleted = 0, sync_status = 0 }
    function dav:putFileAsync(path, _, cb)
        self.calls[#self.calls + 1] = "PUT " .. path
        cb(nil, "WebDAV 没有权限：该账号无法读写这个目录")
    end
    local ok, err, push_error = run(client(dav), { dirty_only = true })
    Assert.is_true(ok)
    Assert.is_nil(err)
    Assert.eq(push_error, "WebDAV 没有权限：该账号无法读写这个目录")
    Assert.eq(books["webdav://改.epub"].sync_status, 0)
    books = {}
end

-- 关掉 WebDAV 后残留的云端书：本地已下载的照常打开；没下载的直接报“未配置”，不发请求。
do
    local L = require("support.config").dir() .. "/webdav-off"
    Paths.ensureDir(L)
    local f = assert(io.open(L .. "/有.epub", "wb"))
    f:write("x")
    f:close()
    local dav = fakeDav()
    local c = Client.new({ path = L })
    c.dav = dav
    local path, err
    c:openWebdavAsync("webdav://有.epub", function(p, e) path, err = p, e end)
    Stubs.flush()
    Assert.eq(path, L .. "/有.epub")
    c:openWebdavAsync("webdav://无.epub", function(p, e) path, err = p, e end)
    Stubs.flush()
    Assert.is_nil(path)
    Assert.eq(err, "未配置 WebDAV，无法下载云端书籍")
    Assert.len(dav.calls, 0)
    os.remove(L .. "/有.epub")
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

    -- 关书推送与推脏任务并发推同一本：各用各的临时文件，先完成的不能删掉后者正在上传的文件。
    local held = {}
    local put = dav.putFileAsync
    function dav:putFileAsync(path, local_path, cb)
        held[#held + 1] = function()
            if not readFile(local_path) then return cb(nil, local_path .. ": No such file or directory") end
            put(self, path, local_path, cb)
        end
    end
    local results = {}
    for i = 1, 2 do
        c:putProgressAsync("webdav://分类/real.epub", { updated_at = 1700000200 + i, chapter_idx = i, fraction = 0.5 },
            function(v, e) results[i] = { v, e } end)
    end
    Stubs.flush()
    Assert.len(held, 2)
    held[1]()
    held[2]()
    Assert.is_true(results[1][1])
    Assert.is_true(results[2][1], "后完成的一方照样能读到自己的临时文件")
    dav.putFileAsync = put

    -- 打开桌面的同步与联网推脏并发拉书目：下载先写 .part、完成才改名，共用临时文件时后完成的一方会扑空。
    putSync(dav, { { filename = "分类/real.epub", bookName = "real" } })
    local held_get, get = {}, dav.getAsync
    function dav:getAsync(path, dest, opts, cb)
        if path ~= SYNC then return get(self, path, dest, opts, cb) end
        local part = assert(io.open(dest .. ".part", "wb"))
        part:write(self.files[SYNC].data)
        part:close()
        held_get[#held_get + 1] = function()
            local ok, err = os.rename(dest .. ".part", dest)
            if not ok then return cb(nil, err) end
            cb(true)
        end
    end
    warns = {}
    local done = {}
    for i = 1, 2 do c:scanWebdavAsync(function(v) done[i] = v end, { dirty_only = true }) end
    Stubs.flush()
    Assert.len(held_get, 1, "同一书目文件的两轮同步排队，后一轮等前一轮写完再读")
    held_get[1]()
    Stubs.flush()
    Assert.is_true(done[1])
    Assert.len(held_get, 2)
    held_get[2]()
    Stubs.flush()
    Assert.is_true(done[1])
    Assert.is_true(done[2])
    local unreadable = 0
    for _, msg in ipairs(warns) do
        if msg == "book webdav books.sync unreadable" then unreadable = unreadable + 1 end
    end
    Assert.eq(unreadable, 0, "两边都读到自己的书目")
    dav.getAsync = get
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

    -- 日常同步：以书目为准扫本地、上传新书；书目里有的不补传（远端文件丢了只有刷新列目录才知道）。
    Assert.is_true(scan(c))
    Assert.eq(dav.files[ROOT .. "/新书.epub"].data, "new", "日常同步上传本地新书")
    Assert.not_nil(remoteEntries(dav)["新书.epub"], "日常同步写进书目")
    Assert.is_nil(dav.files[ROOT .. "/恢复.epub"], "书目里有 = 当远端已有")
    Assert.eq(books["webdav://恢复.epub"].path, L .. "/恢复.epub", "书目里有的收编本地文件")
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

    -- 打开远端书：按需下载到本地目录（desktop.open 随后 Store.touch 登记 path）。
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

    -- 在 KOReader 里删书（deleteBookAsync 先删本地书库里那份）：本地只留脏墓碑；
    -- 下一轮同步删远端文件与书目条目，成了才撕墓碑。
    os.remove(L .. "/both.epub")
    BookDB.markDeleted(nil, "webdav://both.epub")
    Assert.is_true(scan(c))
    Assert.is_nil(dav.files[ROOT .. "/both.epub"])
    Assert.is_nil(remoteEntries(dav)["both.epub"])
    Assert.not_nil(remoteEntries(dav)["远端.epub"])
    Assert.is_nil(books["webdav://both.epub"], "远端确认删除后撕墓碑")
    books = {}
end

-- 远端空（无 books.sync）而本地书架已有云端身份的书：状态不明，不下架；日常同步不上传、不写书目，刷新才传上去。
do
    local L = require("support.config").dir() .. "/webdav-first"
    Paths.ensureDir(L)
    local f = assert(io.open(L .. "/首.epub", "wb"))
    f:write("first")
    f:close()
    books[L .. "/首.epub"] = { stable_id = L .. "/首.epub", title = "首", deleted = 0, sync_status = 1 }
    books["webdav://旧云书.epub"] = { stable_id = "webdav://旧云书.epub", title = "旧云书", deleted = 0, sync_status = 1 }
    local dav = fakeDav()
    local c = Client.new({ webdav_url = "https://dav.example", path = L })
    c.dav = dav

    Assert.is_true(scan(c))
    Assert.eq(books[L .. "/首.epub"].deleted, 0, "日常同步不因远端空而下架")
    Assert.is_nil(dav.files[SYNC], "远端书库状态不明：日常同步不上传、不写书目，留给刷新")
    Assert.is_nil(dav.files[ROOT .. "/首.epub"])

    local steps = {}
    Assert.is_true(run(c, { refresh = true, on_progress = function(text, done, total)
        steps[#steps + 1] = table.concat({ text, done or "", total or "" }, "|")
    end }))
    Assert.eq(dav.files[ROOT .. "/首.epub"].data, "first")
    Assert.eq(remoteEntries(dav)["首.epub"].bookName, "首")
    Assert.contains(steps, "正在检查远端目录…||")
    Assert.eq(books["webdav://首.epub"].deleted, 0)
    Assert.eq(books["webdav://首.epub"].path, L .. "/首.epub")
    os.remove(L .. "/首.epub")
    books = {}
end

-- 远端书目丢了（服务端清空 / 目录改错）而本地有一条没推上去的编辑：日常同步、推脏都不能写出只含这一本的书目，
-- 否则下一轮按残缺书目把其余云端书当成被删，连本地下载一起删掉。
do
    books["webdav://甲.epub"] = { stable_id = "webdav://甲.epub", title = "甲", deleted = 0, sync_status = 1 }
    books["webdav://乙.epub"] = { stable_id = "webdav://乙.epub", title = "乙改", deleted = 0, sync_status = 0 }
    local dav = fakeDav()
    local c = client(dav)
    Assert.is_true(scan(c))
    Assert.is_true(run(c, { dirty_only = true }))
    Assert.is_nil(dav.files[SYNC], "不写残缺书目")
    Assert.eq(books["webdav://甲.epub"].deleted, 0)
    Assert.eq(books["webdav://乙.epub"].sync_status, 0, "编辑留脏，等刷新或书目恢复")
    books = {}
end

-- 桌面日常同步还在读书目时用户删了书、推脏随即启动：两轮排队，先读的那轮不能把删掉的条目写回去。
do
    local L = require("support.config").dir() .. "/webdav-race"
    Paths.ensureDir(L)
    local dav = fakeDav()
    dav:put(ROOT .. "/删.epub", "x")
    dav:put(ROOT .. "/留.epub", "y")
    putSync(dav, { { filename = "删.epub", bookName = "删" }, { filename = "留.epub", bookName = "留" } })
    local c = Client.new({ webdav_url = "https://dav.example", path = L })
    c.dav = dav
    Assert.is_true(scan(c))

    local held, get = nil, dav.getAsync
    function dav:getAsync(path, dest, opts, cb)
        if path == SYNC and not held then
            held = function() get(self, path, dest, opts, cb) end
            return
        end
        return get(self, path, dest, opts, cb)
    end
    local done = {}
    c:scanWebdavAsync(function(v) done.desktop = v end)
    Stubs.flush()
    Assert.not_nil(held, "桌面同步卡在读书目")
    BookDB.markDeleted(nil, "webdav://删.epub")
    c:scanWebdavAsync(function(v) done.dirty = v end, { dirty_only = true })
    Stubs.flush()
    Assert.not_nil(dav.files[ROOT .. "/删.epub"], "推脏排在桌面同步之后")
    held()
    Stubs.flush()
    dav.getAsync = get
    Assert.is_true(done.desktop)
    Assert.is_true(done.dirty)
    Assert.is_nil(dav.files[ROOT .. "/删.epub"])
    Assert.is_nil(remoteEntries(dav)["删.epub"], "删掉的书没被写回书目")
    Assert.not_nil(remoteEntries(dav)["留.epub"])
    Assert.is_nil(books["webdav://删.epub"], "远端确认删除后撕墓碑")
    books = {}
end

-- 服务端被清空后刷新：本地书先入库解析出书名、再后台上传，远端和本地都没有的旧书按新书目下架。
do
    local L = require("support.config").dir() .. "/webdav-reset"
    Paths.ensureDir(L)
    local f = assert(io.open(L .. "/新.epub", "wb"))
    f:write("new")
    f:close()
    books["webdav://幽灵.epub"] = { stable_id = "webdav://幽灵.epub", title = "幽灵", deleted = 0, sync_status = 1 }
    index_title = "真书名"
    local dav = fakeDav()
    local c = Client.new({ webdav_url = "https://dav.example", path = L })
    c.dav = dav
    Assert.is_true(refresh(c))
    Assert.eq(books["webdav://新.epub"].title, "真书名", "上传的书同一轮解析")
    Assert.eq(remoteEntries(dav)["新.epub"].bookName, "真书名")
    Assert.eq(books["webdav://幽灵.epub"].deleted, 1, "不在新书目里的旧书下架")
    Assert.eq(books["webdav://新.epub"].deleted, 0)
    index_title = nil
    os.remove(L .. "/新.epub")
    books = {}
end

-- 刷新时上传成功但书目没写上：行保持脏，下一轮日常同步不能当成别的设备删了而删掉本地原书。
do
    local L = require("support.config").dir() .. "/webdav-upload-nosync"
    Paths.ensureDir(L)
    local f = assert(io.open(L .. "/新.epub", "wb"))
    f:write("new")
    f:close()
    local dav = fakeDav()
    putSync(dav, { { filename = "别的.epub", bookName = "别的" } })
    local put = dav.putFileAsync
    local sync_fails = true
    function dav:putFileAsync(path, local_path, cb)
        if path == SYNC and sync_fails then return cb(nil, "HTTP 500") end
        return put(self, path, local_path, cb)
    end
    local c = Client.new({ webdav_url = "https://dav.example", path = L })
    c.dav = dav
    refresh(c)
    Assert.eq(books["webdav://新.epub"].sync_status, 0, "书目没写上，保持脏")
    Assert.is_true(scan(c))
    Assert.eq(books["webdav://新.epub"].deleted, 0)
    Assert.not_nil(io.open(L .. "/新.epub", "rb"), "本地原书还在")
    sync_fails = false
    Assert.is_true(scan(c))
    Assert.not_nil(remoteEntries(dav)["新.epub"], "下一轮把书目补上")
    Assert.eq(books["webdav://新.epub"].sync_status, 1)
    os.remove(L .. "/新.epub")
    books = {}
end

-- 推删（dirty_only）：书文件、封面/进度/笔记边车、书目条目一起删，成了才撕墓碑；书文件本来就没了（404）也算删成功。
do
    local dav = fakeDav()
    dav:put(ROOT .. "/分类/gone.epub", "x")
    dav:put(ROOT .. "/.Moon+/Cache/gone.epub.po", "1*0:1%")
    putSync(dav, { { filename = "分类/gone.epub" }, { filename = "ghost.epub" }, { filename = "keep.epub" } })
    for _, id in ipairs({ "webdav://分类/gone.epub", "webdav://ghost.epub" }) do
        books[id] = { stable_id = id, deleted = 1, sync_status = 0 }
    end
    books["/local/plain.epub"] = { stable_id = "/local/plain.epub", deleted = 1, sync_status = 0 }
    local c = client(dav)
    Assert.is_true(run(c, { dirty_only = true }))
    Assert.is_nil(dav.files[ROOT .. "/分类/gone.epub"])
    Assert.is_nil(dav.files[ROOT .. "/.Moon+/Cache/gone.epub.po"])
    Assert.eq(dav:count("DELETE " .. ROOT .. "/.Moon+/Cover/gone.epub_2.png"), 1)
    Assert.eq(dav:count("DELETE " .. ROOT .. "/.Moon+/Notes/gone.epub.json"), 1)
    Assert.is_nil(remoteEntries(dav)["分类/gone.epub"])
    Assert.is_nil(remoteEntries(dav)["ghost.epub"], "只剩书目条目的书也删得掉")
    Assert.not_nil(remoteEntries(dav)["keep.epub"])
    Assert.is_nil(books["webdav://分类/gone.epub"])
    Assert.is_nil(books["webdav://ghost.epub"])
    Assert.not_nil(books["/local/plain.epub"], "非 WebDAV 身份不归这里推")
    books["/local/plain.epub"] = nil

    -- 书目写失败：墓碑留脏，条目还在；日常同步也不能替它清脏，下一轮推成了再撕。
    dav:put(ROOT .. "/keep.epub", "x")
    books["webdav://keep.epub"] = { stable_id = "webdav://keep.epub", deleted = 1, sync_status = 0 }
    local put = dav.putFileAsync
    function dav:putFileAsync(path, local_path, cb)
        if path == SYNC then return cb(nil, "HTTP 507") end
        return put(self, path, local_path, cb)
    end
    run(c, { dirty_only = true })
    Assert.not_nil(remoteEntries(dav)["keep.epub"])
    Assert.eq(books["webdav://keep.epub"].sync_status, 0)
    dav.putFileAsync = put

    -- 远端删文件失败（非 404）：日常同步照样把条目剔出书目，但墓碑保持脏、不复活。
    dav:put(ROOT .. "/keep.epub", "x")
    local delete = dav.deleteAsync
    function dav:deleteAsync(path, cb)
        if path == ROOT .. "/keep.epub" then return cb(nil, "HTTP 500", 500) end
        return delete(self, path, cb)
    end
    Assert.is_true(scan(c))
    Assert.is_nil(remoteEntries(dav)["keep.epub"])
    Assert.eq(books["webdav://keep.epub"].deleted, 1, "脏墓碑不被远端旧条目复活")
    Assert.eq(books["webdav://keep.epub"].sync_status, 0, "远端文件没删掉，留给下一轮重试")
    dav.deleteAsync = delete

    Assert.is_true(scan(c))
    Assert.is_nil(dav.files[ROOT .. "/keep.epub"])
    Assert.is_nil(books["webdav://keep.epub"])
    books = {}
end

-- 推脏（dirty_only）也推离线编辑：书目条目改上去才清脏；不拉进度、不碰封面。
do
    local dav = fakeDav()
    putSync(dav, { { filename = "改.epub", bookName = "旧名", favorite = "旧类" } })
    books["webdav://改.epub"] = { stable_id = "webdav://改.epub", title = "新名", category = "新类",
        deleted = 0, sync_status = 0 }
    Assert.is_true(run(client(dav), { dirty_only = true }))
    Assert.eq(remoteEntries(dav)["改.epub"].bookName, "新名")
    Assert.eq(remoteEntries(dav)["改.epub"].favorite, "新类")
    Assert.eq(books["webdav://改.epub"].sync_status, 1)
    Assert.eq(dav:count("PROPFIND"), 0, "dirty_only 不列进度 / 封面目录")
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

-- crengine 读不了的书照样“加载成功”，给一份标题为 ERROR: 的错误文档（格式 Unknown format）：不能当书名。
do
    local L = require("support.config").dir() .. "/webdav-crerror"
    Paths.ensureDir(L)
    local f = assert(io.open(L .. "/坏.mobi", "wb"))
    f:write("x")
    f:close()
    package.preload["document/documentregistry"] = function()
        return {
            hasProvider = function() return true end,
            openDocument = function()
                -- 真 CreDocument 载入后 _loaded = true
                return { _loaded = true, loadDocument = function() return true end,
                    getDocumentFormat = function() return "Unknown format" end,
                    getProps = function() return { title = "ERROR: Error reading PDB format" } end,
                    getCoverPageImage = function() return nil end, close = function() end }
            end,
        }
    end
    package.loaded["document/documentregistry"] = nil
    local dav = fakeDav()
    dav:put(ROOT .. "/坏.mobi", "x")
    putSync(dav, { { filename = "坏.mobi" } })
    local c = Client.new({ webdav_url = "https://dav.example", path = L })
    c.dav = dav
    Assert.is_true(scan(c))
    Assert.eq(books["webdav://坏.mobi"].title, "坏")
    Assert.eq(remoteEntries(dav)["坏.mobi"].bookName, "坏")
    package.preload["document/documentregistry"] = nil
    package.loaded["document/documentregistry"] = nil
    os.remove(L .. "/坏.mobi")
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

-- ── 统计：Stats/index.json 总表 + Stats/books/<md5(文件名)>.json 按书 ──
local md5 = require("ffi/sha2").md5
local STATS_DIR = ROOT .. "/.Moon+/Stats"
local STATS_INDEX = STATS_DIR .. "/index.json"
local function statsFile(filename) return STATS_DIR .. "/books/" .. md5(filename) .. ".json" end
--- 模拟别的设备写一本书：书文件 + 总表条目。
local function putStatsBook(dav, filename, rows, device)
    local data = Json.encode(rows)
    dav:put(statsFile(filename), data)
    local index = dav.files[STATS_INDEX] and Json.decode(dav.files[STATS_INDEX].data) or { books = {} }
    index.books[filename] = { updated_at = os.time(), device_id = device, hash = md5(data) }
    dav:put(STATS_INDEX, Json.encode(index))
end
local function statsClient(dav)
    local c = client(dav)
    os.remove(c:webdavCacheRoot() .. "/stats_index.json")
    return c
end
local function pullStats(c)
    local pulled
    c:pullStatsAsync(function(r) pulled = r end)
    Stubs.flush()
    return pulled
end

-- 统计：按书去重合并、更新总表；拉取只下载总表里版本变了的书，入库成功（commit）才记版本。
do
    local dav = fakeDav()
    local c = statsClient(dav)

    -- 远端什么都没有：拉取不带 replace，不抹本地历史。
    local pulled = pullStats(c)
    Assert.eq(#pulled, 0)
    Assert.is_nil(pulled.replace)

    local T = os.time() - 3600
    putStatsBook(dav, "a.epub",
        { { filename = "a.epub", device_id = "dev-B", page = 3, start_time = T + 100, duration = 30, total_pages = 9 } },
        "dev-B")
    local result
    c:pushStatsAsync({
        { stable_id = "webdav://a.epub", page = 4, start_time = T + 200, duration = 60, total_pages = 9 },
        { stable_id = "webdav://a.epub", page = 4, start_time = T + 200, duration = 60, total_pages = 9 },
        { stable_id = "/books/local.epub", page = 2, start_time = T + 300, duration = 10, total_pages = 5 },
        { stable_id = "webdav://x/同名.epub", page = 1, start_time = T + 400, duration = 5 },
        { stable_id = "webdav://y/同名.epub", page = 1, start_time = T + 400, duration = 5 },
    }, function(r) result = r end)
    Stubs.flush()
    Assert.eq(type(result), "table")
    Assert.is_nil(result.synced_ids, "整批确认")
    local remote = Json.decode(dav.files[statsFile("a.epub")].data)
    Assert.len(remote, 2)
    Assert.eq(remote[2].device_id, "dev-A")
    Assert.eq(remote[2].filename, "a.epub")
    Assert.eq(Json.decode(dav.files[statsFile("/books/local.epub")].data)[1].filename, "/books/local.epub")
    Assert.not_nil(dav.files[statsFile("x/同名.epub")])
    Assert.not_nil(dav.files[statsFile("y/同名.epub")], "不同目录同名书各自一个文件")
    local index = Json.decode(dav.files[STATS_INDEX].data)
    Assert.eq(index.books["a.epub"].device_id, "dev-A")
    Assert.eq(index.books["a.epub"].hash, md5(dav.files[statsFile("a.epub")].data))

    -- 拉取：自己写的新书不再下载；a.epub 有别的设备的行、本地没入过，要下载。
    local gets = dav:count("GET " .. STATS_DIR .. "/books/")
    pulled = pullStats(c)
    Assert.eq(dav:count("GET " .. STATS_DIR .. "/books/"), gets + 1, "只下载 a.epub")
    Assert.eq(pulled.replace.mode, "synced_books")
    Assert.eq(table.concat(pulled.replace.stable_ids, ","), "webdav://a.epub")
    local ids = {}
    for _, row in ipairs(pulled.rows) do ids[#ids + 1] = row.stable_id .. "@" .. (row.start_time - T) end
    table.sort(ids)
    Assert.eq(table.concat(ids, ","), "webdav://a.epub@100,webdav://a.epub@200")
    Assert.eq(pulled.rows[1].record_type, "page")

    -- 没 commit（入库失败）：下一轮重拉。
    pulled = pullStats(c)
    Assert.eq(dav:count("GET " .. STATS_DIR .. "/books/"), gets + 2)
    pulled.commit()

    -- commit 后远端没变：不下载，不交 replace。
    gets = dav:count("GET " .. STATS_DIR .. "/books/")
    pulled = pullStats(c)
    Assert.eq(dav:count("GET " .. STATS_DIR .. "/books/"), gets)
    Assert.len(pulled, 0)
    Assert.is_nil(pulled.replace)

    -- 已入库到最新再推：版本随自己的写入推进，拉取不重下自己刚写的文件。
    c:pushStatsAsync({ { stable_id = "webdav://a.epub", page = 5, start_time = T + 500, duration = 9 } },
        function(r) result = r end)
    Stubs.flush()
    gets = dav:count("GET " .. STATS_DIR .. "/books/")
    pulled = pullStats(c)
    Assert.eq(dav:count("GET " .. STATS_DIR .. "/books/"), gets)
    Assert.len(pulled, 0)

    -- 别的设备写过 a.epub：只下载这一本；别的设备的绝对路径书不认、不下载。
    local rows = Json.decode(dav.files[statsFile("a.epub")].data)
    rows[#rows + 1] = { filename = "a.epub", device_id = "dev-B", page = 6, start_time = T + 600, duration = 7 }
    putStatsBook(dav, "a.epub", rows, "dev-B")
    putStatsBook(dav, "/sdcard/b.epub",
        { { filename = "/sdcard/b.epub", device_id = "dev-B", page = 1, start_time = T + 50, duration = 5 } }, "dev-B")
    pulled = pullStats(c)
    Assert.eq(dav:count("GET " .. STATS_DIR .. "/books/"), gets + 1)
    Assert.eq(dav:count("GET " .. statsFile("/sdcard/b.epub")), 0)
    Assert.len(pulled.rows, 4)
    pulled.commit()

    -- 书文件损坏：推送失败，不拿本地行覆盖掉别的设备的数据；拉取跳过这本、不记版本。
    dav:put(statsFile("a.epub"), "{broken")
    local err
    c:pushStatsAsync({ { stable_id = "webdav://a.epub", start_time = T + 700, duration = 1 } },
        function(r, e) result, err = r, e end)
    Stubs.flush()
    Assert.is_nil(result)
    Assert.eq(err, "阅读统计文件损坏")
    Assert.eq(dav.files[statsFile("a.epub")].data, "{broken")
    index = Json.decode(dav.files[STATS_INDEX].data)
    index.books["a.epub"].hash = "changed"
    dav:put(STATS_INDEX, Json.encode(index))
    pulled = pullStats(c)
    Assert.len(pulled, 0)
    Assert.is_nil(pulled.replace)
end

-- 旧版单文件 stats.json：拉取时按书并进按书文件（30 天前的逐页行按 设备+文件+小时 并成汇总行）再删掉。
do
    local STATS = STATS_DIR .. "/stats.json"
    local dav = fakeDav()
    local c = statsClient(dav)
    local clock = os.date("*t", os.time() - 40 * 86400)
    clock.min, clock.sec = 0, 0
    local OLD = os.time(clock)
    local NOW = os.time() - 600
    dav:put(STATS, Json.encode({
        { filename = "a.epub", device_id = "dev-B", page = 3, start_time = OLD + 60, duration = 30, total_pages = 9 },
        { filename = "a.epub", device_id = "dev-B", page = 5, start_time = OLD + 120, duration = 40, total_pages = 9 },
        { filename = "a.epub", device_id = "dev-B", page = 4, start_time = OLD + 900, duration = 20, total_pages = 9 },
        { filename = "a.epub", device_id = "dev-B", page = 6, start_time = NOW, duration = 10, total_pages = 9 },
        -- 别的设备同一小时已有汇总：拉取时并成一条，否则撞本地 书+小时 唯一索引。
        { filename = "a.epub", device_id = "dev-C", page = 7, start_time = OLD, duration = 50, total_pages = 9,
            event_count = 2, last_time = OLD + 1800 },
    }))

    -- 拉取：先并旧文件（压缩写进按书文件、删旧文件），再按总表拉；两台设备同一小时的汇总并成一条 page_rollup。
    local pulled = pullStats(c)
    Assert.is_nil(dav.files[STATS], "并完删掉旧文件")
    local remote = Json.decode(dav.files[statsFile("a.epub")].data)
    Assert.len(remote, 3)
    local rollup = remote[1]
    Assert.eq(rollup.device_id, "dev-B")
    Assert.eq(rollup.start_time, OLD)
    Assert.eq(rollup.duration, 90)
    Assert.eq(rollup.page, 5)
    Assert.eq(rollup.event_count, 3)
    Assert.eq(rollup.last_time, OLD + 900)
    Assert.eq(remote[2].start_time, NOW, "30 天内的逐页行原样保留")
    Assert.is_nil(remote[2].event_count)
    Assert.eq(remote[3].event_count, 2, "已有汇总行原样保留")
    Assert.eq(pulled.replace.mode, "synced_books")
    Assert.len(pulled.rows, 2)
    local merged = pulled.rows[1]
    Assert.eq(merged.record_type, "page_rollup")
    Assert.eq(merged.start_time, OLD)
    Assert.eq(merged.duration, 140)
    Assert.eq(merged.event_count, 5)
    Assert.eq(merged.page, 7)
    Assert.eq(merged.last_time, OLD + 1800)
    Assert.eq(pulled.rows[2].record_type, "page")
    pulled.commit()

    -- 压缩幂等：没有新行就不写书文件、不改总表；远端没变也不再下载。
    local puts, gets = dav:count("PUT "), dav:count("GET ")
    local result
    c:pushStatsAsync({}, function(r) result = r end)
    Stubs.flush()
    Assert.eq(type(result), "table")
    pulled = pullStats(c)
    Assert.eq(dav:count("PUT "), puts)
    Assert.eq(dav:count("GET "), gets + 1, "只读总表")
    Assert.len(pulled, 0)

    -- 旧版插件又写了一份 stats.json：再并一次，同一行按 设备+文件+开始时间 去重不重复计时。
    dav:put(STATS, Json.encode({
        { filename = "a.epub", device_id = "dev-B", page = 6, start_time = NOW, duration = 10, total_pages = 9 },
        { filename = "a.epub", device_id = "dev-B", page = 8, start_time = NOW + 60, duration = 15, total_pages = 9 },
    }))
    pulled = pullStats(c)
    Assert.is_nil(dav.files[STATS])
    Assert.len(Json.decode(dav.files[statsFile("a.epub")].data), 4)
    Assert.len(pulled.rows, 3)
end

-- 书城导入：远端同名不覆盖（加 " (2)"），立即进书架并写书目条目。
do
    local dav = fakeDav()
    dav:put(ROOT .. "/三体.epub", "old")
    putSync(dav, { { filename = "三体.epub", bookName = "三体" } })
    local temp = require("support.config").dir() .. "/import-temp.epub"
    local f = assert(io.open(temp, "wb"))
    f:write("new")
    f:close()
    local ok, err
    client(dav):importWebdavAsync(temp, "三体.epub", function(v, e) ok, err = v, e end)
    Stubs.flush()
    Assert.is_true(ok, err)
    Assert.eq(dav.files[ROOT .. "/三体.epub"].data, "old", "不覆盖远端同名")
    Assert.eq(dav.files[ROOT .. "/三体 (2).epub"].data, "new")
    Assert.eq(books["webdav://三体 (2).epub"].deleted, 0, "立即在书架上")
    Assert.eq(books["webdav://三体 (2).epub"].sync_status, 1, "书目写成即清脏")
    Assert.not_nil(remoteEntries(dav)["三体 (2).epub"])
    Assert.not_nil(remoteEntries(dav)["三体.epub"], "其它条目原样保留")
    os.remove(temp)
    books = {}
end

-- ── 用户场景：经源入口（桌面打开 = syncBooksAsync{}，图书馆刷新 = {force}，联网推脏 = {dirty_only}）──
local function source(c)
    local s = require("source.local").new()
    s._client = c
    return s
end
local function sync(s, opts)
    local result, err
    -- 每次都当作隔了节流窗口再打开桌面，否则日常同步被节流跳过，断言空过。
    s._auto_sync_at = nil
    s:syncBooksAsync(opts or {}, function(r, e) result, err = r, e end)
    Stubs.flush()
    Assert.not_nil(result, err)
end
--- 一台设备：独立的缓存目录（统计已入库版本各记各的）。
local function deviceClient(dav, name, path)
    local c = Client.new({ webdav_url = "https://dav.example", path = path })
    c.dav = dav
    local root = require("support.config").dir() .. "/webdav-device-" .. name
    function c:webdavCacheRoot() return root end
    os.remove(root .. "/stats_index.json")
    return c
end

-- 场景 1：用户把书直接放进本地书库目录。打开桌面的日常同步就扫本地、上传并写进书目，
-- 之后别的设备的日常同步就能看到；再同步不重复上传。
do
    local L = require("support.config").dir() .. "/webdav-scenario-local"
    Paths.ensureDir(L)
    local f = assert(io.open(L .. "/用户放的.epub", "wb"))
    f:write("book")
    f:close()
    local dav = fakeDav()
    putSync(dav, { { filename = "已有.epub", bookName = "已有" } })
    local s = source(deviceClient(dav, "A", L))

    sync(s)
    Assert.eq(dav.files[ROOT .. "/用户放的.epub"].data, "book", "日常同步上传")
    Assert.eq(remoteEntries(dav)["用户放的.epub"].bookName, "用户放的")
    Assert.not_nil(remoteEntries(dav)["已有.epub"], "原有条目保留")
    Assert.eq(books["webdav://用户放的.epub"].deleted, 0)
    Assert.eq(books["webdav://用户放的.epub"].sync_status, 1)

    local puts = 0
    local put = dav.putFileAsync
    function dav.putFileAsync(d, path, ...)
        if path == ROOT .. "/用户放的.epub" then puts = puts + 1 end
        return put(d, path, ...)
    end
    sync(s)
    Assert.eq(puts, 0, "已在书目里的不重复上传")
    dav.putFileAsync = put

    books = {}
    device_id = "dev-B"
    sync(source(deviceClient(dav, "B")))
    Assert.eq(books["webdav://用户放的.epub"].deleted, 0, "另一台设备日常同步即上架")
    device_id = "dev-A"
    os.remove(L .. "/用户放的.epub")
    books = {}
end

-- 上传传输层失败（超时 / 断网）：本轮不再试后面的书，失败的书冷却期内不重传。
do
    local L = require("support.config").dir() .. "/webdav-scenario-fail"
    Paths.ensureDir(L)
    for _idx, name in ipairs({ "a.epub", "b.epub" }) do
        local f = assert(io.open(L .. "/" .. name, "wb"))
        f:write("book")
        f:close()
    end
    local dav = fakeDav()
    putSync(dav, {})
    local puts = 0
    local put = dav.putFileAsync
    function dav:putFileAsync(path, local_path, cb)
        if path:find("%.epub$") then
            puts = puts + 1
            return cb(nil, "timeout")
        end
        return put(self, path, local_path, cb)
    end
    local s = source(deviceClient(dav, "A", L))
    sync(s)
    Assert.eq(puts, 1, "传输层失败后本轮停手")
    sync(s)
    Assert.eq(puts, 2, "a 在冷却期，轮到 b")
    sync(s)
    Assert.eq(puts, 2, "都在冷却期，不再重传")
    dav.putFileAsync = put
    os.remove(L .. "/a.epub")
    os.remove(L .. "/b.epub")
    books = {}
end

-- 扫描不被上传阻塞：同步回调时本地新书已入库可读、尚未上传；后台随后才上传并并成 WebDAV 书。
do
    local L = require("support.config").dir() .. "/webdav-scenario-bg"
    Paths.ensureDir(L)
    local f = assert(io.open(L .. "/后台.epub", "wb"))
    f:write("bg")
    f:close()
    local dav = fakeDav()
    putSync(dav, { { filename = "已有.epub", bookName = "已有" } })
    local c = deviceClient(dav, "A", L)
    local at_done
    c:scanWebdavAsync(function(ok)
        Assert.is_true(ok)
        at_done = { shelved = books[L .. "/后台.epub"] and books[L .. "/后台.epub"].deleted, uploaded = dav.files[ROOT .. "/后台.epub"] ~= nil }
    end)
    Stubs.flush()
    Assert.eq(at_done.shelved, 0, "回调时已可读")
    Assert.is_false(at_done.uploaded, "回调时还没上传")
    Assert.eq(dav.files[ROOT .. "/后台.epub"].data, "bg", "随后后台上传")
    Assert.not_nil(remoteEntries(dav)["后台.epub"])
    Assert.eq(books["webdav://后台.epub"].path, L .. "/后台.epub")
    Assert.is_nil(books[L .. "/后台.epub"], "上传后并成 WebDAV 身份")
    os.remove(L .. "/后台.epub")
    books = {}
end

-- 后台上传交给调用方（任务队列）：调用方没启动就不传；启动后逐本上报进度，结束回调。
do
    local L = require("support.config").dir() .. "/webdav-scenario-bg-progress"
    Paths.ensureDir(L)
    local f = assert(io.open(L .. "/进度.epub", "wb"))
    f:write("p")
    f:close()
    local dav = fakeDav()
    putSync(dav, { { filename = "已有.epub", bookName = "已有" } })
    local c = deviceClient(dav, "A", L)
    local start
    c:scanWebdavAsync(function() end, { on_background = function(fn) start = fn end })
    Stubs.flush()
    Assert.not_nil(start, "有待传的书才交出后台上传")
    Assert.is_nil(dav.files[ROOT .. "/进度.epub"], "调用方没启动就不上传")
    local texts, finished = {}, false
    start(function(text, done, total) texts[#texts + 1] = table.concat({ text, done or "", total or "" }, "|") end,
        function(err) finished = err == nil end)
    Stubs.flush()
    Assert.is_true(finished)
    Assert.contains(texts, "正在上传 进度.epub|1|1")
    Assert.eq(dav.files[ROOT .. "/进度.epub"].data, "p")
    os.remove(L .. "/进度.epub")
    books = {}
end

-- 场景 2：手动编辑 / 刮削。先写本地库（立即生效），再经 book_meta_changed 立即上行书目与封面；
-- 离线没推成保留脏行，联网推脏补上；另一台设备日常同步拿到新元数据。
do
    local dav = fakeDav()
    dav:put(ROOT .. "/a.epub", "x")
    putSync(dav, { { filename = "a.epub", bookName = "旧名", author = "", rate = "5" } })
    local id = "webdav://a.epub"
    local s = source(deviceClient(dav, "A"))
    sync(s)
    Assert.eq(books[id].title, "旧名")

    -- 编辑框：moveBook（WebDAV 只标脏不移动文件）→ upsertLocal → 事件上行。
    Assert.eq(s:moveBook(id, "小说", nil), id)
    BookDB.upsertLocal({ source_id = "local", stable_id = id, title = "新名", authors = "作者", category = "小说" })
    Assert.eq(books[id].title, "新名", "本地立即生效")
    s:onEvent("book_meta_changed", { identity = { source_id = "local", stable_id = id }, cover = false })
    Stubs.flush()
    local entry = remoteEntries(dav)["a.epub"]
    Assert.eq(entry.bookName, "新名")
    Assert.eq(entry.author, "作者")
    Assert.eq(entry.favorite, "小说")
    Assert.eq(entry.rate, "5", "静读天下字段保留")
    Assert.eq(books[id].sync_status, 1)
    sync(s)
    Assert.eq(books[id].title, "新名", "自己的日常同步不盖回")

    -- 刮削：换了封面，cover=true 连封面一起传。
    Paths.ensureLayout("local")
    local cover = Paths.coverPath(id, "local")
    local f = assert(io.open(cover, "wb"))
    f:write("scraped-cover")
    f:close()
    BookDB.upsertLocal({ source_id = "local", stable_id = id, title = "刮削名", authors = "作者", intro = "简介",
        category = "小说" })
    s:onEvent("book_meta_changed", { identity = { source_id = "local", stable_id = id }, cover = true })
    Stubs.flush()
    Assert.eq(dav.files[ROOT .. "/.Moon+/Cover/a.epub_2.png"].data, "scraped-cover")
    Assert.eq(remoteEntries(dav)["a.epub"].bookName, "刮削名")
    Assert.eq(remoteEntries(dav)["a.epub"].description, "简介")

    -- 离线编辑：上行失败，本地照样改了、保留脏行；联网推脏补上。
    local put = dav.putFileAsync
    function dav:putFileAsync(path, local_path, cb)
        if path == SYNC then return cb(nil, "offline") end
        return put(self, path, local_path, cb)
    end
    s:moveBook(id, "小说", nil)
    BookDB.upsertLocal({ source_id = "local", stable_id = id, title = "离线改", authors = "作者", category = "小说" })
    s:onEvent("book_meta_changed", { identity = { source_id = "local", stable_id = id }, cover = false })
    Stubs.flush()
    dav.putFileAsync = put
    Assert.eq(books[id].title, "离线改")
    Assert.eq(books[id].sync_status, 0)
    Assert.eq(remoteEntries(dav)["a.epub"].bookName, "刮削名")
    sync(s, { dirty_only = true })
    Assert.eq(remoteEntries(dav)["a.epub"].bookName, "离线改")
    Assert.eq(books[id].sync_status, 1)

    -- 另一台设备：日常同步拿到书名和封面。
    books = {}
    device_id = "dev-B"
    os.remove(cover)
    sync(source(deviceClient(dav, "B")))
    Assert.eq(books[id].title, "离线改")
    Assert.eq(books[id].authors, "作者")
    Assert.eq(readFile(cover), "scraped-cover", "封面下到本地")
    device_id = "dev-A"
    os.remove(cover)
    books = {}
end

-- 场景 3：多设备阅读进度与阅读时间。两台设备共用一个 WebDAV，各有自己的本地库。
do
    local dav = fakeDav()
    dav:put(ROOT .. "/共读.epub", "x")
    putSync(dav, { { filename = "共读.epub", bookName = "共读" } })
    local id = "webdav://共读.epub"
    local a, b = deviceClient(dav, "A"), deviceClient(dav, "B")
    local sa, sb = source(a), source(b)
    local local_progress = {}
    local function as(name)
        local_progress[device_id], device_id = progress, name
        progress = local_progress[name] or {}
    end
    local function put(s, pos)
        local ok, err
        s:putProgressAsync({ source_id = "local", stable_id = id }, pos, function(v, e) ok, err = v, e end)
        Stubs.flush()
        Assert.is_true(ok, err)
    end

    -- 进度：A 关书推送，B 日常同步拉到；B 读到更后面，A 再同步拿到 B 的。
    progress = { [id] = { fraction = 0.3, chapter_idx = 3, updated_at = os.time() - 60, sync_status = 1 } }
    put(sa, progress[id])
    as("dev-B")
    sync(sb)
    Assert.eq(progress[id].fraction, 0.3)
    Assert.eq(progress[id].chapter_idx, 3)
    progress[id] = { fraction = 0.6, chapter_idx = 6, updated_at = os.time() - 30, sync_status = 1 }
    put(sb, progress[id])
    as("dev-A")
    sync(sa)
    Assert.eq(progress[id].fraction, 0.6, "A 拿到 B 的新进度")
    Assert.eq(progress[id].chapter_idx, 6)

    -- 阅读时间：A 推、B 拉；B 推、A 拉到两台设备的全部记录；没变化不重复下载。
    local T = os.time() - 3600
    local pushed
    sa:pushStatsAsync({ { stable_id = id, page = 3, start_time = T, duration = 120, total_pages = 9 } },
        function(r) pushed = r end)
    Stubs.flush()
    Assert.not_nil(pushed)
    as("dev-B")
    local pulled = pullStats(b)
    Assert.len(pulled.rows, 1)
    Assert.eq(pulled.rows[1].duration, 120)
    pulled.commit()
    sb:pushStatsAsync({ { stable_id = id, page = 6, start_time = T + 600, duration = 300, total_pages = 9 } },
        function(r) pushed = r end)
    Stubs.flush()
    Assert.not_nil(pushed)
    Assert.len(pullStats(b), 0, "B 不重下自己刚写的")
    as("dev-A")
    pulled = pullStats(a)
    local total = 0
    for _, row in ipairs(pulled.rows) do total = total + row.duration end
    Assert.len(pulled.rows, 2)
    Assert.eq(total, 420, "两台设备的阅读时间合在一起")
    Assert.eq(table.concat(pulled.replace.stable_ids, ","), id)
    pulled.commit()
    Assert.len(pullStats(a), 0)
    progress = {}
    books = {}
end

-- 场景 4：别人直接把书传到 WebDAV、没更新 books.sync。日常同步只认书目，不会出现在书架上；
-- 图书馆刷新会列远端目录，把它补进书架并写进书目（正文不下载，打开时按需拉）。
do
    local dav = fakeDav()
    dav:put(ROOT .. "/已有.epub", "x")
    dav:put(ROOT .. "/直接传的.epub", "x")
    putSync(dav, { { filename = "已有.epub", bookName = "已有" } })
    local s = source(deviceClient(dav, "A"))

    sync(s)
    Assert.eq(books["webdav://已有.epub"].deleted, 0)
    Assert.is_nil(books["webdav://直接传的.epub"], "日常同步看不到书目外的文件")
    Assert.is_nil(remoteEntries(dav)["直接传的.epub"])
    Assert.eq(dav:count("PROPFIND " .. ROOT), dav:count("PROPFIND " .. ROOT .. "/.Moon+"), "不列书库目录")

    sync(s, { force = true })
    Assert.eq(books["webdav://直接传的.epub"].deleted, 0, "刷新补进书架")
    Assert.eq(remoteEntries(dav)["直接传的.epub"].bookName, "直接传的")
    Assert.eq(dav:count("GET " .. ROOT .. "/直接传的.epub"), 0, "正文不下载")
    books = {}
end
