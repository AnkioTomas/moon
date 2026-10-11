--[[--
本地源：WebDAV 下 .Moon+/ 的进度、统计、笔记文件读写。
非 webdav:// 身份（纯本地书）没有远端，推送直接成功、拉取为空。
函数首参即 LocalClient，由 source.local.client 装配为方法。

@module koplugin.book.source.local.remote_data
--]]

local _ = require("gettext")
local Common = require("source.local.common")

local SOURCE_ID = Common.SOURCE_ID
local defer, readFile, writeFile, field = Common.defer, Common.readFile, Common.writeFile, Common.field
local eachAsync, fetchText, putText = Common.eachAsync, Common.fetchText, Common.putText
local md5 = require("ffi/sha2").md5
local remoteStableId, remoteRelativePath = Common.remoteStableId, Common.remoteRelativePath
local encodeProgress, decodeProgress = Common.encodeProgress, Common.decodeProgress
local moonPath, progressRemotePath, notesRemotePath = Common.moonPath, Common.progressRemotePath, Common.notesRemotePath

local RemoteData = {}

--- 拉取单本进度（开书时由 book.progress 调用，冲突弹窗在那边）。
---@param stable_id string
---@param cb fun(pos: ProgressPosition|nil, err: string|nil, meta: table|nil)
---@return { cancel: fun() }|nil
---@param self LocalClient
function RemoteData.getProgressAsync(self, stable_id, cb)
    local rel = remoteRelativePath(stable_id)
    if not rel then return defer(cb, nil, nil, { empty = true }) end
    return fetchText(self, progressRemotePath(self, rel), self:webdavCacheRoot() .. "/.progress.get",
        function(raw, err, missing)
            if missing then return cb(nil, nil, { empty = true }) end
            if not raw then return cb(nil, err) end
            local pos = decodeProgress(raw)
            if pos then cb(pos) else cb(nil, _("进度为空")) end
        end)
end

--- 推送单本进度（关书 / 网络恢复时由 book.progress 推脏行）。非 webdav:// 身份没有远端，直接成功。
---@param stable_id string
---@param pos ProgressPosition
---@param cb fun(ok: boolean|nil, err: string|nil)
---@return { cancel: fun() }|nil
---@param self LocalClient
function RemoteData.putProgressAsync(self, stable_id, pos, cb)
    local rel = remoteRelativePath(stable_id)
    if not rel then return defer(cb, true) end
    return putText(self, progressRemotePath(self, rel), self:webdavCacheRoot() .. "/.progress.upload",
        encodeProgress(pos), cb)
end

--- 与本地 compactSynced 同一口径：超过 30 天的逐页行按小时汇总。
local COMPACT_AGE = 30 * 86400

--- 统计行在 stats.json 里的身份：同一设备同一本书同一开始时间只算一条；汇总行（带 event_count）另算。
local function statKey(row)
    return tostring(row.device_id) .. "\31" .. tostring(row.filename) .. "\31" .. tostring(row.start_time)
        .. (row.event_count ~= nil and "\31r" or "")
end

---@param ts number
---@return integer 所在本地整点
local function hourOf(ts)
    local clock = os.date("*t", ts)
    ---@cast clock osdate
    clock.min, clock.sec = 0, 0
    return os.time(clock)
end

--- 把一行（逐页行即 event_count=1 的汇总）并进汇总行。
---@param into table
---@param row table
local function fold(into, row)
    into.page = math.max(tonumber(into.page) or 0, tonumber(row.page) or 0)
    into.total_pages = math.max(tonumber(into.total_pages) or 0, tonumber(row.total_pages) or 0)
    into.duration = (tonumber(into.duration) or 0) + (tonumber(row.duration) or 0)
    into.event_count = (tonumber(into.event_count) or 0) + (tonumber(row.event_count) or 1)
    into.last_time = math.max(tonumber(into.last_time) or 0, tonumber(row.last_time) or tonumber(row.start_time) or 0)
