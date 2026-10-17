--[[--
订阅表：sub_feeds（订阅源）+ sub_items（条目，(feed_id, guid) 唯一，带已读）。

条目只存列表要显示的字段和 RSS 自带的正文摘要；文章正文缓存成 HTML 文件，不进库。

@module koplugin.book.features.subscribe.db
--]]

local DB = require("utils.db")

local SubDB = {}

--- 每个源最多留这么多条；超出的先删最旧的已读条目。
SubDB.KEEP = 300
--- 未读也算上的硬上限：只刷不读的源超出后最旧的连未读一起删（防止无限增长）。
SubDB.HARD_KEEP = 600

DB.schema("sub_feeds", function()
    return DB.exec([[
CREATE TABLE IF NOT EXISTS sub_feeds (
  id INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT NOT NULL, url TEXT NOT NULL, title TEXT NOT NULL,
  grp TEXT NOT NULL DEFAULT '', filter TEXT NOT NULL DEFAULT '', cursor INTEGER,
  updated_at INTEGER NOT NULL DEFAULT 0, sort INTEGER NOT NULL DEFAULT 0, error TEXT NOT NULL DEFAULT '',
  UNIQUE(kind, url)
);
CREATE TABLE IF NOT EXISTS sub_items (
  feed_id INTEGER NOT NULL, guid TEXT NOT NULL, title TEXT NOT NULL, link TEXT NOT NULL DEFAULT '',
  time INTEGER NOT NULL DEFAULT 0, seq INTEGER NOT NULL DEFAULT 0, summary TEXT, read INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (feed_id, guid)
);
CREATE INDEX IF NOT EXISTS idx_sub_items_order ON sub_items(feed_id, time DESC, seq DESC);
]]) ~= nil
end)

--- 同一篇换了 guid 也只留一条：公众号同一篇文章在不同请求下回两种 reviewId（短 id / WR1A… 长 id），
--- RSS 也可能改 guid / 链接。同源内「标题 + 时间」（时间有效时）唯一。建索引前先清掉历史重复：
--- 每组留已读的那条（其正文缓存按 guid 存，也就跟着保留），都没读留最早入库的。
local function dedupe()
    if DB.rowexec("SELECT 1 FROM sqlite_master WHERE type='index' AND name='idx_sub_items_title_time';") then return true end
    DB.exec([[
DELETE FROM sub_items WHERE time > 0 AND rowid NOT IN (
  SELECT (SELECT b.rowid FROM sub_items b WHERE b.feed_id = a.feed_id AND b.title = a.title AND b.time = a.time
          ORDER BY b.read DESC, b.rowid LIMIT 1)
  FROM sub_items a WHERE a.time > 0 GROUP BY a.feed_id, a.title, a.time);]])
    return DB.exec("CREATE UNIQUE INDEX IF NOT EXISTS idx_sub_items_title_time ON sub_items(feed_id, title, time) WHERE time > 0;") ~= nil
end
DB.schema("sub_items_dedupe", dedupe)
SubDB._dedupe = dedupe

local FEED_COLS = { "id", "kind", "url", "title", "grp", "filter", "cursor", "updated_at", "sort", "error", "unread" }

--- 列式结果 → 行表。
local function rows(result, n, cols)
    local out = {}
    for i = 1, n do
        local row = {}
        for c, name in ipairs(cols) do row[name] = result[c][i] end
        out[i] = row
    end
    return out
end

local FEED_SQL = [[
SELECT f.id, f.kind, f.url, f.title, f.grp, f.filter, f.cursor, f.updated_at, f.sort, f.error,
  (SELECT COUNT(*) FROM sub_items i WHERE i.feed_id = f.id AND i.read = 0)
FROM sub_feeds f ]]

local function feedRows(where, ...)
    local result, n = DB.query(FEED_SQL .. where, ...)
    local out = rows(result, n or 0, FEED_COLS)
    for _idx, f in ipairs(out) do
        f.id, f.unread, f.updated_at = tonumber(f.id), tonumber(f.unread) or 0, tonumber(f.updated_at) or 0
        f.cursor, f.sort, f.error = tonumber(f.cursor), tonumber(f.sort) or 0, f.error or ""
    end
    return out
end

--- 所有订阅（含未读数），按分组、手动顺序、标题排序。
---@return table[]
function SubDB.feeds()
    return feedRows("ORDER BY f.grp, f.sort, f.title;")
end

---@param id integer
---@return table|nil
function SubDB.feed(id)
    if id == nil then return nil end
    return feedRows("WHERE f.id = ?;", id)[1]
end

--- 新增订阅；同类同地址已存在返回 nil。
---@param feed { kind: string, url: string, title: string, grp: string|nil, filter: string|nil }
---@return integer|nil id
function SubDB.add(feed)
    if not DB.exec("INSERT OR IGNORE INTO sub_feeds (kind, url, title, grp, filter) VALUES (?,?,?,?,?);",
        feed.kind, feed.url, feed.title, feed.grp or "", feed.filter or "") then
        return nil
    end
    if tonumber(DB.rowexec("SELECT changes();")) == 0 then return nil end
    return tonumber(DB.rowexec("SELECT id FROM sub_feeds WHERE kind=? AND url=?;", feed.kind, feed.url))
end

