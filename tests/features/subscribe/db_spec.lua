--[[-- features.subscribe.db：订阅源增删改、条目合并（保留已读、新条目排前）、分页、上限淘汰，真实 sqlite。 --]]

local Assert = require("support.assert")
local Config = require("support.config")
if not pcall(require, "lua-ljsqlite3/init") then
    Assert.skip("当前离线环境没有 ljsqlite3 Lua 模块")
end

local db_path = Config.dir() .. "/subscribe_spec.sqlite3"
for _idx, suffix in ipairs({ "", "-wal", "-shm" }) do os.remove(db_path .. suffix) end
package.loaded["utils.paths"] = nil
package.preload["utils.paths"] = function()
    return { dbPath = function() return db_path end, ensureSettings = function() end }
end
for _idx, name in ipairs({ "utils.db", "features.subscribe.db" }) do package.loaded[name] = nil end
local Base = require("utils.db")
local SubDB = require("features.subscribe.db")
Assert.not_nil(Base.open())

-- 下面用的是演示用的小时间戳，别被 180 天淘汰；淘汰单独在末尾测。
local MAX_AGE = SubDB.MAX_AGE
SubDB.MAX_AGE = math.huge

local id = SubDB.add({ kind = "rss", url = "https://a.com/feed", title = "A", grp = "科技" })
Assert.not_nil(id)
Assert.eq(SubDB.add({ kind = "rss", url = "https://a.com/feed", title = "A2" }), nil, "同地址不重复订阅")
local mp = SubDB.add({ kind = "mp", url = "MP_WXS_1", title = "号" })

-- 合并：新增计数；已有条目只改标题、保留已读；同时间（网页）新条目排在旧的前面。
Assert.eq(SubDB.merge(id, { { guid = "1", title = "一" }, { guid = "2", title = "二" } }), 2)
SubDB.markRead(id, "1")
Assert.eq(SubDB.merge(id, { { guid = "3", title = "三" }, { guid = "1", title = "一改" } }), 1)
local items, total = SubDB.items(id, 1, 20)
Assert.eq(total, 3)
Assert.eq(items[1].guid, "3", "新条目在前")
Assert.eq(items[2].guid, "1")
Assert.eq(items[2].title, "一改")
Assert.eq(items[2].read, true, "已读保留")
Assert.eq(items[3].guid, "2")

-- 有时间的按时间新到旧；分页。
SubDB.merge(mp, { { guid = "a", title = "旧", time = 100 }, { guid = "b", title = "新", time = 300 }, { guid = "c", title = "中", time = 200 } })
items = SubDB.items(mp, 1, 2)
Assert.eq(items[1].guid, "b")
Assert.eq(items[2].guid, "c")
items = SubDB.items(mp, 2, 2)
Assert.eq(items[1].guid, "a")

-- 列表：未读数、分组；改字段；摘要；全部已读。
SubDB.merge(id, { { guid = "4", title = "四", summary = "<p>全文</p>" } })
Assert.eq(SubDB.summary(id, "4"), "<p>全文</p>")
local feed = SubDB.feed(id)
Assert.eq(feed.unread, 3)
Assert.eq(feed.grp, "科技")
SubDB.update(id, { title = "新名", cursor = 40, updated_at = 5 })
feed = SubDB.feed(id)
Assert.eq(feed.title, "新名")
Assert.eq(feed.cursor, 40)
Assert.eq(feed.updated_at, 5)
SubDB.markRead(id)
Assert.eq(SubDB.feed(id).unread, 0)

-- 阅读时间：带时间标已读才记条目与源的 read_at；全部已读、远程标已读不算「读过」。
Assert.eq(SubDB.feed(id).read_at, 0)
SubDB.merge(id, { { guid = "r1", title = "读" }, { guid = "r2", title = "没读" } })
SubDB.markRead(id, "r2")
Assert.eq(SubDB.feed(id).read_at, 0, "无时间不记")
SubDB.markRead(id, "r1", 1234)
Assert.eq(SubDB.feed(id).read_at, 1234)
local read_items = SubDB.items(id, 1, 20)
local by_guid = {}
for _idx, item in ipairs(read_items) do by_guid[item.guid] = item end
Assert.eq(by_guid.r1.read_at, 1234)
Assert.eq(by_guid.r2.read_at, 0)

-- 条数上限：超出 KEEP 的最旧条目被删（已读未读都算），新增计数不受淘汰影响。
SubDB.KEEP = 3
Assert.eq(SubDB.merge(mp, { { guid = "d", title = "最新", time = 400 } }), 1)
local _list, n = SubDB.items(mp, 1, 20)
Assert.eq(n, 3, "超出上限淘汰最旧的")
Assert.eq(_list[3].guid, "c", "删的是最旧的 a")
Assert.eq(SubDB.merge(mp, { { guid = "f", title = "六", time = 600 }, { guid = "g", title = "七", time = 700 } }), 2,
    "淘汰不影响新增计数")
