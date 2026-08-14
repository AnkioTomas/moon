--- Book / BookRef 领域类型。
--- stable_id 仅源内唯一；跨源主键为 book_key = md5(source_id .. ":" .. stable_id)。

local md5 = require("ffi/sha2").md5

--- 跨层书籍身份：业务传 BookRef，缓存用派生 book_key。
---@class BookRef
---@field source_id string 源标识（moon / webdav / wechat 等）
---@field stable_id string 源内稳定身份；禁止跨源比较或合并
---@field book_key string md5(source_id .. ":" .. stable_id)；SQLite / 目录 / 缓存键，不传远端

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

--- 对应表 books：身份列 + 展示元数据 + 统计 md5。
--- 列顺序与 CREATE TABLE / BookDB.upsert 一致。
---@class Book
---@field book_key string PRIMARY KEY；md5(source_id .. ":" .. stable_id)
---@field source_id string 源标识
---@field stable_id string 源内稳定身份
---@field filename string|nil 统计/本地关联名（常等于 stable_id）
---@field md5 string|nil 内容 partialMD5；清缓存不删
---@field title string|nil 书名
---@field authors string|nil 作者
---@field percent number 阅读进度 0..100（DB REAL，默认 0）
---@field category string|nil 分类 / 标签
---@field favorite string|nil 收藏 / 置顶等标记（DB TEXT）
---@field series string|nil 系列名
---@field intro string|nil 简介
---@field fetched_at integer 元数据拉取时间戳；0 表示仅身份行
---@field ref BookRef|nil 运行时由身份列派生，不入库
---@field cover string|nil 封面 URL，不入库（下载走 Source.coverRequest）

local Book = {}

--- 百分比钳制到 0..100 整数。
--- as_frac 或 (0,1) 区间值按比例换算；finished 为真且未满则抬到 100。
---@param raw any 原始进度（百分数或 0..1 比例）
---@param finished boolean|nil 是否已读完
---@param as_frac boolean|nil 强制按 0..1 比例解释
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
