









local _ = require("l10n").get("source.local")
local Common = require("source.local.common")

local SOURCE_ID = Common.SOURCE_ID
local defer, readFile, writeFile, field = Common.defer, Common.readFile, Common.writeFile, Common.field
local eachAsync, fetchText, putText = Common.eachAsync, Common.fetchText, Common.putText
local md5 = require("ffi/sha2").md5
local remoteStableId, remoteRelativePath = Common.remoteStableId, Common.remoteRelativePath
local relFor, localRoot = Common.relFor, Common.localRoot
local encodeProgress, decodeProgress = Common.encodeProgress, Common.decodeProgress
local moonPath, progressRemotePath, notesRemotePath = Common.moonPath, Common.progressRemotePath, Common.notesRemotePath

local RemoteData = {}

function RemoteData.progressUploadGuardEnabled()
    return require("utils.settings").getSource(SOURCE_ID).webdav_check_progress_before_upload == true
end

function RemoteData.progressFractionTolerance()
    return require("utils.settings").getSource(SOURCE_ID).webdav_ignore_small_progress_diff ~= false and 0.01 or 0
end


function RemoteData.isProgressAhead(remote, local_pos)
    return remote and not (remote.locator and remote.locator == local_pos.locator)
        and (tonumber(remote.fraction) or 0) > (tonumber(local_pos.fraction) or 0)
end







function RemoteData.getProgressAsync(self, stable_id, cb, opts)
    local rel = relFor(self, stable_id)
    if not rel then return defer(cb, nil, nil, { empty = true }) end
    local cancelled, active = false, nil
    local remote = progressRemotePath(self, rel)
    local first = fetchText(self, remote, self:webdavCacheRoot() .. "/.progress.get",
        function(raw, err, missing)
            if cancelled then return end
            if missing then return cb(nil, nil, { empty = true }) end
            if not raw then return cb(nil, err) end
            local pos = decodeProgress(raw)
            if not pos then return cb(nil, _("进度为空")) end
            local meta = { webdav_progress_marker = raw }
            if opts and opts.metadata_present == false then return cb(pos, nil, meta) end
            active = fetchText(self, remote .. ".json", self:webdavCacheRoot() .. "/.position.get",
                function(metadata, meta_err, absent)
                    if cancelled then return end
                    if absent then return cb(pos, nil, meta) end
                    if not metadata then return cb(nil, meta_err) end
                    local ok, data = pcall(require("json").decode, metadata)
                    if not ok or type(data) ~= "table" or type(data.position) ~= "table"
                        or type(data.position.fraction) ~= "number" then
                        return cb(nil, _("进度文件损坏"))
                    end
                    if data.file ~= rel or data.marker ~= raw then return cb(pos, nil, meta) end
                    cb(data.position, nil, meta)
                end)
        end)
    active = active or first
    return { cancel = function()
        cancelled = true
        if active and active.cancel then active:cancel() end
    end }
end









