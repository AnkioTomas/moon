--[[--
Moon wire → 领域对象

@module koplugin.book.source.moon.mapper
--]]

local Contract = require("source.contract")

local Mapper = {}

local SOURCE_ID = "moon"

--- 从列表行提取稳定书 ID（filename 优先）。
---@param row table|nil
---@return string|nil
local function stableId(row)
    if type(row) ~= "table" then
        return nil
    end
    local id = row.filename or row.fileName or row.file or row.id or row.bookId
    if id == nil then
        return nil
    end
    id = tostring(id)
    if id == "" then
        return nil
    end
    return id
end

--- 判断用户是否已读完该书。
---@param row table|nil
---@return boolean
local function userFinished(row)
    if type(row) ~= "table" then
        return false
    end
    if row.finished == true then
        return true
    end
    if row.finishReading == 1 or row.finishReading == true then
        return true
    end
    return false
end

--- 列表行 wire → Book。
---@param row table|nil
---@return Book|nil
function Mapper.book(row)
    if type(row) ~= "table" then
        return nil
    end
    local sid = stableId(row)
    if not sid then
        return nil
    end
    local finished = userFinished(row)
    return {
        ref = Contract.makeRef(SOURCE_ID, sid),
        title = row.title or row.bookName or row.name,
        authors = row.authors or row.author,
        percent = Contract.clampPercent(
            row.percent or row.progress or row.progressPercent or row.readProgress,
            finished
        ),
        category = row.category,
        favorite = row.favorite,
        series = row.series,
        cover = type(row.cover) == "string" and row.cover or nil,
    }
end

--- 详情行 wire → BookDetail。
---@param row table|nil
---@return BookDetail|nil
function Mapper.detail(row)
    local book = Mapper.book(row)
    if not book then
        return nil
    end
    local intro = row and (row.intro or row.description or row.summary)
    if type(intro) == "string" and intro ~= "" then
        book.intro = intro
    end
    return book
end

--- 列表 wire → BookListResult。
---@param wire table|nil
---@return BookListResult
function Mapper.list(wire)
    if type(wire) ~= "table" then
        return Contract.emptyList()
    end
    local list = wire.data or wire.list or wire.books or {}
    local out = {}
    if type(list) == "table" then
        for _, row in ipairs(list) do
            local b = Mapper.book(row)
            if b then
                out[#out + 1] = b
            end
        end
    end
    return Contract.listResult(out, tonumber(wire.count) or #out)
end

--- Moon 进度 wire → ProgressPosition
---@param wire any
---@return ProgressPosition|nil
function Mapper.progress(wire)
    if wire == nil then
        return nil
    end
    local node = wire
    if type(wire) == "table" then
        if type(wire.data) == "table" then
            node = wire.data
        elseif type(wire.data) == "number" then
            return { fraction = Contract.clampFraction(wire.data) }
        end
    elseif type(wire) == "number" then
        return { fraction = Contract.clampFraction(wire) }
    else
        return nil
    end
    if type(node) ~= "table" then
        return nil
    end
    local finished = userFinished(node)
    local percent = Contract.clampPercent(
        node.percent or node.progress or node.progressPercent or node.readingProgress,
        finished
    )
    return {
        fraction = Contract.clampFraction(percent / 100),
        chapter_idx = tonumber(node.chapter_idx or node.chapterIdx or node.spine),
        locator = node.locator,
    }
end

--- 构造空的阅读统计洞察结构。
---@return StatsInsight
local function emptyInsight()
    return {
        has_data = false,
        total = { has_data = false },
        calendar = {
            initial_ym = os.date("%Y-%m"),
            days = {},
        },
    }
end

--- 统计洞察 wire → StatsInsight。
---@param raw table|nil
---@return StatsInsight
function Mapper.insight(raw)
    if type(raw) ~= "table" then
        return emptyInsight()
    end
    if type(raw.total) == "table" and type(raw.calendar) == "table"
        and raw.readingActivity == nil and raw.perDay == nil then
        local has_data = not not (raw.has_data or raw.total.has_data)
        return {
            has_data = has_data,
            total = {
                has_data = has_data,
                total_pages = tonumber(raw.total.total_pages),
                total_text = raw.total.total_text,
                last7_text = raw.total.last7_text,
                longest_day_text = raw.total.longest_day_text,
            },
            calendar = {
                initial_ym = raw.calendar.initial_ym or os.date("%Y-%m"),
                days = raw.calendar.days or {},
            },
        }
    end

    local data = raw
    if type(raw.data) == "table" and (raw.data.readingActivity or raw.data.perDay or raw.data.hasData ~= nil) then
        data = raw.data
    end

    local activity = data.readingActivity or {}
    local kpi = activity.kpi or {}
    local has_data = not not (data.hasData or activity.hasData or data.has_data)

    local per_day = data.perDay or data.days or {}
    local days = {}
    for ymd, day in pairs(per_day) do
        if type(day) == "table" then
            local books = {}
            if type(day.books) == "table" then
                for _, b in ipairs(day.books) do
                    local nb = Mapper.book(b)
                    if nb then
                        books[#books + 1] = nb
                    end
                end
            end
            days[ymd] = {
                duration_seconds = tonumber(day.duration_seconds or day.duration),
                duration_text = day.duration_text or day.durationText,
                books = books,
            }
        end
    end

    return {
        has_data = has_data,
        total = {
            has_data = has_data,
            total_pages = tonumber(kpi.total_pages or kpi.totalPagesRead),
            total_text = kpi.total_text or kpi.totalReadingTime,
            last7_text = kpi.last7_text or kpi.last7DaysReadTime,
            longest_day_text = kpi.longest_day_text or kpi.longestDay,
        },
        calendar = {
            initial_ym = data.initialYm or data.initial_ym or os.date("%Y-%m"),
            days = days,
        },
    }
end

return Mapper
