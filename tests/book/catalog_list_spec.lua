--[[--
book.catalog.listBooks：书库分页 / 筛选 / 搜索（books LEFT JOIN pending_progress）

@module tests.book.catalog_list_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

local Assert = require("support.assert")

local function stubDbDeps()
    package.preload["utils.paths"] = function()
        return {
            dbPath = function() return "unused.sqlite3" end,
            ensureSettings = function() end,
            sanitizeSourceId = function(id) return id end,
        }
    end
    package.preload["ffi/sha2"] = function()
        return { md5 = function(s) return s end }
    end
end

-- 书架缓存钩子：只有声明 shelf_cache 的源才有投影；别的源（如 wechat）解析不出声明。
local shelf_caps, shelf_projection = false, nil
local shelf_calls = 0
local registry = {
    list = function() return {} end,
    listEnabled = function() return {} end,
    resolve = function(id)
        if id ~= "kavita" then return nil end
        return {
            id = "kavita",
            capabilities = function() return { shelf_cache = shelf_caps } end,
            shelfCache = function()
                shelf_calls = shelf_calls + 1
                if shelf_projection == "boom" then error("shelf cache boom") end
                return shelf_projection
            end,
        }
    end,
}
package.preload["source.registry"] = function() return registry end
-- listLibraryAsync 的推迟回调与混合作用域解析。
package.preload["ui/uimanager"] = function()
    return { nextTick = function(_, fn) fn() end }
end
package.preload["ui/guard"] = function()
    return { wrap = function(_, fn) return fn end }
end
package.preload["utils.settings"] = function()
    return { get = function() return {} end }
end

local function clearMods()
    for _, name in ipairs({
        "utils.paths",
        "workers.job",
        "lua-ljsqlite3/init",
        "ffi/sha2",
        "utils.db",
        "book.books_db",
        "book.chapters_db",
        "http.cache", "utils.event",
        "book.note_db",
        "book.progress_db",
        "book.stats_db",
        "features.xray.db", "book.catalog",
        "source.registry", "ui/uimanager", "ui/guard", "utils.settings",
    }) do
        package.preload[name] = nil
        package.loaded[name] = nil
    end
end

do
    local calls = {}
    local fail_count = false
    -- 假结果集的行身份：书架缓存用例要拿 kavita 的行来对投影。
    local row_source, row_stable = "local", "/books/a.epub"
    local connection = {
        exec = function() end,
        close = function() end,
        prepare = function(_, sql)
            local call = { sql = sql }
            calls[#calls + 1] = call
            return {
                bind = function(self, ...)
                    call.argc = select("#", ...)
                    call.args = { ... }
                    return self
                end,
                step = function()
                    if fail_count then error("database is locked") end
                    if sql:find("COUNT", 1, true) then
                        return { 7 }, { "COUNT(*)" }
                    end
                    return nil
                end,
                resultset = function()
                    if sql:find("DISTINCT category", 1, true) then
                        return { { "sub", "zeta" } }, 2
                    end
                    if sql:find("DISTINCT series", 1, true) then
                        return { { "第一辑", "第二辑" } }, 2
                    end
                    if sql:find("COUNT(*)", 1, true) and sql:find("GROUP BY", 1, true) then
                        if sql:find("WHEN read_state=1 THEN 'read'", 1, true) then
                            return { { "read", "unread" }, { 2, 4 } }, 2
                        end
                        if sql:find("GROUP BY source_id", 1, true) then
                            return { { "local", "wechat" }, { 3, 5 } }, 2
                        end
                        if sql:find("CASE WHEN series", 1, true) then
                            return { { "第一辑", "" }, { 5, 2 } }, 2
                        end
                        return { { "sub", "" }, { 3, 2 } }, 2
                    end
                    return {
                        { row_source },
                        { row_stable },
                        { "书名" },
                        { "作者" },
                        { 42 },
                        { "sub" },
                        { "第一辑" },
                        { "介绍" },
                        { "https://img.test/a.jpg" },
                        { 1000 },
                        { 1 },
                        { "/cache/a.epub" },
                        { 1 },
                    }, 1
                end,
                close = function() end,
            }
        end,
    }

    stubDbDeps()
    package.preload["lua-ljsqlite3/init"] = function()
        return { open = function() return connection end }
    end
    package.loaded["utils.db"] = nil
    package.loaded["book.books_db"] = nil
    package.loaded["book.progress_db"] = nil
    package.loaded["book.catalog"] = nil

    local DbBase = require("utils.db")
    local Catalog = require("book.catalog")
    require("book.progress_db")
    DbBase.open()

    -- 无筛选：仅 source_id；LIMIT/OFFSET 绑定
    local rows, count = Catalog.listBooks("local", { limit = 24, offset = 48 })
    Assert.eq(count, 7)
    Assert.eq(#rows, 1)
    Assert.eq(rows[1].source_id, "local")
    Assert.eq(rows[1].stable_id, "/books/a.epub")
    Assert.eq(rows[1].title, "书名")
    Assert.eq(rows[1].percent, 42)
    Assert.eq(rows[1].series, "第一辑")
    Assert.is_true(rows[1].downloaded)
    Assert.eq(rows[1].cover, "https://img.test/a.jpg")
    Assert.eq(rows[1].inserted_at, 1000)
    Assert.eq(rows[1].read_state, 1)
    Assert.eq(rows[1].path, "/cache/a.epub")
    Assert.eq(rows[1].deleted, 0)
    local count_q = calls[#calls - 1]
    Assert.is_true(count_q.sql:find("WHERE source_id=%?", 1) ~= nil or count_q.sql:find("source_id=?", 1, true) ~= nil)
    Assert.is_true(count_q.sql:find("b.deleted=0", 1, true) ~= nil)
    Assert.is_false(count_q.sql:find("category=", 1, true) ~= nil)
    local list_q = calls[#calls]
    Assert.is_true(list_q.sql:find("b.inserted_at", 1, true) ~= nil)
    Assert.is_true(list_q.sql:find("is_new", 1, true) == nil)
    Assert.is_true(list_q.sql:find("LIMIT ? OFFSET ?", 1, true) ~= nil)
    Assert.eq(list_q.args[#list_q.args - 1], 24)
    Assert.eq(list_q.args[#list_q.args], 48)

    -- 分类 + 系列 + 搜索：AND 条件与 LIKE 参数
    calls = {}
    rows, count = Catalog.listBooks("local", {
        category = "sub",
        series = "第一辑",
        search = "鲁",
        limit = 10,
        offset = 0,
    })
    Assert.eq(count, 7)
    count_q = calls[1]
    Assert.is_true(count_q.sql:find("AND b.category=?", 1, true) ~= nil)
    Assert.is_true(count_q.sql:find("AND b.series=?", 1, true) ~= nil)
    Assert.is_true(count_q.sql:find("b.title LIKE ?", 1, true) ~= nil)
    Assert.eq(count_q.args[1], "local")
    Assert.eq(count_q.args[2], "sub")
    Assert.eq(count_q.args[3], "第一辑")
    Assert.eq(count_q.args[4], "%鲁%")
    Assert.eq(count_q.args[5], "%鲁%")
    Assert.eq(count_q.args[6], "%鲁%")

    calls = {}
    Catalog.listBooks("local", { read_status = "unread" })
    Assert.is_true(calls[1].sql:find("b.read_state<>1", 1, true) ~= nil)
    calls = {}
    Catalog.listBooks("local", { read_status = "read" })
    Assert.is_true(calls[1].sql:find("b.read_state=1", 1, true) ~= nil)
    calls = {}
    Catalog.listBooks("local", { uncategorized = true })
    Assert.is_true(calls[1].sql:find("b.category IS NULL OR b.category=''", 1, true) ~= nil)
    calls = {}
    Catalog.listBooks("local", { unseries = true })
    Assert.is_true(calls[1].sql:find("b.series IS NULL OR b.series=''", 1, true) ~= nil)
    calls = {}
    Catalog.listBooks("local", { unauthor = true, author = "鲁迅" })
    Assert.is_true(calls[1].sql:find("b.authors IS NULL OR b.authors=''", 1, true) ~= nil)
    Assert.is_nil(calls[1].sql:find("b.authors=?", 1, true), "空桶优先于组名")
    calls = {}
    Catalog.listBooks("local", { author = "鲁迅" })
    Assert.is_true(calls[1].sql:find("AND b.authors=?", 1, true) ~= nil)
    Assert.eq(calls[1].args[2], "鲁迅")
    calls = {}
    Catalog.listBooks({ "local", "wechat" }, { source_id = "wechat" })
    Assert.is_true(calls[1].sql:find("b.source_id IN (?,?)", 1, true) ~= nil)
    Assert.is_true(calls[1].sql:find("AND b.source_id=?", 1, true) ~= nil)
    Assert.eq(calls[1].args[1], "local")
    Assert.eq(calls[1].args[2], "wechat")
    Assert.eq(calls[1].args[3], "wechat")
    calls = {}
    Catalog.listBooks("local", { downloaded = true, chapter_sources = { "wechat", "jdread" } })
    Assert.is_true(calls[1].sql:find("CASE WHEN b.source_id IN (?,?) THEN", 1, true) ~= nil)
    Assert.is_true(calls[1].sql:find("COUNT(DISTINCT c.chapter_idx) = MAX(c.chapter_idx) - MIN(c.chapter_idx) + 1", 1, true) ~= nil)
    Assert.is_nil(calls[1].sql:find("b.toc", 1, true), "已下载不看目录")
    Assert.is_true(calls[1].sql:find("FROM chapters c", 1, true) ~= nil)
    Assert.is_true(calls[1].sql:find("COALESCE(b.path, '')<>''", 1, true) ~= nil)
    Assert.eq(calls[1].args[1], "local")
    Assert.eq(calls[1].args[2], "wechat")
    Assert.eq(calls[1].args[3], "jdread")


    -- 查询出错：不能当成 0 本，带 err 返回
    fail_count = true
    local err_rows, err_count, err = Catalog.listBooks("local", { limit = 24 })
    fail_count = false
    Assert.len(err_rows, 0)
    Assert.eq(err_count, 0)
    Assert.not_nil(err, "库查询出错要带错误，图书馆页据此显示「加载失败」")

    -- 「最近阅读」只是排序：LEFT JOIN，只列在架书；卷行是进度身份、不是书架成员。
    calls = {}
    Catalog.listBooks("local", { sort = "recent_read", limit = 24 })
    Assert.is_true(calls[1].sql:find("LEFT JOIN pending_progress p", 1, true) ~= nil, "没进度的书也要计数")
    Assert.is_true(calls[1].sql:find("AND b.deleted=0", 1, true) ~= nil, "最近阅读只列在架书")
    Assert.is_nil(calls[1].sql:find("p.stable_id IS NOT NULL", 1, true), "卷行不靠「有进度」挤进列表")
    Assert.is_true(calls[2].sql:find("ORDER BY MAX(COALESCE(p.updated_at, 0), b.read_at) DESC, b.inserted_at DESC", 1, true) ~= nil,
        "按本机 / 云端最近阅读时间排，没读过的按加入时间")
    -- 其它排序仍 LEFT JOIN + 只在架：按书名 / 加入时间排要列出全库。
    calls = {}
    Catalog.listBooks("local", { sort = "title" })
    Assert.is_true(calls[1].sql:find("LEFT JOIN pending_progress", 1, true) ~= nil)
    Assert.is_true(calls[1].sql:find("b.deleted=0", 1, true) ~= nil)
    calls = {}
    Catalog.listBooks("local", { sort = "recent_added" })
    Assert.is_true(calls[1].sql:find("LEFT JOIN pending_progress", 1, true) ~= nil)
    Assert.is_true(calls[1].sql:find("b.deleted=0", 1, true) ~= nil)

    -- 软删除：默认隐藏，hidden 筛选只列软删除的书。
    calls = {}
    Catalog.listBooks("local", {})
    Assert.is_true(calls[1].sql:find("b.hidden=0", 1, true) ~= nil)
    calls = {}
    Catalog.listBooks("local", { hidden = true })
    Assert.is_true(calls[1].sql:find("b.hidden=1", 1, true) ~= nil)

    -- 书架缓存标记：只认声明 shelf_cache 的源给出的 mark，按行身份透传成 cache_mark。
    shelf_caps, shelf_projection = true, {
        series_ids = { ["700"] = true },
        mark = { ["700"] = true },
        cover = { ["700"] = "/cache/700.jpg" },
    }
    row_source, row_stable = "kavita", "700"
    calls = {}
    rows = Catalog.listBooks("kavita", { limit = 24 })
    Assert.is_true(rows[1].cache_mark, "投影 mark 命中：已缓存")
    row_stable = "701"
    calls = {}
    rows = Catalog.listBooks("kavita", { limit = 24 })
    Assert.is_nil(rows[1].cache_mark, "不在投影里：未缓存")
    -- 没有声明能力的源不看投影，也不多出 SQL。
    shelf_caps = false
    calls = {}
    rows = Catalog.listBooks("local", { limit = 24 })
    Assert.is_nil(rows[1].cache_mark)
    Assert.is_nil(calls[1].sql:find("b.stable_id IN (", 1, true), "未声明 shelf_cache：不进离线子句")

    --- 取外层 where 片段（count 与 select 必须共用同一份；子查询里也有 WHERE，靠 join 位置定位）。
    local function whereOf(sql)
        local join = sql:find(" LEFT JOIN pending_progress p ON ", 1, true)
        if not join then return nil end
        local from = sql:find(" WHERE ", join, true)
        if not from then return nil end
        local tail = sql:sub(from + 7)
        return tail:match("^(.-)%s*ORDER BY") or tail:match("^(.-);")
    end

    -- 离线可见集：已缓存 series ∪ 已下载 ∪ 卷行；单源全是缓存源时不加 source_id 限制。
    shelf_caps, shelf_projection = true, {
        series_ids = { ["700"] = true },
        mark = { ["700"] = true },
        cover = {},
    }
    row_source, row_stable = "kavita", "700"
    calls = {}
    rows, count = Catalog.listBooks("kavita", {
        offline_only = true, limit = 10, offset = 0, chapter_sources = { "wechat" },
    })
    local count_offline, list_offline = calls[1], calls[2]
    for _idx, q in ipairs({ count_offline, list_offline }) do
        Assert.is_true(q.sql:find("b.stable_id IN (?)", 1, true) ~= nil, "已缓存 series")
        Assert.is_true(q.sql:find("FROM chapters c", 1, true) ~= nil, "已下载也算可离线读")
        Assert.is_true(q.sql:find("instr(b.stable_id, ':') > 0", 1, true) ~= nil, "卷行放行")
        Assert.is_nil(q.sql:find("b.source_id NOT IN", 1, true), "单源全是缓存源：不加源限制")
    end
    Assert.eq(whereOf(count_offline.sql), whereOf(list_offline.sql), "count 与 select 共用同一 where")
    Assert.eq(count_offline.args[1], "kavita")
    Assert.eq(count_offline.args[2], "700", "series 参数在源参数之后")
    Assert.eq(count_offline.args[3], "wechat", "下载子句参数排在最后")
    Assert.eq(list_offline.args[#list_offline.args - 1], 10)
    Assert.eq(list_offline.args[#list_offline.args], 0)
    Assert.is_true(rows[1].cache_mark, "离线行也带缓存标记")

    -- random：同一条分页 SELECT（列序只有一份），只是不 COUNT、ORDER BY RANDOM()。
    calls = {}
    rows = Catalog.listBooks("kavita", { random = true, limit = 2, offline_only = true, chapter_sources = { "wechat" } })
    Assert.len(calls, 1, "random 不先 COUNT")
    Assert.is_true(calls[1].sql:find("ORDER BY RANDOM()", 1, true) ~= nil)
    Assert.eq(whereOf(calls[1].sql), whereOf(list_offline.sql), "random 与分页同一 where")
    Assert.eq(calls[1].args[#calls[1].args - 1], 2)
    Assert.eq(calls[1].args[#calls[1].args], 0)
    Assert.is_true(rows[1].cache_mark, "random 行与分页行同一字段映射")

    -- 混合源：只约束声明了 shelf_cache 的源，其它源的行原样放行（05 A4）。
    calls = {}
    Catalog.listBooks({ "kavita", "wechat" }, {
        offline_only = true, limit = 24, chapter_sources = { "wechat" },
    })
    local mixed_count = calls[1]
    Assert.is_true(mixed_count.sql:find("b.source_id NOT IN (?)", 1, true) ~= nil,
        "同范围里别的源不受离线过滤")
    Assert.eq(mixed_count.args[1], "kavita")
    Assert.eq(mixed_count.args[2], "wechat")
    Assert.eq(mixed_count.args[3], "kavita", "缓存源列表")
    Assert.eq(mixed_count.args[4], "700")

    -- 参数上限：series 多到超过单条 IN 的分块大小就拆成多个 OR 组（SQLite 默认 999 个绑定参数）。
    local many = { series_ids = {}, mark = {}, cover = {} }
    for i = 1, 600 do many.series_ids["s" .. i] = true end
    shelf_caps, shelf_projection = true, many
    calls = {}
    Catalog.listBooks("kavita", { offline_only = true, limit = 24 })
    local groups = 0
    for _idx in calls[1].sql:gmatch("b%.stable_id IN %(") do groups = groups + 1 end
    Assert.eq(groups, 2, "600 个 series 拆成两块")
    local marks = 0
    for _idx in calls[1].sql:gmatch("%?") do marks = marks + 1 end
    Assert.eq(marks, 601, "一块最多 500 个参数 args=" .. #calls[1].args)
    Assert.eq(#calls[1].args, 601)

    -- 页面只置离线标志：listLibraryAsync 原样透传给 listBooks。
    shelf_caps, shelf_projection = true, {
        series_ids = { ["700"] = true }, mark = { ["700"] = true }, cover = {},
    }
    calls = {}
    local listed
    Catalog.listLibraryAsync("kavita", { offline_only = true, page = 2, page_size = 24 },
        function(res) listed = res and res.count end)
    Assert.eq(listed, 7)
    Assert.is_true(calls[1].sql:find("instr(b.stable_id, ':') > 0", 1, true) ~= nil, "离线子句到达查询")
    Assert.eq(calls[2].args[#calls[2].args - 1], 24)
    Assert.eq(calls[2].args[#calls[2].args], 24, "第 2 页偏移")

    -- 投影不可用（Kavita 未配置 / kamare 缺失 / index 取不到）不等于「源没声明能力」：
    -- 离线书架仍要收窄到已下载 ∪ 卷行，否则会列出点开即死路的行（05 A4 / US 11）。
    shelf_caps, shelf_projection = true, nil
    shelf_calls = 0
    Assert.is_true(Catalog.hasShelfCache("kavita"), "声明了 shelf_cache 就算数，投影为 nil 也算")
    Assert.eq(shelf_calls, 0, "hasShelfCache 只查能力，不为一次判断构建整份投影")
    calls = {}
    Catalog.listBooks("kavita", { offline_only = true, limit = 10, chapter_sources = {} })
    Assert.is_nil(calls[1].sql:find("b.stable_id IN (?)", 1, true), "没有缓存 series：不加 IN 参数")
    Assert.is_true(calls[1].sql:find("COALESCE(b.path, '')<>''", 1, true) ~= nil, "已下载仍可离线")
    Assert.is_true(calls[1].sql:find("instr(b.stable_id, ':') > 0", 1, true) ~= nil, "卷行仍放行")

    -- 空投影同理：不能因为集合为空就关掉离线过滤。
    shelf_caps, shelf_projection = true, { series_ids = {}, mark = {}, cover = {} }
    calls = {}
    Catalog.listBooks("kavita", { offline_only = true, limit = 10, chapter_sources = {} })
    Assert.is_true(calls[1].sql:find("COALESCE(b.path, '')<>''", 1, true) ~= nil, "空投影仍限制到已下载")
    Assert.is_true(calls[1].sql:find("instr(b.stable_id, ':') > 0", 1, true) ~= nil, "空投影仍放行卷行")

    -- 源的 shelfCache 抛错不吞：冒到入口弹错误页，而不是把「出错」当「没缓存」把整个书架限制到已下载。
    shelf_caps, shelf_projection = true, "boom"
    Assert.errors(function() Catalog.shelfCaches({ "kavita" }) end, "shelf cache boom")

    DbBase.close()
    clearMods()
end
