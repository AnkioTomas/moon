--[[--
月读同步的书籍附属数据：推拉判定、两台设备之间的整本覆盖 / 清空传播、摘要并集、不在书库的书不碰。
真库（沙箱）+ 内存 WebDAV；换设备 = 换本机「上次同步」记录 + 换本地数据。

@module tests.moon_sync.extra_spec
--]]

local Assert = require("support.assert")
package.preload["json"] = function()
    local JSON = require("support.json_stub")
    return { encode = JSON.encode, decode = JSON.decode }
end
package.loaded["json"] = nil

local DB = require("utils.db")
require("book.books_db")
local Fs = require("utils.fs")
local Paths = require("utils.paths")
local XrayDB = require("features.xray.db")
local SummaryDB = require("ai.summary_db")
local Extra = require("moon_sync.extra")
local Run = require("moon_sync.run")
local json = require("json")

-- ── 判定 ───────────────────────────────────────────────

local function act(seen, hash, remote_mtime, merge, trusted)
    return Extra.action({ seen = seen, hash = hash, remote_mtime = remote_mtime, merge = merge,
        trusted = trusted ~= false })
end
Assert.eq(Extra.hash(nil), "")
Assert.eq(act(nil, "", nil), "skip", "两边都没有")
Assert.eq(act(nil, "h", nil), "push", "只有本地")
Assert.eq(act(nil, "", 5), "pull", "只有远端")
Assert.eq(act(nil, "h", 5), "both", "两边各有、从没同步过")
Assert.eq(act({ hash = "h", mtime = 5 }, "h", 5), "skip")
Assert.eq(act({ hash = "h", mtime = 5 }, "", 5), "push", "本地清空也要推")
Assert.eq(act({ hash = "h", mtime = 5 }, "h", 9), "pull")
Assert.eq(act({ hash = "h", mtime = 5 }, "x", 9), "both")
Assert.eq(act({ hash = "h", mtime = 5 }, "h", 9, false, false), "skip", "远端不可信时整本覆盖的不拉")
Assert.eq(act({ hash = "h", mtime = 5 }, "x", 9, false, false), "push")
Assert.eq(act({ hash = "h", mtime = 5 }, "h", 9, true, false), "pull", "并集不怕旧清单")
Assert.eq(act({ hash = "h" }, "h", 9), "pull", "推完没记上远端时间：再拉一次自愈")

-- ── 端到端 ─────────────────────────────────────────────

local SRC = "moon-sync-extra"
local BOOK, STRANGER = "book-1", "stranger"
local function wipe()
    XrayDB.removeSource(SRC)
    SummaryDB.removeSource(SRC)
end
wipe()
DB.exec("DELETE FROM books WHERE source_id=?;", SRC)
Assert.is_true(DB.exec("INSERT INTO books (source_id, stable_id) VALUES (?,?);", SRC, BOOK) ~= nil)

require("utils.extension").add("sync.book_data", {
    id = "xray", books = XrayDB.books, export = XrayDB.export, import = XrayDB.import,
})

local remote, clock, puts = {}, 100, 0
local function put(path, body)
    clock = clock + 1
    remote[path] = { body = body, mtime = clock }
