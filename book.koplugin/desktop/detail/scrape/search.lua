--[[--
多源图书搜索：按用户选的来源查（豆瓣自带解析，其余全走数据源 searchAsync）

@module koplugin.book.desktop.detail.scrape.search
--]]

local Douban = require("desktop.detail.scrape.douban")
local Novel = require("desktop.detail.scrape.novel")
local Text = require("utils.text")
local _ = require("gettext")

local Search = {}

local BASE = {
    { id = "douban", name = _("豆瓣"), run = Douban.searchAsync },
}

--- 可单独指定的数据来源（顺序即选择列表顺序）：内置的豆瓣 + 已启用的第三方书源（id 去掉可能的 ext. 前缀）。
---@return { id: string, name: string, run: fun(query: string, cb: function): table|nil }[]
function Search.sources()
    local out = { BASE[1] }
    for _idx, meta in ipairs(require("source.registry").listEnabled()) do
        local short = tostring(meta.id):gsub("^ext%.", "")
        if require("source.registry").external(meta.id) and short ~= "demo" and short ~= BASE[1].id then
            out[#out + 1] = { id = short, name = meta.name or short,
                run = function(q, cb) return Novel.viaSource(meta.id, q, cb, short) end }
        end
    end
    return out
end

---@param id string
---@return string
function Search.name(id)
    if id == BASE[1].id then return BASE[1].name end
    for _idx, src in ipairs(Search.sources()) do
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
    for _idx, src in ipairs(Search.sources()) do
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