_list, n = SubDB.items(mp, 1, 20)
Assert.eq(n, 3)
Assert.eq(_list[3].guid, "d")
Assert.eq(SubDB.merge(mp, { { guid = "g", title = "七改", time = 700 } }), 0, "已有条目不算新增")
Assert.eq(SubDB.items(mp, 1, 1)[1].title, "七改")
SubDB.KEEP = 600

-- 按 id 直查；不存在 / nil 回 nil。
Assert.eq(SubDB.feed(mp).url, "MP_WXS_1")
Assert.is_nil(SubDB.feed(99999))
Assert.is_nil(SubDB.feed(nil))

-- 批量新增（OPML 导入）：一个事务，返回新增与已存在条数。
local added, skipped = SubDB.addMany({ { kind = "rss", url = "https://m1", title = "1" },
    { kind = "rss", url = "https://m1", title = "重复" }, { kind = "site", url = "https://m2", title = "2", grp = "G" } })
Assert.eq(added, 2)
Assert.eq(skipped, 1)

SubDB.remove(id)
Assert.eq(SubDB.feed(id), nil)
Assert.eq(select(2, SubDB.items(id, 1, 20)), 0, "条目一并删")
Base.close()
for _idx, suffix in ipairs({ "", "-wal", "-shm" }) do os.remove(db_path .. suffix) end