function RemoteData.putProgressAsync(self, stable_id, pos, cb)
    if not self:isWebdav() then return defer(cb, true) end
    local rel = relFor(self, stable_id)
    if not rel then
        return defer(cb, nil, _("这本书不在 WebDAV 书库目录内，进度只保存在本机"))
    end
    local cancelled, active = false, nil
    local remote, raw = progressRemotePath(self, rel), encodeProgress(pos)
    local confirmed = type(pos.extra) == "table" and pos.extra.webdav_overwrite_marker
    local function upload()
        if pos.locator or pos.page then
            -- .po 是发布标记，精确坐标先到位；任一步失败都不能确认本地脏行。
            local wire = {}
            for k, v in pairs(pos) do wire[k] = v end
            if confirmed then
                wire.extra = {}
                for k, v in pairs(pos.extra) do
                    if k ~= "webdav_overwrite_marker" then wire.extra[k] = v end
                end
                if not next(wire.extra) then wire.extra = nil end
            end
            local first = putText(self, remote .. ".json", self:webdavCacheRoot() .. "/.position.upload",
                require("json").encode({ file = rel, marker = raw, position = wire }), function(ok, err)
                    if cancelled then return end
                    if not ok then return cb(nil, err) end
                    active = putText(self, remote, self:webdavCacheRoot() .. "/.progress.upload", raw, cb)
                end)
            active = active or first
        else
            active = putText(self, remote, self:webdavCacheRoot() .. "/.progress.upload", raw, cb)
        end
    end
    if RemoteData.progressUploadGuardEnabled() then
        local first = self:getProgressAsync(stable_id, function(cloud, err, meta)
            if cancelled then return end
            active = nil
            if not cloud and (not meta or not meta.empty) then
                return cb(nil, err or _("无法检查云端进度，已保留本地进度"))
            end
            if RemoteData.isProgressAhead(cloud, pos) and
                (not confirmed or not meta or confirmed ~= meta.webdav_progress_marker) then
                return cb(nil, _("云端进度领先，请打开本书选择阅读位置"))
            end
            upload()
        end)
        active = active or first
    else
        upload()
    end
    return { cancel = function()
        cancelled = true
        if active and active.cancel then active:cancel() end
    end }
end


local COMPACT_AGE = 30 * 86400


local function statKey(row)
    return tostring(row.device_id) .. "\31" .. tostring(row.filename) .. "\31" .. tostring(row.start_time)
        .. (row.event_count ~= nil and "\31r" or "")
end



local function hourOf(ts)
    local clock = os.date("*t", ts)

    clock.min, clock.sec = 0, 0
    return os.time(clock)
end




local function fold(into, row)
    into.page = math.max(tonumber(into.page) or 0, tonumber(row.page) or 0)
    into.total_pages = math.max(tonumber(into.total_pages) or 0, tonumber(row.total_pages) or 0)
    into.duration = (tonumber(into.duration) or 0) + (tonumber(row.duration) or 0)
    into.event_count = (tonumber(into.event_count) or 0) + (tonumber(row.event_count) or 1)
    into.last_time = math.max(tonumber(into.last_time) or 0, tonumber(row.last_time) or tonumber(row.start_time) or 0)
end






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

--[[ 旧统计布局（兼容读取与旧版 stats.json 迁移）：
  Stats/index.json          总表 { version = 1, books = { [filename] = { updated_at, device_id, hash } } }
                            （hash = 书文件内容 md5，作版本号；updated_at 只到秒，同秒连写会撞）
  Stats/books/<md5>.json    一本书全部设备的统计行（JSON 数组，行形如 book 服务端 /index/stats/import 的
                            stats[]，外加 device_id；30 天前的并成带 event_count 的小时汇总行）
  Stats/stats.json          旧版单文件，拉取时并进按书文件后删除
新格式写入 Stats/devices/<md5(device_id)>/index.json 与该设备独立的 books 文件。
本地 <缓存>/stats_index.json 按旧版 / 设备+文件名记已入库版本。]]
local STATS_INDEX = "Stats/index.json"
local LEGACY_STATS = "Stats/stats.json"



local function deviceStatsRoot(self, device_id)
    return moonPath(self, "Stats/devices/" .. md5(device_id))
end



local function statsIndexPath(self, device_id)
    return device_id and (deviceStatsRoot(self, device_id) .. "/index.json")
        or moonPath(self, STATS_INDEX)
end




local function bookStatsPath(self, filename, device_id)
    local root = device_id and (deviceStatsRoot(self, device_id) .. "/books")
        or moonPath(self, "Stats/books")
    return root .. "/" .. md5(filename) .. ".json"
end



local function rev(entry)
    return entry and entry.hash
end

local function seenKey(filename, device_id)
    return device_id and ("device:" .. device_id .. "\31" .. filename) or filename
end






