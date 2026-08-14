--- Book / BookRef 领域类型。

local md5 = require("ffi/sha2").md5

---@class BookRef
---@field source_id string
---@field stable_id string
---@field book_key string

local BookRef = {}

--- 计算跨源书籍主键。
---@param source_id string
---@param stable_id string
---@return string
function BookRef.keyOf(source_id, stable_id)
    if type(source_id) ~= "string" or source_id == "" then
        error("BookRef.source_id required")
    end
    if type(stable_id) ~= "string" or stable_id == "" then
        error("BookRef.stable_id required")
    end
    return md5(source_id .. ":" .. stable_id)
end

--- 构造完整书籍身份。
---@param source_id string
---@param stable_id string
---@return BookRef
function BookRef.new(source_id, stable_id)
    return {
        source_id = source_id,
        stable_id = stable_id,
        book_key = BookRef.keyOf(source_id, stable_id),
    }
end

---@class Book
---@field ref BookRef
---@field title string|nil
---@field authors string|nil
---@field percent number 阅读进度 0..100
---@field category string|nil
---@field favorite any
---@field series string|nil
---@field cover string|nil
---@field intro string|nil

local Book = {}

--- 百分比钳制到 0..100 整数。
---@param raw any
---@param finished boolean|nil
---@param as_frac boolean|nil
---@return number
function Book.clampPercent(raw, finished, as_frac)
    local n = tonumber(raw) or 0
    if as_frac or (n > 0 and n < 1) then
        n = n * 100
    end
    n = math.floor(n + 0.5)
    if n < 0 then
        n = 0
    elseif n > 100 then
        n = 100
    end
    if finished and n < 100 then
        return 100
    end
    return n
end

return {
    BookRef = BookRef,
    Book = Book,
}
