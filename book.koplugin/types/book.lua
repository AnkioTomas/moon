--- Book 领域类型。
--- stable_id 仅源内唯一；跨源身份 = (source_id, stable_id)。

--- 路径解析出的阅读身份（Store.identityFor / ensureIdentity 返回值）。
---@class BookIdentity
---@field source_id string 源标识（moon / wechat / local 等）
---@field stable_id string 源内稳定身份
---@field chapter_idx number|nil 章节文件时为章号；整本书为 nil
---@field book Book|nil books 表元数据行；刚登记/未入库时可能为内存行或 nil
---@field source BookSource|nil 属主源实例；仅 ensureIdentity（打开时）解析，identityFor 不挂

--- 对应表 books：身份列 + 展示元数据 + 统计 md5。
---@class Book
---@field source_id string 源标识；与 stable_id 共同组成 PRIMARY KEY
---@field stable_id string 源内稳定身份；本地源即文件绝对路径
---@field md5 string|nil 内容 partialMD5；本地源用它识别文件改名/移动
---@field title string|nil 书名
---@field authors string|nil 作者
---@field percent number 阅读进度 0..100（DB REAL，默认 0）
---@field category string|nil 分类 / 标签
---@field series string|nil 系列名
---@field intro string|nil 简介
---@field fetched_at integer 元数据拉取时间戳；0 表示仅身份行
---@field path string|nil 本地文件路径；身份解析唯一入口（下载/登记后由各源收口更新）
---@field last_open integer 最近打开时间戳；0 表示未打开过
---@field in_library boolean|nil 是否属于当前源书架；false 时仍保留身份与历史
---@field metadata_dirty integer|nil 本地展示元数据尚未被远端确认
---@field metadata_updated_at integer|nil 本地展示元数据版本
---@field cover string|nil 封面 URL，不入库；存在时 UI 直接下载
---@field cover_headers table|nil 封面请求头

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
    Book = Book,
}
