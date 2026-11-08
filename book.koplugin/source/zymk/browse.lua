--[[--
知音漫客分类库：官网动态标签与完整 allComic 数据，过滤后按官网字段降序。

@module source.zymk.browse
--]]

local Client = require("source.zymk.client")
local Mapper = require("source.zymk.mapper")
local Browse = require("source.browse")
local Text = require("utils.text")
local _ = require("l10n").get("source.zymk")

local Library = {}
local SORTS = {
    { key = "update_time", title = _("新更") },
    { key = "total_click", title = _("人气") },
    { key = "dashang", title = _("打赏") },
    { key = "pingfen", title = _("评分") },
    { key = "zongpiao", title = _("月票") },
}
local LABELS = {
    ["题材"] = _("题材"), ["受众"] = _("受众"), ["媒体"] = _("媒体"),
    ["热血"] = _("热血"), ["搞笑"] = _("搞笑"), ["生活"] = _("生活"), ["恋爱"] = _("恋爱"),
    ["动作"] = _("动作"), ["战争"] = _("战争"), ["穿越"] = _("穿越"), ["后宫"] = _("后宫"),
    ["萝莉"] = _("萝莉"), ["漫改"] = _("漫改"), ["修真"] = _("修真"), ["霸总"] = _("霸总"),
    ["古风"] = _("古风"), ["真人"] = _("真人"), ["完结"] = _("完结"), ["少男"] = _("少男"),
    ["少女"] = _("少女"), ["青年"] = _("青年"), ["神漫"] = _("神漫"), ["飒漫画"] = _("飒漫画"),
    ["漫客栈"] = _("漫客栈"), ["飒漫乐画"] = _("飒漫乐画"),
}

local function node(params)
    return "library?" .. Text.formEncode(params)
end

local function change(params, key, value)
    local out = {}
    for name, current in pairs(params) do out[name] = current end
    out[key] = value ~= "" and value or nil
    return node(out)
end

---@param opts { node?: string, limit?: integer }
---@param cb fun(result: table|nil, err: string|nil)
---@return { cancel: fun() }
function Library.run(opts, cb)
    return Client.libraryAsync(function(data, err)
        if not data then cb(nil, err); return end
        local params = { sort = "update_time" }
        local keys, tags = { sort = true }, {}
        for index, filter in ipairs(data.filters) do
            local key = "tag" .. index
            keys[key], tags[key] = true, {}
            for _idx, item in ipairs(filter.items) do tags[key][item.id] = true end
        end
        if opts.node then
            if not opts.node:match("^library%?") then cb(nil, _("响应无效")); return end
            for key, value in opts.node:sub(9):gmatch("([^&=]+)=([^&]*)") do
                if not keys[key] then cb(nil, _("响应无效")); return end
                params[key] = Text.urlDecode(value)
            end
        end
        local sort_valid = false
        for _idx, sort in ipairs(SORTS) do
            if params.sort == sort.key then sort_valid = true end
        end
        if not sort_valid then cb(nil, _("响应无效")); return end
        for key, allowed in pairs(tags) do
            if params[key] and not allowed[params[key]] then cb(nil, _("响应无效")); return end
        end
        local rows = {}
        for _idx, row in ipairs(data.rows) do
            if type(row) ~= "table" or type(row.class_idlist) ~= "string"
                or type(row.update_time) ~= "string" or not row.comic_id
                or type(row.comic_name) ~= "string" or row.comic_name == "" then
                cb(nil, _("响应无效")); return
            end
            local matches = true
            for key in pairs(tags) do
                if params[key] and not row.class_idlist:find("," .. params[key] .. ",", 1, true) then
                    matches = false
                end
            end
            if matches then rows[#rows + 1] = row end
        end
        table.sort(rows, function(left, right)
            local a, b
            if params.sort == "update_time" then
                a, b = left.update_time, right.update_time
            else
                a, b = tonumber(left[params.sort]) or 0, tonumber(right[params.sort]) or 0
            end
            if a == b then return (tonumber(left.total_click) or 0) > (tonumber(right.total_click) or 0) end
            return a > b
        end)
        local current, groups, sort_chips = node(params), {}, {}
        for _idx, sort in ipairs(SORTS) do
            sort_chips[#sort_chips + 1] = { id = change(params, "sort", sort.key), title = sort.title }
        end
        groups[1] = Browse.group(sort_chips, current)
        groups[1].title = _("排序")
        for index, filter in ipairs(data.filters) do
            local key = "tag" .. index
            local chips = { { id = change(params, key, ""), title = _("全部") } }
            for _idx, item in ipairs(filter.items) do
                chips[#chips + 1] = { id = change(params, key, item.id), title = LABELS[item.title] or _(item.title) }
            end
            local group = Browse.group(chips, current)
            group.title = LABELS[filter.title] or _(filter.title)
            groups[#groups + 1] = group
        end
        local result = Mapper.list({ status = 0, data = { page = { comic_list = rows } } })
        if not result then cb(nil, _("响应无效")); return end
        while #result > (opts.limit or 60) do result[#result] = nil end
        cb({ data = result, groups = groups })
    end)
end

return Library