local function readJson(self, remote, cb)
    return fetchText(self, remote, self:webdavCacheRoot() .. "/.stats.get", function(raw, err, missing)
        if missing then return cb(nil, nil, true) end
        if not raw then return cb(nil, err) end
        local ok, value = pcall(require("json").decode, raw)
        if not ok or type(value) ~= "table" then return cb(nil, _("阅读统计文件损坏")) end
        cb(value)
    end)
end





local function readIndexAt(self, path, cb)
    return readJson(self, path, function(index, err, missing)
        if missing then return cb({ books = {} }) end
        if index and type(index.books) ~= "table" then return cb(nil, _("阅读统计文件损坏")) end
        cb(index, err)
    end)
end

local function readIndex(self, cb)
    return readIndexAt(self, statsIndexPath(self), cb)
end


local function seenPath(self)
    return self:webdavCacheRoot() .. "/stats_index.json"
end




local function loadSeen(self)
    if not self._stats_seen then
        local ok, seen = pcall(require("json").decode, readFile(seenPath(self)) or "")
        self._stats_seen = ok and type(seen) == "table" and seen or {}
    end
    return self._stats_seen
end



local function saveSeen(self, updates)
    local seen = loadSeen(self)
    for filename, value in pairs(updates) do seen[filename] = value end
    writeFile(seenPath(self), require("json").encode(seen))
end







local function mergeBook(self, filename, rows, cb, device_id)
    local path, cancelled, active = bookStatsPath(self, filename, device_id), false, nil
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









