--[[--
豆瓣阅读段评。

他人批注走 POST `/j/article_v2/<article>/annotations_by_paragraphs`。
有 `note` 的才是段评，纯划线丢掉。段落序号按本章非空段，和章节 HTML 的 `<p>` 一致。

@module source.douban.reviews
--]]

local Client = require("source.douban.client")
local Mapper = require("source.douban.mapper")

local Reviews = {}

---@param chapter BookChapter
---@param cb fun(rows: table|nil, pids: string[]|nil, err: string|nil)
---@return { cancel: fun() }
local function load(chapter, cb)
    local handle = {}
    local start_pid = chapter.slice and tonumber(chapter.uid) or nil
    local end_pid = chapter.slice and tonumber(chapter.end_pid) or nil
    local pending = true
    local first = Client.articleAsync(chapter.content_url, function(article, err)
        pending = false
        if handle.cancelled then return end
        if not article then cb(nil, nil, err); return end
        local pids = Mapper.paragraphIds(article, start_pid, end_pid)
        handle.job = Client.annotationsAsync(chapter.content_url, pids, function(rows, reason)
            if handle.cancelled then return end
            if not rows then cb(nil, nil, reason); return end
            cb(rows, pids)
        end)
    end)
    if pending then handle.job = first end
    return { cancel = function()
        handle.cancelled = true
        if handle.job and handle.job.cancel then handle.job.cancel() end
    end }
end

---@param chapter BookChapter
---@param cb fun(hotspots: table[]|nil, err: string|nil)
---@return { cancel: fun() }
function Reviews.hotspotsAsync(chapter, cb)
    return load(chapter, function(rows, pids, err)
        if not rows then cb(nil, err); return end
        cb(Mapper.reviewHotspots(rows, pids))
    end)
end

---@param chapter BookChapter
---@param range string|number
---@param cb fun(page: table|nil, err: string|nil)
---@return { cancel: fun() }
function Reviews.pageAsync(chapter, range, cb)
    return load(chapter, function(rows, pids, err)
        if not rows then cb(nil, err); return end
        cb(Mapper.reviewPage(rows, pids, range))
    end)
end

return Reviews