-- 手动顺序与移组、分组改名、最近错误
local b = SubDB.add({ kind = "rss", url = "https://b.com/feed", title = "B", grp = "科技" })
id = SubDB.add({ kind = "rss", url = "https://c.com/feed", title = "A", grp = "科技" })
SubDB.order("科技", { b, id })
local order = {}
for _, f in ipairs(SubDB.feeds()) do if f.grp == "科技" then order[#order + 1] = f.title end end
Assert.eq(table.concat(order, ","), "B,A")
SubDB.update(b, { error = "HTTP 500" })
Assert.eq(SubDB.feed(b).error, "HTTP 500")
SubDB.renameGroup("科技", "技术")
Assert.eq(SubDB.feed(id).grp, "技术")
Assert.eq(SubDB.feed(b).sort, 1)

-- 库已打开时才加载模块（远程管理首次 require 的真实路径）：建表回调立即执行。
Base.close()
for _idx, suffix in ipairs({ "", "-wal", "-shm" }) do os.remove(db_path .. suffix) end
package.loaded["utils.db"] = nil
package.loaded["features.subscribe.db"] = nil
Base = require("utils.db")
Assert.not_nil(Base.open())
local ok, Late = pcall(require, "features.subscribe.db")
Assert.is_true(ok, tostring(Late))
local late_id = Late.add({ kind = "rss", url = "https://late/feed", title = "L" })
Late.update(late_id, { sort = 3, error = "x" })
Assert.eq(Late.feed(late_id).sort, 3)
Assert.eq(Late.feed(late_id).error, "x")
Base.close()

-- 同一篇换了 guid（公众号短 id / WR1A 长 id）：同源「标题 + 时间」只留一条
do
    local f = SubDB.add({ kind = "mp", url = "MP_WXS_DUP", title = "重" })
    Assert.eq(SubDB.merge(f, { { guid = "short1", title = "同一篇", time = 900 } }), 1)
    Assert.eq(SubDB.merge(f, { { guid = "WR1Along1", title = "同一篇", time = 900 } }), 0, "换 guid 不算新增")
    local _l, n = SubDB.items(f, 1, 20)
    Assert.eq(n, 1)
    -- 历史重复：删索引、写入重复，再跑清理：留已读那条
    Base.exec("DROP INDEX idx_sub_items_title_time;")
    Base.exec("INSERT INTO sub_items (feed_id, guid, title, time, read) VALUES (?, 'WR1Along1', '同一篇', 900, 1);", f)
    Base.exec("INSERT INTO sub_items (feed_id, guid, title, time) VALUES (?, 'x1', '无时间', 0);", f)
    Base.exec("INSERT INTO sub_items (feed_id, guid, title, time) VALUES (?, 'x2', '无时间', 0);", f)
    Assert.is_true(SubDB._dedupe())
    local list, total = SubDB.items(f, 1, 20)
    Assert.eq(total, 3, "无时间的不按标题合并")
    local kept
    for _i, it in ipairs(list) do if it.title == "同一篇" then kept = it end end
    Assert.eq(kept.guid, "WR1Along1")
    Assert.is_true(kept.read == 1 or kept.read == true, "留已读的那条")
    Assert.eq(Base.rowexec("SELECT COUNT(*) FROM sqlite_master WHERE name='idx_sub_items_title_time';"), 1)
end

-- 已读 / 未读筛选在 SQL 里做：分页、总数按筛后算
do
    local f = SubDB.add({ kind = "rss", url = "https://filter.test/feed", title = "筛" })
    SubDB.merge(f, { { guid = "u1", title = "未一", time = 10 }, { guid = "u2", title = "未二", time = 20 },
        { guid = "r1", title = "已一", time = 30 } })
    SubDB.markRead(f, "r1")
    local list, total = SubDB.items(f, 1, 20, false)
    Assert.eq(total, 2)
    Assert.eq(list[1].guid, "u2")
    list, total = SubDB.items(f, 1, 20, true)
    Assert.eq(total, 1)
    Assert.eq(list[1].guid, "r1")
    list, total = SubDB.items(f, 2, 1, false)
    Assert.eq(total, 2)
    Assert.eq(list[1].guid, "u1", "第二页")
    local _l, all = SubDB.items(f, 1, 20)
    Assert.eq(all, 3)
end

-- 跨源文章流：新到旧混排；未读 / 收藏 / 分组 / 标题搜索，分页总数按筛后算。
do
    local a = SubDB.add({ kind = "rss", url = "https://s.com/a", title = "SA", grp = "G1" })
    local b = SubDB.add({ kind = "rss", url = "https://s.com/b", title = "SB" })
    SubDB.merge(a, { { guid = "x", title = "Hello%", time = 9001 }, { guid = "y", title = "y", time = 9003 } })
    SubDB.merge(b, { { guid = "z", title = "z", time = 9002 } })
    SubDB.markRead(a, "y")
    local list, total = SubDB.stream({ mode = "all" }, 1, 3)
    Assert.eq(list[1].guid, "y")
    Assert.eq(list[2].feed_title, "SB")
    Assert.eq(list[3].grp, "G1")
    Assert.eq(select(2, SubDB.stream({}, 1, 0)) < total, true, "缺省只要未读")
    local grouped, count = SubDB.stream({ mode = "all", grp = "G1" }, 1, 20)
    Assert.eq(count, 2)
    Assert.eq(select(2, SubDB.stream({ mode = "all", grp = "" }, 1, 20)) >= 1, true, "未分组")
    Assert.eq(select(2, SubDB.stream({ mode = "all", q = "hello%" }, 1, 20)), 1, "搜索不分大小写，% 不是通配符")
    Assert.eq(select(2, SubDB.stream({ mode = "star" }, 1, 20)), 0)
    SubDB.setStarred(a, "x", true)
    local starred = SubDB.stream({ mode = "star" }, 1, 20)
    Assert.eq(#starred, 1)
    Assert.eq(starred[1].starred, true)
    -- 单个源、取全部（size = -1）、按 id 取一条
    local only, n = SubDB.stream({ mode = "all", feed = b, grp = "G1" }, 1, -1)
    Assert.eq(n, 1, "指定源时不看分组")
    Assert.eq(only[1].guid, "z")
    Assert.eq(only[1].link, "")
    Assert.eq(SubDB.item(a, "x").feed_title, "SA")
    Assert.is_nil(SubDB.item(a, "none"))

    -- 阅读范围：单源 + 全部 + 无搜索词沿用订阅 id，其余登记成 s<md5>，能还原
    Assert.eq(SubDB.scope({ feed = a, mode = "all", q = "" }), tostring(a))
    Assert.eq(SubDB.scopeOf(tostring(a)).feed, a)
    local id = SubDB.scope({ grp = "G1", mode = "unread", q = "he" })
    Assert.matches(id, "^s%x+$")
    Assert.eq(SubDB.scope({ grp = "G1", mode = "unread", q = "he" }), id, "同条件同 id")
    Assert.is_true(SubDB.scope({ grp = "", mode = "unread", q = "he" }) ~= id, "未分组与 G1 不同")
    local spec = SubDB.scopeOf(id)
    Assert.eq(spec.grp, "G1")
    Assert.eq(spec.mode, "unread")
    Assert.eq(spec.q, "he")
    Assert.is_nil(spec.feed)
    Assert.is_nil(SubDB.scopeOf("s0000"))
end

-- 超过 180 天的自动淘汰，收藏的与没有发布时间的保留；返回淘汰条数。
do
    local f = SubDB.add({ kind = "rss", url = "https://age.com/feed", title = "age" })
    local now = os.time()
    SubDB.MAX_AGE = math.huge
    SubDB.merge(f, { { guid = "old", title = "旧", time = now - MAX_AGE - 100 }, { guid = "oldstar", title = "旧藏", time = now - MAX_AGE - 200 },
        { guid = "new", title = "新", time = now - 100 }, { guid = "notime", title = "无时间" } })
    SubDB.setStarred(f, "oldstar", true)
    SubDB.MAX_AGE = MAX_AGE
    local _added, removed = SubDB.merge(f, { { guid = "new2", title = "新二", time = now } })
    Assert.eq(removed, 1)
    local left = SubDB.guids(f)
    Assert.is_nil(left.old)
    Assert.is_true(left.oldstar and left.new and left.notime and left.new2)
end