local function commitIndex(self, before, written, own, cb, device_id)
    local cancelled, active = false, nil
    active = readIndexAt(self, statsIndexPath(self, device_id), function(index, err)
        if cancelled then return end
        if not index then return cb(nil, err) end
        local seen, advance = loadSeen(self), {}
        for filename, entry in pairs(written) do
            local old = rev(before.books[filename])
            local key = seenKey(filename, device_id)
            if own and seen[key] == old and rev(index.books[filename]) == old then advance[key] = rev(entry) end
            index.books[filename] = entry
        end
        index.version = 1
        if device_id then index.device_id = device_id end
        active = putText(self, statsIndexPath(self, device_id),
            self:webdavCacheRoot() .. (device_id and "/.stats.device.index" or "/.stats.index"),
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








local function writeBooks(self, by_file, own, cb, device_id)
    local writer_device_id = require("utils.device_id").ensure()
    local files = {}
    for filename in pairs(by_file) do files[#files + 1] = filename end
    table.sort(files)
    if #files == 0 then return defer(cb, true) end
    local cancelled, active, failed, written, count = false, nil, nil, {}, 0
    local done_files = {}
    active = readIndexAt(self, statsIndexPath(self, device_id), function(before, err)
        if cancelled then return end
        if not before then return cb(nil, err) end
        eachAsync(files, function(filename, next_item)
            active = mergeBook(self, filename, by_file[filename], function(hash, merge_err)
                if cancelled then return end
                if hash then
                    written[filename] = { updated_at = os.time(), device_id = writer_device_id, hash = hash }
                    count = count + 1
                elseif hash == false then
                    done_files[filename] = true
                else
                    failed = merge_err
                end
                next_item()
            end, device_id)
        end, function()
            if cancelled then return end
            if count == 0 then return cb(not failed or nil, failed, done_files) end
            active = commitIndex(self, before, written, own, function(ok, commit_err)
                if cancelled then return end
                if not ok then return cb(nil, commit_err, done_files) end
                for filename in pairs(written) do done_files[filename] = true end
                cb(not failed or nil, failed, done_files)
            end, device_id)
        end)
    end)
    return { cancel = function()
        cancelled = true
        if active and active.cancel then active:cancel() end
    end }
end








function RemoteData.pushStatsAsync(self, rows, cb)
    local device_id = require("utils.device_id").ensure()
    local by_file, ids_by_file = {}, {}
    for _idx, row in ipairs(rows) do
        -- 书库目录里的本地书也按相对路径上报，别的设备才能把这本书记成同一本书、时长才并得起来。
        local filename = relFor(self, row.stable_id) or row.stable_id
        by_file[filename] = by_file[filename] or {}
        table.insert(by_file[filename], {
            filename = filename, device_id = device_id,
            page = row.page, start_time = row.start_time,
            duration = row.duration, total_pages = row.total_pages,
        })
        if row.id then
            ids_by_file[filename] = ids_by_file[filename] or {}
            table.insert(ids_by_file[filename], row.id)
        end
    end
    return writeBooks(self, by_file, true, function(ok, err, done_files)
        if ok then return cb({}) end
        local synced = {}
        for filename in pairs(done_files or {}) do
            for _idx, id in ipairs(ids_by_file[filename] or {}) do synced[#synced + 1] = id end
        end
        if #synced == 0 then return cb(nil, err) end
        cb({ synced_ids = synced }, err)
    end, device_id)
end



local function legacyEntry(entries)
    for _idx, entry in ipairs(entries or {}) do
        if entry.name == "stats.json" and not entry.is_dir then return entry end
    end
end






local function foldLegacy(self, cb)
    local cancelled, active = false, nil
    active = self.dav:listAsync(moonPath(self, "Stats"), function(entries)
        if cancelled then return end
        local legacy = legacyEntry(entries)
        if not legacy then return cb(true, nil, entries or {}) end
        active = readJson(self, moonPath(self, LEGACY_STATS), function(rows, err, missing)
            if cancelled then return end
            if missing then return cb(true, nil, entries or {}) end
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
                    if not now or now.size ~= legacy.size or now.mtime ~= legacy.mtime then
                        return cb(true, nil, after or {})
                    end
                    active = self.dav:deleteAsync(moonPath(self, LEGACY_STATS), function()
                        if not cancelled then cb(true, nil, after or {}) end
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





local function pulledRow(item, stable_id)
    if not stable_id or type(item) ~= "table" or not field(item.filename) then return nil end
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






local function collectBook(remote, stable_id, out)
    for _idx, item in ipairs(remote) do
        local row = pulledRow(item, stable_id)
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






function RemoteData.pullStatsAsync(self, cb)
    local device_id = require("utils.device_id").ensure()
    local cancelled, active = false, nil
    active = foldLegacy(self, function(ok, fold_err, entries)
        if cancelled then return end
        if not ok then return cb(nil, fold_err) end
        active = readIndex(self, function(index, err)
            if cancelled then return end
            if not index then return cb(nil, err) end
            local sources = { { index = index } }
            local function pullBooks()
                if cancelled then return end
                local seen = loadSeen(self)
                local function eligible(source, filename, entry)
                    local owner = source.device_id or entry.device_id
                    return filename:sub(1, 1) ~= "/" or owner == device_id
                end


                local BookDB, root = require("book.books_db"), localRoot(self)
                local resolved = {}
                local function targetId(filename)
                    if resolved[filename] ~= nil then return resolved[filename] or nil end
                    local id
                    if filename:sub(1, 1) == "/" then
                        id = filename
                    else
                        local path = root and (root .. "/" .. filename)
                        id = path and BookDB.get(SOURCE_ID, path) and path or remoteStableId(filename)
                    end
                    resolved[filename] = id or false
                    return id
                end


                local groups, dirty = {}, {}
                for _idx, source in ipairs(sources) do
                    for filename, entry in pairs(source.index.books) do
                        if eligible(source, filename, entry) then
                            local id = targetId(filename)
                            if id then
                                groups[id] = groups[id] or {}
                                groups[id][filename] = true
                                if seen[seenKey(filename, source.device_id)] ~= rev(entry) then
                                    dirty[id] = true
                                end
                            end
                        end
                    end
                end
                -- 整本替换要求拿到这本书的全部云端文件：只看变了的文件会把它其余的历史行删掉。
                local ids = {}
                for id in pairs(dirty) do ids[#ids + 1] = id end
                table.sort(ids)
                if #ids == 0 then return cb({}) end

                local out, updates, fetched = { rows = {}, ids = {}, seen_ids = {} }, {}, 0
                eachAsync(ids, function(stable_id, next_group)
                    local filenames = {}
                    for filename in pairs(groups[stable_id]) do filenames[#filenames + 1] = filename end
                    table.sort(filenames)
                    local book_out = { rows = {}, rollups = {}, ids = {}, seen_ids = {} }
                    local book_updates, failed = {}, false
                    eachAsync(filenames, function(filename, next_file)
                        local targets = {}
                        for _idx, source in ipairs(sources) do
                            local entry = source.index.books[filename]
                            if entry and eligible(source, filename, entry) then
                                targets[#targets + 1] = {
                                    source = source,
                                    entry = entry,
                                    path = bookStatsPath(self, filename, source.device_id),
                                }
                            end
                        end
                        eachAsync(targets, function(target, next_target)
                            active = readJson(self, target.path, function(remote, book_err)
                                if cancelled then return end
                                if not remote then
                                    require("utils.log").warn("book webdav stats book skipped", filename, book_err)
                                    failed = true
                                    return next_target()
                                end
                                collectBook(remote, stable_id, book_out)
                                book_updates[seenKey(filename, target.source.device_id)] = rev(target.entry)
                                next_target()
                            end)
                        end, next_file)
                    end, function()
                        if cancelled then return end
                        if not failed then
                            fetched = fetched + 1
                            for _idx, row in ipairs(book_out.rows) do
                                out.rows[#out.rows + 1] = row
                            end
                            if not out.seen_ids[stable_id] then
                                out.seen_ids[stable_id] = true
                                out.ids[#out.ids + 1] = stable_id
                            end
                            for key, value in pairs(book_updates) do updates[key] = value end
                        end
                        next_group()
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
            end
            local devices_entry
            for _idx, entry in ipairs(entries or {}) do
                if entry.name == "devices" and entry.is_dir then
                    devices_entry = entry
                    break
                end
            end
            if not devices_entry then return pullBooks() end
            active = self.dav:listAsync(devices_entry.path, function(device_dirs, list_err)
                if cancelled then return end
                if not device_dirs then return cb(nil, list_err) end
                local dirs = {}
                for _idx, entry in ipairs(device_dirs) do
                    if entry.is_dir then dirs[#dirs + 1] = entry.name end
                end
                eachAsync(dirs, function(dir, next_dir)
                    local path = devices_entry.path .. "/" .. dir .. "/index.json"
                    active = readIndexAt(self, path, function(device_index, index_err)
                        if cancelled then return end
                        if not device_index then
                            return cb(nil, index_err)
                        end
                        local owner = device_index.device_id
                        if next(device_index.books) and
                            (type(owner) ~= "string" or owner == "" or md5(owner) ~= dir) then
                            return cb(nil, _("阅读统计文件损坏"))
                        end
                        if owner and next(device_index.books) then
                            sources[#sources + 1] = { index = device_index, device_id = owner }
                        end
                        next_dir()
                    end)
                end, pullBooks)
            end)
        end)
    end)
    return { cancel = function()
        cancelled = true
        if active and active.cancel then active:cancel() end
    end }
end






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


local function posKey(pos)
    if type(pos) == "table" then
        return table.concat({ tostring(pos.x), tostring(pos.y), tostring(pos.page) }, ",")
    end
    return tostring(pos or "")
end








function RemoteData.pushNotesAsync(self, stable_id, annotations, cb)
    if not self:isWebdav() then return defer(cb, {}) end
    local rel = relFor(self, stable_id)
    if not rel then
        return defer(cb, nil, _("这本书不在 WebDAV 书库目录内，笔记只保存在本机"))
    end
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








function RemoteData.pullNotesAsync(self, stable_id, cb)
    local rel = relFor(self, stable_id)
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
