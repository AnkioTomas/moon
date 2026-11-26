--[[--
月读同步的一轮：先跑静读天下书库同步，再传 .moon-koreader 里的设置、字体、
每本书的自定义设置和阅读数据，最后把本机设备写进 sync.lck。

不占 syncing.lock。sync.lck 只记上一台写完的设备。远端比这台见过的更新，或同一时间同一台设备，
才用远端清单覆盖本地；更旧或分叉的清单不盖本地，里面多出来的文件留在清单里。

锁不放在书库根上。静读天下自己的 syncing.lock / sync.lck 在根目录或 .Moon+，
以前误写在根上的、内容是本机设备 id 的，看到就删。

自动同步走静读天下的日常回合（只认 books.sync 和 .po，不列书库目录）。
立即同步才逐目录核对。

@module koplugin.book.moon_sync.run
--]]

local Fs = require("utils.fs")
local Paths = require("utils.paths")
local Lock = require("moon_sync.lock")
local Plan = require("moon_sync.plan")
local _ = require("gettext")

local Run = {}

local ROOT_NAME = ".moon-koreader"
local STAMP = "moon_sync_device"

---@return string
local function stampPath()
    return Paths.cacheDir() .. "/" .. STAMP
end

---@param content string
local function writeStamp(content)
    if not Paths.ensureDir(Paths.cacheDir()) then return end
    local file = io.open(stampPath(), "wb")
    if not file then return end
    file:write(content)
    file:close()
end

---@param rel string
---@return string|nil
local function localPath(rel)
    if rel:sub(1, 9) == "settings/" then return Paths.settingsDir() .. "/" .. rel:sub(10) end
    if rel:sub(1, 8) == "secrets/" then return Paths.root() .. "/secrets/" .. rel:sub(9) end
    if rel:sub(1, 6) == "fonts/" then return Paths.fontsDir() .. "/" .. rel:sub(7) end
    return nil
end

---@param data string
---@return string
local function hashOf(data)
    return require("ffi/sha2").md5(data)
end

---@param dir string
---@param prefix string
---@param out table<string, { hash: string, mtime: number, path: string }>
local function walk(dir, prefix, out)
    for _idx, name in ipairs(Fs.list(dir)) do
        if not name:find("\0", 1, true) and name ~= "." and name ~= ".." then
            local path = dir .. "/" .. name
            local rel = prefix .. name
            local mode = require("libs/libkoreader-lfs").attributes(path, "mode")
            if mode == "directory" then
                walk(path, rel .. "/", out)
            elseif mode == "file" and Plan.safeRel(rel) then
                local data = Fs.read(path)
                if data then
                    out[rel] = {
                        path = path,
                        hash = hashOf(data),
                        mtime = require("libs/libkoreader-lfs").attributes(path, "modification") or 0,
                    }
                end
            end
        end
    end
end

---@param include_fonts boolean
---@return table
local function localFiles(include_fonts)
    local out = {}
    walk(Paths.settingsDir(), "settings/", out)
    walk(Paths.root() .. "/secrets", "secrets/", out)
    if include_fonts then walk(Paths.fontsDir(), "fonts/", out) end
    return out
end

---@param dav WebdavClient
---@param path string
---@param cb fun(body: string|nil, err: string|nil, code: number|nil)
local function getText(dav, path, cb)
    local dest = Paths.tmpname(".moon-sync")
    return dav:getAsync(path, dest, {}, function(ok, err, code)
        if not ok then
            os.remove(dest)
            cb(nil, err, code)
            return
        end
        local body = Fs.read(dest)
        os.remove(dest)
        if body == nil then
            cb(nil, _("无法读取临时文件"))
            return
        end
        cb(body)
    end)
end

