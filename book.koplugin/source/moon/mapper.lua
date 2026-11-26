--[[--
Moon wire → 领域对象

字段即服务端（PHP book）响应：
  /index/book/list      data[] = BookModel 字段 + progressPercent(0–100) + hasReadTag
  /index/book/progress  data = { percent(0–100), spine, page, offset, locator, timestamp(ms) } | null

@module koplugin.book.source.moon.mapper
--]]

local Progress = require("book.progress")
local Catalog = require("book.catalog")
local Text = require("utils.text")

local Mapper = {}

local SOURCE_ID = "moon"

--- 列表行 wire → Book；没有 filename 的行不是可打开的书。
---@param row table
---@return Book|nil
function Mapper.book(row)
    if type(row) ~= "table" or type(row.filename) ~= "string" or row.filename == "" then
        return nil
    end
    local book = {
        source_id = SOURCE_ID,
        stable_id = row.filename,
        title = row.bookName,
        authors = row.author,
        percent = Progress.clampPercent(row.progressPercent, row.hasReadTag == true),
        category = row.favorite,
        series = row.series,
        cover = row.coverUrl,
    }
    if type(row.description) == "string" and row.description ~= "" then book.intro = Text.stripHtml(row.description) end
    return book
end

--- 列表 wire → BookListResult；data 不是数组返回 nil（不能拿残缺书单对账）。
---@param wire table
---@return BookListResult|nil
function Mapper.list(wire)
    if type(wire.data) ~= "table" then return nil end
    local out = {}
    for _idx, row in ipairs(wire.data) do
        out[#out + 1] = Mapper.book(row)
    end
    return Catalog.listResult(out, wire.count)
end

--- 进度 wire → ProgressPosition；云端没有进度（data 为 null）返回 nil，percent 不是数字算响应无效。
---@param wire table
---@return ProgressPosition|nil, boolean|nil invalid
function Mapper.progress(wire)
    local node = wire.data
    if type(node) ~= "table" then
        return nil
    end
    if type(node.percent) ~= "number" then return nil, true end
    local timestamp = tonumber(node.timestamp)
    return {
        fraction = Progress.clampFraction(node.percent / 100),
        chapter_idx = node.spine,
        page = node.page,
        -- 服务端在 locator 过期时回空串；归一成 nil，免得下游到处判空串。
        locator = node.locator ~= "" and node.locator or nil,
        extra = { offset = node.offset },
        updated_at = timestamp and math.floor(timestamp / 1000) or nil,
    }
end

return Mapper
