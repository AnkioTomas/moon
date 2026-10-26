--[[--
本地目录唯一读入口：books 提供书库列表，pending_progress 提供最近阅读，
reading_stats 提供统计。

约定：
  - UI 查询经 SourceBase 的本地方法到达此处
  - 远端源只负责 sync* 把变更写入本地库；读路径与源协议解耦
  - library_mixed 打开时，列表/筛选/最近/洞察跨已启用源聚合；
    每本书仍带真实 source_id，阅读打开走属主源

@module koplugin.book.book.catalog
--]]

--- 图书馆筛选项与分类索引。
---@class BookFiltersResult
---@field data { category_counts: { category: string, count: integer }[]|nil, series_counts: { series: string, count: integer }[]|nil, author_counts: { authors: string, count: integer }[]|nil, read_counts: { status: string, count: integer }[]|nil, downloaded_count: integer|nil, hidden_count: integer|nil, source_counts: { source_id: string, name: string, count: integer }[]|nil }|nil

--- 图书馆 / 书城列表查询参数。
--- 未使用的筛选项传 nil 或空串；源不支持的项可忽略。
---@class BookListOpts
---@field root string|nil 本地目录查询根
---@field page number|nil 页码，从 1 起
---@field page_size number|nil 每页条数（须与网格容量一致）
---@field search string|nil 关键词搜索
---@field scope number|nil 书城搜索范围（wechat：0 全部 / 10 电子书 / 16 网文 / 14 听书 等）
---@field series string|nil 按系列筛选
---@field category string|nil 按分类筛选
---@field uncategorized boolean|nil 只查询 category 为 NULL/空串的未分类桶
---@field unseries boolean|nil 只查询 series 为 NULL/空串的无系列桶
---@field author string|nil 按作者筛选（authors 整串精确匹配）
---@field unauthor boolean|nil 只查询 authors 为 NULL/空串的未知作者桶
---@field read_status "read"|"unread"|nil 按独立阅读状态筛选
---@field hidden boolean|nil 只查软删除的书；缺省只查未软删除的
---@field downloaded boolean|nil 只查询已下载到本地的书（口径同 BookDB.isDownloaded）
---@field source_id string|nil 混合模式下按书行所属源筛选
---@field force boolean|nil 强制重扫、忽略扫描缓存（本地源手动刷新）
---@field sort "title"|"author"|"recent_read"|"recent_added"|nil 排序字段
---@field sort_desc boolean|nil 是否降序

--- 日历某一天的阅读摘要。
---@class StatsCalendarDay
---@field duration_seconds number|nil 当日阅读秒数（>0 则日历格高亮）
---@field duration_text string|nil 当日时长文案（日详情标题）
---@field pages number|nil 当日翻页数
---@field hours number[]|nil 本机记录按小时的秒数（24 格，[1] 为 0 点）；只有云端时长的日子为 nil
---@field books Book[]|nil 日详情书单（含云端单书按日时长）

--- 阅读日历（insight 页月历）。
---@class StatsCalendar
---@field initial_ym string 初始年月，格式 YYYY-MM
---@field days table<string, StatsCalendarDay> 键为 YYYY-MM-DD

--- 阅读统计总览 KPI（insight 页英雄区 + 次级指标）。
---@class StatsTotal
---@field has_data boolean 是否有可展示的统计数据
---@field total_pages number|nil 累计阅读页数
---@field total_seconds number|nil 总阅读秒数
---@field total_text string|nil 总阅读时长文案（英雄区大字）
---@field last7_text string|nil 近 7 天阅读时长文案
---@field longest_day_text string|nil 单日最长阅读时长文案

--- 阅读洞察整页数据（总览 KPI + 日历），由 Catalog.toInsight 从 reading_stats 聚合产出。
---@class StatsInsight
---@field has_data boolean 是否有统计；false 时 insight 页显示空态
---@field total StatsTotal 总览 KPI
---@field calendar StatsCalendar 月历与日书单
---@field sessions table[] 近一年本机阅读段（Calc.sessions）
---@field finished table[] 读完的书（StatsDB.progressBooks）
---@field reading table[] 在读的书，最近阅读在前

--- readingInsight 返回包装；失败走第二返回值 err。
---@class BookInsightResult
---@field data StatsInsight|nil