---@param dav WebdavClient
---@param path string
---@param data string
---@param cb fun(ok: boolean|nil, err: string|nil, code: number|nil)
---@param opts { headers?: table<string, string>, allow_empty?: boolean }|nil
local function putText(dav, path, data, cb, opts)
    if data == "" then
        cb(nil, _("待上传文件为空"))
        return nil
    end
    local dest = Paths.tmpname(".moon-sync")
    local file = io.open(dest, "wb")
    if not file or not file:write(data) or not file:close() then
        if file then file:close() end
        os.remove(dest)
        cb(nil, _("无法写入临时文件"))
        return nil
    end
    local parent = path:match("(.+)/[^/]+$")
    local current
    local function upload()
        current = dav:putFileAsync(path, dest, function(ok, err, code)
            os.remove(dest)
            cb(ok, err, code)
        end, nil, opts)
        return current
    end
    if not parent then return upload() end
    current = dav:ensurePathAsync(parent, function(ok, err)
        if not ok then
            os.remove(dest)
            cb(nil, err)
            return
        end
        upload()
    end)
    return {
        cancel = function()
            if current and current.cancel then current:cancel() end
            os.remove(dest)
        end,
    }
end

--- 封面已经在磁盘上，直接传，不先拷进临时文件。
---@param dav WebdavClient
---@param path string
---@param src string
---@param cb fun(ok: boolean|nil, err: string|nil, code: number|nil)
local function putExisting(dav, path, src, cb)
    local parent = path:match("(.+)/[^/]+$")
    local current
    local function upload()
        current = dav:putFileAsync(path, src, cb)
        return current
    end
    if not parent then return upload() end
    current = dav:ensurePathAsync(parent, function(ok, err)
        if not ok then return cb(nil, err) end
        upload()
    end)
    return {
        cancel = function()
            if current and current.cancel then current:cancel() end
        end,
    }
end

---@param items any[]
---@param step fun(item: any, cb: fun(err: string|nil)): table|nil
---@param cb fun(ok: boolean|nil, err: string|nil)
local function series(items, step, cb)
    local index = 0
    local wrapper = {}
    local function go(err)
        if wrapper.cancelled then return end
        if err then cb(nil, err); return end
        index = index + 1
        local item = items[index]
        if item == nil then cb(true); return end
        local started = false
        local sync_err, ran_sync
        local job = step(item, function(step_err)
            if not started then
                ran_sync, sync_err = true, step_err
                return
            end
            go(step_err)
        end)
        started = true
        wrapper.job = job
        if ran_sync then go(sync_err) end
    end
    function wrapper.cancel()
        wrapper.cancelled = true
        local job = wrapper.job
        if job and job.cancel then job:cancel() end
    end
    go()
    return wrapper
end

