--[[--
订阅清单的月读同步。

一份文档，身份是 kind + url。标题、分组、筛选和排序看 changed_at，后改的赢；时间相同就按内容比，两台算出同一份。
已读只增不减。收藏看 star_at，后改的赢。删过的源记在墓碑里，比修订新才真删，重新订阅会把墓碑清掉。
文章正文和图片缓存在本机，不进这份文档；换机后打开文章再抓。

@module koplugin.book.features.subscribe.sync
--]]

local SubDB = require("features.subscribe.db")

local Sync = {}

--- 空文档。
---@return { feeds: table[], removed: table[] }
local function blank()
    return { feeds = {}, removed = {} }
end

--- 线上的文档是两层数组：{ feeds, removed }。条目也是数组，空位不用 nil，编码才稳定。
---@param doc table|nil
---@return { feeds: table[], removed: table[] }
function Sync.unpack(doc)
    local out = blank()
    if type(doc) ~= "table" or type(doc[1]) ~= "table" then return out end
    for _idx, raw in ipairs(doc[1]) do
        if type(raw) == "table" and type(raw[1]) == "string" and raw[1] ~= ""
            and type(raw[2]) == "string" and raw[2] ~= "" then
            local items = {}
            if type(raw[9]) == "table" then
                for _item_idx, it in ipairs(raw[9]) do
                    if type(it) == "table" and type(it[1]) == "string" and it[1] ~= "" then
                        items[#items + 1] = {
                            guid = it[1], title = it[2] or "", link = it[3] or "",
                            time = tonumber(it[4]) or 0, seq = tonumber(it[5]) or 0,
                            read = tonumber(it[6]) == 1, read_at = tonumber(it[7]) or 0,
                            starred = tonumber(it[8]) == 1, star_at = tonumber(it[9]) or 0,
                        }
                    end
                end
            end
            out.feeds[#out.feeds + 1] = {
                kind = raw[1], url = raw[2], title = raw[3] or "", grp = raw[4] or "",
                filter = raw[5] or "", sort = tonumber(raw[6]) or 0,
                read_at = tonumber(raw[7]) or 0, changed_at = tonumber(raw[8]) or 0,
                items = items,
            }
        end
    end
    if type(doc[2]) == "table" then
        for _idx, raw in ipairs(doc[2]) do
            if type(raw) == "table" and type(raw[1]) == "string" and raw[1] ~= ""
                and type(raw[2]) == "string" and raw[2] ~= "" then
                out.removed[#out.removed + 1] = { kind = raw[1], url = raw[2], at = tonumber(raw[3]) or 0 }
            end
        end
    end
    return out
end

---@param doc { feeds: table[], removed: table[] }
---@return table
function Sync.pack(doc)
    local feeds = {}
    for _idx, feed in ipairs(doc.feeds or {}) do
        local items = {}
        for _item_idx, it in ipairs(feed.items or {}) do
            items[#items + 1] = {
                it.guid, it.title or "", it.link or "", tonumber(it.time) or 0, tonumber(it.seq) or 0,
                it.read and 1 or 0, tonumber(it.read_at) or 0, it.starred and 1 or 0, tonumber(it.star_at) or 0,
            }
        end
        feeds[#feeds + 1] = {
            feed.kind, feed.url, feed.title or "", feed.grp or "", feed.filter or "",
            tonumber(feed.sort) or 0, tonumber(feed.read_at) or 0, tonumber(feed.changed_at) or 0, items,
        }
    end
    local removed = {}
    for _idx, tomb in ipairs(doc.removed or {}) do
        removed[#removed + 1] = { tomb.kind, tomb.url, tonumber(tomb.at) or 0 }
    end
    return { feeds, removed }
end

---@param item table
---@param into table
local function takeItem(item, into)
    local guid = item.guid
    if type(guid) ~= "string" or guid == "" then return end
    local cur = into[guid]
    if not cur then
        into[guid] = {
            guid = guid, title = item.title or "", link = item.link or "",
            time = tonumber(item.time) or 0, seq = tonumber(item.seq) or 0,
            read = item.read and true or false, read_at = tonumber(item.read_at) or 0,
            starred = item.starred and true or false, star_at = tonumber(item.star_at) or 0,
        }
        return
    end
    if cur.title == "" then cur.title = item.title or "" end
    if cur.link == "" then cur.link = item.link or "" end
    if cur.time == 0 then cur.time = tonumber(item.time) or 0 end
    if (tonumber(item.seq) or 0) > cur.seq then cur.seq = tonumber(item.seq) or 0 end
    if item.read then cur.read = true end
    if (tonumber(item.read_at) or 0) > cur.read_at then cur.read_at = tonumber(item.read_at) or 0 end
    local star_at = tonumber(item.star_at) or 0
    if star_at > cur.star_at or (star_at == cur.star_at and item.starred and not cur.starred) then
        cur.starred = item.starred and true or false
        cur.star_at = math.max(cur.star_at, star_at)
    end
end

---@param a table[]|nil
---@param b table[]|nil
---@return table[]
local function mergeItems(a, b)
    local by = {}
    for _idx, item in ipairs(a or {}) do takeItem(item, by) end
    for _idx, item in ipairs(b or {}) do takeItem(item, by) end
    local guids = {}
    for guid in pairs(by) do guids[#guids + 1] = guid end
    table.sort(guids)
    local out = {}
    for i, guid in ipairs(guids) do out[i] = by[guid] end
    return out
end

---@param feed table
---@return string
local function metaKey(feed)
    return table.concat({
        feed.title or "", feed.grp or "", feed.filter or "", tostring(tonumber(feed.sort) or 0),
    }, "\0")
end

--- 修订时间新的一边赢；相同则按标题、分组、筛选、排序的字节序，两边结果一致。
---@param a table
---@param b table
---@return table
local function prefer(a, b)
    local ac, bc = tonumber(a.changed_at) or 0, tonumber(b.changed_at) or 0
    if ac ~= bc then return ac > bc and a or b end
    local am, bm = metaKey(a), metaKey(b)
    if am ~= bm then return am > bm and a or b end
    return a
end

---@param local_doc { feeds: table[], removed: table[] }
---@param remote_doc { feeds: table[], removed: table[] }
---@return { feeds: table[], removed: table[] }
local function mergeRich(local_doc, remote_doc)
    local by = {}
    local function take(feed)
        if type(feed.kind) ~= "string" or feed.kind == "" or type(feed.url) ~= "string" or feed.url == "" then
            return
        end
        local key = feed.kind .. "\0" .. feed.url
        local cur = by[key]
        if not cur then
            by[key] = {
                kind = feed.kind, url = feed.url, title = feed.title or "", grp = feed.grp or "",
                filter = feed.filter or "", sort = tonumber(feed.sort) or 0,
                read_at = tonumber(feed.read_at) or 0, changed_at = tonumber(feed.changed_at) or 0,
                items = mergeItems(feed.items, {}),
            }
            return
        end
        local win = prefer(cur, feed)
        by[key] = {
            kind = win.kind, url = win.url, title = win.title or "", grp = win.grp or "",
            filter = win.filter or "", sort = tonumber(win.sort) or 0,
            read_at = math.max(tonumber(cur.read_at) or 0, tonumber(feed.read_at) or 0),
            changed_at = tonumber(win.changed_at) or 0,
            items = mergeItems(cur.items, feed.items),
        }
    end
    for _idx, feed in ipairs(local_doc.feeds or {}) do take(feed) end
    for _idx, feed in ipairs(remote_doc.feeds or {}) do take(feed) end

    local tombs = {}
    local function takeTomb(tomb)
        if type(tomb.kind) ~= "string" or tomb.kind == "" or type(tomb.url) ~= "string" or tomb.url == "" then
            return
        end
        local key = tomb.kind .. "\0" .. tomb.url
        local at = tonumber(tomb.at) or 0
        if at <= 0 then return end
        local cur = tombs[key]
        if not cur or at > cur.at then tombs[key] = { kind = tomb.kind, url = tomb.url, at = at } end
    end
    for _idx, tomb in ipairs(local_doc.removed or {}) do takeTomb(tomb) end
    for _idx, tomb in ipairs(remote_doc.removed or {}) do takeTomb(tomb) end
    for key, tomb in pairs(tombs) do
        local feed = by[key]
        if feed and feed.changed_at > tomb.at then
            tombs[key] = nil
        else
            by[key] = nil
        end
    end

    local feeds, removed = {}, {}
    for _key, feed in pairs(by) do feeds[#feeds + 1] = feed end
    table.sort(feeds, function(a, b)
        if a.kind ~= b.kind then return a.kind < b.kind end
        return a.url < b.url
    end)
    for _key, tomb in pairs(tombs) do removed[#removed + 1] = tomb end
    table.sort(removed, function(a, b)
        if a.kind ~= b.kind then return a.kind < b.kind end
        return a.url < b.url
    end)
    return { feeds = feeds, removed = removed }
end

---@return table
function Sync.export()
    local snap = SubDB.syncSnapshot()
    for _idx, feed in ipairs(snap.feeds) do feed.id = nil end
    table.sort(snap.feeds, function(a, b)
        if a.kind ~= b.kind then return a.kind < b.kind end
        return a.url < b.url
    end)
    for _idx, feed in ipairs(snap.feeds) do
        table.sort(feed.items, function(a, b) return a.guid < b.guid end)
    end
    table.sort(snap.removed, function(a, b)
        if a.kind ~= b.kind then return a.kind < b.kind end
        return a.url < b.url
    end)
    return Sync.pack(snap)
end

---@param local_doc table
---@param remote_doc table
---@return table
function Sync.merge(local_doc, remote_doc)
    return Sync.pack(mergeRich(Sync.unpack(local_doc), Sync.unpack(remote_doc)))
end

--- 墓碑盖过的源交给订阅自己删（工作目录、隐藏书行一起清掉），再写入合并结果。
---@param doc table
---@return boolean
function Sync.import(doc)
    local rich = Sync.unpack(doc)
    local Subscribe = require("features.subscribe")
    for _idx, feed in ipairs(SubDB.feedsBeatenBy(rich.removed)) do
        Subscribe.remove(feed)
    end
    return SubDB.applySync(rich) == true
end

require("utils.extension").add("sync.document", {
    id = "subscribe",
    export = Sync.export,
    merge = Sync.merge,
    import = Sync.import,
})

return Sync
