--- Book / BookRef 领域类型。
--- stable_id 仅源内唯一；跨源身份 = (source_id, stable_id)。

--- 跨层书籍身份：业务全程传 BookRef，不派生额外主键。
---@class BookRef
---@field source_id string 源标识（moon / webdav / wechat / local 等）
---@field stable_id string 源内稳定身份；禁止跨源比较或合并

local BookRef = {}

--- 构造书籍身份。
---@param source_id string
---@param stable_id string
---@return BookRef
function BookRef.new(source_id, stable_id)
    if type(source_id) ~= "string" or source_id == "" then
        error("BookRef.source_id required")
    end
    if type(stable_id) ~= "string" or stable_id == "" then
        error("BookRef.stable_id required")
    end
    return {
        source_id = source_id,
        stable_id = stable_id,
    }
end

--- 对应表 books：身份列 + 展示元数据 + 统计 md5。
---@class Book
---@field source_id string 源标识；与 stable_id 共同组成 PRIMARY KEY
---@field stable_id string 源内稳定身份；本地源即文件绝对路径
---@field md5 string|nil 内容 partialMD5；本地源用它识别文件改名/移动
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
