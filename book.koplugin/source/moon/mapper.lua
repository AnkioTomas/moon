--[[--
Moon wire → 领域对象

@module koplugin.book.source.moon.mapper
--]]

local Book = require("types.book").Book
local ProgressPosition = require("types.book_progress")
local BookListResult = require("types.book_list")

local Mapper = {}

local SOURCE_ID = "moon"

---@param value any
---@return number|nil
local function percentNumber(value)
    if type(value) == "string" then
        value = value:match("^%s*([%+%-]?[%d%.]+)%%?%s*$")
    end
    return tonumber(value)
end

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
    if row.hasReadTag == 1 or row.hasReadTag == true then
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
    local out = {
        source_id = SOURCE_ID, stable_id = sid,
        title = row.title or row.bookName or row.name,
        authors = row.authors or row.author,
        percent = Book.clampPercent(
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
        return BookListResult.empty()
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
    return BookListResult.new(out, tonumber(wire.count) or #out)
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
            return { fraction = ProgressPosition.clampFraction(wire.data) }
        end
    elseif type(wire) == "number" then
        return { fraction = ProgressPosition.clampFraction(wire) }
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
    local fraction = percent and ProgressPosition.clampFraction(percent / 100)
        or ProgressPosition.clampFraction(node.frac)
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