---@param report fun(text: string|nil, count: integer|nil, total: integer|nil)
---@param done fun(result: table)
---@param interactive boolean
---@return { cancel: fun() }
function Run.start(report, done, interactive)
    local MoonSync = require("moon_sync")
    local handle = {}
    local dav, root, device

    local function finish(result)
        if handle.settled or handle.cancelled then return end
        handle.settled = true
        done(result)
    end

    local function release(cb)
        local content = Lock.encode(device, os.time())
        handle.job = putText(dav, root .. "/" .. ROOT_NAME .. "/" .. Lock.DONE, content, function(wrote, write_err)
            if wrote then writeStamp(content) end
            cb(wrote, write_err)
        end)
    end

    function handle.cancel()
        if handle.cancelled then return end
        handle.cancelled = true
        local job = handle.job
        if job and job.cancel then job:cancel() end
    end

    local function fail(err)
        finish({ ok = false, err = err })
    end

    if not MoonSync.configured() then
        finish({ ok = false, err = _("未配置 WebDAV") })
        return handle
    end
    local cfg = MoonSync.config()
    dav = require("http.webdav").new({
        url = cfg.webdav_url,
        username = cfg.webdav_username,
        password = cfg.webdav_password,
    })
    root = MoonSync.path(cfg.webdav_path)
    device = require("utils.device_id").ensure()
    local source = require("source.registry").resolve("local")
    if not source then
        finish({ ok = false, err = _("未配置 WebDAV") })
        return handle
    end

    report(_("正在同步"), 0, 4)
    -- 以前把锁写在书库根上，静读天下会把它当成自己的锁。内容是本机设备 id 才删。
    local function dropLegacy(name, cb)
        handle.job = getText(dav, root .. "/" .. name, function(body)
            if handle.cancelled then return end
            if Lock.owner(body) ~= device then cb(); return end
            handle.job = dav:deleteAsync(root .. "/" .. name, function() cb() end)
        end)
    end
    local function afterBooks()
        Run.payload(handle, dav, root, report, function(payload_ok, payload_err)
            if handle.cancelled then return end
            if not payload_ok then return fail(payload_err) end
            release(function(released, release_err)
                if not released then return finish({ ok = false, err = release_err }) end
                finish({ ok = true, push_error = handle.push_error })
            end)
        end)
    end
    local function syncBooks()
        report(_("正在同步本地书"), 1, 4)
        -- manual：不吃桌面自动同步的 60 秒节流，否则唤醒经常跳过书目。
        -- 不带 force：日常回合只认 .Moon+/books.sync 和 .po，不列书库目录，跟静读天下同一套。
        -- 立即同步才 force，那是用户要的全量核对。
        local book_opts = {
            manual = true,
            on_background = function(start)
                handle.upload_started = true
                handle.job = start(function() end, function(up_err)
                    if handle.cancelled then return end
                    if up_err then return fail(up_err) end
                    afterBooks()
                end)
            end,
        }
        if interactive then book_opts.force = true end
        handle.job = source:syncBooksAsync(book_opts, function(result, sync_err)
            if handle.cancelled then return end
            if not result then return fail(sync_err) end
            handle.push_error = result.push_error
            -- on_background 在这个回调返回之后才登记。下一帧再决定要不要等上传。
            require("ui/uimanager"):nextTick(function()
                if handle.cancelled or handle.upload_started then return end
                afterBooks()
            end)
        end)
    end
    dropLegacy("syncing.lock", function()
        if handle.cancelled then return end
        dropLegacy("sync.lck", function()
            if handle.cancelled then return end
            syncBooks()
        end)
    end)
    return handle
end

