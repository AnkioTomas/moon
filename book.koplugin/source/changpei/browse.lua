--[[--
长佩官网分类库；旧「榜单号:子榜值」节点继续可用。

@module source.changpei.browse
--]]

local Browse = require("source.browse")
local Client = require("source.changpei.client")
local Mapper = require("source.changpei.mapper")
local SourceBase = require("source.base")
local _ = require("l10n").get("source.changpei")

local Library = {}
local KEYS = { "channel", "category", "process", "sell", "number", "field" }
local DEFAULT = { channel = 0, category = 0, process = 0, sell = 2, number = 0, field = 8 }
local FILTERS = {
    { key = "field", title = _("排序"), items = {
        { 8, _("综合") }, { 4, _("最新") }, { 7, _("热门") }, { 1, _("人气") },
        { 2, _("收藏") }, { 3, _("字数") },
    } },
    { key = "process", title = _("状态"), items = { { 0, _("全部") }, { 1, _("连载") }, { 2, _("完结") } } },
    { key = "sell", title = _("价格"), items = { { 2, _("全部") }, { 0, _("免费") }, { 1, _("付费") } } },
    { key = "number", title = _("字数"), items = {
        { 0, _("全部") }, { 1, _("7万以下") }, { 2, _("7-15万") }, { 3, _("15-25万") },
        { 4, _("25-40万") }, { 5, _("40-60万") }, { 6, _("60万以上") },
    } },
}

local function node(params, key, value)
    local parts = {}
    local changing_channel = key == "channel" and tonumber(value) ~= params.channel
    for idx, name in ipairs(KEYS) do
        parts[idx] = tostring(name == key and value or (changing_channel and name == "category" and 0 or params[name]))
    end
    return "cate:" .. table.concat(parts, ":")
end

local function types(wire)
    local list = type(wire.data) == "table" and wire.data.list
    if type(list) ~= "table" then return nil end
    for _idx, row in ipairs(list) do
        if type(row) ~= "table" or not tonumber(row.id) or type(row.type_name) ~= "string" then return nil end
    end
    return list
end

local function select(params, key, list)
    if params[key] == 0 then return end
    for _idx, row in ipairs(list) do
        if tonumber(row.id) == params[key] then return end
    end
    params[key] = 0
end

local function group(params, key, title, items)
    local chips = {}
    for _idx, item in ipairs(items) do
        chips[#chips + 1] = { id = node(params, key, item[1]), title = item[2] }
    end
    local out = Browse.group(chips, node(params))
    out.title = title
    return out
end

function Library.run(opts, cb)
    opts = opts or {}
    local params = {}
    for key, value in pairs(DEFAULT) do params[key] = value end
    if opts.node then
        local channel, category, process, sell, number, field =
            opts.node:match("^cate:(%d+):(%d+):(%d+):(%d+):(%d+):(%d+)$")
        if not channel then return SourceBase.defer(cb, nil, _("长佩分类条件无效")) end
        params = { channel = tonumber(channel), category = tonumber(category), process = tonumber(process),
            sell = tonumber(sell), number = tonumber(number), field = tonumber(field) }
        for _idx, filter in ipairs(FILTERS) do
            local valid = false
            for _item, item in ipairs(filter.items) do
                if params[filter.key] == item[1] then valid = true end
            end
            if not valid then return SourceBase.defer(cb, nil, _("长佩分类条件无效")) end
        end
    end
    local cancelled, job, pending = false, nil, true
    local initial = Client.typesAsync(nil, function(wire, err)
        pending = false
        if cancelled then return end
        local channels = wire and types(wire)
        if not channels then cb(nil, err or _("响应无效")); return end
        select(params, "channel", channels)
        if params.channel == 0 then params.category = 0 end
        local function load(categories, reason)
            if cancelled then return end
            if not categories then cb(nil, reason or _("响应无效")); return end
            select(params, "category", categories)
            local channel_items, category_items = { { 0, _("全部") } }, { { 0, _("全部") } }
            for _idx, row in ipairs(channels) do channel_items[#channel_items + 1] = { row.id, _(row.type_name) } end
            for _idx, row in ipairs(categories) do category_items[#category_items + 1] = { row.id, _(row.type_name) } end
            local groups = { group(params, "channel", _("频道"), channel_items) }
            groups[1].chips[#groups[1].chips + 1] = { id = "rank", title = _("排行榜") }
            if params.channel ~= 0 then groups[#groups + 1] = group(params, "category", _("分类"), category_items) end
            for _idx, filter in ipairs(FILTERS) do
                groups[#groups + 1] = group(params, filter.key, filter.title, filter.items)
            end
            local query = { field = params.field,
                tid = params.category ~= 0 and params.category or (params.channel ~= 0 and params.channel or nil),
                process = params.process ~= 0 and params.process or nil,
                sell = params.sell ~= 2 and params.sell or nil,
                number = params.number ~= 0 and params.number or nil }
            job = Browse.pages(function(page, done)
                return Client.libraryAsync(query, page, function(result, failure)
                    if not result then done(nil, failure); return end
                    local data = result.data
                    if type(data) ~= "table" or type(data.list) ~= "table" or not tonumber(data.count) then
                        done(nil, _("响应无效")); return
                    end
                    done(Mapper.search(result), nil, page * 10 < tonumber(data.count))
                end)
            end, opts.limit or 60, groups, cb)
        end
        if params.channel == 0 then load({}); return end
        local loading = true
        local categories = Client.typesAsync(params.channel, function(result, failure)
            loading = false
            load(result and types(result), failure)
        end)
        if loading then job = categories end
    end)
    if pending then job = initial end
    return { cancel = function()
        cancelled = true
        if job then job.cancel() end
    end }
end

return Library