end

--- 远端压缩：早于 before_ts 的逐页行按 设备+文件+小时 并成汇总行（event_count 为原页事件数）。
--- 返回新数组，汇总行都是新表，不改入参（入参可能是缓存）。
---@param rows table[]
---@param before_ts number
---@return table[] rows, integer compacted 本次并掉的逐页行数
local function compactStats(rows, before_ts)
    local out, groups, compacted = {}, {}, 0
    for _idx, row in ipairs(rows) do
        local ts = type(row) == "table" and tonumber(row.start_time)
        local raw = ts and row.event_count == nil
        if not ts or raw and ts >= before_ts then
            out[#out + 1] = row
        else
            local start = raw and hourOf(ts) or ts
            local key = tostring(row.device_id) .. "\31" .. tostring(row.filename) .. "\31" .. start
            local group = groups[key]
            if not group then
                group = { filename = row.filename, device_id = row.device_id, start_time = start }
                groups[key] = group
                out[#out + 1] = group
            end
            fold(group, row)
            if raw then compacted = compacted + 1 end
        end
    end
    return out, compacted
end

--[[ 统计布局（本插件私有，所有设备共用）：
  Stats/index.json          总表 { version = 1, books = { [filename] = { updated_at, device_id, hash } } }
                            （hash = 书文件内容 md5，作版本号；updated_at 只到秒，同秒连写会撞）
  Stats/books/<md5>.json    一本书全部设备的统计行（JSON 数组，行形如 book 服务端 /index/stats/import 的
                            stats[]，外加 device_id；30 天前的并成带 event_count 的小时汇总行）
  Stats/stats.json          旧版单文件，拉取时并进按书文件后删除
本地 <缓存>/stats_index.json 记每本书已入库的版本（只比相等，不比先后）。]]
local STATS_INDEX = "Stats/index.json"
local LEGACY_STATS = "Stats/stats.json"

--- 一本书的统计文件：按文件名哈希，不同目录同名书不撞。
---@param self LocalClient
---@param filename string
local function bookStatsPath(self, filename)
    return moonPath(self, "Stats/books/" .. md5(filename) .. ".json")
end

---@param entry table|nil 总表条目
---@return string|nil
local function rev(entry)
    return entry and entry.hash
end

--- 读远端统计 JSON；不存在时 cb(nil, nil, true)。
---@param self LocalClient
---@param remote string
---@param cb fun(value: table|nil, err: string|nil, missing: boolean|nil)
---@return { cancel: fun() }
local function readJson(self, remote, cb)
    return fetchText(self, remote, self:webdavCacheRoot() .. "/.stats.get", function(raw, err, missing)
        if missing then return cb(nil, nil, true) end
        if not raw then return cb(nil, err) end
        local ok, value = pcall(require("json").decode, raw)
        if not ok or type(value) ~= "table" then return cb(nil, _("阅读统计文件损坏")) end
        cb(value)
    end)
end

--- 读总表；不存在为空表。
---@param self LocalClient
---@param cb fun(index: { version: integer|nil, books: table<string, table> }|nil, err: string|nil)
---@return { cancel: fun() }
local function readIndex(self, cb)
    return readJson(self, moonPath(self, STATS_INDEX), function(index, err, missing)
        if missing then return cb({ books = {} }) end
        if index and type(index.books) ~= "table" then return cb(nil, _("阅读统计文件损坏")) end
        cb(index, err)
    end)
end

---@param self LocalClient
local function seenPath(self)
    return self:webdavCacheRoot() .. "/stats_index.json"
end

--- 本地已入库版本表；文件缺失或损坏当作什么都没入过（下一轮全量拉一次）。
---@param self LocalClient
---@return table<string, string>
local function loadSeen(self)
    if not self._stats_seen then
        local ok, seen = pcall(require("json").decode, readFile(seenPath(self)) or "")
        self._stats_seen = ok and type(seen) == "table" and seen or {}
    end
    return self._stats_seen
end

---@param self LocalClient
---@param updates table<string, string>
local function saveSeen(self, updates)
    local seen = loadSeen(self)
    for filename, value in pairs(updates) do seen[filename] = value end
    writeFile(seenPath(self), require("json").encode(seen))
end

--- 把一本书的新行并进它的统计文件（去重、压缩），有变化才写回。
---@param self LocalClient
---@param filename string
---@param rows table[] wire 行
---@param cb fun(hash: string|false|nil, err: string|nil) 写回时为新内容 md5，无变化 false，失败 nil
---@return { cancel: fun() }
local function mergeBook(self, filename, rows, cb)
    local path, cancelled, active = bookStatsPath(self, filename), false, nil
    active = readJson(self, path, function(remote, err, missing)
        if cancelled then return end
        if not remote and not missing then return cb(nil, err) end
        local merged, seen, added = {}, {}, 0
        for i, row in ipairs(remote or {}) do
            merged[i] = row
            if type(row) == "table" then seen[statKey(row)] = true end
        end
        for _idx, row in ipairs(rows) do
            if not seen[statKey(row)] then
                seen[statKey(row)] = true
                merged[#merged + 1] = row
                added = added + 1
            end
        end
        local compacted
        merged, compacted = compactStats(merged, os.time() - COMPACT_AGE)
        if added == 0 and compacted == 0 then return cb(false) end
        local body = require("json").encode(merged)
        active = putText(self, path, self:webdavCacheRoot() .. "/.stats.upload", body, function(ok, put_err)
            if cancelled then return end
            if not ok then return cb(nil, put_err) end
            cb(md5(body) --[[@as string]])
        end)
    end)
    return { cancel = function()
        cancelled = true
        if active and active.cancel then active:cancel() end
    end }
end

--- 写回总表里写过的书。own=写入的全是本机行（本地都有）：写之前本地已入库到该书最新版本、
--- 期间也没被别人改过，就直接把本地版本推进到新版本，免得下次拉取重下自己刚写的文件。
---@param self LocalClient
---@param before table 写书之前读到的总表
---@param written table<string, table> 文件名 → 新条目
---@param own boolean
---@param cb fun(ok: boolean|nil, err: string|nil)
---@return { cancel: fun() }
local function commitIndex(self, before, written, own, cb)
    local cancelled, active = false, nil
    active = readIndex(self, function(index, err)
        if cancelled then return end
        if not index then return cb(nil, err) end
        local seen, advance = loadSeen(self), {}
        for filename, entry in pairs(written) do
            local old = rev(before.books[filename])
            if own and seen[filename] == old and rev(index.books[filename]) == old then advance[filename] = rev(entry) end
            index.books[filename] = entry
        end
        index.version = 1
        active = putText(self, moonPath(self, STATS_INDEX), self:webdavCacheRoot() .. "/.stats.index",
            require("json").encode(index), function(ok, put_err)
                if cancelled then return end
                if ok then saveSeen(self, advance) end
                cb(ok, put_err)
            end)
    end)
    return { cancel = function()
        cancelled = true
        if active and active.cancel then active:cancel() end
    end }
end

--- 按书并入统计行并更新总表。任何一本失败整批算失败（行留待重推，按 statKey 去重不会重复写入）。
---@param self LocalClient
---@param by_file table<string, table[]> 文件名 → wire 行
---@param own boolean 见 commitIndex
---@param cb fun(ok: boolean|nil, err: string|nil)
---@return { cancel: fun() }|nil
local function writeBooks(self, by_file, own, cb)
    local device_id = require("utils.device_id").ensure()
    local files = {}
    for filename in pairs(by_file) do files[#files + 1] = filename end
    table.sort(files)
    if #files == 0 then return defer(cb, true) end
    local cancelled, active, failed, written, count = false, nil, nil, {}, 0
    active = readIndex(self, function(before, err)
        if cancelled then return end
        if not before then return cb(nil, err) end
        eachAsync(files, function(filename, next_item)
            active = mergeBook(self, filename, by_file[filename], function(hash, merge_err)
                if cancelled then return end
                if hash then
                    written[filename] = { updated_at = os.time(), device_id = device_id, hash = hash }
                    count = count + 1
                elseif hash == nil then
                    failed = merge_err
                end
                next_item()
            end)
        end, function()
            if cancelled then return end
            if count == 0 then return cb(not failed or nil, failed) end
            active = commitIndex(self, before, written, own, function(ok, commit_err)
                if cancelled then return end
                if not ok then return cb(nil, commit_err) end
                cb(not failed or nil, failed)
            end)
        end)
    end)
    return { cancel = function()
        cancelled = true
        if active and active.cancel then active:cancel() end
    end }
end

--- 上报统计：按书并入各自的统计文件，再更新总表。两台设备同时写同一本书 / 总表仍可能互相覆盖，
--- 写前先读把窗口缩到最小，消不掉。早于 30 天的行已在远端并成汇总，同一行重推（确认丢失）会再计一次。
--- WebDAV 书写相对路径（和 book 服务端同构）；其它本地书写绝对路径，拉取时只认本设备的。
---@param rows BookStatsRow[]
---@param cb fun(result: BookStatsPushResult|nil, err: string|nil)
---@return { cancel: fun() }|nil
---@param self LocalClient
function RemoteData.pushStatsAsync(self, rows, cb)
    local device_id = require("utils.device_id").ensure()
    local by_file = {}
    for _idx, row in ipairs(rows) do
        local filename = remoteRelativePath(row.stable_id) or row.stable_id
        by_file[filename] = by_file[filename] or {}
        table.insert(by_file[filename], {
            filename = filename, device_id = device_id,
            page = row.page, start_time = row.start_time,
            duration = row.duration, total_pages = row.total_pages,
        })
    end
    return writeBooks(self, by_file, true, function(ok, err)
        if ok then cb({}) else cb(nil, err) end
    end)
end

---@param entries WebdavEntry[]|nil
---@return WebdavEntry|nil
local function legacyEntry(entries)
    for _idx, entry in ipairs(entries or {}) do
        if entry.name == "stats.json" and not entry.is_dir then return entry end
    end
end

--- 旧版单文件 stats.json（含旧版插件之后又写进去的）：行按书并进按书文件，
--- 并完确认文件没被改过再删，改过就留到下次再并（按 statKey 去重，不会重复）。
---@param self LocalClient
---@param cb fun(ok: boolean|nil, err: string|nil)
---@return { cancel: fun() }
local function foldLegacy(self, cb)
    local cancelled, active = false, nil
    active = self.dav:listAsync(moonPath(self, "Stats"), function(entries)
        if cancelled then return end
        local legacy = legacyEntry(entries)
        if not legacy then return cb(true) end
        active = readJson(self, moonPath(self, LEGACY_STATS), function(rows, err, missing)
            if cancelled then return end
            if missing then return cb(true) end
            if not rows then return cb(nil, err) end
            local by_file = {}
            for _idx, row in ipairs(rows) do
                local filename = type(row) == "table" and field(row.filename)
                if filename then
                    by_file[filename] = by_file[filename] or {}
                    table.insert(by_file[filename], row)
                end
            end
            active = writeBooks(self, by_file, false, function(ok, write_err)
                if cancelled then return end
                if not ok then return cb(nil, write_err) end
                active = self.dav:listAsync(moonPath(self, "Stats"), function(after)
                    if cancelled then return end
                    local now = legacyEntry(after)
                    if not now or now.size ~= legacy.size or now.mtime ~= legacy.mtime then return cb(true) end
                    active = self.dav:deleteAsync(moonPath(self, LEGACY_STATS), function()
                        if not cancelled then cb(true) end
                    end)
                end)
            end)
        end)
    end)
    return { cancel = function()
        cancelled = true
        if active and active.cancel then active:cancel() end
    end }
end

--- stats.json 一行转领域记录；别的设备的非 WebDAV 书（绝对路径）不认。
---@param item any
---@param device_id string
---@return BookStatsRow|nil
local function pulledRow(item, device_id)
    local filename = type(item) == "table" and field(item.filename)
    local stable_id = filename and (filename:sub(1, 1) ~= "/" and remoteStableId(filename)
        or item.device_id == device_id and filename or nil)
    if not stable_id then return nil end
    local row = {
        source_id = SOURCE_ID, stable_id = stable_id, record_type = "page",
        page = tonumber(item.page) or 0, start_time = tonumber(item.start_time),
        duration = tonumber(item.duration), total_pages = tonumber(item.total_pages) or 0,
    }
    if item.event_count ~= nil then
        row.record_type = "page_rollup"
        row.event_count = tonumber(item.event_count) or 1
        row.last_time = tonumber(item.last_time) or 0
    end
    return row
end

--- 把一本书的统计文件转成领域记录追加进 out；本地汇总行按 书+小时 唯一，
--- 别的设备同一小时的汇总在这里先并成一条。
---@param remote table[]
---@param device_id string
---@param out { rows: BookStatsRow[], rollups: table<string, BookStatsRow>, ids: string[], seen_ids: table<string, boolean> }
local function collectBook(remote, device_id, out)
    for _idx, item in ipairs(remote) do
        local row = pulledRow(item, device_id)
        local hour = row and row.record_type == "page_rollup" and row.stable_id .. "\31" .. tostring(row.start_time)
        local same = hour and out.rollups[hour]
        if same then
            fold(same, row)
        elseif row then
            out.rows[#out.rows + 1] = row
            if hour then out.rollups[hour] = row end
            if not out.seen_ids[row.stable_id] then
                out.seen_ids[row.stable_id] = true
                out.ids[#out.ids + 1] = row.stable_id
            end
        end
    end
end

--- 拉取统计：先并旧版 stats.json，再按总表只下载版本变了的书，入库时只覆盖这些书的已同步行。
--- 入库成功（commit）后才记下版本，失败下一轮重拉。书文件缺失或损坏跳过，不抹本地。
---@param cb fun(result: BookStatsRow[]|BookStatsPullResult|nil, err: string|nil)
---@return { cancel: fun() }
---@param self LocalClient
function RemoteData.pullStatsAsync(self, cb)
    local device_id = require("utils.device_id").ensure()
    local cancelled, active = false, nil
    active = foldLegacy(self, function(ok, fold_err)
        if cancelled then return end
        if not ok then return cb(nil, fold_err) end
        active = readIndex(self, function(index, err)
            if cancelled then return end
            if not index then return cb(nil, err) end
            local seen, changed = loadSeen(self), {}
            for filename, entry in pairs(index.books) do
                -- 别的设备的非 WebDAV 书（绝对路径）一行都不认，不下载
                local mine = filename:sub(1, 1) ~= "/" or entry.device_id == device_id
                if mine and seen[filename] ~= rev(entry) then changed[#changed + 1] = filename end
            end
            table.sort(changed)
            local out, updates, fetched = { rows = {}, rollups = {}, ids = {}, seen_ids = {} }, {}, 0
            eachAsync(changed, function(filename, next_item)
                active = readJson(self, bookStatsPath(self, filename), function(remote, book_err)
                    if cancelled then return end
                    if not remote then
                        require("utils.log").warn("book webdav stats book skipped", filename, book_err)
                        return next_item()
                    end
                    if filename:sub(1, 1) ~= "/" and not out.seen_ids[remoteStableId(filename)] then
                        out.seen_ids[remoteStableId(filename)] = true
                        out.ids[#out.ids + 1] = remoteStableId(filename)
                    end
                    collectBook(remote, device_id, out)
                    updates[filename] = rev(index.books[filename])
                    fetched = fetched + 1
                    next_item()
                end)
            end, function()
                if cancelled then return end
                if fetched == 0 then return cb({}) end
                cb({
                    rows = out.rows,
                    replace = { mode = "synced_books", stable_ids = out.ids },
                    commit = function() saveSeen(self, updates) end,
                })
            end)
        end)
    end)
    return { cancel = function()
        cancelled = true
        if active and active.cancel then active:cancel() end
    end }
end

--- 读一本书的笔记文件；远端没有时 missing。
---@param self LocalClient
---@param rel string
---@param cb fun(devices: table|nil, err: string|nil, missing: boolean|nil)
---@return { cancel: fun() }
local function readNotes(self, rel, cb)
    return fetchText(self, notesRemotePath(self, rel), self:webdavCacheRoot() .. "/.notes.get",
        function(raw, err, missing)
            if missing then return cb({}, nil, true) end
            if not raw then return cb(nil, err) end
            local ok, devices = pcall(require("json").decode, raw)
            if not ok or type(devices) ~= "table" then return cb(nil, _("笔记文件损坏")) end
            cb(devices)
        end)
end

--- 注解坐标：分页文档的 pos 是 {x,y,page} 表，不能直接 tostring。
local function posKey(pos)
    if type(pos) == "table" then
        return table.concat({ tostring(pos.x), tostring(pos.y), tostring(pos.page) }, ",")
    end
    return tostring(pos or "")
end

--- 上传本设备这本书的完整注解快照；别的设备的快照原样保留（语义同 book 服务端 annotations 接口）。
--- 非 webdav:// 身份没有远端，直接成功。
---@param stable_id string
---@param annotations table[]
---@param cb fun(value: table|nil, err: string|nil)
---@return { cancel: fun() }|nil
---@param self LocalClient
function RemoteData.pushNotesAsync(self, stable_id, annotations, cb)
    local rel = remoteRelativePath(stable_id)
    if not rel then return defer(cb, {}) end
    local JSON = require("json")
    local device_id = require("utils.device_id").ensure()
    local cancelled, active = false, nil
    active = readNotes(self, rel, function(devices, err)
        if cancelled then return end
        if not devices then return cb(nil, err) end
        devices[device_id] = #annotations > 0 and annotations or JSON.util.InitArray({})
        active = putText(self, notesRemotePath(self, rel), self:webdavCacheRoot() .. "/.notes.upload",
            JSON.encode(devices), function(ok, put_err)
                if cancelled then return end
                if ok then cb({}) else cb(nil, put_err) end
            end)
    end)
    return { cancel = function()
        cancelled = true
        if active and active.cancel then active:cancel() end
    end }
end

--- 拉取所有设备快照的并集，同一位置（页 + 起止坐标）只留最后修改的一条。
--- 删除只在删过它的设备快照里消失：另一台设备的快照还带着它时会被并回来（与 book 服务端一致）。
--- 远端还没有笔记文件时不报权威快照，免得把本地已同步的笔记当成“云端已删”清掉。
---@param stable_id string
---@param cb fun(annotations: table[]|nil, err: string|nil, meta: table|nil)
---@return { cancel: fun() }|nil
---@param self LocalClient
function RemoteData.pullNotesAsync(self, stable_id, cb)
    local rel = remoteRelativePath(stable_id)
    if not rel then return defer(cb, {}) end
    return readNotes(self, rel, function(devices, err, missing)
        if not devices then return cb(nil, err) end
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
        local out = {}
        for i, key in ipairs(order) do out[i] = by_pos[key] end
        cb(out, nil, { authoritative = not missing })
    end)
end

return RemoteData