--- 设置、字体、阅读数据。handle.downloaded_settings 由调用方的 upvalue 记录，这里改 handle 上的标记。
---@param handle table
---@param dav WebdavClient
---@param root string
---@param report fun(text: string|nil, count: integer|nil, total: integer|nil)
---@param cb fun(ok: boolean|nil, err: string|nil)
function Run.payload(handle, dav, root, report, cb)
    local MoonSync = require("moon_sync")
    local include_fonts = MoonSync.syncFonts()
    local manifest_path = root .. "/" .. ROOT_NAME .. "/manifest.json"
    local function syncManifest(trusted)
        handle.trusted = trusted
        report(_("正在同步设置"), 2, 4)
        handle.job = getText(dav, manifest_path, function(body, _err, code)
        if handle.cancelled then return end
        if body == nil and code ~= 404 then return cb(nil, _err) end
        if body == "" then return cb(nil, _("同步清单损坏")) end
        local remote_map = {}
        if type(body) == "string" then
            local ok, decoded = pcall(require("json").decode, body)
            if not ok or type(decoded) ~= "table" or type(decoded.files) ~= "table" then
                return cb(nil, _("同步清单损坏"))
            end
            for rel, meta in pairs(decoded.files) do
                if Plan.safeRel(rel) and type(meta) == "table" and type(meta.hash) == "string" then
                    remote_map[rel] = { hash = meta.hash, mtime = tonumber(meta.mtime) or 0 }
                end
            end
        end
        -- 没勾选字体时，字体文件留在远端清单里，这轮不下载也不覆盖。
        local planned_remote = remote_map
        if not include_fonts then
            planned_remote = {}
            for rel, meta in pairs(remote_map) do
                if rel:sub(1, 6) ~= "fonts/" then planned_remote[rel] = meta end
            end
        end
        local local_map = localFiles(include_fonts)
        local upload, download = Plan.files(local_map, planned_remote, trusted)
        handle.job = series(download, function(rel, next_item)
            local path = localPath(rel)
            if not path then next_item(); return nil end
            local parent = path:match("(.+)/[^/]+$")
            if parent then
                local ok_dir, dir_err = Paths.ensureDir(parent)
                if not ok_dir then next_item(dir_err); return nil end
            end
            if rel:sub(1, 9) == "settings/" then handle.downloaded_settings = true end
            return dav:getAsync(root .. "/" .. ROOT_NAME .. "/" .. rel, path, {}, function(ok, err)
                next_item(ok and nil or err)
            end)
        end, function(ok, err)
            if handle.cancelled then return end
            if not ok then return cb(nil, err) end
            if handle.downloaded_settings then
                require("utils.settings").reload()
                handle.downloaded_settings = false
                -- 调用方用自己的标记决定要不要再读盘。下载过设置就记在 handle 上留给收尾。
                handle.settings_reloaded = true
            end
            handle.job = series(upload, function(rel, next_item)
                local file = local_map[rel]
                local remote = root .. "/" .. ROOT_NAME .. "/" .. rel
                local parent = remote:match("(.+)/[^/]+$")
                local function upload_file()
                    return dav:putFileAsync(remote, file.path, function(put_ok, put_err)
                        next_item(put_ok and nil or put_err)
                    end, nil, { allow_empty = true })
                end
                if not parent then return upload_file() end
                return dav:ensurePathAsync(parent, function(dir_ok, dir_err)
                    if not dir_ok then next_item(dir_err); return end
                    handle.job = upload_file()
                end)
            end, function(uploaded, upload_err)
                if handle.cancelled then return end
                if not uploaded then return cb(nil, upload_err) end
                local fresh = localFiles(include_fonts)
                local files = {}
                if not trusted then
                    for rel, meta in pairs(remote_map) do
                        files[rel] = { hash = meta.hash, mtime = meta.mtime }
                    end
                end
                for rel, file in pairs(fresh) do
                    files[rel] = { hash = file.hash, mtime = file.mtime }
                end
                if trusted and not include_fonts then
                    for rel, meta in pairs(remote_map) do
                        if rel:sub(1, 6) == "fonts/" then files[rel] = { hash = meta.hash, mtime = meta.mtime } end
                    end
                end
                handle.job = putText(dav, manifest_path, require("json").encode({ files = files }), function(put_ok, put_err)
                    if handle.cancelled then return end
                    if not put_ok then return cb(nil, put_err) end
                    Run.reading(handle, dav, root, report, cb)
                end)
            end)
        end)
    end)
    end
    handle.job = getText(dav, root .. "/" .. ROOT_NAME .. "/" .. Lock.DONE, function(body, err, code)
        if handle.cancelled then return end
        if body == nil and code ~= 404 then return cb(nil, err) end
        local remote_stamp = (code == 404 or body == nil) and nil or body
        local trusted = Lock.trusted(remote_stamp, Fs.read(stampPath()))
        if trusted and remote_stamp then writeStamp(remote_stamp) end
        syncManifest(trusted)
    end)
end

--- 目录不存在就是还没有这个书源的文件。
---@param dav WebdavClient
---@param path string
---@param cb fun(entries: table[]|nil, err: string|nil)
local function listDir(dav, path, cb)
    return dav:listAsync(path, function(entries, err, code)
        if entries then return cb(entries) end
        if code == 404 then return cb({}) end
        cb(nil, err)
    end)
end

---@param dav WebdavClient
---@param path string
---@param cb fun(doc: table|nil, err: string|nil)
local function readMap(dav, path, cb)
    return getText(dav, path, function(body, err, code)
        if body == nil and code == 404 then return cb({}) end
        if type(body) ~= "string" or body == "" then return cb(nil, err or _("阅读数据损坏")) end
        local ok, decoded = pcall(require("json").decode, body)
        if not ok or type(decoded) ~= "table" then return cb(nil, _("阅读数据损坏")) end
        cb(decoded)
    end)
end

---@param books table<string, { dirty: table, stable_id: string }>
---@return table[]
local function dirtyBooks(books)
    local out = {}
    for _id, book in pairs(books) do
        if #book.dirty > 0 then out[#out + 1] = book end
    end
    table.sort(out, function(a, b) return a.stable_id < b.stable_id end)
    return out
end

