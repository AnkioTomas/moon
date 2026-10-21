--[[--
多源图书搜索协调器

默认豆瓣优先，失败或无结果 fallback 微信读书；也可指定单个站点搜索

@module koplugin.book.desktop.detail.scrape.search
--]]

local Douban = require("desktop.detail.scrape.douban")
local Weread = require("desktop.detail.scrape.weread")
local Novel = require("desktop.detail.scrape.novel")
local logger = require("utils.log")
local Text = require("utils.text")
local _ = require("gettext")

local Search = {}

--- 可单独指定的数据来源（顺序即选择列表顺序）。
Search.SOURCES = {
    { id = "douban", name = _("豆瓣"), run = Douban.searchAsync },
    { id = "weread", name = _("微信读书"), run = Weread.searchAsync },
    { id = "qimao", name = _("七猫小说"), run = function(q, cb) return Novel.viaSource("qimao", q, cb) end },
    { id = "jjwxc", name = _("晋江文学城"), run = function(q, cb) return Novel.viaSource("jjwxc", q, cb) end },
    { id = "qidian", name = _("起点中文网"), run = function(q, cb) return Novel.viaSource("qidian", q, cb) end },
    { id = "fanqie", name = _("番茄小说"), run = function(q, cb) return Novel.viaSource("fanqie", q, cb) end },
    { id = "changpei", name = _("长佩文学"), run = function(q, cb) return Novel.viaSource("changpei", q, cb) end },
    { id = "xiaoxiang", name = _("潇湘书院"), run = function(q, cb) return Novel.viaSource("xiaoxiang", q, cb) end },
}

---@param id string
---@return string
function Search.name(id)
    for _idx, src in ipairs(Search.SOURCES) do
        if src.id == id then return src.name end
    end
    return id
end

--- 搜索。source_id 为空走自动链：豆瓣 -> 微信读书；否则只查指定来源。
---@param query string
---@param cb fun(results: table[]|nil, err: string|nil, source: string|nil)
---@param source_id string|nil
---@return { cancel: fun() }|nil
function Search.searchAsync(query, cb, source_id)
    query = Text.trim(query)
    if query == "" then
        cb(nil, _("搜索关键词为空"))
        return nil
    end
    if source_id then
        for _idx, src in ipairs(Search.SOURCES) do
            if src.id == source_id then
                return src.run(query, function(results, err)
                    if results and #results > 0 then
                        cb(results, nil, source_id)
                    else
                        cb(nil, err or _("无搜索结果"), nil)
                    end
                end)
            end
        end
        cb(nil, _("未知数据源"))
        return nil
    end
    local cancelled = false
    local current_job

    --- 豆瓣无结果时改走微信读书；仍然空结果则回调错误。
    local function tryWeread()
        if cancelled then return end
        logger.info("scrape: fallback to weread")
        current_job = Weread.searchAsync(query, function(results, err)
            if cancelled then return end
            if results and #results > 0 then
                cb(results, nil, "weread")
            else
                cb(nil, err or _("无搜索结果"), nil)
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

    return { cancel = function()
            cancelled = true
            if current_job then
                current_job.cancel()
            end
        end }
end

return Search
