--- Book 领域类型。
--- stable_id 仅源内唯一；跨源身份 = (source_id, stable_id)。

--- 路径解析出的阅读身份（Store.identityFor / ensureIdentity 返回值）。
---@class BookIdentity
---@field source_id string 源标识（moon / wechat / jdread / local 等）
---@field stable_id string 源内稳定身份
---@field chapter_idx number|nil 章节文件时为章号；整本书为 nil
---@field book Book|nil books 表元数据行；刚登记/未入库时可能为内存行或 nil
---@field source BookSource|nil 属主源实例；仅 ensureIdentity（打开时）解析，identityFor 不挂
---@field cover string|nil 封面 URL（部分源直接挂在身份上）
---@field cover_url string|nil 封面 URL 别名

--- 对应表 books：身份列 + 展示元数据 + 软删成员 + sync_status。
---@class Book
---@field source_id string 源标识；与 stable_id 共同组成 PRIMARY KEY
---@field stable_id string 源内稳定身份；本地源即文件绝对路径
---@field md5 string|nil 内容 partialMD5；本地源用它识别文件改名/移动
---@field title string|nil 书名
---@field authors string|nil 作者
---@field percent number|nil 展示用进度 0..100（来自 pending_progress.fraction，非 books 列）
---@field chapter_idx integer|nil 展示用章节序号（来自 pending_progress，非 books 列）
---@field chapter_title string|nil 展示用章节标题（来自 pending_progress，非 books 列）
---@field page integer|nil 展示用页码（来自 pending_progress，非 books 列）
---@field total_pages integer|nil 展示用总页数（来自 pending_progress，非 books 列）
---@field category string|nil 分类 / 标签
---@field series string|nil 系列名
---@field intro string|nil 简介
---@field inserted_at integer|nil 本行首次写入时间；0 表示仅身份行；内存展示行可能没有
---@field path string|nil 本地文件路径；身份解析唯一入口
---@field deleted integer|nil 0=在架有效，1=软删/非成员
---@field sync_status integer|nil 0=待上传，1=已同步
---@field cover string|nil 封面 URL
---@field cover_url string|nil 封面 URL（部分源别名）
---@field cover_headers table|nil 封面请求头
---@field format string|nil 文件格式（epub/pdf 等，zlib 预览书）
---@field author string|nil 作者（部分源单数字段；展示优先 authors）
---@field fileSize number|nil 文件大小（字节，驼峰）
---@field filesize number|nil 文件大小（字节）
---@field file_size number|nil 文件大小（字节，蛇形）
---@field size number|nil 文件大小（字节，泛用）
---@field chapter table|nil 当前章元数据（阅读态）
---@field read_state integer|nil 0=未读且可自动标记，1=已读，2=用户强制未读
---@field reader_prefs string|nil 全书排版偏好 JSON（仅本地）
---@field toc string|nil 目录缓存 JSON（仅本地）
---@field toc_fetched_at integer|nil 目录缓存时间
local Book = {}

--- 首页书摘 / 一言共用展示结构。
---@class BookExcerptQuote
---@field text string
---@field author string
---@field title string
---@field chapter string|nil
---@field source_id string|nil
---@field stable_id string|nil

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
