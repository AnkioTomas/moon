--[[--
源自己没有同步的阅读数据，按静读天下的方式一书一个文件。

进度是一行 `.po`（章、字符偏移或页码、百分比），上传直接覆盖，不先读远端。
笔记和统计各一书一份，按设备分栏，别的设备的内容留着。
本地书的进度仍走 `.Moon+/Cache/*.po`；这里只交换静读天下不认识的 extra。

@module koplugin.book.moon_sync.reading
--]]

local DB = require("utils.db")
local Plan = require("moon_sync.plan")
local Common = require("source.local.common")

local Reading = {}

---@param result table|nil
---@param nrows integer|nil
---@param fields string[]
---@return table[]
local function rows(result, nrows, fields)
    local out = {}
    if not result then return out end
    for i = 1, nrows or 0 do
        local row = {}
        for col, name in ipairs(fields) do row[name] = result[col][i] end
        out[i] = row
    end
    return out
end

-- 单级文件名 255 字节。最长的后缀是 `.cover.webp`（11 字节），茎留 244。
local NAME_MAX = 244

--- 文件名。字母和横线原样留下，其余字节写成 %HH。
--- 编码后放不进 255 字节就改用 `h-` 加 md5：短名字保持原样，已经传上去的文件还能对上。
---@param stable_id string
---@return string|nil
function Reading.fileName(stable_id)
    if type(stable_id) ~= "string" or stable_id == "" or stable_id:find("\0", 1, true) then return nil end
    local name = (stable_id:gsub("[^%w%-]", function(ch)
        return string.format("%%%02X", ch:byte())
    end))
    if #name <= NAME_MAX then return name end
    return "h-" .. require("ffi/sha2").md5(stable_id)
end

--- `h-` 加 32 位十六进制。这种文件名还原不了身份，得查书库。
---@param name string
---@return boolean
function Reading.isDigest(name)
    return type(name) == "string" and #name == 34 and name:match("^h%-%x+$") ~= nil
end

