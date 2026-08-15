--[[--
多源图书搜索协调器

豆瓣优先，失败或无结果 fallback 微信读书

@module koplugin.book.scrape.search
--]]

local Douban = require("scrape.douban")
local Weread = require("scrape.weread")
local logger = require("logger")

local Search = {}

--- 多源搜索：豆瓣 -> 微信读书
---@param query string
---@param cb fun(results: table[]|nil, err: string|nil, source: string|nil)
---@return { cancel: fun() }|nil
function Search.searchAsync(query, cb)
    local cancelled = false
    local current_job = nil

    local function tryWeread()
        if cancelled then return end
        logger.info("scrape: fallback to weread")
        current_job = Weread.searchAsync(query, function(results, err)
            if cancelled then return end
            if results and #results > 0 then
                cb(results, nil, "weread")
            else
                cb(nil, err or "无搜索结果", nil)
            end
        end)
    end

    logger.info("scrape: trying douban first")
    current_job = Douban.searchAsync(query, function(results, err)
        if cancelled then return end
        if results and #results > 0 then
            cb(results, nil, "douban")
        else
            logger.info("scrape: douban failed or empty, trying weread", err)
            tryWeread()
        end
    end)

    return {
        cancel = function()
            cancelled = true
            if current_job then
                current_job.cancel()
            end
        end,
    }
end

return Search