--- 批量新增（OPML 导入）：一个事务里写完。返回新增条数与已存在条数。
---@param feeds table[]
---@return integer added, integer skipped
function SubDB.addMany(feeds)
    local added = 0
    DB.transaction(function()
        for _idx, feed in ipairs(feeds) do
            if SubDB.add(feed) then added = added + 1 end
        end
        return true
    end)
    return added, #feeds - added
end

--- 改标题 / 分组 / 翻页游标 / 刷新时间 / 手动顺序 / 最近错误（只改给了的字段）。
---@param id integer
---@param fields table
function SubDB.update(id, fields)
    for _idx, key in ipairs({ "title", "grp", "cursor", "updated_at", "sort", "error" }) do
        if fields[key] ~= nil then
            DB.exec("UPDATE sub_feeds SET " .. key .. "=? WHERE id=?;", fields[key], id)
        end
    end
end

--- 整组改名（new_name 为空串即解散到未分组；改成已有组名即并入该组）。
---@param old string
---@param new_name string
function SubDB.renameGroup(old, new_name)
    DB.exec("UPDATE sub_feeds SET grp=? WHERE grp=?;", new_name, old)
end

--- 按给定顺序把这些订阅放进分组并重排 sort（拖拽排序 / 移组）。
---@param grp string
---@param ids integer[]
function SubDB.order(grp, ids)
    DB.transaction(function()
        for i, id in ipairs(ids) do DB.exec("UPDATE sub_feeds SET grp=?, sort=? WHERE id=?;", grp, i, id) end
        return true
    end)
end

---@param id integer
function SubDB.remove(id)
    DB.transaction(function()
        DB.exec("DELETE FROM sub_items WHERE feed_id=?;", id)
        DB.exec("DELETE FROM sub_feeds WHERE id=?;", id)
        return true
    end)
end

--- 写入条目：已有的（同 guid，或同标题 + 时间）只更新标题，保留已读。seq 递增：同一时间（网页链接无时间）的新条目排在旧的前面、彼此保持页面顺序。
--- 超出 KEEP 删最旧的已读条目，再超出 HARD_KEEP 连未读一起删。返回真正新增的条数。
---@param feed_id integer
---@param items table[]
---@return integer
function SubDB.merge(feed_id, items)
    local base = tonumber(DB.rowexec("SELECT COALESCE(MAX(seq), 0) FROM sub_items WHERE feed_id=?;", feed_id)) or 0
    local added = 0
    DB.transaction(function()
        for i, item in ipairs(items) do
            DB.exec([[INSERT OR IGNORE INTO sub_items (feed_id, guid, title, link, time, seq, summary) VALUES (?,?,?,?,?,?,?);]],
                feed_id, item.guid, item.title or "", item.link or "", item.time or 0, base + #items - i + 1, item.summary)
            if tonumber(DB.rowexec("SELECT changes();")) == 1 then
                added = added + 1
            else
                DB.exec("UPDATE OR IGNORE sub_items SET title=? WHERE feed_id=? AND guid=?;", item.title or "", feed_id, item.guid)
            end
        end
        local trim = [[DELETE FROM sub_items WHERE feed_id=? %s AND guid IN (
  SELECT guid FROM sub_items WHERE feed_id=? ORDER BY time DESC, seq DESC LIMIT -1 OFFSET ?);]]
        DB.exec(trim:format("AND read=1"), feed_id, feed_id, SubDB.KEEP)
        DB.exec(trim:format(""), feed_id, feed_id, SubDB.HARD_KEEP)
        return true
    end)
    return added
end

--- 一页条目，新到旧。
---@param feed_id integer
---@param page integer 从 1 起
---@param size integer
---@return table[] items
---@return integer total
---@param read boolean|nil 筛选：nil 全部，true 只要已读，false 只要未读（在 SQL 里筛，分页、总数都按筛后算）
function SubDB.items(feed_id, page, size, read)
    local where = read == nil and "" or (read and " AND read=1" or " AND read=0")
    local total = tonumber(DB.rowexec("SELECT COUNT(*) FROM sub_items WHERE feed_id=?" .. where .. ";", feed_id)) or 0
    local result, n = DB.query([[SELECT guid, title, link, time, read FROM sub_items WHERE feed_id=?]] .. where .. " " .. [[ORDER BY time DESC, seq DESC LIMIT ? OFFSET ?;]], feed_id, size, (page - 1) * size)
    local out = rows(result, n, { "guid", "title", "link", "time", "read" })
    for _idx, item in ipairs(out) do
        item.time, item.read = tonumber(item.time) or 0, tonumber(item.read) == 1
    end
    return out, total
end

--- 条目自带正文（RSS content / description）。
---@return string|nil
function SubDB.summary(feed_id, guid)
    return DB.rowexec("SELECT summary FROM sub_items WHERE feed_id=? AND guid=?;", feed_id, guid)
end

--- 标已读；guid 为 nil 时整个源全部已读。
function SubDB.markRead(feed_id, guid)
    if guid then
        DB.exec("UPDATE sub_items SET read=1 WHERE feed_id=? AND guid=?;", feed_id, guid)
    else
        DB.exec("UPDATE sub_items SET read=1 WHERE feed_id=?;", feed_id)
    end
end

return SubDB