--- 进度：列 Cache，比本地新的 .po 拉下来；脏行直接覆盖上传，不先读远端。
---@param handle table
---@param dav WebdavClient
---@param dir string
---@param source_id string
---@param cb fun(err: string|nil)
local function syncProgress(handle, dav, dir, source_id, cb)
    local Reading = require("moon_sync.reading")
    local job = listDir(dav, dir, function(entries, err)
        if handle.cancelled then return end
        if not entries then return cb(err) end
        local pulls = {}
        for _idx, entry in ipairs(entries) do
            local name = not entry.is_dir and entry.name:match("^([%w%%%-]+)%.po$")
            local id = name and Reading.idFromName(name)
            local updated_at, dirty = id and Reading.progressStamp(source_id, id)
            if id and handle.trusted ~= false and Reading.shouldPull(updated_at, dirty, entry.mtime) then
                pulls[#pulls + 1] = { id = id, name = name, mtime = entry.mtime }
            end
        end
        handle.job = series(pulls, function(item, next_item)
            return getText(dav, dir .. "/" .. item.name .. ".po", function(body, get_err, code)
                if handle.cancelled then return end
                if body == nil and code ~= 404 then return next_item(get_err) end
                if type(body) == "string" then Reading.applyProgress(source_id, item.id, body, item.mtime) end
                next_item()
            end)
        end, function(ok, pull_err)
            if not ok then return cb(pull_err) end
            handle.job = series(Reading.dirtyProgress(source_id), function(row, next_item)
                local name = Reading.fileName(row.stable_id)
                if not name then return next_item() end
                return putText(dav, dir .. "/" .. name .. ".po", Reading.progressLine(row), function(put_ok, put_err)
                    if not put_ok then return next_item(put_err) end
                    Reading.confirmProgress(source_id, row)
                    next_item()
                end)
            end, function(push_ok, push_err)
                if not push_ok then return cb(push_err) end
                cb()
            end)
        end)
    end)
    handle.job = job
    return job
end

--- 笔记和统计：一书一份，按设备分栏。先拉干净的书，再把脏书合并后写回。
---@param handle table
---@param dav WebdavClient
---@param dir string
---@param books table
---@param device_id string
---@param suffix string
---@param apply fun(book_id: string, doc: table, mtime: number|nil)
---@param confirm fun(book: table)
---@param cb fun(err: string|nil)
local function syncPerBook(handle, dav, dir, books, device_id, ext, apply, confirm, cb)
    local Reading = require("moon_sync.reading")
    local pattern = "^([%w%%%-]+)" .. ext:gsub("%.", "%%.") .. "$"
    local job = listDir(dav, dir, function(entries, err)
        if handle.cancelled then return end
        if not entries then return cb(err) end
        local pulls = {}
        for _idx, entry in ipairs(entries) do
            local name = not entry.is_dir and entry.name:match(pattern)
            local id = name and Reading.idFromName(name)
            local book = id and books[id]
            if id and handle.trusted ~= false and Reading.shouldPull(book and book.latest, book and #book.dirty > 0, entry.mtime) then
                pulls[#pulls + 1] = { id = id, name = name, mtime = entry.mtime }
            end
        end
        handle.job = series(pulls, function(item, next_item)
            return getText(dav, dir .. "/" .. item.name .. ext, function(body, get_err, code)
                if handle.cancelled then return end
                if body == nil and code == 404 then return next_item() end
                if type(body) ~= "string" or body == "" then return next_item(get_err or _("阅读数据损坏")) end
                local decoded_ok, doc = pcall(require("json").decode, body)
                if not decoded_ok or type(doc) ~= "table" then return next_item(_("阅读数据损坏")) end
                apply(item.id, doc, item.mtime)
                next_item()
            end)
        end, function(ok, pull_err)
            if not ok then return cb(pull_err) end
            handle.job = series(dirtyBooks(books), function(book, next_item)
                local name = Reading.fileName(book.stable_id)
                if not name then return next_item() end
                local path = dir .. "/" .. name .. ext
                return readMap(dav, path, function(remote, read_err)
                    if handle.cancelled then return end
                    if not remote then return next_item(read_err) end
                    local payload = book.rows or book.items
                    return putText(dav, path, require("json").encode(Reading.mergeDevice(remote, device_id, payload)),
                        function(put_ok, put_err)
                            if not put_ok then return next_item(put_err) end
                            confirm(book)
                            next_item()
                        end)
                end)
            end, function(push_ok, push_err)
                if not push_ok then return cb(push_err) end
                cb()
            end)
        end)
    end)
    handle.job = job
    return job
end

---@param handle table
---@param dav WebdavClient
---@param root string
---@param item { id: string, progress: boolean, notes: boolean, stats: boolean }
---@param device_id string
---@param cb fun(err: string|nil)
local function syncFallback(handle, dav, root, item, device_id, cb)
    local Reading = require("moon_sync.reading")
    local base = root .. "/" .. ROOT_NAME .. "/reading/" .. item.id
    local function after_notes(err)
        if err or handle.cancelled then return cb(err) end
        if not item.stats then return cb() end
        syncPerBook(handle, dav, base .. "/Stats", Reading.statsByBook(item.id), device_id, ".json",
            function(id, doc) Reading.applyStats(item.id, id, doc, device_id) end,
            function(book) Reading.confirmStats(book.dirty) end,
            cb)
    end
    local function after_progress(err)
        if err or handle.cancelled then return cb(err) end
        if not item.notes then return after_notes() end
        syncPerBook(handle, dav, base .. "/Notes", Reading.notesByBook(item.id), device_id, ".json",
            function(id, doc, mtime) Reading.applyNotes(item.id, id, doc, mtime) end,
            function(book) Reading.confirmNotes(item.id, book) end,
            after_notes)
    end
    if not item.progress then return after_progress() end
    return syncProgress(handle, dav, base .. "/Cache", item.id, after_progress)
end

---@param remote table<string, table>
---@param name string
---@param keep string|nil
---@return string[]
local function staleCovers(remote, name, keep)
    local out = {}
    for fname in pairs(remote) do
        local id = fname:match("^([%w%%%-]+)%.cover%.[%w]+$")
        if id == name and fname ~= keep then out[#out + 1] = fname end
    end
    table.sort(out)
    return out
end

---@param seen table
---@param key string
---@param mtime number
---@param hash string
local function remember(seen, key, mtime, hash)
    seen[key] = { mtime = mtime, hash = hash }
end

---@param handle table
---@param dav WebdavClient
---@param dir string
---@param name string
---@param doc table
---@param file_mtime number
---@param cover_path string|nil
---@param hash string
---@param remote table
---@param seen table
---@param key string
---@param next_item fun(err: string|nil)
local function pushBook(handle, dav, dir, name, doc, file_mtime, cover_path, hash, remote, seen, key, next_item)
    local payload = {
        updated_at = math.floor((file_mtime or 0) > 0 and file_mtime or os.time()),
        settings = doc.settings,
        reader_prefs = doc.reader_prefs,
        custom_metadata = doc.custom_metadata,
        cover_ext = doc.cover_ext,
        cover_hash = doc.cover_hash or "",
    }
    local keep = (cover_path and doc.cover_ext ~= "") and (name .. ".cover." .. doc.cover_ext) or nil
    return putText(dav, dir .. "/" .. name .. ".json", require("json").encode(payload), function(ok, err)
        if handle.cancelled then return end
        if not ok then return next_item(err) end
        handle.job = series(staleCovers(remote, name, keep), function(fname, done)
            return dav:deleteAsync(dir .. "/" .. fname, function(del_ok, del_err, code)
                if del_ok or code == 404 then return done() end
                done(del_err or _("书籍设置损坏"))
            end)
        end, function(del_ok, del_err)
            if handle.cancelled then return end
            if not del_ok then return next_item(del_err) end
            if not keep then
                remember(seen, key, payload.updated_at, hash)
                return next_item()
            end
            handle.job = putExisting(dav, dir .. "/" .. keep, cover_path, function(put_ok, put_err)
                if handle.cancelled then return end
                if not put_ok then return next_item(put_err) end
                remember(seen, key, payload.updated_at, hash)
                next_item()
            end)
        end)
    end)
end

---@param handle table
---@param dav WebdavClient
---@param dir string
---@param name string
---@param row table
---@param hash string
---@param remote_mtime number
---@param seen table
---@param key string
---@param prefs_only boolean
---@param next_item fun(err: string|nil)
local function pullBook(handle, dav, dir, name, row, hash, remote_mtime, seen, key, prefs_only, next_item)
    local Sdr = require("moon_sync.sdr")
    return getText(dav, dir .. "/" .. name .. ".json", function(body, get_err, code)
        if handle.cancelled then return end
        if body == nil and code == 404 then return next_item() end
        if type(body) ~= "string" or body == "" then return next_item(get_err or _("书籍设置损坏")) end
        local decoded_ok, decoded = pcall(require("json").decode, body)
        if not decoded_ok or type(decoded) ~= "table" then return next_item(_("书籍设置损坏")) end
        if prefs_only then
            if type(decoded.reader_prefs) == "string" and decoded.reader_prefs ~= "" then
                require("book.books_db").setReaderPrefs(row.source_id, row.stable_id, decoded.reader_prefs)
                row.reader_prefs = decoded.reader_prefs
            end
            local prefs_hash = Sdr.fingerprint({
                settings = {},
                reader_prefs = type(row.reader_prefs) == "string" and row.reader_prefs or "",
                custom_metadata = {},
                cover_ext = "",
                cover_hash = "",
            })
            seen[key] = { mtime = remote_mtime, hash = prefs_hash, prefs_only = true }
            return next_item()
        end
        if Sdr.fingerprint(decoded) == hash then
            remember(seen, key, remote_mtime, hash)
            return next_item()
        end
        Sdr.applyDoc(row, decoded)
        local ext = decoded.cover_ext
        if ext == nil or ext == "" then
            Sdr.removeCover(row.path)
            remember(seen, key, remote_mtime, Sdr.fingerprint(decoded))
            return next_item()
        end
        if not Sdr.coverExtOk(ext) then return next_item(_("书籍设置损坏")) end
        local dest = Paths.tmpname("." .. ext)
        handle.job = dav:getAsync(dir .. "/" .. name .. ".cover." .. ext, dest, {}, function(got, cover_err, _cover_code)
            if not got then
                os.remove(dest)
                return next_item(cover_err or _("书籍设置损坏"))
            end
            Sdr.removeCover(row.path)
            local wrote = Sdr.applyCover(row.path, dest)
            os.remove(dest)
            if not wrote then return next_item(_("书籍设置损坏")) end
            remember(seen, key, remote_mtime, Sdr.fingerprint(decoded))
            next_item()
        end)
    end)
end

---@param handle table
---@param dav WebdavClient
---@param dir string
---@param source_id string
---@param books table<string, table>
---@param seen table
---@param cb fun(err: string|nil)
local function syncSdrSource(handle, dav, dir, source_id, books, seen, cb)
    local Sdr = require("moon_sync.sdr")
    local job = listDir(dav, dir, function(entries, err)
        if handle.cancelled then return end
        if not entries then return cb(err) end
        local remote = {}
        for _i, entry in ipairs(entries) do
            if not entry.is_dir and type(entry.name) == "string" then remote[entry.name] = entry end
        end
        local names = {}
        for name in pairs(books) do names[#names + 1] = name end
        table.sort(names)
        handle.job = series(names, function(name, next_item)
            local row = books[name]
            local doc, file_mtime, cover_path, can_write = Sdr.snapshot(row)
            if not doc then
                require("utils.log").warn("moon sync: skip unreadable book settings", row.path)
                return next_item()
            end
            local hash = Sdr.fingerprint(doc)
            local entry = remote[name .. ".json"]
            local remote_mtime = entry and (tonumber(entry.mtime) or 0) or nil
            local act = Sdr.action({
                seen = seen[source_id .. "/" .. name],
                remote_mtime = remote_mtime,
                hash = hash,
                file_mtime = file_mtime,
                can_write = can_write == true,
                has_content = Sdr.hasContent(doc),
                trusted = handle.trusted,
            })
            local key = source_id .. "/" .. name
            if act == "skip" then return next_item() end
            if act == "push" then
                return pushBook(handle, dav, dir, name, doc, file_mtime, cover_path, hash, remote, seen, key, next_item)
            end
            return pullBook(handle, dav, dir, name, row, hash, remote_mtime, seen, key, act == "prefs", next_item)
        end, function(ok, step_err)
            cb(ok and nil or step_err)
        end)
    end)
    handle.job = job
    return job
end

--- 每本书一份自定义设置。没有在架的书就什么都不列。
---@param handle table
---@param dav WebdavClient
---@param root string
---@param cb fun(err: string|nil)
local function syncSdr(handle, dav, root, cb)
    local Sdr = require("moon_sync.sdr")
    local groups = Sdr.bySource(require("book.books_db").sidecarBooks())
    local seen = Sdr.loadSeen()
    local ids = {}
    for id in pairs(groups) do ids[#ids + 1] = id end
    table.sort(ids)
    local function done(err)
        Sdr.saveSeen(seen)
        cb(err)
    end
    if #ids == 0 then return done() end
    local base = root .. "/" .. ROOT_NAME .. "/sdr"
    local job = series(ids, function(id, next_item)
        return syncSdrSource(handle, dav, base .. "/" .. id, id, groups[id], seen, next_item)
    end, function(ok, err)
        done(ok and nil or err)
    end)
    handle.job = job
    return job
end

---@param handle table
---@param dav WebdavClient
---@param root string
---@param report function
---@param cb fun(ok: boolean|nil, err: string|nil)
function Run.reading(handle, dav, root, report, cb)
    local MoonSync = require("moon_sync")
    local Reading = require("moon_sync.reading")
    local jobs = {}
    if MoonSync.configured() then
        jobs[#jobs + 1] = {
            rel = "reading/local-extra.json",
            export = Reading.localExtra,
            apply = Reading.applyLocalExtra,
            merge = true,
        }
    end
    local sources = MoonSync.readingPlan()
    local function finishSources()
        if handle.cancelled then return end
        if #sources == 0 then
            report(_("正在结束"), 4, 4)
            cb(true)
            return
        end
        local device_id = require("utils.device_id").ensure()
        handle.job = series(sources, function(item, next_item)
            return syncFallback(handle, dav, root, item, device_id, next_item)
        end, function(sources_ok, sources_err)
            if sources_ok then report(_("正在结束"), 4, 4) end
            cb(sources_ok, sources_err)
        end)
    end
    local function startSdr()
        if handle.cancelled then return end
        handle.job = syncSdr(handle, dav, root, function(sdr_err)
            if handle.cancelled then return end
            if sdr_err then return cb(nil, sdr_err) end
            finishSources()
        end)
    end
    report(_("正在同步阅读数据"), 3, 4)
    if #jobs == 0 then return startSdr() end
    handle.job = series(jobs, function(job, next_item)
        local remote = root .. "/" .. ROOT_NAME .. "/" .. job.rel
        return getText(dav, remote, function(body, err, code)
            if handle.cancelled then return end
            if body == nil and code ~= 404 then return next_item(err) end
            if body == "" then return next_item(_("阅读数据损坏")) end
            local remote_data
            if type(body) == "string" then
                local ok, decoded = pcall(require("json").decode, body)
                if not ok or type(decoded) ~= "table" then return next_item(_("阅读数据损坏")) end
                remote_data = decoded
            end
            if job.merge or remote_data then job.apply(remote_data) end
            local exported = job.export() or {}
            if job.merge then exported = Reading.mergeLocalExtra(exported, remote_data) end
            local payload = require("json").encode(exported)
            handle.job = putText(dav, remote, payload, function(ok, put_err)
                if not ok then return next_item(put_err) end
                next_item()
            end)
        end)
    end, function(ok, err)
        if not ok then return cb(nil, err) end
        if handle.cancelled then return end
        startSdr()
    end)
end

return Run