--- 列表响应（图书馆 / 书城 / 最近阅读）。
---@class BookListResult
---@field count number|nil 符合条件的总条数（分页用）
---@field data Book[]|nil 本页书籍；无数据时为空表

require("l10n").apply()

local _ = require("gettext")

local Catalog = {}

--- 构造标准 BookListResult。
---@param books Book[]|nil
---@param count number|nil
---@return BookListResult
function Catalog.listResult(books, count)
    local data = books or {}
    return {
        data = data,
        count = tonumber(count) or #data,
    }
end

--- 简易模板替换（离线测试的 LuaJIT 无 table.pack，不能依赖 ffi/util.template）。
---@param fmt string
---@return string
local function T(fmt, a1, a2)
    local s = tostring(fmt)
    if a1 ~= nil then s = s:gsub("%%1", tostring(a1), 1) end
    if a2 ~= nil then s = s:gsub("%%2", tostring(a2), 1) end
    return s
end

--- 时长格式化（秒 → 「N小时N分钟」/「N分钟」）。
---@param seconds number|nil
---@return string
function Catalog.formatDuration(seconds)
    local sec = math.floor(tonumber(seconds) or 0)
    if sec <= 0 then
        return T(_("%1分钟"), 0)
    end
    local h = math.floor(sec / 3600)
    local m = math.floor((sec % 3600) / 60)
    if h > 0 then
        return T(_("%1小时%2分钟"), h, m)
    end
    return T(_("%1分钟"), math.max(1, m))
end

