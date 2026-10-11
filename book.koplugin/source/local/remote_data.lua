--[[--
本地源：WebDAV 下 .Moon+/ 的进度、统计、笔记文件读写。
非 webdav:// 身份（纯本地书）没有远端，推送直接成功、拉取为空。
函数首参即 LocalClient，由 source.local.client 装配为方法。

@module koplugin.book.source.local.remote_data
--]]

local _ = require("gettext")
local Common = require("source.local.common")

local SOURCE_ID = Common.SOURCE_ID
local defer, ensureParent, readFile, writeFile, field = Common.defer, Common.ensureParent, Common.readFile, Common.writeFile, Common.field
local remoteStableId, remoteRelativePath = Common.remoteStableId, Common.remoteRelativePath
local encodeProgress, decodeProgress = Common.encodeProgress, Common.decodeProgress
local moonPath, progressRemotePath, notesRemotePath = Common.moonPath, Common.progressRemotePath, Common.notesRemotePath

local RemoteData = {}

--- 下载远端小文件并读出内容；远端不存在时 cb(nil, nil, true)。
---@param self LocalClient
---@param remote string
---@param temp string
---@param cb fun(raw: string|nil, err: string|nil, missing: boolean|nil)
---@return { cancel: fun() }
local function fetchText(self, remote, temp, cb)
    ensureParent(temp)
    return self.dav:getAsync(remote, temp, nil, function(ok, err, code)
        local raw = ok and readFile(temp)
        os.remove(temp)
        if raw then return cb(raw) end
        cb(nil, err or _("读取失败"), code == 404)
    end)
end

--- 上传一段文本到远端（先建父目录）。
---@param self LocalClient
---@param remote string
---@param temp string
---@param data string
---@param cb fun(ok: boolean|nil, err: string|nil)
---@return { cancel: fun() }|nil
local function putText(self, remote, temp, data, cb)
    if not writeFile(temp, data) then
        cb(nil, _("无法写入临时文件"))
        return nil
    end
    local cancelled, active = false, nil
    active = self.dav:ensurePathAsync(remote:match("(.+)/[^/]+$"), function(ok_dir, dir_err)
        if cancelled then return end
        if not ok_dir then os.remove(temp); return cb(nil, dir_err) end
        active = self.dav:putFileAsync(remote, temp, function(ok, err)
            os.remove(temp)
            if not cancelled then cb(ok, err) end
        end)
    end)
    return { cancel = function()
        cancelled = true
        if active and active.cancel then active:cancel() end
        os.remove(temp)
    end }
end

--- 拉取单本进度（开书时由 book.progress 调用，冲突弹窗在那边）。
---@param stable_id string
---@param cb fun(pos: ProgressPosition|nil, err: string|nil, meta: table|nil)
---@return { cancel: fun() }|nil
---@param self LocalClient
function RemoteData.getProgressAsync(self, stable_id, cb)
    local rel = remoteRelativePath(stable_id)
    if not rel then defer(cb, nil, nil, { empty = true }); return nil end
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
    if not rel then defer(cb, true); return nil end
    return putText(self, progressRemotePath(self, rel), self:webdavCacheRoot() .. "/.progress.upload",
        encodeProgress(pos), cb)
end

--- 统计行在 stats.json 里的身份：同一设备同一本书同一开始时间只算一条。
local function statKey(row)
    return tostring(row.device_id) .. "\31" .. tostring(row.filename) .. "\31" .. tostring(row.start_time)
end

--- 读 stats.json（JSON 数组，行形如 book 服务端 /index/stats/import 的 stats[]，外加 device_id）。
---@param self LocalClient
---@param cb fun(rows: table[]|nil, err: string|nil, missing: boolean|nil)
---@return { cancel: fun() }
local function readStats(self, cb)
    return fetchText(self, moonPath(self, "Stats/stats.json"), self:webdavCacheRoot() .. "/.stats.json",
        function(raw, err, missing)
            if missing then return cb({}, nil, true) end
            if not raw then return cb(nil, err) end
            local ok, rows = pcall(require("json").decode, raw)
            if not ok or type(rows) ~= "table" then return cb(nil, _("阅读统计文件损坏")) end
            cb(rows)
        end)
end

--- 上报统计：读远端全量、按 statKey 合并、整文件写回。所有设备共用一个文件，
--- 写前先读能把并发覆盖缩到“两台设备同一时刻写”的窗口，但消不掉。
--- WebDAV 书写相对路径（和 book 服务端同构）；其它本地书写绝对路径，拉取时只认本设备的。
---@param rows BookStatsRow[]
---@param cb fun(result: BookStatsPushResult|nil, err: string|nil)
---@return { cancel: fun() }|nil
---@param self LocalClient
function RemoteData.pushStatsAsync(self, rows, cb)
    local device_id = require("utils.device_id").ensure()
    local cancelled, active = false, nil
    active = readStats(self, function(remote, err)
        if cancelled then return end
        if not remote then return cb(nil, err) end
        local seen, added = {}, 0
        for _idx, row in ipairs(remote) do
            if type(row) == "table" then seen[statKey(row)] = true end
        end
        for _idx, row in ipairs(rows) do
            local wire = {
                filename = remoteRelativePath(row.stable_id) or row.stable_id, device_id = device_id,
                page = row.page, start_time = row.start_time,
                duration = row.duration, total_pages = row.total_pages,
            }
            if not seen[statKey(wire)] then
                seen[statKey(wire)] = true
                remote[#remote + 1] = wire
                added = added + 1
            end
        end
        if added == 0 then return cb({}) end
        active = putText(self, moonPath(self, "Stats/stats.json"), self:webdavCacheRoot() .. "/.stats.upload",
            require("json").encode(remote), function(ok, put_err)
                if cancelled then return end
                if ok then cb({}) else cb(nil, put_err) end
            end)
    end)
    return { cancel = function()
        cancelled = true
        if active and active.cancel then active:cancel() end
    end }
end

--- 拉取统计。远端是全部设备的全量快照：非空时覆盖本地全部已同步行
--- （含本地 30 天压缩出的汇总行，否则汇总行 + 原始行会重复计时）；
--- 文件不存在或为空时只追加，不能拿空快照抹掉本地历史。
---@param cb fun(result: BookStatsRow[]|BookStatsPullResult|nil, err: string|nil)
---@return { cancel: fun() }
---@param self LocalClient
function RemoteData.pullStatsAsync(self, cb)
    local device_id = require("utils.device_id").ensure()
    return readStats(self, function(remote, err)
        if not remote then return cb(nil, err) end
        local rows = {}
        for _idx, item in ipairs(remote) do
            local filename = type(item) == "table" and field(item.filename)
            local stable_id = filename and (filename:sub(1, 1) ~= "/" and remoteStableId(filename)
                or item.device_id == device_id and filename or nil)
            if stable_id then
                rows[#rows + 1] = {
                    source_id = SOURCE_ID, stable_id = stable_id, record_type = "page",
                    page = tonumber(item.page) or 0, start_time = tonumber(item.start_time),
                    duration = tonumber(item.duration), total_pages = tonumber(item.total_pages) or 0,
                }
            end
        end
        cb(#rows > 0 and { rows = rows, replace = { mode = "all_synced" } } or rows)
    end)
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
    if not rel then defer(cb, {}); return nil end
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
    if not rel then defer(cb, {}, nil, nil); return nil end
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