end
local dav = {
    listAsync = function(_self, path, cb)
        local entries, seen_dirs = {}, {}
        for p, file in pairs(remote) do
            local rest = p:sub(#path + 2)
            if p:sub(1, #path + 1) == path .. "/" and rest ~= "" then
                local head = rest:match("^([^/]+)/")
                if head then
                    if not seen_dirs[head] then
                        seen_dirs[head] = true
                        entries[#entries + 1] = { name = head, is_dir = true }
                    end
                else
                    entries[#entries + 1] = { name = rest, is_dir = false, mtime = file.mtime }
                end
            end
        end
        if #entries == 0 then return cb(nil, "missing", 404) end
        cb(entries)
    end,
    getAsync = function(_self, path, dest, _opts, cb)
        local file = remote[path]
        if not file then return cb(nil, "missing", 404) end
        local out = assert(io.open(dest, "wb"))
        out:write(file.body)
        out:close()
        cb(true)
    end,
    putFileAsync = function(_self, path, src, cb)
        puts = puts + 1
        put(path, Fs.read(src))
        cb(true)
    end,
    ensurePathAsync = function(_self, _path, cb) cb(true) end,
}

local seen_file = Paths.cacheDir() .. "/moon_sync_extra"
local function run(trusted)
    ---@type string|boolean
    local result = "pending"
    Run.extra({ trusted = trusted }, dav, "R", function(err) result = err or true end)
    Assert.eq(result, true, "同步一轮应同步完成且无错")
end
local function remoteDoc(provider, id)
    local file = remote["R/.moon-koreader/extra/" .. provider .. "/" .. SRC .. "/" .. id .. ".json"]
    return file and json.decode(file.body)
end
local function entity(name, desc, at)
    return { kind = "character", name = name, aliases = {}, role = "", description = desc, gender = "",
        occupation = "" }, at
end

-- 设备 A：有 X-Ray 与两章摘要，第一轮全推上去，第二轮什么都不动。
os.remove(seen_file)
XrayDB.upsert(SRC, BOOK, entity("林黛玉", "A 写的", 50))
XrayDB.remove(SRC, BOOK, { kind = "character", name = "贾宝玉", aliases = { "宝玉" } })
XrayDB.addEvents(SRC, BOOK, { { title = "主线", time = "", description = "进府", characters = { "林黛玉" }, pos = 3.5 } })
XrayDB.markChapter(SRC, BOOK, 2)
XrayDB.saveScanCursor(SRC, BOOK, "d", 1, 9)
SummaryDB.put(SRC, BOOK, 1, "第一回", "摘要一")
SummaryDB.putReport(SRC, BOOK, "读书报告")
local a_xray = XrayDB.export(SRC, BOOK)
local a_summary = SummaryDB.export(SRC, BOOK)
run()
Assert.eq(puts, 2, "两个提供者各推一份")
Assert.eq(#remoteDoc("xray", BOOK).data[1], 1)
Assert.eq(#remoteDoc("summary", BOOK).data, 2)
run()
Assert.eq(puts, 2, "没变化的第二轮不推")
local a_seen = Fs.read(seen_file)

-- 设备 B：本地什么都没有，拉下来与 A 一致；续扫游标是本机的，不跟过来。
wipe()
os.remove(seen_file)
run()
Assert.eq(puts, 2, "纯拉取不回推")
Assert.eq(Extra.hash(XrayDB.export(SRC, BOOK)), Extra.hash(a_xray))
Assert.eq(Extra.hash(SummaryDB.export(SRC, BOOK)), Extra.hash(a_summary))
Assert.is_nil(XrayDB.scanCursor(SRC, BOOK))
Assert.eq(XrayDB.listEvents(SRC, BOOK)[1].pos, 3.5)
Assert.is_true(XrayDB.removedSet(SRC, BOOK)["character\0宝玉"] ~= nil)

-- B 清空 X-Ray：推一份空快照。
XrayDB.reset(SRC, BOOK)
run()
Assert.eq(puts, 3)
Assert.is_nil(remoteDoc("xray", BOOK).data, "空快照不带 data")
local b_seen = Fs.read(seen_file)

-- 回到 A：数据还在、上次同步记录是 A 的。拉到空快照即清空。
XrayDB.import(SRC, BOOK, a_xray)
local out = assert(io.open(seen_file, "wb"))
out:write(a_seen)
out:close()
run()
Assert.is_nil(XrayDB.export(SRC, BOOK), "别的设备清空，这台也清空")
Assert.eq(puts, 3)

-- 两边都改 X-Ray：后写的整本赢。
local function conflict(local_at, remote_at, remote_name)
    XrayDB.reset(SRC, BOOK)
    XrayDB.upsert(SRC, BOOK, entity("本地", "", local_at))
    put("R/.moon-koreader/extra/xray/" .. SRC .. "/" .. BOOK .. ".json", json.encode({
        updated_at = remote_at,
        data = { { { "character", remote_name, "", "", "", "", "", remote_at } }, {}, {}, {} },
    }))
    os.remove(seen_file)
    run()
    return XrayDB.list(SRC, BOOK)[1].name
end
Assert.eq(conflict(10, 20, "远端"), "远端", "远端后写")
Assert.eq(conflict(30, 20, "远端"), "本地", "本地后写")
Assert.eq(remoteDoc("xray", BOOK).data[1][1][2], "本地", "本地赢了要推上去")

-- 摘要两边都有：按章并集，同一章新的赢，合并结果再推。
out = assert(io.open(seen_file, "wb"))
out:write(b_seen)
out:close()
SummaryDB.removeSource(SRC)
DB.exec([[INSERT INTO chapter_summaries (source_id, stable_id, chapter_idx, title, summary, updated_at)
    VALUES (?,?,?,?,?,?);]], SRC, BOOK, 1, "第一回", "本地更新", 2000)
put("R/.moon-koreader/extra/summary/" .. SRC .. "/" .. BOOK .. ".json", json.encode({
    updated_at = 1000,
    data = { { 1, "第一回", "远端旧的", "", 1000 }, { 2, "第二回", "远端独有", "", 1000 } },
}))
run()
Assert.eq(SummaryDB.get(SRC, BOOK, 1).summary, "本地更新", "同一章新的赢")
Assert.eq(SummaryDB.get(SRC, BOOK, 2).summary, "远端独有")
local merged = remoteDoc("summary", BOOK).data
Assert.eq(#merged, 2, "并集推回远端")
Assert.eq(merged[1][3], "本地更新")

-- 本机书库没有的书：远端文件留着，不导入也不报错。
put("R/.moon-koreader/extra/summary/" .. SRC .. "/" .. STRANGER .. ".json", json.encode({
    updated_at = 1, data = { { 1, "x", "y", "", 1 } },
}))
run()
Assert.is_nil(SummaryDB.export(SRC, STRANGER))

-- 损坏的远端文件报错，不吞掉。
put("R/.moon-koreader/extra/summary/" .. SRC .. "/" .. BOOK .. ".json", "not json")
local result
Run.extra({}, dav, "R", function(err) result = err end)
Assert.eq(result, "书籍附属数据损坏")

wipe()
DB.exec("DELETE FROM books WHERE source_id=?;", SRC)
os.remove(seen_file)