--- 从文件名还原 stable_id。百分号后面不是两位十六进制就当无效文件。摘要文件名返回 nil。
---@param name string
---@return string|nil
function Reading.idFromName(name)
    if Reading.isDigest(name) then return nil end
    if type(name) ~= "string" or name == "" or name:find("\0", 1, true) then return nil end
    local out, i = {}, 1
    while i <= #name do
        local ch = name:sub(i, i)
        if ch == "%" then
            local hex = name:sub(i + 1, i + 2)
            local byte = #hex == 2 and tonumber(hex, 16)
            if not byte then return nil end
            out[#out + 1] = string.char(byte)
            i = i + 3
        else
            out[#out + 1] = ch
            i = i + 1
        end
    end
    local id = table.concat(out)
    if id == "" or id:find("\0", 1, true) then return nil end
    return id
end

--- 摘要文件名对上书库里的身份；普通文件名直接还原。
---@param name string
---@param index table<string, string>|nil
---@return string|nil
function Reading.idOf(name, index)
    if Reading.isDigest(name) then return index and index[name] end
    return Reading.idFromName(name)
end

--- 这个源里，摘要文件名 → stable_id。短名字不进表。
---@param source_id string
---@return table<string, string>
function Reading.digestIndex(source_id)
    local index = {}
    local result, nrows = DB.query("SELECT stable_id FROM books WHERE source_id=?;", source_id)
    for i = 1, nrows or 0 do
        local id = result[1][i]
        local name = Reading.fileName(id)
        if name and Reading.isDigest(name) then index[name] = id end
    end
    return index
end

--- 远端文件比本地新，且本地这行不脏，才拉。没有本地行也拉。
---@param updated_at number|nil
---@param dirty boolean|nil
---@param remote_mtime number|nil
---@return boolean
function Reading.shouldPull(updated_at, dirty, remote_mtime)
    if not remote_mtime or dirty then return false end
    return remote_mtime > (tonumber(updated_at) or 0)
end

---@param source_id string
---@param stable_id string
---@return number|nil
---@return boolean
function Reading.progressStamp(source_id, stable_id)
    local row = require("book.progress_db").get(source_id, stable_id)
    if not row then return nil, false end
    return row.updated_at, tonumber(row.sync_status) == 0
end

---@param pos table
---@return string
function Reading.progressLine(pos)
    return Common.encodeProgress(pos)
end

---@param source_id string
---@return table[]
function Reading.dirtyProgress(source_id)
    local out = {}
    for _idx, row in ipairs(require("book.progress_db").unsynced(source_id)) do
        if Reading.fileName(row.stable_id) then out[#out + 1] = row end
    end
    return out
end

--- 把一行 .po 写进库。本地脏行由 upsertRemote 留下。
---@param source_id string
---@param stable_id string
---@param raw string
---@param mtime number|nil
---@return boolean
function Reading.applyProgress(source_id, stable_id, raw, mtime)
    if not Reading.fileName(stable_id) then return false end
    local pos = Common.decodeProgress(raw)
    if not pos then return false end
    if mtime then pos.updated_at = mtime end
    return require("book.progress_db").upsertRemote(source_id, stable_id, pos) == true
end

---@param source_id string
---@param row table
---@return boolean
function Reading.confirmProgress(source_id, row)
    return require("book.progress_db").markSynced(source_id, row.stable_id, row.updated_at, row) == true
end

---@param source_id string
---@return table<string, { stable_id: string, items: table[], dirty: table[], latest: number }>
function Reading.notesByBook(source_id)
    local Normalize = require("book.note.normalize")
    local books = {}
    for _idx, row in ipairs(require("book.note_db").all(source_id)) do
        local id = Reading.fileName(row.stable_id) and row.stable_id
        if id then
            local book = books[id]
            if not book then
                book = { stable_id = id, items = {}, dirty = {}, latest = 0 }
                books[id] = book
            end
            local decoded = Normalize.decode(row.payload)
            if decoded then
                for _item_idx, item in ipairs(decoded) do book.items[#book.items + 1] = item end
            end
            local at = tonumber(row.updated_at) or 0
            if at > book.latest then book.latest = at end
            if tonumber(row.sync_status) == 0 then
                book.dirty[#book.dirty + 1] = { chapter_idx = row.chapter_idx, updated_at = row.updated_at }
            end
        end
    end
    return books
end

--- 换上本设备这一本的注解，其它设备原样留下。
---@param remote table|nil
---@param device_id string
---@param items table[]
---@return table
function Reading.mergeDevice(remote, device_id, items)
    local out = {}
    if type(remote) == "table" then
        for key, value in pairs(remote) do
            if key ~= device_id and type(key) == "string" and type(value) == "table" then
                out[key] = value
            end
        end
    end
    out[device_id] = items
    return out
end

local function posKey(pos)
    if type(pos) == "table" then
        return table.concat({ tostring(pos.x), tostring(pos.y), tostring(pos.page) }, ",")
    end
    return tostring(pos or "")
end

--- 各设备快照按位置取最新的一条，再按章写回。本地脏分片不盖。
---@param source_id string
---@param stable_id string
---@param devices table|nil
---@param mtime number|nil
---@return integer
function Reading.applyNotes(source_id, stable_id, devices, mtime)
    if not Reading.fileName(stable_id) or type(devices) ~= "table" then return 0 end
    local by_pos, order = {}, {}
    for _device, items in pairs(devices) do
        for _idx, item in ipairs(type(items) == "table" and items or {}) do
            if type(item) == "table" and item.page ~= nil then
                local key = posKey(item.page) .. "\31" .. posKey(item.pos0) .. "\31" .. posKey(item.pos1)
                local cur = by_pos[key]
                local stamp = tostring(item.datetime_updated or item.datetime or "")
                if not cur then order[#order + 1] = key end
                if not cur or stamp > tostring(cur.datetime_updated or cur.datetime or "") then
                    by_pos[key] = item
                end
            end
        end
    end
    local buckets = {}
    for _idx, key in ipairs(order) do
        local item = by_pos[key]
        local idx = tonumber(item.chapter_idx)
        local bucket = idx and idx > 0 and idx or 0
        buckets[bucket] = buckets[bucket] or {}
        buckets[bucket][#buckets[bucket] + 1] = item
    end
    local NoteDB = require("book.note_db")
    for _idx, row in ipairs(NoteDB.all(source_id, stable_id)) do
        if tonumber(row.sync_status) == 1 then
            local bucket = tonumber(row.chapter_idx) or 0
            if buckets[bucket] == nil then buckets[bucket] = {} end
        end
    end
    local Normalize = require("book.note.normalize")
    local JSON = require("json")
    local applied = 0
    for bucket, items in pairs(buckets) do
        local ok, payload = pcall(JSON.encode, Normalize.pack(items, true))
        if ok and NoteDB.upsertRemote(source_id, stable_id, bucket, payload, mtime) then
            applied = applied + 1
        end
    end
    return applied
end

---@param source_id string
---@param book { stable_id: string, dirty: { chapter_idx: integer, updated_at: number }[] }
function Reading.confirmNotes(source_id, book)
    local NoteDB = require("book.note_db")
    for _idx, row in ipairs(book.dirty) do
        NoteDB.markSynced(source_id, book.stable_id, row.chapter_idx, row.updated_at)
    end
end

---@param source_id string
---@return table<string, { stable_id: string, rows: table[], dirty: integer[], latest: number }>
function Reading.statsByBook(source_id)
    local result, nrows = DB.query([[SELECT stable_id, id, record_type, page, start_time, duration, total_pages,
        chapter_idx, chapter_fraction, event_count, last_time, sync_status
        FROM reading_stats WHERE source_id=? AND record_type IN ('page', 'page_rollup')
        ORDER BY start_time ASC, id ASC;]], source_id)
    local books = {}
    for _idx, row in ipairs(rows(result, nrows, {
        "stable_id", "id", "record_type", "page", "start_time", "duration", "total_pages",
        "chapter_idx", "chapter_fraction", "event_count", "last_time", "sync_status",
    })) do
        local id = Reading.fileName(row.stable_id) and row.stable_id
        if id then
            local book = books[id]
            if not book then
                book = { stable_id = id, rows = {}, dirty = {}, latest = 0 }
                books[id] = book
            end
            local at = math.max(tonumber(row.start_time) or 0, tonumber(row.last_time) or 0)
            if at > book.latest then book.latest = at end
            if tonumber(row.sync_status) == 0 then book.dirty[#book.dirty + 1] = tonumber(row.id) end
            book.rows[#book.rows + 1] = {
                record_type = row.record_type,
                page = tonumber(row.page) or 0,
                start_time = tonumber(row.start_time) or 0,
                duration = tonumber(row.duration) or 0,
                total_pages = tonumber(row.total_pages) or 0,
                chapter_idx = tonumber(row.chapter_idx),
                chapter_fraction = tonumber(row.chapter_fraction),
                event_count = tonumber(row.event_count) or 0,
                last_time = tonumber(row.last_time) or 0,
            }
        end
    end
    return books
end

--- 写上别的设备的统计。本设备的行留在本地，等这次推送自己的文件。
---@param source_id string
---@param stable_id string
---@param doc table|nil
---@param device_id string
---@return integer
function Reading.applyStats(source_id, stable_id, doc, device_id)
    if not Reading.fileName(stable_id) or type(doc) ~= "table" then return 0 end
    local StatsDB = require("book.stats_db")
    local applied = 0
    for owner, list in pairs(doc) do
        if owner ~= device_id and type(list) == "table" then
            for _idx, row in ipairs(list) do
                if type(row) == "table" then
                    row.source_id = source_id
                    row.stable_id = stable_id
                    if StatsDB.add(row, StatsDB.SYNCED) then applied = applied + 1 end
                end
            end
        end
    end
    return applied
end

---@param ids integer[]
function Reading.confirmStats(ids)
    if #ids == 0 then return end
    require("book.stats_db").markSynced(ids)
end

---@param source_id string
---@return table[]
function Reading.localExtra()
    require("book.progress_db")
    local result, nrows = DB.query([[SELECT stable_id, extra, updated_at, sync_status FROM pending_progress
        WHERE source_id=? AND extra IS NOT NULL AND extra<>'';]], "local")
    return rows(result, nrows, { "stable_id", "extra", "updated_at", "sync_status" })
end

--- 上传前按 stable_id 合并。远端有、这台没有进度行的书留在文件里。
--- extra 文本一样就不动内容，只保留较新的时间戳（阅读会抬进度时间，不代表 extra 改了）。
--- 文本不同：本地脏行优先；否则时间戳新的一边赢。结果不带 sync_status。
---@param local_rows table[]|nil
---@param remote_rows table[]|nil
---@return table[]
function Reading.mergeLocalExtra(local_rows, remote_rows)
    local by_id, order = {}, {}
    local function add(row)
        local id = type(row) == "table" and row.stable_id
        if type(id) ~= "string" or by_id[id] then return end
        order[#order + 1] = id
        by_id[id] = {
            stable_id = id,
            extra = row.extra,
            updated_at = tonumber(row.updated_at) or 0,
        }
    end
    for _idx, row in ipairs(remote_rows or {}) do add(row) end
    for _idx, row in ipairs(local_rows or {}) do
        local id = type(row) == "table" and row.stable_id
        local prev = type(id) == "string" and by_id[id] or nil
        local local_at = tonumber(row.updated_at) or 0
        if not prev then
            add(row)
        elseif row.extra ~= prev.extra and (tonumber(row.sync_status) == 0 or local_at >= prev.updated_at) then
            prev.extra = row.extra
            prev.updated_at = math.max(prev.updated_at, local_at)
        elseif row.extra == prev.extra then
            prev.updated_at = math.max(prev.updated_at, local_at)
        end
    end
    local out = {}
    for _idx, id in ipairs(order) do out[#out + 1] = by_id[id] end
    return out
end

--- 本地书的 extra。有进度行才更新，不新建行，也不动静读天下已经在同步的进度。
---@param remote_rows table[]|nil
---@return integer
function Reading.applyLocalExtra(remote_rows)
    local applied = 0
    for _idx, row in ipairs(remote_rows or {}) do
        if type(row.stable_id) == "string" and type(row.extra) == "string" then
            local updated_at, sync_status = DB.rowexec(
                "SELECT updated_at, sync_status FROM pending_progress WHERE source_id=? AND stable_id=?;",
                "local", row.stable_id)
            local local_row = updated_at ~= nil and { updated_at = updated_at, sync_status = sync_status } or nil
            if local_row and Plan.shouldApply(local_row, row) then
                -- 时间戳一起抬到远端，避免新内容配着旧修订号被写回云端。
                if DB.exec([[UPDATE pending_progress SET extra=?, updated_at=MAX(updated_at, ?)
                    WHERE source_id=? AND stable_id=?;]],
                    row.extra, tonumber(row.updated_at) or 0, "local", row.stable_id) ~= nil then
                    applied = applied + 1
                end
            end
        end
    end
    return applied
end

return Reading
