---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

--[[-- source.local.client：扫描写库 / 清失效 / 单本入库 / 导入 / 移动 / 替换 / 自动扫描节流 / 封面 --]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")

-- 虚拟目录树：.moon（插件配置/缓存）与 .hidden 都不该被扫进书库
-- sub 是第 2 层（分类）；sub/deep 是第 3 层（系列）；x4 是第 4 层，按约定不识别；bad.epub 模拟引擎解析失败
-- a.sdr 模拟 KOReader 边车目录（a.epub → a.sdr）：扫盘不当下钻；moveBook 时的迁移见 book.sidecar 桩
local DENIED_DIRS = {}
local COVERS = {}
local MTIMES = {} -- 路径 → 修改时间（默认 0）：模拟文件被改过
local TREE = {
    ["/books"] = { "a.epub", "a.sdr", ".moon", ".hidden", "sub", "note.md", "old.cbr", "x.lit" },
    ["/books/a.sdr"] = { "metadata.epub.lua" },
    ["/books/.moon"] = { "cache" },
    ["/books/.moon/cache"] = { "cached.epub" },
    ["/books/.hidden"] = { "b.epub" },
    ["/books/sub"] = { "c.pdf", "d.djvu", "deep", "bad.epub" },
    ["/books/sub/deep"] = { "e.epub", "x4" },
    ["/books/sub/deep/x4"] = { "f.epub" },
}
local DIRS = {
    ["/books"] = true,
    ["/books/a.sdr"] = true,
    ["/books/.moon"] = true,
    ["/books/.moon/cache"] = true,
    ["/books/.hidden"] = true,
    ["/books/sub"] = true,
    ["/books/sub/deep"] = true,
    ["/books/sub/deep/x4"] = true,
}

local dirs_scanned = {}
package.preload["libs/libkoreader-lfs"] = function()
    return {
        dir = function(path)
            dirs_scanned[#dirs_scanned + 1] = path
            if DENIED_DIRS[path] then error("cannot open " .. path .. ": Permission denied") end
            local entries = TREE[path] or {}
            local i = 0
            return function()
                i = i + 1
                return entries[i]
            end, {}
        end,
        attributes = function(path, request)
            local attr
            if COVERS[path] then
                attr = { mode = "file", size = 10, modification = 0 }
            elseif DIRS[path] then
                attr = { mode = "directory", size = 0, modification = 0 }
            else
                for dir, entries in pairs(TREE) do
                    for _, name in ipairs(entries) do
                        if dir .. "/" .. name == path then
                            attr = { mode = "file", size = 10, modification = MTIMES[path] or 0 }
                            break
                        end
                    end
                    if attr then
                        break
                    end
                end
            end
            -- 与真实 lfs 一致：第二参为字段名时只回该字段
            if attr and type(request) == "string" then
                return attr[request]
            end
            -- 封面缓存等其它路径一律不存在
            return attr
        end,
        mkdir = function()
            return true
        end,
        symlinkattributes = function(path, request)
            return require("libs/libkoreader-lfs").attributes(path, request)
        end,
    }
end

-- KOReader 按路径记的状态（.sdr / 阅读历史 / 收藏）由 book.sidecar 负责，这里只记调用；sidecar_fail 模拟 .sdr 搬不动
local sidecar_moves, sidecar_fail = {}, nil
package.preload["book.sidecar"] = function()
    return {
        move = function(old_path, new_path)
            sidecar_moves[#sidecar_moves + 1] = { old_path, new_path }
            if sidecar_fail then return false, sidecar_fail end
            return true
        end,
    }
end

package.preload["utils.paths"] = function()
    return {
        ensureDir = function() return true end,
        root = function()
            return "/data/.moon"
        end,
        imageDir = function(id)
            return "/data/.moon/cache/" .. tostring(id) .. "/image"
        end,
        coverPath = function(stable_id, id)
            return "/data/.moon/cache/" .. tostring(id) .. "/image/" .. tostring(stable_id) .. ".png"
        end,
    }
end

-- local_scan 表：内存假实现，跨 Client 实例保留（= 重启后库还在）
local scan_rows = {}
package.preload["source.local.scan_db"] = function()
    return {
        all = function()
            local out = {}
            for path, row in pairs(scan_rows) do out[path] = { fp = row.fp, md5 = row.md5, cover = row.cover } end
            return out
        end,
        save = function(_, files)
            scan_rows = {}
            for _, f in ipairs(files) do
                scan_rows[f.path] = { fp = f.fp, md5 = f.md5, cover = f.cover_tried == true }
            end
            return true
        end,
    }
end

-- util.partialMD5 读文件内容算摘要：测试环境里没有真实文件，io.open 一律失败 → digest 恒为 nil，
-- 等同于关闭改名识别分支，测试可专注在其它路径上（改名识别单独在下方测试块覆盖）。

local opened = {}
local covers_saved = {}
local props_read = 0
package.preload["document/documentregistry"] = function()
    return {
        hasProvider = function(_, path)
            return path ~= "/books/sub/bad.epub"
        end,
        -- 注意：冒号调用，首参是 self（曾因此 stub 写成 function(path) 导致断言全炸）
        openDocument = function(_, path)
            opened[#opened + 1] = path
            return {
                getProps = function()
                    props_read = props_read + 1
                    return { title = "T:" .. path, authors = "A:" .. path, description = "D:" .. path }
                end,
                getCoverPageImage = function()
                    return {
                        getWidth = function() return 100 end,
                        getHeight = function() return 150 end,
                        writePNG = function(_, tmp)
                            covers_saved[#covers_saved + 1] = tmp
                            return true
                        end,
                        free = function() end,
                    }
                end,
                close = function() end,
            }
        end,
    }
end

--- 测试内用复合键 "source_id\1stable_id" 模拟 (source_id, stable_id) 主键。
---@param source_id string
---@param stable_id string
---@return string
local function rowKey(source_id, stable_id)
    return tostring(source_id) .. "\1" .. tostring(stable_id)
end

local db_rows = {}
local upserts = {}
local removed = {}
local renames = {}

-- 扫描走子进程（workers.job）：离线测试不 fork，worker 就地同步跑，
-- progress 直接转给 on_progress，结果经 nextTick 交 on_done 保持异步语义。
-- 子进程不碰 sqlite 的约束由 utils.db 在真机上强制，这里的 book.books_db 全是内存假实现。
-- CRASH_AT 里的书一开打就模拟引擎段错误：子进程死亡，父进程只收到 "job exited without result"。
local CRASH_AT = {}
local job_runs = 0
package.preload["workers.job"] = function()
    return {
        run = function(worker, opts)
            opts = opts or {}
            job_runs = job_runs + 1
            local ok, result = pcall(worker, function(value)
                if opts.on_progress then opts.on_progress(value) end
                if value and CRASH_AT[value] then error("job exited without result") end
            end)
            require("ui/uimanager"):nextTick(function()
                if ok then
                    if opts.on_done then
                        opts.on_done(result)
                    end
                elseif opts.on_failed then
                    opts.on_failed(result)
                end
            end)
            return { cancel = function() end }
        end,
    }
end
package.preload["book.books_db"] = function()
    return {
        get = function(source_id, stable_id)
            return db_rows[rowKey(source_id, stable_id)]
        end,
        getMany = function(source_id, stable_ids)
            local out = {}
            for _, stable_id in ipairs(stable_ids) do
                local row = db_rows[rowKey(source_id, stable_id)]
                if row then out[stable_id] = row end
            end
            return out
        end,
        stableIdsByMd5 = function(source_id, md5)
            local out = {}
            for _, row in pairs(db_rows) do
                if row.source_id == source_id and row.md5 == md5 and (row.deleted or 0) == 0 then
                    out[#out + 1] = row.stable_id
                end
            end
            table.sort(out)
            return out
        end,
        renameStableId = function(source_id, old_stable_id, new_stable_id, category, series)
            renames[#renames + 1] = { source_id, old_stable_id, new_stable_id }
            -- 与真实 sqlite 一致：新 stable_id 已有行（含墓碑）时主键冲突，整笔回滚
            if db_rows[rowKey(source_id, new_stable_id)] then return false end
            local row = db_rows[rowKey(source_id, old_stable_id)]
            if row then
                db_rows[rowKey(source_id, old_stable_id)] = nil
                row.stable_id = new_stable_id
                row.category = category
                row.series = series
                db_rows[rowKey(source_id, new_stable_id)] = row
            end
            return true
        end,
        upsert = function(row)
            upserts[#upserts + 1] = row
            row.deleted = 0
            db_rows[rowKey(row.source_id, row.stable_id)] = row
            return true
        end,
        stableIdsBySource = function(source_id)
            local out = {}
            for _, row in pairs(db_rows) do
                if row.source_id == source_id then
                    out[#out + 1] = row.stable_id
                end
            end
            table.sort(out)
            return out
        end,
        remove = function(source_id, stable_id)
            removed[#removed + 1] = stable_id
            db_rows[rowKey(source_id, stable_id)] = nil
            return true
        end,
        setLibraryMembership = function(source_id, stable_id, on_shelf, clear_path)
            local row = db_rows[rowKey(source_id, stable_id)]
            if row then
                row.deleted = on_shelf and 0 or 1
                if clear_path and not on_shelf then row.path = nil end
            end
            if not on_shelf then removed[#removed + 1] = stable_id end
            return true
        end,
        reconcile = function(source_id, rows, opts)
            local keep = {}
            for _, row in ipairs(rows) do
                keep[row.stable_id] = true
                local old = db_rows[rowKey(source_id, row.stable_id)] or {}
                for key, value in pairs(row) do old[key] = value end
                old.source_id = source_id
                old.deleted = 0
                db_rows[rowKey(source_id, row.stable_id)] = old
                upserts[#upserts + 1] = row
            end
            for _, row in pairs(db_rows) do
                if row.source_id == source_id and not keep[row.stable_id] then
                    row.deleted = 1
                    if opts and opts.clear_missing_paths then row.path = nil end
                    removed[#removed + 1] = row.stable_id
                end
            end
            return true
        end,
        markSyncedMany = function(source_id, stable_ids)
            for _, stable_id in ipairs(stable_ids) do
                db_rows[rowKey(source_id, stable_id)].sync_status = 1
            end
            return true
        end,
    }
end
for _, name in ipairs({
    "libs/libkoreader-lfs",
    "utils.paths",
    "document/documentregistry",
    "utils.task",
    "book.books_db",
    "source.local.scan_db",
    "source.local.client",
}) do
    package.loaded[name] = nil
end

local Client = require("source.local.client")

-- 可控时钟：自动扫描节流断言用
local real_time = os.time
local real_remove = os.remove
local now = 1000
os.time = function()
    return now
end

local removed_files = {}
os.remove = function(path)
    removed_files[#removed_files + 1] = path
    COVERS[path] = nil
    return true
end

local function hasValue(t, v)
    for _, x in ipairs(t) do
        if x == v then
            return true
        end
    end
    return false
end

local function reset()
    db_rows = {}
    upserts = {}
    removed = {}
    renames = {}
    opened = {}
    covers_saved = {}
    props_read = 0
    dirs_scanned = {}
    removed_files = {}
    CRASH_AT = {}
    job_runs = 0
    scan_rows = {}
end

-- ── 子目录列不出来：记日志跳过，扫盘照常成功；其下原有的书当“未知”保留，不软删 ──────
do
    reset()
    db_rows[rowKey("local", "/books/sub/c.pdf")] = {
        source_id = "local", stable_id = "/books/sub/c.pdf", title = "c", path = "/books/sub/c.pdf",
        deleted = 0, sync_status = 1,
    }
    db_rows[rowKey("local", "/books/gone.epub")] = {
        source_id = "local", stable_id = "/books/gone.epub", title = "gone", path = "/books/gone.epub",
        deleted = 0, sync_status = 1,
    }
    local log, warns = require("utils.log"), {}
    local realWarn = log.warn
    log.warn = function(...) warns[#warns + 1] = table.concat({ ... }, " ") end
    DENIED_DIRS["/books/sub"] = true
    local ok, err
    Client.new({ path = "/books" }):scanAsync(function(o, e) ok, err = o, e end)
    Stubs.flush()
    DENIED_DIRS["/books/sub"] = nil
    log.warn = realWarn
    Assert.is_true(ok)
    Assert.is_nil(err)
    Assert.matches(table.concat(warns, "\n"), "book local scan skip unreadable dir /books/sub")
    Assert.matches(table.concat(warns, "\n"), "Permission denied")
    -- 读不了的目录里的书原样在架
    local c = db_rows[rowKey("local", "/books/sub/c.pdf")]
    Assert.eq(c.deleted, 0)
    Assert.eq(c.path, "/books/sub/c.pdf")
    Assert.is_false(hasValue(removed, "/books/sub/c.pdf"))
    -- 可读的兄弟照扫，真没了的照下架
    Assert.eq(db_rows[rowKey("local", "/books/a.epub")].deleted, 0)
    Assert.is_true(hasValue(removed, "/books/gone.epub"))
end

-- ── 扫盘 → 解析写库（失败回退文件名）→ 清失效 ──────
do
    reset()
    db_rows[rowKey("local", "/books/gone.epub")] = { source_id = "local", stable_id = "/books/gone.epub", title = "gone" }

    local ok, err
    Client.new({ path = "/books" }):scanAsync(function(o, e)
        ok, err = o, e
    end)
    Stubs.flush()
    Assert.is_true(ok)
    Assert.is_nil(err)
    -- 白名单内 6 本进完整快照：a.epub / note.md / c.pdf / d.djvu / bad.epub / e.epub（第 3 层）
    Assert.len(upserts, 6)
    Assert.is_true(#dirs_scanned > 0)
    -- 第 4 层不识别
    Assert.is_nil(db_rows[rowKey("local", "/books/sub/deep/x4/f.epub")])
    Assert.is_false(hasValue(dirs_scanned, "/books/sub/deep/x4"))
    -- KOReader .sdr 边车目录不下钻、不入库
    Assert.is_false(hasValue(dirs_scanned, "/books/a.sdr"))
    Assert.is_nil(db_rows[rowKey("local", "/books/a.sdr/metadata.epub.lua")])
    -- 白名单外与隐藏项不入库
    Assert.is_nil(db_rows[rowKey("local", "/books/old.cbr")])
    Assert.is_nil(db_rows[rowKey("local", "/books/.hidden/b.epub")])
    -- 解析成功的 5 本带元数据；第 1 层无分类，第 2 层分类 = 一级子目录名
    local a = db_rows[rowKey("local", "/books/a.epub")]
    Assert.eq(a.title, "T:/books/a.epub")
    Assert.eq(a.authors, "A:/books/a.epub")
    Assert.eq(a.path, "/books/a.epub")
    Assert.is_nil(a.category)
    Assert.is_nil(a.series)
    Assert.eq(a.sync_status, 1, "扫到即确认，文件被外部删掉后下轮才会下架")
    local cpdf = db_rows[rowKey("local", "/books/sub/c.pdf")]
    Assert.eq(cpdf.category, "sub")
    Assert.is_nil(cpdf.series)
    -- 第 3 层：category 继承一级目录，series = 二级子目录名
    local e = db_rows[rowKey("local", "/books/sub/deep/e.epub")]
    Assert.not_nil(e)
    Assert.eq(e.category, "sub")
    Assert.eq(e.series, "deep")
    -- 引擎解析失败（bad.epub）回退文件名入库，不丢书
    local bad = db_rows[rowKey("local", "/books/sub/bad.epub")]
    Assert.not_nil(bad)
    Assert.eq(bad.title, "bad")
    -- 失效书只退出书架，身份与历史仍保留；存活书不动
    Assert.is_true(hasValue(removed, "/books/gone.epub"))
    Assert.not_nil(db_rows[rowKey("local", "/books/gone.epub")])
    Assert.eq(db_rows[rowKey("local", "/books/gone.epub")].deleted, 1)
    Assert.is_nil(db_rows[rowKey("local", "/books/gone.epub")].path)
    Assert.is_false(hasValue(removed_files, "/data/.moon/cache/local/image//books/gone.epub.png"))
    Assert.not_nil(db_rows[rowKey("local", "/books/a.epub")])
    -- 封面：解析成功的 5 本都尝试提取（bad.epub 无引擎不提取）
    Assert.len(covers_saved, 5)
end

-- ── 已有行缺少作者/简介时，扫描必须补齐元数据，不能被 title 命中永久冻结 ──
do
    reset()
    db_rows[rowKey("local", "/books/a.epub")] = {
        source_id = "local", stable_id = "/books/a.epub", title = "旧书名",
    }
    Client.new({ path = "/books" }):scanAsync(function() end)
    Stubs.flush()
    local a = db_rows[rowKey("local", "/books/a.epub")]
    Assert.eq(a.title, "T:/books/a.epub")
    Assert.eq(a.authors, "A:/books/a.epub")
    Assert.eq(a.intro, "D:/books/a.epub")
end

-- ── 改名识别：新路径按内容 md5 命中旧行时原地改 stable_id，不当新书插入 ──────
do
    reset()
    db_rows[rowKey("local", "/books/old_name.epub")] = {
        source_id = "local", stable_id = "/books/old_name.epub", md5 = "digest-a", title = "已有元数据",
    }
    local BookDB = require("book.books_db")
    -- 模拟扫描发现同 md5 的新路径（partialMD5 在此测试环境恒为 nil，直接调用 DB 层验证原地改名的效果）
    local by_md5 = BookDB.stableIdsByMd5("local", "digest-a")
    Assert.eq(by_md5[1], "/books/old_name.epub")
    -- 文件移进 sub/deep：category/series 由新位置派生，随 stable_id 一并刷新
    BookDB.renameStableId("local", by_md5[1], "/books/sub/deep/new_name.epub", "sub", "deep")
    Assert.is_nil(db_rows[rowKey("local", "/books/old_name.epub")])
    local renamed = db_rows[rowKey("local", "/books/sub/deep/new_name.epub")]
    Assert.not_nil(renamed)
    Assert.eq(renamed.title, "已有元数据")
    Assert.eq(renamed.md5, "digest-a")
    Assert.eq(renamed.category, "sub")
    Assert.eq(renamed.series, "deep")
    Assert.eq(#renames, 1)
end

-- ── 扫盘内的 md5 改名识别：只有旧文件已消失且新路径无任何行才改名 ──────
do
    local util = require("util")
    local real_md5 = util.partialMD5
    local digests = {}
    util.partialMD5 = function(path) return digests[path] end

    --- 跑一次全量扫描，返回 ok, err
    local function scan()
        local ok, err
        Client.new({ path = "/books" }):scanAsync(function(o, e) ok, err = o, e end)
        Stubs.flush()
        return ok, err
    end

    -- 真移动：旧路径已不在盘上，新路径无行 → 原地改名，继承旧行
    reset()
    digests = { ["/books/a.epub"] = "m" }
    db_rows[rowKey("local", "/books/gone.epub")] = {
        source_id = "local", stable_id = "/books/gone.epub", md5 = "m", title = "旧", inserted_at = 7,
    }
    Assert.is_true(scan())
    Assert.len(renames, 1)
    Assert.is_nil(db_rows[rowKey("local", "/books/gone.epub")])
    Assert.eq(db_rows[rowKey("local", "/books/a.epub")].inserted_at, 7)

    -- 同内容副本并存且其一元数据残缺（不在 known）：不能把另一本改名过来撞主键
    reset()
    digests = { ["/books/a.epub"] = "dup", ["/books/sub/c.pdf"] = "dup" }
    db_rows[rowKey("local", "/books/a.epub")] = {
        source_id = "local", stable_id = "/books/a.epub", md5 = "dup",
        title = "a", authors = "x", intro = "y", deleted = 0,
    }
    db_rows[rowKey("local", "/books/sub/c.pdf")] = {
        source_id = "local", stable_id = "/books/sub/c.pdf", md5 = "dup", title = "c", deleted = 0,
    }
    local ok, err = scan()
    Assert.is_true(ok)
    Assert.is_nil(err)
    Assert.len(renames, 0)
    Assert.eq(db_rows[rowKey("local", "/books/a.epub")].deleted, 0)
    Assert.eq(db_rows[rowKey("local", "/books/sub/c.pdf")].deleted, 0)

    -- 同内容副本还在盘上时移走另一本：收编被移走的那本（排序靠前的在盘副本不能挡住它），副本不动
    reset()
    digests = { ["/books/a.epub"] = "m", ["/books/sub/c.pdf"] = "m" }
    db_rows[rowKey("local", "/books/sub/c.pdf")] = {
        source_id = "local", stable_id = "/books/sub/c.pdf", md5 = "m", title = "副本", deleted = 0,
    }
    db_rows[rowKey("local", "/books/zz_gone.epub")] = {
        source_id = "local", stable_id = "/books/zz_gone.epub", md5 = "m", title = "被移走", deleted = 0,
        inserted_at = 7,
    }
    Assert.is_true(scan())
    Assert.len(renames, 1)
    Assert.eq(renames[1][2], "/books/zz_gone.epub")
    Assert.eq(renames[1][3], "/books/a.epub")
    Assert.eq(db_rows[rowKey("local", "/books/a.epub")].inserted_at, 7)
    Assert.is_nil(db_rows[rowKey("local", "/books/zz_gone.epub")])
    Assert.eq(db_rows[rowKey("local", "/books/sub/c.pdf")].title, "副本")
    Assert.eq(db_rows[rowKey("local", "/books/sub/c.pdf")].deleted, 0)

    -- 新路径是墓碑：旧文件虽已消失，也不改名，墓碑由快照复活
    reset()
    digests = { ["/books/a.epub"] = "m" }
    db_rows[rowKey("local", "/books/gone.epub")] = {
        source_id = "local", stable_id = "/books/gone.epub", md5 = "m", title = "旧",
    }
    db_rows[rowKey("local", "/books/a.epub")] = {
        source_id = "local", stable_id = "/books/a.epub", md5 = "m", title = "a", deleted = 1,
    }
    Assert.is_true(scan())
    Assert.len(renames, 0)
    Assert.eq(db_rows[rowKey("local", "/books/a.epub")].deleted, 0)

    -- 旧行是墓碑（用户删过的书）：同内容新文件当新书入库，不收编墓碑复活旧书的进度笔记
    reset()
    digests = { ["/books/a.epub"] = "m" }
    db_rows[rowKey("local", "/books/deleted.epub")] = {
        source_id = "local", stable_id = "/books/deleted.epub", md5 = "m", title = "删过", deleted = 1,
    }
    Assert.is_true(scan())
    Assert.len(renames, 0)
    Assert.eq(db_rows[rowKey("local", "/books/deleted.epub")].deleted, 1)
    Assert.eq(db_rows[rowKey("local", "/books/a.epub")].deleted, 0)

    util.partialMD5 = real_md5
end

-- ── 增量扫盘：文件指纹（大小:修改时间）没变就不重算 md5、不重开文档；盘与库一致整轮不写库 ──────
do
    local util = require("util")
    local real_md5 = util.partialMD5
    local hashed = {}
    util.partialMD5 = function(path)
        hashed[#hashed + 1] = path
        return "md5:" .. path
    end

    reset()
    local c = Client.new({ path = "/books" })
    c:scanAsync(function() end)
    Stubs.flush()
    Assert.len(opened, 5)
    Assert.eq(props_read, 5)
    Assert.len(hashed, 6)
    db_rows[rowKey("local", "/books/a.epub")].percent = 42

    -- 同一会话再扫：不算 md5、不开文档、不写库
    opened, upserts, removed, hashed, dirs_scanned = {}, {}, {}, {}, {}
    local ok
    c:scanAsync(function(v) ok = v end)
    Stubs.flush()
    Assert.is_true(ok)
    Assert.is_true(#dirs_scanned > 0)
    Assert.len(hashed, 0)
    Assert.len(opened, 0)
    Assert.eq(props_read, 5)
    Assert.len(upserts, 0, "盘与库一致：不 reconcile")
    Assert.eq(db_rows[rowKey("local", "/books/a.epub")].percent, 42)

    -- 重启（新实例读回索引）：本身没封面的书不再为补封面重开，md5 也不重算
    c = Client.new({ path = "/books" })
    c:scanAsync(function() end)
    Stubs.flush()
    Assert.len(opened, 0)
    Assert.len(hashed, 0)

    -- 改过一本（修改时间变了）：只重算它的 md5；内容没变就仍不开文档
    MTIMES["/books/sub/c.pdf"] = 99
    c:scanAsync(function() end)
    Stubs.flush()
    Assert.eq(table.concat(hashed, ","), "/books/sub/c.pdf")
    Assert.len(opened, 0)
    MTIMES = {}

    -- 库里的书被外部下架（或盘上少了一本）：不一致就照常整轮写库
    db_rows[rowKey("local", "/books/a.epub")].deleted = 1
    c:scanAsync(function() end)
    Stubs.flush()
    Assert.eq(db_rows[rowKey("local", "/books/a.epub")].deleted, 0)
    Assert.len(upserts, 6)

    -- 索引丢了：退回旧行为，缺封面的书补提一次，元数据不重解析
    scan_rows = {}
    COVERS["/data/.moon/cache/local/image//books/a.epub.png"] = true
    c = Client.new({ path = "/books" })
    opened, covers_saved, hashed = {}, {}, {}
    c:scanAsync(function() end)
    Stubs.flush()
    Assert.len(hashed, 6)
    Assert.len(opened, 4)
    Assert.is_false(hasValue(opened, "/books/a.epub"))
    Assert.eq(props_read, 5)
    Assert.len(covers_saved, 4)

    opened = {}
    c:scanAsync(function() end)
    Stubs.flush()
    COVERS = {}
    Assert.len(opened, 0)

    -- 解析过（有 md5）但书本身没有作者/简介：不因缺字段每轮重解析
    reset()
    db_rows[rowKey("local", "/books/a.epub")] = {
        source_id = "local", stable_id = "/books/a.epub", md5 = "md5:/books/a.epub", title = "只有书名",
    }
    COVERS["/data/.moon/cache/local/image//books/a.epub.png"] = true
    Client.new({ path = "/books" }):scanAsync(function() end)
    Stubs.flush()
    COVERS = {}
    Assert.is_false(hasValue(opened, "/books/a.epub"))
    Assert.eq(db_rows[rowKey("local", "/books/a.epub")].title, "只有书名")

    util.partialMD5 = real_md5
end

-- ── 关闭「按文件夹分类」：不由目录派生分类 / 系列（手动编辑保留），第 4 层也收；再打开时按目录重算 ──────
do
    reset()
    db_rows[rowKey("local", "/books/sub/c.pdf")] = {
        source_id = "local", stable_id = "/books/sub/c.pdf", title = "c", path = "/books/sub/c.pdf",
        md5 = "md5", category = "手动", deleted = 0, sync_status = 1,
    }
    Client.new({ path = "/books", folder_category = false }):scanAsync(function() end)
    Stubs.flush()
    Assert.eq(db_rows[rowKey("local", "/books/sub/c.pdf")].category, "手动", "关闭时扫盘不覆盖手动分类")
    Assert.is_nil(db_rows[rowKey("local", "/books/sub/deep/e.epub")].series)
    Assert.not_nil(db_rows[rowKey("local", "/books/sub/deep/x4/f.epub")])
    upserts = {}
    Client.new({ path = "/books" }):scanAsync(function() end)
    Stubs.flush()
    Assert.is_true(#upserts > 0, "分类与目录不一致不走 upToDate 快路径")
    Assert.eq(db_rows[rowKey("local", "/books/sub/c.pdf")].category, "sub")
end

-- ── 同路径换了文件（删书后拷入同名新书）：删旧封面重提、刷新元数据、绕过位图缓存 ──────
do
    local util = require("util")
    local real_md5 = util.partialMD5
    local invalidated = {}
    package.loaded["ui.themes.widgets.image"] = {
        invalidate = function(path) invalidated[#invalidated + 1] = path end,
    }
    local cover = "/data/.moon/cache/local/image//books/a.epub.png"

    -- 内容没变：封面已缓存照旧跳过
    reset()
    util.partialMD5 = function() return "old" end
    db_rows[rowKey("local", "/books/a.epub")] = {
        source_id = "local", stable_id = "/books/a.epub", md5 = "old", deleted = 1, sync_status = 0,
        title = "旧书", authors = "旧作者", intro = "旧简介", inserted_at = 7,
    }
    COVERS[cover] = true
    Client.new({ path = "/books" }):scanAsync(function() end)
    Stubs.flush()
    Assert.is_false(hasValue(opened, "/books/a.epub"))
    Assert.is_false(hasValue(removed_files, cover))
    Assert.len(invalidated, 0)

    -- 内容变了：全量扫盘
    reset()
    util.partialMD5 = function(path) return path == "/books/a.epub" and "new" or nil end
    db_rows[rowKey("local", "/books/a.epub")] = {
        source_id = "local", stable_id = "/books/a.epub", md5 = "old", deleted = 1, sync_status = 0,
        title = "旧书", authors = "旧作者", intro = "旧简介", inserted_at = 7,
    }
    COVERS[cover] = true
    Client.new({ path = "/books" }):scanAsync(function() end)
    Stubs.flush()
    Assert.is_true(hasValue(removed_files, cover))
    Assert.is_true(hasValue(opened, "/books/a.epub"))
    Assert.is_true(hasValue(covers_saved, cover .. ".part"))
    local a = db_rows[rowKey("local", "/books/a.epub")]
    Assert.eq(a.md5, "new")
    Assert.eq(a.title, "T:/books/a.epub")
    Assert.eq(a.deleted, 0)
    Assert.eq(invalidated[1], cover)
    Assert.len(renames, 0)

    -- 内容变了：单本入库（导入同名文件）同样重提
    reset()
    invalidated = {}
    db_rows[rowKey("local", "/books/a.epub")] = {
        source_id = "local", stable_id = "/books/a.epub", md5 = "old", deleted = 1,
        title = "旧书", authors = "旧作者", intro = "旧简介",
    }
    COVERS[cover] = true
    local ok
    Client.new({ path = "/books" }):indexOneAsync("/books/a.epub", function(o) ok = o end)
    Stubs.flush()
    Assert.is_true(ok)
    Assert.is_true(hasValue(removed_files, cover))
    Assert.eq(opened[1], "/books/a.epub")
    Assert.eq(db_rows[rowKey("local", "/books/a.epub")].title, "T:/books/a.epub")
    Assert.eq(invalidated[1], cover)

    COVERS = {}
    package.loaded["ui.themes.widgets.image"] = nil
    util.partialMD5 = real_md5
end

-- ── 子进程死在某本书的引擎里：跳过它重扫，其余书照常入库，坏书按文件名入库 ──────
do
    reset()
    CRASH_AT["/books/sub/c.pdf"] = true
    local ok, err
    local c = Client.new({ path = "/books" })
    c:scanAsync(function(o, e) ok, err = o, e end)
    Stubs.flush()
    Assert.is_true(ok)
    Assert.is_nil(err)
    Assert.eq(job_runs, 2)
    Assert.eq(db_rows[rowKey("local", "/books/sub/c.pdf")].title, "c")
    Assert.eq(db_rows[rowKey("local", "/books/sub/deep/e.epub")].title, "T:/books/sub/deep/e.epub")

    -- 同一会话再扫：不再打开坏书，不再崩溃重来
    job_runs, opened = 0, {}
    c:scanAsync(function(o, e) ok, err = o, e end)
    Stubs.flush()
    Assert.is_true(ok)
    Assert.eq(job_runs, 1)
    Assert.is_false(hasValue(opened, "/books/sub/c.pdf"))

    -- 两本坏书：逐本跳过，最终收敛
    reset()
    CRASH_AT["/books/a.epub"] = true
    CRASH_AT["/books/sub/deep/e.epub"] = true
    Client.new({ path = "/books" }):scanAsync(function(o, e) ok, err = o, e end)
    Stubs.flush()
    Assert.is_true(ok)
    Assert.eq(job_runs, 3)
    Assert.eq(db_rows[rowKey("local", "/books/a.epub")].title, "a")

    -- 不在打开文档时失败（如书库根列不出来）：不重试，照常报错
    reset()
    DENIED_DIRS["/books"] = true
    Client.new({ path = "/books" }):scanAsync(function(o, e) ok, err = o, e end)
    Stubs.flush()
    DENIED_DIRS["/books"] = nil
    Assert.is_false(ok)
    Assert.eq(job_runs, 1)
end

-- ── 单本入库：只解析目标文件，不扫盘、不清失效 ──────
do
    reset()
    db_rows[rowKey("local", "/books/gone.epub")] = {
        source_id = "local", stable_id = "/books/gone.epub", title = "gone",
    }
    local ok, err
    Client.new({ path = "/books" }):indexOneAsync("/books/a.epub", function(o, e)
        ok, err = o, e
    end)
    Stubs.flush()
    Assert.is_true(ok)
    Assert.is_nil(err)
    Assert.len(dirs_scanned, 0)
    Assert.len(opened, 1)
    Assert.eq(opened[1], "/books/a.epub")
    local a = db_rows[rowKey("local", "/books/a.epub")]
    Assert.not_nil(a)
    Assert.eq(a.title, "T:/books/a.epub")
    Assert.eq(a.path, "/books/a.epub")
    Assert.is_nil(a.category)
    Assert.is_nil(a.series)
    -- 其它库内行不受影响（无 prune）
    Assert.not_nil(db_rows[rowKey("local", "/books/gone.epub")])
    Assert.len(removed, 0)

    -- 非法扩展名 / 空路径
    ok, err = true, nil
    Client.new({ path = "/books" }):indexOneAsync("/books/old.cbr", function(o, e)
        ok, err = o, e
    end)
    Stubs.flush()
    Assert.is_nil(ok)
    Assert.not_nil(err)

    ok, err = true, nil
    Client.new({ path = "/books" }):indexOneAsync("", function(o, e)
        ok, err = o, e
    end)
    Stubs.flush()
    Assert.is_nil(ok)
    Assert.not_nil(err)
end

-- ── importAsync：文件名消毒 + 重名避让 + 入库；rename 由 os.rename 打桩 ──────
do
    reset()
    local real_rename = os.rename
    local renamed = {}
    os.rename = function(from, to)
        -- 只记书籍落位（封面 PNG 的 .part→.png 改名也在此钩子上，滤掉）
        if tostring(to):match("%.epub$") then
            renamed[#renamed + 1] = { from, to }
        end
        return true
    end

    -- 文件名含路径分隔符 → 消毒下划线
    local ok, err
    Client.new({ path = "/books" }):importAsync("/tmp/dl.epub", "sub/a.epub", function(o, e)
        ok, err = o, e
    end)
    Stubs.flush()
    Assert.is_true(ok)
    Assert.is_nil(err)
    Assert.eq(#renamed, 1)
    Assert.eq(renamed[1][1], "/tmp/dl.epub")
    Assert.eq(renamed[1][2], "/books/sub_a.epub")
    local row = db_rows[rowKey("local", "/books/sub_a.epub")]
    Assert.not_nil(row)
    Assert.eq(row.path, "/books/sub_a.epub")
    Assert.is_nil(row.category)
    Assert.is_nil(row.series)

    -- 与库内已有文件重名 → 加 " (2)"
    ok, err = nil, nil
    Client.new({ path = "/books" }):importAsync("/tmp/dl2.epub", "a.epub", function(o, e)
        ok, err = o, e
    end)
    Stubs.flush()
    Assert.is_true(ok)
    Assert.eq(#renamed, 2)
    Assert.eq(renamed[2][2], "/books/a (2).epub")
    Assert.not_nil(db_rows[rowKey("local", "/books/a (2).epub")])

    -- 未配置路径：报错（下一帧回调），不碰文件
    ok, err = true, nil
    Client.new({}):importAsync("/tmp/dl.epub", "x.epub", function(o, e)
        ok, err = o, e
    end)
    Assert.is_true(ok, "失败也不得同步回调")
    Stubs.flush()
    Assert.is_nil(ok)
    Assert.not_nil(err)
    Assert.eq(#renamed, 2)

    -- 空文件名：消毒前即为空，报错
    ok, err = true, nil
    Client.new({ path = "/books" }):importAsync("/tmp/dl.epub", "", function(o, e)
        ok, err = o, e
    end)
    Stubs.flush()
    Assert.is_nil(ok)
    Assert.eq(err, "无效文件名")

    -- 无扩展名文件名：落位后由 indexOneAsync 拒绝（异步）
    ok, err = true, nil
    Client.new({ path = "/books" }):importAsync("/tmp/dl.epub", "  ", function(o, e)
        ok, err = o, e
    end)
    Stubs.flush()
    Assert.is_nil(ok)
    Assert.eq(err, "不支持的文件格式")

    os.rename = real_rename
end

-- ── importAsync 跨设备复制：close 刷盘失败（磁盘满）要报错并删掉半截文件，不入库 ──
do
    reset()
    local real_rename, real_open, real_remove = os.rename, io.open, os.remove
    local removed = {}
    os.rename = function() return nil, "cross-device" end
    os.remove = function(p) removed[#removed + 1] = p; return true end
    io.open = function(path, mode)
        if path == "/tmp/full.epub" then
            local sent = false
            return { read = function() if sent then return nil end sent = true; return "data" end,
                close = function() return true end }
        end
        if path == "/books/full.epub" and mode == "wb" then
            return { write = function(self) return self end,
                close = function() return nil, "No space left on device" end }
        end
        return real_open(path, mode)
    end
    local ok, err = true, nil
    Client.new({ path = "/books" }):importAsync("/tmp/full.epub", "full.epub", function(o, e) ok, err = o, e end)
    Stubs.flush()
    io.open, os.rename, os.remove = real_open, real_rename, real_remove
    Assert.is_nil(ok)
    Assert.eq(err, "No space left on device")
    Assert.contains(removed, "/books/full.epub")
    Assert.is_nil(db_rows[rowKey("local", "/books/full.epub")])
end

-- ── moveBook：改分类/系列 = 移动文件；四表迁移 + 重名/非法目录名拒绝 ──────
do
    reset()
    db_rows[rowKey("local", "/books/a.epub")] = {
        source_id = "local",
        stable_id = "/books/a.epub",
        title = "A",
    }
    local real_rename = os.rename
    local renamed = {}
    os.rename = function(from, to)
        renamed[#renamed + 1] = { from, to }
        return true
    end

    -- 根目录的书给分类+系列 → 移到 root/分类/系列/ 下，身份迁移；.sdr 边车目录跟随
    local c = Client.new({ path = "/books" })
    local new_id, err = c:moveBook("/books/a.epub", "科幻", "三部曲")
    Assert.is_nil(err)
    Assert.eq(new_id, "/books/科幻/三部曲/a.epub")
    Assert.eq(#renamed, 1)
    Assert.eq(renamed[1][1], "/books/a.epub")
    Assert.eq(renamed[1][2], "/books/科幻/三部曲/a.epub")
    Assert.eq(sidecar_moves[#sidecar_moves][1], "/books/a.epub")
    Assert.eq(sidecar_moves[#sidecar_moves][2], "/books/科幻/三部曲/a.epub")
    Assert.eq(#renames, 1)
    Assert.eq(renames[1][2], "/books/a.epub")
    Assert.eq(renames[1][3], "/books/科幻/三部曲/a.epub")
    Assert.is_nil(db_rows[rowKey("local", "/books/a.epub")])
    local row = db_rows[rowKey("local", "/books/科幻/三部曲/a.epub")]
    Assert.not_nil(row)
    Assert.eq(row.category, "科幻")
    Assert.eq(row.series, "三部曲")

    -- 位置没变（分类即现目录）：原样返回，不动文件不动库
    local before_files, before_renames = #renamed, #renames
    new_id, err = c:moveBook("/books/sub/c.pdf", "sub", nil)
    Assert.eq(new_id, "/books/sub/c.pdf")

    -- 关闭「按文件夹分类」：编辑分类 / 系列只改库，不移动文件、不建目录
    local flat_files, flat_renames = #renamed, #renames
    new_id, err = Client.new({ path = "/books", folder_category = false }):moveBook("/books/sub/c.pdf", "新分类", "新系列")
    Assert.is_nil(err)
    Assert.eq(new_id, "/books/sub/c.pdf")
    Assert.eq(#renamed, flat_files)
    Assert.eq(#renames, flat_renames)
    Assert.is_nil(err)
    Assert.eq(#renamed, before_files)
    Assert.eq(#renames, before_renames)

    -- 只有系列没有分类：系列丢弃（扫盘模型里系列必须挂在分类下），落根目录
    new_id, err = c:moveBook("/books/sub/c.pdf", nil, "孤立系列")
    Assert.is_nil(err)
    Assert.eq(new_id, "/books/c.pdf")
    Assert.eq(renamed[#renamed][2], "/books/c.pdf")

    -- 非法目录名（路径分隔符 / 点开头）：拒绝，不碰文件
    before_files = #renamed
    new_id, err = c:moveBook("/books/a.epub", "科/幻", nil)
    Assert.is_nil(new_id)
    Assert.not_nil(err)
    new_id, err = c:moveBook("/books/a.epub", ".hidden", nil)
    Assert.is_nil(new_id)
    Assert.not_nil(err)
    Assert.eq(#renamed, before_files)

    -- 目标位置已有同名文件：拒绝（虚拟目录树里临时塞一个冲突文件）
    table.insert(TREE["/books/sub"], "a.epub")
    new_id, err = c:moveBook("/books/a.epub", "sub", nil)
    Assert.is_nil(new_id)
    Assert.not_nil(err)
    Assert.eq(#renamed, before_files)
    TREE["/books/sub"][#TREE["/books/sub"]] = nil

    -- 未配置路径：直接报错
    new_id, err = Client.new({}):moveBook("/books/a.epub", "科幻", nil)
    Assert.is_nil(new_id)
    Assert.not_nil(err)

    -- 身份迁移失败：书移回原处，报错而不是返回新路径
    local BookDB = require("book.books_db")
    local real_rename_id = BookDB.renameStableId
    BookDB.renameStableId = function() return false end
    new_id, err = c:moveBook("/books/a.epub", "科幻", nil)
    Assert.is_nil(new_id)
    Assert.eq(err, "更新书籍身份失败")
    Assert.eq(renamed[#renamed][1], "/books/科幻/a.epub")
    Assert.eq(renamed[#renamed][2], "/books/a.epub")
    BookDB.renameStableId = real_rename_id

    -- .sdr 移动失败：书移回原处，不改库
    local before_renames_id = #renames
    before_files = #renamed
    sidecar_fail = "busy"
    new_id, err = c:moveBook("/books/a.epub", "科幻", nil)
    sidecar_fail = nil
    Assert.is_nil(new_id)
    Assert.matches(err, "busy")
    Assert.eq(#renames, before_renames_id)
    Assert.eq(renamed[#renamed][1], "/books/科幻/a.epub")
    Assert.eq(renamed[#renamed][2], "/books/a.epub")

    os.rename = real_rename
end

-- ── cachedCoverPath：冒号调用约定（源门面以 self._client:cachedCoverPath 调用）──
do
    reset()
    local c = Client.new({ path = "/books" })
    -- stub lfs 对封面路径一律返回 nil → 不存在
    Assert.is_nil(c:cachedCoverPath("whatever"))
end

-- ── 书库目录不得落在插件数据目录内 ────────────────────
do
    reset()
    local ok, err = Client.new({ path = "/data/.moon" }):validatePath()
    Assert.is_false(ok)
    Assert.eq(err, "书库目录不能是插件数据目录")

    ok, err = Client.new({ path = "/data/.moon/cache" }):validatePath()
    Assert.is_false(ok)
    Assert.eq(err, "书库目录不能是插件数据目录")
end

os.time = real_time
os.remove = real_remove

for _, name in ipairs({
    "libs/libkoreader-lfs",
    "utils.paths",
    "document/documentregistry",
    "utils.task",
    "book.books_db",
    "source.local.scan_db",
    "source.local.client",
}) do
    package.preload[name] = nil
    package.loaded[name] = nil
end
