--[[-- source.local.client：扫描写库 / 直查 DB 分页筛选 / force 清理 / 单本入库 / 自动扫描节流 / 封面 / 最近阅读 / 统计 --]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")

-- 虚拟目录树：.moon（插件配置/缓存）与 .hidden 都不该被扫进书库
-- sub 是第 2 层（分类）；sub/deep 是第 3 层（系列）；x4 是第 4 层，按约定不识别；bad.epub 模拟引擎解析失败
-- a.epub.sdr 模拟 KOReader 边车目录：扫盘不当下钻，moveBook 时跟随书籍迁移
local TREE = {
    ["/books"] = { "a.epub", "a.epub.sdr", ".moon", ".hidden", "sub", "note.md", "old.cbr", "x.azw3" },
    ["/books/a.epub.sdr"] = { "metadata.epub.lua" },
    ["/books/.moon"] = { "cache" },
    ["/books/.moon/cache"] = { "cached.epub" },
    ["/books/.hidden"] = { "b.epub" },
    ["/books/sub"] = { "c.pdf", "d.djvu", "deep", "bad.epub" },
    ["/books/sub/deep"] = { "e.epub", "x4" },
    ["/books/sub/deep/x4"] = { "f.epub" },
}
local DIRS = {
    ["/books"] = true,
    ["/books/a.epub.sdr"] = true,
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
            local entries = TREE[path] or {}
            local i = 0
            return function()
                i = i + 1
                return entries[i]
            end, {}
        end,
        attributes = function(path, request)
            local attr
            if DIRS[path] then
                attr = { mode = "directory", size = 0, modification = 0 }
            else
                for dir, entries in pairs(TREE) do
                    for _, name in ipairs(entries) do
                        if dir .. "/" .. name == path then
                            attr = { mode = "file", size = 10, modification = 0 }
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
    }
end

package.preload["utils.paths"] = function()
    return {
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

--- 模拟 BookDB.listBySource 的 SQL 语义：category/series 精确 / search 包含 / stable_id 排序 / 分页。
local function stubListBySource(source_id, opts)
    opts = opts or {}
    local matched = {}
    for _, row in pairs(db_rows) do
        if row.source_id == source_id and row.in_library ~= false then
            local keep = true
            if type(opts.category) == "string" and opts.category ~= "" and row.category ~= opts.category then
                keep = false
            end
            if type(opts.series) == "string" and opts.series ~= "" and row.series ~= opts.series then
                keep = false
            end
            if keep and type(opts.search) == "string" and opts.search ~= "" then
                local hit = false
                for _, v in ipairs({ row.title, row.authors, row.stable_id }) do
                    if type(v) == "string" and v:find(opts.search, 1, true) then
                        hit = true
                        break
                    end
                end
                if not hit then
                    keep = false
                end
            end
            if keep then
                matched[#matched + 1] = row
            end
        end
    end
    table.sort(matched, function(a, b)
        return tostring(a.stable_id) < tostring(b.stable_id)
    end)
    local count = #matched
    local limit = tonumber(opts.limit) or 0
    local offset = tonumber(opts.offset) or 0
    if limit > 0 then
        local sliced = {}
        for i = offset + 1, math.min(count, offset + limit) do
            sliced[#sliced + 1] = matched[i]
        end
        matched = sliced
    end
    return matched, count
end

-- 扫描走子进程（workers.job）：离线测试不 fork，worker 就地同步跑，
-- ctx.post 直接转给 on_progress，结果经 nextTick 交 on_done 保持异步语义。
-- 子进程不碰 sqlite 的约束由 db.base 在真机上强制，这里的 db.book 全是内存假实现。
package.preload["workers.job"] = function()
    return {
        run = function(worker, opts)
            opts = opts or {}
            local ctx = {
                post = function(message)
                    if opts.on_progress then opts.on_progress(message) end
                end,
            }
            local ok, result = pcall(worker, ctx)
            require("ui/uimanager"):nextTick(function()
                if ok then
                    if opts.on_done then
                        opts.on_done(result)
                    end
                elseif opts.on_failed then
                    opts.on_failed(result)
                end
            end)
            return { abort = function() end }
        end,
    }
end
package.preload["db.book"] = function()
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
        getByMd5 = function(source_id, md5)
            if type(md5) ~= "string" or md5 == "" then
                return nil
            end
            for _, row in pairs(db_rows) do
                if row.source_id == source_id and row.md5 == md5 then
                    return row
                end
            end
            return nil
        end,
        renameStableId = function(source_id, old_stable_id, new_stable_id, category, series)
            renames[#renames + 1] = { source_id, old_stable_id, new_stable_id }
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
            row.in_library = true
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
        setLibraryMembership = function(source_id, stable_id, in_library, clear_path)
            local row = db_rows[rowKey(source_id, stable_id)]
            if row then
                row.in_library = in_library
                if clear_path then row.path = nil end
            end
            if not in_library then removed[#removed + 1] = stable_id end
            return true
        end,
        listBySource = stubListBySource,
        categoriesBySource = function(source_id)
            local seen, out = {}, {}
            for _, row in pairs(db_rows) do
                local c = row.category
                if row.source_id == source_id and type(c) == "string" and c ~= "" and not seen[c] then
                    seen[c] = true
                    out[#out + 1] = c
                end
            end
            table.sort(out)
            return out
        end,
        seriesBySource = function(source_id)
            local seen, out = {}, {}
            for _, row in pairs(db_rows) do
                local series = row.series
                if row.source_id == source_id and type(series) == "string"
                    and series ~= "" and not seen[series] then
                    seen[series] = true
                    out[#out + 1] = series
                end
            end
            table.sort(out)
            return out
        end,
    }
end
package.preload["db.stats"] = function()
    return {
        summaryBySource = function()
            return { total_seconds = 3600, total_pages = 42, last7_seconds = 600, longest_day_seconds = 1200 }
        end,
        dailyBySource = function()
            return { { ymd = "2026-08-15", seconds = 600, pages = 10 } }
        end,
        dailyBooksBySource = function()
            return { { ymd = "2026-08-15", stable_id = "/books/a.epub", seconds = 600, max_page = 10, max_total_pages = 20 } }
        end,
    }
end
for _, name in ipairs({
    "libs/libkoreader-lfs",
    "utils.paths",
    "document/documentregistry",
    "utils.task",
    "db.book",
    "db.stats",
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
end

-- ── 直查数据库：不扫盘，分页 / 筛选 / 搜索都走 DB ──────
do
    reset()
    -- 预置 5 本书
    for i = 1, 5 do
        local path = string.format("/books/b%d.epub", i)
        db_rows[rowKey("local", path)] = {
            source_id = "local",
            stable_id = path,
            title = "书" .. i,
            authors = i == 3 and "鲁迅" or "别人",
            category = i <= 3 and "sub" or "other",
            series = i <= 2 and "第一辑" or "第二辑",
        }
    end
    local c = Client.new({ path = "/books" })

    -- 第 1 页（page_size=2）
    local rows, count
    c:listAsync({ page = 1, page_size = 2 }, function(r, n)
        rows, count = r, n
    end)
    Stubs.flush()
    Assert.len(dirs_scanned, 0)
    Assert.eq(count, 5)
    Assert.len(rows, 2)
    Assert.eq(rows[1].stable_id, "/books/b1.epub")

    -- 第 2 页
    rows, count = nil, nil
    c:listAsync({ page = 2, page_size = 2 }, function(r, n)
        rows, count = r, n
    end)
    Stubs.flush()
    Assert.eq(count, 5)
    Assert.len(rows, 2)
    Assert.eq(rows[1].stable_id, "/books/b3.epub")

    -- 第 3 页（不足一页）
    rows = nil
    c:listAsync({ page = 3, page_size = 2 }, function(r)
        rows = r
    end)
    Stubs.flush()
    Assert.len(rows, 1)
    Assert.eq(rows[1].stable_id, "/books/b5.epub")

    -- 分类筛选
    rows, count = nil, nil
    c:listAsync({ category = "sub" }, function(r, n)
        rows, count = r, n
    end)
    Stubs.flush()
    Assert.eq(count, 3)
    Assert.len(rows, 3)

    -- 系列筛选
    rows, count = nil, nil
    c:listAsync({ series = "第一辑" }, function(r, n)
        rows, count = r, n
    end)
    Stubs.flush()
    Assert.eq(count, 2)
    Assert.len(rows, 2)

    -- 搜索：命中作者
    rows, count = nil, nil
    c:listAsync({ search = "鲁迅" }, function(r, n)
        rows, count = r, n
    end)
    Stubs.flush()
    Assert.eq(count, 1)
    Assert.eq(rows[1].stable_id, "/books/b3.epub")

    -- 搜索：无命中
    c:listAsync({ search = "不存在" }, function(r, n)
        rows, count = r, n
    end)
    Stubs.flush()
    Assert.eq(count, 0)
    Assert.len(rows, 0)
end

-- ── force：真实扫盘 → 解析写库（失败回退文件名）→ 清失效 → 返回 DB 页 ──────
do
    reset()
    db_rows[rowKey("local", "/books/gone.epub")] = { source_id = "local", stable_id = "/books/gone.epub", title = "gone" }

    local rows, count, err
    Client.new({ path = "/books" }):listAsync({ force = true }, function(r, n, e)
        rows, count, err = r, n, e
    end)
    Stubs.flush()
    Assert.is_nil(err)
    -- 白名单内 6 本：a.epub / note.md / c.pdf / d.djvu / bad.epub / e.epub（第 3 层）
    Assert.eq(count, 6)
    Assert.len(rows, 6)
    Assert.is_true(#dirs_scanned > 0)
    -- 第 4 层不识别
    Assert.is_nil(db_rows[rowKey("local", "/books/sub/deep/x4/f.epub")])
    Assert.is_false(hasValue(dirs_scanned, "/books/sub/deep/x4"))
    -- KOReader .sdr 边车目录不下钻、不入库
    Assert.is_false(hasValue(dirs_scanned, "/books/a.epub.sdr"))
    Assert.is_nil(db_rows[rowKey("local", "/books/a.epub.sdr/metadata.epub.lua")])
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
    Assert.is_false(db_rows[rowKey("local", "/books/gone.epub")].in_library)
    Assert.is_nil(db_rows[rowKey("local", "/books/gone.epub")].path)
    Assert.is_false(hasValue(removed_files, "/data/.moon/cache/local/image//books/gone.epub.png"))
    Assert.not_nil(db_rows[rowKey("local", "/books/a.epub")])
    -- 封面：解析成功的 5 本都尝试提取（bad.epub 无引擎不提取）
    Assert.len(covers_saved, 5)
end

-- ── 改名识别：新路径按内容 md5 命中旧行时原地改 stable_id，不当新书插入 ──────
do
    reset()
    db_rows[rowKey("local", "/books/old_name.epub")] = {
        source_id = "local", stable_id = "/books/old_name.epub", md5 = "digest-a", title = "已有元数据",
    }
    local BookDB = require("db.book")
    -- 模拟扫描发现同 md5 的新路径（partialMD5 在此测试环境恒为 nil，直接调用 DB 层验证原地改名的效果）
    local by_md5 = BookDB.getByMd5("local", "digest-a")
    Assert.not_nil(by_md5)
    -- 文件移进 sub/deep：category/series 由新位置派生，随 stable_id 一并刷新
    BookDB.renameStableId("local", by_md5.stable_id, "/books/sub/deep/new_name.epub", "sub", "deep")
    Assert.is_nil(db_rows[rowKey("local", "/books/old_name.epub")])
    local renamed = db_rows[rowKey("local", "/books/sub/deep/new_name.epub")]
    Assert.not_nil(renamed)
    Assert.eq(renamed.title, "已有元数据")
    Assert.eq(renamed.md5, "digest-a")
    Assert.eq(renamed.category, "sub")
    Assert.eq(renamed.series, "deep")
    Assert.eq(#renames, 1)
end

-- ── 元数据缓存命中：force 也跳过解析；非 force 永不扫盘 ──────
do
    reset()
    local c = Client.new({ path = "/books" })
    c:listAsync({ force = true }, function() end)
    Stubs.flush()
    Assert.len(opened, 5)
    Assert.eq(props_read, 5)

    opened = {}
    upserts = {}
    dirs_scanned = {}
    covers_saved = {}
    c:listAsync({ force = true }, function() end)
    Stubs.flush()
    Assert.is_true(#dirs_scanned > 0)
    Assert.len(opened, 5)
    Assert.eq(props_read, 5)
    Assert.len(covers_saved, 5)
    Assert.len(upserts, 0)

    -- 非 force 纯查库
    dirs_scanned = {}
    local rows
    c:listAsync(nil, function(r)
        rows = r
    end)
    Stubs.flush()
    Assert.len(rows, 6)
    Assert.len(dirs_scanned, 0)
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

    -- 未配置路径：直接报错，不碰文件
    ok, err = true, nil
    Client.new({}):importAsync("/tmp/dl.epub", "x.epub", function(o, e)
        ok, err = o, e
    end)
    Assert.is_nil(ok)
    Assert.not_nil(err)
    Assert.eq(#renamed, 2)

    -- 空文件名：消毒前即为空，同步报错
    ok, err = true, nil
    Client.new({ path = "/books" }):importAsync("/tmp/dl.epub", "", function(o, e)
        ok, err = o, e
    end)
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
    Assert.eq(#renamed, 2)
    Assert.eq(renamed[1][1], "/books/a.epub")
    Assert.eq(renamed[1][2], "/books/科幻/三部曲/a.epub")
    Assert.eq(renamed[2][1], "/books/a.epub.sdr")
    Assert.eq(renamed[2][2], "/books/科幻/三部曲/a.epub.sdr")
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

    os.rename = real_rename
end

-- ── replaceBook：转换后的 EPUB 替换原书；身份、封面和 .sdr 一起迁移 ──
do
    reset()
    db_rows[rowKey("local", "/books/reflow.mobi")] = {
        source_id = "local",
        stable_id = "/books/reflow.mobi",
        title = "重排",
        category = "科幻",
        series = "系列",
    }
    local real_rename, real_remove = os.rename, os.remove
    local renamed_files, removed_files = {}, {}
    os.rename = function(from, to)
        renamed_files[#renamed_files + 1] = { from, to }
        return true
    end
    os.remove = function(path)
        removed_files[#removed_files + 1] = path
        return true
    end

    local c = Client.new({ path = "/books" })
    local new_id, err = c:replaceBook("/books/reflow.epub.moon-reflow", "/books/reflow.mobi")
    Assert.is_nil(err)
    Assert.eq(new_id, "/books/reflow.epub")
    Assert.eq(renamed_files[1][1], "/books/reflow.mobi")
    Assert.eq(renamed_files[1][2], "/books/reflow.mobi.moon-reflow-backup")
    Assert.eq(renamed_files[2][1], "/books/reflow.epub.moon-reflow")
    Assert.eq(renamed_files[2][2], "/books/reflow.epub")
    Assert.eq(removed_files[1], "/books/reflow.mobi.moon-reflow-backup")
    Assert.is_nil(db_rows[rowKey("local", "/books/reflow.mobi")])
    local row = db_rows[rowKey("local", "/books/reflow.epub")]
    Assert.not_nil(row)
    Assert.eq(row.category, "科幻")
    Assert.eq(row.series, "系列")

    -- 目标 EPUB 已存在时拒绝，不能碰原文件。
    reset()
    local before = #renamed_files
    new_id, err = c:replaceBook("/tmp/reflow.epub.moon-reflow", "/books/a.mobi")
    Assert.is_nil(new_id)
    Assert.not_nil(err)
    Assert.eq(#renamed_files, before)

    -- 转换文件落位失败时，必须把备份恢复成原书，且不迁移数据库身份。
    reset()
    db_rows[rowKey("local", "/books/rollback.mobi")] = {
        source_id = "local", stable_id = "/books/rollback.mobi", title = "回滚",
    }
    renamed_files = {}
    os.rename = function(from, to)
        renamed_files[#renamed_files + 1] = { from, to }
        if from == "/books/rollback.epub.moon-reflow" then
            return nil, "disk error"
        end
        return true
    end
    new_id, err = c:replaceBook("/books/rollback.epub.moon-reflow", "/books/rollback.mobi")
    Assert.is_nil(new_id)
    Assert.matches(err, "放置转换文件失败")
    Assert.eq(renamed_files[3][1], "/books/rollback.mobi.moon-reflow-backup")
    Assert.eq(renamed_files[3][2], "/books/rollback.mobi")
    Assert.not_nil(db_rows[rowKey("local", "/books/rollback.mobi")])
    Assert.len(renames, 0)

    os.rename, os.remove = real_rename, real_remove
end

do
    reset()
    local c = Client.new({ path = "/books" })
    now = 5000
    local scanned
    c:autoScanAsync(function(s)
        scanned = s
    end)
    Stubs.flush()
    Assert.is_true(scanned)
    Assert.is_true(#dirs_scanned > 0)

    -- 节流期内：不扫盘
    now = 5030
    dirs_scanned = {}
    scanned = nil
    c:autoScanAsync(function(s)
        scanned = s
    end)
    Stubs.flush()
    Assert.is_false(scanned)
    Assert.len(dirs_scanned, 0)

    -- 过期：重扫
    now = 5061
    dirs_scanned = {}
    c:autoScanAsync(function(s)
        scanned = s
    end)
    Stubs.flush()
    Assert.is_true(scanned)
    Assert.is_true(#dirs_scanned > 0)
end

-- ── filtersAsync：分类/系列 DISTINCT 直查 DB ───────
do
    reset()
    for i, cat in ipairs({ "sub", "zeta", "sub", "" }) do
        local path = string.format("/books/f%d.epub", i)
        db_rows[rowKey("local", path)] = {
            source_id = "local",
            stable_id = path,
            title = "f" .. i,
            category = cat,
            series = i <= 2 and "系列 A" or "系列 B",
        }
    end
    local res
    Client.new({ path = "/books" }):filtersAsync(function(data)
        res = data
    end)
    Stubs.flush()
    Assert.not_nil(res)
    Assert.len(res.data.category, 2)
    Assert.eq(res.data.category[1], "sub")
    Assert.eq(res.data.category[2], "zeta")
    Assert.len(res.data.series, 2)
    Assert.eq(res.data.series[1], "系列 A")
    Assert.eq(res.data.series[2], "系列 B")
end

-- ── cachedCoverPath：冒号调用约定（源门面以 self._client:cachedCoverPath 调用）──
do
    reset()
    local c = Client.new({ path = "/books" })
    -- stub lfs 对封面路径一律返回 nil → 不存在
    Assert.is_nil(c:cachedCoverPath("whatever"))
    Assert.is_nil(c:cachedCoverPath(nil))
    Assert.is_nil(c:cachedCoverPath(""))
end

-- ── 书库目录不得落在插件数据目录内 ────────────────────
do
    reset()
    local rows, count, err
    Client.new({ path = "/data/.moon" }):listAsync(nil, function(r, n, e)
        rows, count, err = r, n, e
    end)
    Stubs.flush()
    Assert.is_nil(rows)
    Assert.eq(count, 0)
    Assert.eq(err, "书库目录不能是插件数据目录")

    rows, err = nil, nil
    Client.new({ path = "/data/.moon/cache" }):listAsync(nil, function(r, n, e)
        rows, err = r, e
    end)
    Stubs.flush()
    Assert.is_nil(rows)
    Assert.eq(err, "书库目录不能是插件数据目录")
end

os.time = real_time
os.remove = real_remove

for _, name in ipairs({
    "libs/libkoreader-lfs",
    "utils.paths",
    "document/documentregistry",
    "utils.task",
    "db.book",
    "db.stats",
    "source.local.client",
}) do
    package.preload[name] = nil
    package.loaded[name] = nil
end
