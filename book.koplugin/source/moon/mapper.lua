--[[--
Moon wire → 领域对象

@module koplugin.book.source.moon.mapper
--]]

local Progress = require("book.progress")
local Catalog = require("book.catalog")

local Mapper = {}

local SOURCE_ID = "moon"

---@return number|nil
local function percentNumber(value)
    if type(value) == "string" then
        value = value:match("^%s*([%+%-]?[%d%.]+)%%?%s*$")
    end
    return tonumber(value)
end

--- 从列表行提取稳定书 ID（filename 优先）。
---@param row table
---@return string|nil
local function stableId(row)
    local id = row.filename or row.fileName or row.file or row.id or row.bookId
    if id == nil then
        return nil
    end
    id = tostring(id)
    return id ~= "" and id or nil
end

--- 判断用户是否已读完该书。
---@param row table
---@return boolean
local function userFinished(row)
    return row.finished == true
        or row.finishReading == 1 or row.finishReading == true
        or row.hasReadTag == 1 or row.hasReadTag == true
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
    local out = {
        source_id = SOURCE_ID, stable_id = sid,
        title = row.title or row.bookName or row.name,
        authors = row.authors or row.author,
        percent = Progress.clampPercent(
            row.percent or row.progress or row.progressPercent or row.readProgress,
            finished
        ),
        category = row.favorite or row.category,
        series = row.series,
        cover = type(row.coverUrl) == "string" and row.coverUrl or nil,
    }
    local intro = row.description or row.intro or row.summary
    if type(intro) == "string" and intro ~= "" then out.intro = intro end
    return out
end

--- 列表 wire → BookListResult。
---@param wire table|nil
---@return BookListResult
function Mapper.list(wire)
    if type(wire) ~= "table" then
        return Catalog.listResult()
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
    return Catalog.listResult(out, tonumber(wire.count) or #out)
end

--- Moon 进度 wire → ProgressPosition
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
            return { fraction = Progress.clampFraction(wire.data) }
        end
    elseif type(wire) == "number" then
        return { fraction = Progress.clampFraction(wire) }
    else
        return nil
    end
    if type(node) ~= "table" then
        return nil
    end
    local finished = userFinished(node)
    local percent = percentNumber(
        node.percent or node.progress or node.progressPercent or node.readingProgress
    )
    local fraction = percent and Progress.clampFraction(percent / 100)
        or Progress.clampFraction(node.frac)
    if finished then fraction = 1 end
    local updated_at = tonumber(node.timestamp or node.progressTimestamp or node.readUpdateTime)
    if updated_at and updated_at > 1e12 then
        updated_at = math.floor(updated_at / 1000)
    end
    return {
        fraction = fraction,
        chapter_idx = tonumber(node.chapter_idx or node.chapterIdx or node.spine),
        page = tonumber(node.page or node.pageIndex),
        -- 服务端在 locator 过期时回空串；归一成 nil，免得下游到处判空串。
        locator = node.locator ~= "" and node.locator or nil,
        extra = tonumber(node.offset) and { offset = tonumber(node.offset) } or nil,
        updated_at = updated_at,
    }
end

return Mapper
