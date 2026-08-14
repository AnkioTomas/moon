--[[--
Source 契约公共工具：BookRef、能力默认值、数值规整。
源特有 wire 映射放在各自 mapper，不进本模块。

@module koplugin.book.source.contract
--]]

local md5 = require("ffi/sha2").md5

local Contract = {}

--- 构造 BookRef（含 book_key）。
---@param source_id string
---@param stable_id string
---@return BookRef
function Contract.makeRef(source_id, stable_id)
    if type(source_id) ~= "string" or source_id == "" then
        error("BookRef.source_id required")
    end
    if type(stable_id) ~= "string" or stable_id == "" then
        error("BookRef.stable_id required")
    end
    return {
        source_id = source_id,
        stable_id = stable_id,
        book_key = md5(source_id .. ":" .. stable_id),
    }
end

--- 返回全 false 的默认能力表。
---@return SourceCapabilities
function Contract.defaultCapabilities()
    return {
        library = false,
        recent = false,
        search = false,
        filters = false,
        detail = false,
        cover = false,
        whole_book = false,
        chapters = false,
        progress_pull = false,
        progress_push = false,
        insight = false,
        stats_import = false,
        store = false,
    }
end

--- 百分比钳制到 0..100 整数。
---@param raw any
---@param finished boolean|nil
---@param as_frac boolean|nil 若 true，raw 按 0..1 比例解释
---@return number
function Contract.clampPercent(raw, finished, as_frac)
    local n = tonumber(raw)
    if not n then
        n = 0
    end
    if as_frac then
        n = n * 100
    elseif n > 0 and n < 1 then
        n = n * 100
    end
    n = math.floor(n + 0.5)
    if n < 0 then
        n = 0
    elseif n > 100 then
        n = 100
    end
    if finished and n < 100 then
        n = 100
    end
    return n
end

--- fraction 钳制到 0..1。
---@param raw any
---@return number
function Contract.clampFraction(raw)
    local n = tonumber(raw)
    if not n then
        return 0
    end
    if n > 1 and n <= 100 then
        n = n / 100
    end
    if n < 0 then
        return 0
    end
    if n > 1 then
        return 1
    end
    return n
end

--- 归一化为空列表结果（可带已有 books）。
---@param books Book[]|nil
---@param count number|nil
---@return BookListResult
function Contract.emptyList(books, count)
    local data = books or {}
    return {
        data = data,
        count = tonumber(count) or #data,
    }
end

--- 构造标准 BookListResult。
---@param books Book[]
---@param count number|nil
---@return BookListResult
function Contract.listResult(books, count)
    return Contract.emptyList(books, count)
end

return Contract