--- 展示查询范围：混合 → 已启用源 id 列表；否则原样返回 preferred_id。
--- 单元素列表收成字符串，SQL 走 `=` 而不是 `IN`。
---@param preferred_id string|string[]|nil
---@return string|string[]|nil
function Catalog.libraryScope(preferred_id)
    if not require("utils.settings").get("source").library_mixed then
        return preferred_id
    end
    local ids = {}
    for _idx, meta in ipairs(require("source.registry").listEnabled()) do
        ids[#ids + 1] = meta.id
    end
    if #ids == 1 then
        return ids[1]
    end
    return ids
end

--- books 表行 → Book。
---@param row table|nil
---@param source_id string|nil 行内缺 source_id 时使用
---@return Book|nil
local function toBook(row, source_id)
    if type(row) ~= "table" or type(row.stable_id) ~= "string" or row.stable_id == "" then
        return nil
    end
    return {
        source_id = row.source_id or source_id,
        stable_id = row.stable_id,
        title = row.title,
        authors = row.authors,
        intro = row.intro,
        category = row.category,
        series = row.series,
        percent = tonumber(row.percent) or 0,
        read_state = tonumber(row.read_state) or 0,
        path = row.path,
        inserted_at = row.inserted_at,
        downloaded = row.downloaded,
        chapter_idx = row.chapter_idx,
        chapter_title = row.chapter_title,
        page = row.page,
        total_pages = row.total_pages,
    }
end

--- books 表行 → BookListResult。
---@param rows table[]|nil
---@param count number|nil
---@param source_id string|nil 行内缺 source_id 时使用
---@return BookListResult
function Catalog.toList(rows, count, source_id)
    local books = {}
    for _idx, row in ipairs(rows or {}) do
        local book = toBook(row, source_id)
        if book then
            books[#books + 1] = book
        end
    end
    return Catalog.listResult(books, tonumber(count) or #books)
end

--- 阅读统计聚合 → StatsInsight。
---@param source_id string|string[] 单源字符串或多源列表
---@param summary table|nil
---@param daily table[]|nil
---@param daily_books table[]|nil
---@param hourly table<string, number[]>|nil StatsDB.hourlyBySource
---@param extra table|nil { session_rows, finished, reading }
---@return StatsInsight
function Catalog.toInsight(source_id, summary, daily, daily_books, hourly, extra)
    extra = extra or {}
    local has_data = (tonumber(summary and summary.total_seconds) or 0) > 0
    local days = {}
    for _idx, d in ipairs(daily or {}) do
        if type(d.ymd) == "string" then
            days[d.ymd] = {
                duration_seconds = tonumber(d.seconds) or 0,
                duration_text = Catalog.formatDuration(d.seconds),
                pages = tonumber(d.pages) or 0,
                hours = hourly and hourly[d.ymd],
                books = {},
            }
        end
    end
    local BookDB = require("book.books_db")
    -- 全部历史的（天，书）可达上千行，书却只有几十本：按书查一次，否则 UI 线程上逐行查库。
    local metas, fractions = {}, {}
    local function appendBook(day, b)
        if day and type(b.stable_id) == "string" and b.stable_id ~= "" then
            local sid = b.source_id or source_id
            local key = tostring(sid) .. "\0" .. b.stable_id
            if metas[key] == nil then
                metas[key] = type(sid) == "string" and BookDB.get(sid, b.stable_id) or false
            end
            local meta = metas[key] or nil
            local max_total = tonumber(b.max_total_pages) or 0
            local percent = 0
            if max_total > 0 then
                percent = math.floor((tonumber(b.max_page) or 0) * 100 / max_total + 0.5)
                if percent > 100 then
                    percent = 100
                end
            elseif type(sid) == "string" then
                -- 只有云端时长的那天没有页坐标，退回当前阅读进度
                if fractions[key] == nil then
                    local progress = require("book.progress_db").get(sid, b.stable_id)
                    fractions[key] = progress and tonumber(progress.fraction) or false
                end
                if fractions[key] then
                    percent = math.floor(fractions[key] * 100 + 0.5)
                end
            end
            local title = meta and meta.title or nil
            if not title or title == "" then
                title = (b.stable_id:match("([^/]+)$") or b.stable_id):gsub("%.[^.]+$", "")
            end
            day.books[#day.books + 1] = {
                source_id = sid,
                stable_id = b.stable_id,
                title = title,
                authors = meta and meta.authors or nil,
                percent = percent,
                duration_seconds = tonumber(b.seconds) or 0,
                duration_text = Catalog.formatDuration(b.seconds),
            }
        end
    end
    for _idx, b in ipairs(daily_books or {}) do
        appendBook(type(b.ymd) == "string" and days[b.ymd] or nil, b)
    end
    local total_seconds = tonumber(summary and summary.total_seconds) or 0
    return {
        has_data = has_data,
        total = {
            has_data = has_data,
            total_pages = tonumber(summary and summary.total_pages) or 0,
            total_seconds = total_seconds,
            total_text = Catalog.formatDuration(total_seconds),
            last7_text = Catalog.formatDuration(summary and summary.last7_seconds),
            longest_day_text = Catalog.formatDuration(summary and summary.longest_day_seconds),
        },
        calendar = {
            initial_ym = os.date("%Y-%m"),
            days = days,
        },
        sessions = require("book.insight_calc").sessions(extra.session_rows or {}),
        finished = extra.finished or {},
        reading = extra.reading or {},
    }
end

---@param scope string|string[]|nil
---@return boolean
local function validScope(scope)
    return type(scope) == "string" and scope ~= ""
        or type(scope) == "table" and #scope > 0
end

--- 下一 tick 解析展示范围再查询：范围无效时 cb(nil, "invalid source_id")，否则 fn(scope)。
---@param source_id string
---@param cb fun(data: any, err: string|nil)
---@param fn fun(scope: string|string[])
---@return { cancel: fun() }
local function deferScoped(source_id, cb, fn)
    local cancelled = false
    require("ui/uimanager"):nextTick(require("ui.guard").wrap("catalog defer", function()
        if cancelled then
            return
        end
        local scope = Catalog.libraryScope(source_id)
        if not validScope(scope) then
            cb(nil, "invalid source_id")
            return
        end
        ---@cast scope string|string[]
        fn(scope)
    end))
    return { cancel = function()
            cancelled = true
        end }
end

--- 章节型源 id（已下载要按章节登齐判定）。
---@return string[]
local function chapterSources()
    local ids = {}
    for _idx, meta in ipairs(require("source.registry").list()) do
        if meta.type == "chapter" then ids[#ids + 1] = meta.id end
    end
    return ids
end

--- 书库分页查询：books 筛选 + LEFT JOIN pending_progress 取进度与最近阅读排序；每行带 downloaded。
---@param source_id string|string[]
---@param opts table|nil limit/offset/sort/sort_desc/chapter_sources 及 BookListOpts 的筛选项
---@return table[] rows, number count, string|nil err 查询出错时 rows 为空表、err 非空（区别于真的 0 本）
function Catalog.listBooks(source_id, opts)
    opts = opts or {}
    local DB = require("utils.db")
    local BookDB = require("book.books_db")
    require("book.progress_db")
    local where, args = DB.sourceClause("b.source_id", source_id)
    -- 「最近阅读」列整个书架：在架书全列；Kavita 卷行这种「非书架成员但仍是有效身份」的
    -- 只在有进度时进来（进度记在卷行上）。其它排序 / 筛选只列在架书。
    where = where .. (opts.sort == "recent_read"
        and " AND (b.deleted=0 OR (" .. BookDB.readableClause("b") .. " AND p.stable_id IS NOT NULL"
            -- 下架后换了身份重新上架的书（同源同名的在架行）只列在架那本，旧行不再像重复条目
            .. " AND NOT EXISTS (SELECT 1 FROM books s WHERE s.source_id=b.source_id"
            .. " AND s.deleted=0 AND s.title=b.title)))"
        or " AND b.deleted=0")
    where = where .. (opts.hidden and " AND b.hidden=1" or " AND b.hidden=0")
    if type(opts.source_id) == "string" and opts.source_id ~= "" then
        where = where .. " AND b.source_id=?"
        args[#args + 1] = opts.source_id
    end
    if opts.uncategorized then
        where = where .. " AND (b.category IS NULL OR b.category='')"
    elseif opts.category and opts.category ~= "" then
        where = where .. " AND b.category=?"
        args[#args + 1] = opts.category
    end
    if opts.unseries then
        where = where .. " AND (b.series IS NULL OR b.series='')"
    elseif opts.series and opts.series ~= "" then
        where = where .. " AND b.series=?"
        args[#args + 1] = opts.series
    end
    if type(opts.dir) == "string" and opts.dir ~= "" then
        -- 只取该目录下直接放的书；substr 按字符计，前缀长度也要按字符数。
        local prefix = opts.dir .. "/"
        local chars = select(2, prefix:gsub("[^\128-\191]", ""))
        local expr, root_args = Catalog.folderPathExpr("b", opts.root)
        where = where .. " AND substr(" .. expr .. ", 1, ?)=? AND instr(substr(" .. expr .. ", ?), '/')=0"
        for i = 1, 2 do
            for _idx, a in ipairs(root_args) do args[#args + 1] = a end
            if i == 1 then
                args[#args + 1] = chars
                args[#args + 1] = prefix
            else
                args[#args + 1] = chars + 1
            end
        end
    end
    if opts.unauthor then
        where = where .. " AND (b.authors IS NULL OR b.authors='')"
    elseif opts.author and opts.author ~= "" then
        where = where .. " AND b.authors=?"
        args[#args + 1] = opts.author
    end
    if opts.search and opts.search ~= "" then
        where = where .. [[ AND (b.title LIKE ? ESCAPE '\' OR b.authors LIKE ? ESCAPE '\' OR b.stable_id LIKE ? ESCAPE '\')]]
        local like = "%" .. opts.search:gsub("([%%_\\])", "\\%1") .. "%"
        args[#args + 1] = like
        args[#args + 1] = like
        args[#args + 1] = like
    end
    if opts.read_status == "read" then
        where = where .. " AND b.read_state=1"
    elseif opts.read_status == "unread" then
        where = where .. " AND b.read_state<>1"
    elseif opts.read_status == "new" then
        where = where .. " AND b.read_state<>1 AND COALESCE(p.fraction, 0)<=0"
    end
    if opts.downloaded then
        where = where .. " AND " .. BookDB.downloadedClause(opts.chapter_sources, args)
    end
    -- 一律 LEFT JOIN：「最近阅读」按 max(本机进度时间, 云端最近阅读时间 b.read_at) 倒序，
    -- 都没有的书排在后面按加入时间倒序。首页「最近阅读 / 当前阅读」走 ProgressDB.recent，仍只列有进度的书。
    local join = " LEFT JOIN pending_progress p ON p.source_id=b.source_id AND p.stable_id=b.stable_id"
    local count_raw = DB.rowexec("SELECT COUNT(*) FROM books b" .. join .. " WHERE " .. where .. ";", unpack(args))
    if count_raw == nil then
        return {}, 0, "query failed"
    end
    local total = tonumber(count_raw) or 0
    if total == 0 then
        return {}, 0
    end
    local limit = tonumber(opts.limit) or 0
    local offset = tonumber(opts.offset) or 0
    local sort_sql = {
        title = "COALESCE(b.title, '') COLLATE NOCASE %s, b.stable_id ASC",
        author = "COALESCE(b.authors, '') COLLATE NOCASE %s, COALESCE(b.title, '') COLLATE NOCASE %s, b.stable_id ASC",
        recent_read = "MAX(COALESCE(p.updated_at, 0), b.read_at) DESC, b.inserted_at DESC, b.stable_id ASC",
        recent_added = "b.inserted_at DESC, b.stable_id ASC",
    }
    local order = (sort_sql[opts.sort] or sort_sql.recent_added)
        :gsub("%%s", opts.sort_desc and "DESC" or "ASC")
    -- SELECT 里的占位符排在 WHERE 之前，绑定参数也要按这个顺序拼。
    local sel_args = {}
    local downloaded = BookDB.downloadedClause(opts.chapter_sources or {}, sel_args)
    local sel = [[SELECT b.source_id, b.stable_id, b.title, b.authors,
                        COALESCE(p.fraction * 100, 0),
                        b.category, b.series, b.intro, b.cover, b.inserted_at,
                        b.read_state, b.path, ]] .. downloaded .. [[
                   FROM books b]] .. join .. [[
                   WHERE ]] .. where .. " ORDER BY " .. order
    for _idx, v in ipairs(args) do sel_args[#sel_args + 1] = v end
    if limit > 0 then
        sel = sel .. " LIMIT ? OFFSET ?"
        sel_args[#sel_args + 1] = limit
        sel_args[#sel_args + 1] = math.max(0, offset)
    end
    local result, nrows = DB.query(sel .. ";", unpack(sel_args))
    if not result then
        return {}, 0, "query failed"
    end
    local rows = {}
    for i = 1, nrows do
        rows[i] = {
            source_id = result[1][i],
            stable_id = result[2][i],
            title = result[3][i],
            authors = result[4][i],
            percent = tonumber(result[5][i]) or 0,
            category = result[6][i],
            series = result[7][i],
            intro = result[8][i],
            cover = result[9][i],
            inserted_at = tonumber(result[10][i]) or 0,
            read_state = tonumber(result[11][i]) or 0,
            path = result[12][i],
            downloaded = tonumber(result[13][i]) == 1,
            deleted = 0,
        }
    end
    return rows, total
end

--- 图书馆分页 / 搜索 / 筛选。
---@param source_id string
---@param opts BookListOpts|nil
---@param cb fun(data: BookListResult|nil, err: string|nil)
---@return { cancel: fun() }
function Catalog.listLibraryAsync(source_id, opts, cb)
    opts = opts or {}
    local page = math.max(1, tonumber(opts.page) or 1)
    local page_size = math.max(1, tonumber(opts.page_size) or 24)
    return deferScoped(source_id, cb, function(scope)
        local rows, count, err = Catalog.listBooks(scope, {
            category = opts.category,
            uncategorized = opts.uncategorized,
            series = opts.series,
            unseries = opts.unseries,
            author = opts.author,
            unauthor = opts.unauthor,
            search = opts.search,
            read_status = opts.read_status,
            downloaded = opts.downloaded,
            hidden = opts.hidden,
            chapter_sources = chapterSources(),
            source_id = opts.source_id,
            sort = opts.sort,
            sort_desc = opts.sort_desc,
            limit = page_size,
            offset = (page - 1) * page_size,
        })
        if err then
            -- 库查询出错不能显示成「0 本」：交给图书馆页显示「加载失败」。
            cb(nil, _("加载失败"))
            return
        end
        cb(Catalog.toList(rows, count, type(scope) == "string" and scope or nil))
    end)
end

local FOLDER_COVERS = { "cover.jpg", "cover.jpeg", "cover.png" }

--- 文件夹约定封面：目录里的 cover.jpg / cover.png。
---@param dir string
---@return string|nil
local function folderCover(dir)
    local lfs = require("libs/libkoreader-lfs")
    for _idx, name in ipairs(FOLDER_COVERS) do
        local path = dir .. "/" .. name
        if lfs.attributes(path, "mode") == "file" then return path end
    end
end

--- 文件夹视图用的书路径：已落盘的取 path，WebDAV 远端未下载的书（path 为空）取下载后会在的 root/相对路径。
---@param alias string
---@param root string|nil
---@return string expr, any[] args
function Catalog.folderPathExpr(alias, root)
    if not root or root == "" then return alias .. ".path", {} end
    return "COALESCE(" .. alias .. ".path, CASE WHEN " .. alias .. ".stable_id LIKE 'webdav://%' THEN ? || '/' || substr("
        .. alias .. ".stable_id, 10) END)", { root }
end

--- 本地书库的文件夹视图一页：先列 dir 下的子文件夹（按名称），再列直接放在 dir 里的书。
--- 子文件夹以 { is_folder = true, title, dir, cover } 条目返回，cover 取目录里的 cover.jpg / cover.png。
---@param source_id string
---@param opts { dir: string, root?: string, page: number|nil, page_size: number|nil, sort: string|nil }
---@param cb fun(data: BookListResult|nil, err: string|nil)
---@return { cancel: fun() }
function Catalog.folderPageAsync(source_id, opts, cb)
    local page = math.max(1, tonumber(opts.page) or 1)
    local page_size = math.max(1, tonumber(opts.page_size) or 24)
    local dir = opts.dir
    return deferScoped(source_id, cb, function(scope)
        local DB = require("utils.db")
        local where, args = DB.sourceClause("source_id", scope)
        local prefix = dir .. "/"
        -- 范围比较取出前缀下的全部路径（\255 大于任何 UTF-8 字节）。
        local expr, root_args = Catalog.folderPathExpr("books", opts.root)
        local qargs = {}
        local function push(list) for _idx, a in ipairs(list) do qargs[#qargs + 1] = a end end
        push(root_args)
        push(args)
        push(root_args)
        qargs[#qargs + 1] = prefix
        push(root_args)
        qargs[#qargs + 1] = prefix .. "\255"
        local result, nrows = DB.query(
            "SELECT " .. expr .. " FROM books WHERE " .. where
                .. " AND source_id='local' AND deleted=0 AND hidden=0 AND " .. expr .. ">=? AND " .. expr .. "<?;",
            unpack(qargs)
        )
        local counts, names = {}, {}
        for i = 1, nrows or 0 do
            local name = tostring(result[1][i] or ""):sub(#prefix + 1):match("^([^/]+)/")
            if name then
                if not counts[name] then names[#names + 1] = name end
                counts[name] = (counts[name] or 0) + 1
            end
        end
        table.sort(names, function(a, b)
            local la, lb = a:lower(), b:lower()
            if la ~= lb then return la < lb end
            return a < b
        end)
        local start = (page - 1) * page_size
        local entries = {}
        for i = start + 1, math.min(#names, start + page_size) do
            local full = prefix .. names[i]
            entries[#entries + 1] = {
                is_folder = true, title = names[i], dir = full, cover = folderCover(full), count = counts[names[i]],
            }
        end
        local need = page_size - #entries
        local rows, total, err = Catalog.listBooks(scope, {
            dir = dir,
            root = opts.root,
            source_id = "local",
            sort = opts.sort,
            limit = need > 0 and need or 1,
            offset = need > 0 and math.max(0, start - #names) or 0,
        })
        if err then
            cb(nil, _("加载失败"))
            return
        end
        if need > 0 then
            for _idx, book in ipairs(Catalog.toList(rows, total, type(scope) == "string" and scope or nil).data) do
                entries[#entries + 1] = book
            end
        end
        cb(Catalog.listResult(entries, #names + (tonumber(total) or 0)))
    end)
end

--- 一列的分组计数（图书馆作者 / 系列 / 分类页签）；只算这一列，切页签不连带算全部筛选聚合。
---@param source_id string
---@param column "authors"|"series"|"category"
---@param cb fun(rows: table[]|nil, err: string|nil) 行带 [column] 与 count
---@return { cancel: fun() }
function Catalog.groupCountsAsync(source_id, column, cb)
    return deferScoped(source_id, cb, function(scope)
        cb(require("book.books_db").countsBy(column, scope))
    end)
end

--- 分类 / 系列 /（混合时）数据源筛选项。
---@param source_id string
---@param cb fun(data: BookFiltersResult|nil, err: string|nil)
---@return { cancel: fun() }
function Catalog.filtersAsync(source_id, cb)
    return deferScoped(source_id, cb, function(scope)
        local BookDB = require("book.books_db")
        local data = {
            category_counts = BookDB.countsBy("category", scope),
            series_counts = BookDB.countsBy("series", scope),
            author_counts = BookDB.countsBy("authors", scope),
            read_counts = BookDB.readStatusCountsBySource(scope),
            downloaded_count = BookDB.downloadedCountBySource(scope, chapterSources()),
            hidden_count = BookDB.hiddenCountBySource(scope),
        }
        -- 仅多源混合时给出源分组；顺序跟已启用列表，册数来自聚合。
        if type(scope) == "table" then
            local by_id = {}
            for _idx, row in ipairs(BookDB.sourceCountsBySource(scope)) do
                by_id[row.source_id] = row.count
            end
            local Registry = require("source.registry")
            local source_counts = {}
            for _idx, meta in ipairs(Registry.listEnabled()) do
                local name = meta.name
                if type(name) ~= "string" or name == "" then
                    name = meta.id
                end
                source_counts[#source_counts + 1] = {
                    source_id = meta.id,
                    name = name,
                    count = by_id[meta.id] or 0,
                }
            end
            data.source_counts = source_counts
        end
        cb({ data = data })
    end)
end

--- 首页书架：第一本当前阅读，其余在读；source 无效时带错误文案。
---@param source_id string|nil
---@param limit number|nil
---@return Book|nil
---@return Book[]
---@return string|nil
function Catalog.recentShelf(source_id, limit)
    if not validScope(Catalog.libraryScope(source_id)) then
        return nil, {}, _("当前数据源不可用")
    end
    -- pending_progress 主键是 (source_id, stable_id)，行不重复，第一本之后即其余在读
    local rows = Catalog.recentBooks(source_id, limit or 24)
    return rows[1], { unpack(rows, 2) }, nil
end

--- 最近阅读同步快照：进度决定准入、顺序和阅读位置，books 只补书库元数据。
---@param source_id string|string[]|nil
---@param limit number|nil
---@return Book[]
function Catalog.recentBooks(source_id, limit)
    local scope = Catalog.libraryScope(source_id)
    if not validScope(scope) then
        return {}
    end
    ---@cast scope string|string[]
    local progress_rows = require("book.progress_db").recent(scope, limit)
    local books = {}
    local BookDB = require("book.books_db")
    local chapter = {}
    for _idx, id in ipairs(chapterSources()) do chapter[id] = true end
    for _idx, progress in ipairs(progress_rows) do
        -- 按 (source_id, stable_id) 取元数据，避免跨源 stable_id 碰撞。
        local meta = BookDB.get(progress.source_id, progress.stable_id)
        local book = toBook(meta, progress.source_id)
        if book then
            book.downloaded = BookDB.isDownloaded(book.source_id, book.stable_id, chapter[book.source_id] == true)
            book.percent = math.floor((tonumber(progress.fraction) or 0) * 100 + 0.5)
            book.chapter_idx = progress.chapter_idx
            book.chapter_title = progress.chapter_title
            book.page = progress.page
            book.total_pages = progress.total_pages
            books[#books + 1] = book
        end
    end
    return books
end

--- 阅读洞察（reading_stats 聚合）。
---@param source_id string
---@param cb fun(data: BookInsightResult|nil, err: string|nil)
---@return { cancel: fun() }
function Catalog.readingInsightAsync(source_id, cb)
    return deferScoped(source_id, cb, function(scope)
        cb({ data = Catalog.readingInsight(scope) })
    end)
end

--- 同步读本地洞察（桌面统计页与锁屏统计背景共用）。
---@param scope string|string[] Catalog.libraryScope 的结果
---@return StatsInsight
function Catalog.readingInsight(scope)
    local StatsDB = require("book.stats_db")
    return Catalog.toInsight(
        scope,
        StatsDB.summaryBySource(scope),
        StatsDB.dailyBySource(scope),
        StatsDB.dailyBooksBySource(scope),
        StatsDB.hourlyBySource(scope),
        {
            session_rows = StatsDB.sessionRows(scope, os.time() - 400 * 86400),
            finished = StatsDB.progressBooks(scope, true),
            reading = StatsDB.progressBooks(scope, false, 5),
        }
    )
end

return Catalog
