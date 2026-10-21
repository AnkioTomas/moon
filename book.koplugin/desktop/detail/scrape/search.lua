--[[--
多源图书搜索：按用户选的来源查（豆瓣自带解析，其余全走数据源 searchAsync）

@module koplugin.book.desktop.detail.scrape.search
--]]

local Douban = require("desktop.detail.scrape.douban")
local Novel = require("desktop.detail.scrape.novel")
local Text = require("utils.text")
local _ = require("gettext")

local Search = {}

--- 可单独指定的数据来源（顺序即选择列表顺序）。
Search.SOURCES = {
    { id = "douban", name = _("豆瓣"), run = Douban.searchAsync },
    { id = "weread", name = _("微信读书"), run = function(q, cb) return Novel.viaSource("wechat", q, cb, "weread") end },
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

--- 只查指定来源；无结果按错误回调。
---@param query string
---@param source_id string
---@param cb fun(results: table[]|nil, err: string|nil, source: string|nil)
---@return { cancel: fun() }|nil
function Search.searchAsync(query, source_id, cb)
    query = Text.trim(query)
    if query == "" then
        cb(nil, _("搜索关键词为空"))
        return nil
    end
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

return Search
