--[[--
潇湘官网分类库：动态分类与标签，筛选编码沿用官网，顺序聚合分页。

@module source.xiaoxiang.browse
--]]

require("l10n").apply()
local Browse = require("source.browse")
local Client = require("source.xiaoxiang.client")
local Mapper = require("source.xiaoxiang.mapper")
local JSON_NULL = require("json").decode("null")
local _ = require("gettext")

local Library = {}
local KEYS = { "state", "charge", "update", "words", "order", "category", "tag" }
local DEFAULT = { state = -1, charge = -1, update = -1, words = -1, order = 10, category = 0, tag = -1 }
local FILTERS = {
    { key = "order", title = _("排序"), items = { { 6, _("综合热度") }, { 10, _("最畅销") }, { 3, _("收藏最多") } } },
    { key = "state", title = _("状态"), items = { { -1, _("全部") }, { 0, _("连载") }, { 1, _("完结") } } },
    { key = "charge", title = _("价格"), items = { { -1, _("全部") }, { 0, _("免费") }, { 2, _("付费") } } },
    { key = "update", title = _("更新"), items = {
        { -1, _("全部") }, { 0, _("3天以内") }, { 1, _("7天以内") }, { 2, _("15天以内") }, { 3, _("一个月以内") },
    } },
    { key = "words", title = _("字数"), items = {
        { -1, _("全部") }, { 11, _("20万以内") }, { 12, _("20-30万") }, { 3, _("30-50万") },
        { 24, _("50-100万") }, { 25, _("100-200万") }, { 26, _("200万以上") },
    } },
}

local function node(params, key, value)
    local values = {}
    for index, name in ipairs(KEYS) do
        values[index] = tostring(name == key and value
            or (key == "category" and name == "tag" and -1 or params[name]))
    end
    return "cate:" .. table.concat(values, ":")
end

local function group(params, key, title, items)
    local chips = {}
    for _idx, item in ipairs(items) do chips[#chips + 1] = { id = node(params, key, item[1]), title = item[2] } end
    local result = Browse.group(chips, node(params))
    result.title = title
    return result
end

function Library.run(opts, cb)
    opts = opts or {}
    local params = {}
    for key, value in pairs(DEFAULT) do params[key] = value end
    local valid = true
    if opts.node then
        local values = { opts.node:match("^cate:(%-?%d+):(%-?%d+):(%-?%d+):(%-?%d+):(%-?%d+):(%-?%d+):(%-?%d+)$") }
        valid = #values == #KEYS
        if valid then for index, key in ipairs(KEYS) do params[key] = tonumber(values[index]) end end
    end
    for _idx, filter in ipairs(FILTERS) do
        local found = false
        for _item, item in ipairs(filter.items) do if params[filter.key] == item[1] then found = true end end
        valid = valid and found
    end
    if not valid then return require("source.base").defer(cb, nil, _("潇湘分类条件无效")) end
    local cancelled, job, pending = false, nil, true
    local initial = Client.libraryAsync(params, 1, function(wire, err)
        pending = false
        if cancelled then return end
        local data = wire and wire.data
        if type(data) ~= "table" or type(data.categoryList) ~= "table" then cb(nil, err or _("响应无效")); return end
        local categories, tags, selected = {}, { { -1, _("全部") } }, nil
        for _idx, category in ipairs(data.categoryList) do
            if type(category) ~= "table" or not tonumber(category.id) or type(category.name) ~= "string" then
                cb(nil, _("响应无效")); return
            end
            categories[#categories + 1] = { tonumber(category.id), _(category.name) }
            if tonumber(category.id) == params.category then selected = category end
        end
        if not selected or type(selected.labelClassList) ~= "table" then cb(nil, _("响应无效")); return end
        local seen, found = {}, params.tag == -1
        for _idx, class in ipairs(selected.labelClassList) do
            if type(class) ~= "table" then cb(nil, _("响应无效")); return end
            local items = class.tagInfoList
            if items == JSON_NULL then items = nil end
            if items ~= nil and type(items) ~= "table" then
                cb(nil, _("响应无效")); return
            end
            for _tag, tag in ipairs(items or {}) do
                if type(tag) ~= "table" or not tonumber(tag.tagId) or type(tag.tagName) ~= "string" then
                    cb(nil, _("响应无效")); return
                end
                local id = tonumber(tag.tagId)
                if id == params.tag then found = true end
                if not seen[id] then tags[#tags + 1], seen[id] = { id, _(tag.tagName) }, true end
            end
        end
        if not found then cb(nil, _("潇湘分类条件无效")); return end
        local groups = { group(params, "category", _("分类"), categories) }
        groups[1].chips[#groups[1].chips + 1] = { id = "rank", title = _("排行榜") }
        if #tags > 1 then groups[#groups + 1] = group(params, "tag", _("标签"), tags) end
        for _idx, filter in ipairs(FILTERS) do groups[#groups + 1] = group(params, filter.key, filter.title, filter.items) end
        job = Browse.pages(function(index, done)
            local function receive(result, reason)
                local page_data = result and result.data
                if type(page_data) ~= "table" or not tonumber(page_data.total) then
                    done(nil, reason or _("响应无效")); return
                end
                local books, failure = Mapper.books(page_data.bookList)
                done(books, failure, index * 20 < tonumber(page_data.total))
            end
            if index == 1 then receive(wire); return end
            return Client.libraryAsync(params, index, receive)
        end, opts.limit or 60, groups, cb)
    end)
    if pending then job = initial end
    return { cancel = function()
        cancelled = true
        if job then job.cancel() end
    end }
end

return Library
