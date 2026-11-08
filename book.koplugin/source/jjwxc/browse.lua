--[[--
晋江官网分类库：动态表单筛选、顺序分页；榜单旧节点仍由源入口处理。

@module source.jjwxc.browse
--]]

local Browse = require("source.browse")
local Client = require("source.jjwxc.client")
local SourceBase = require("source.base")
local _ = require("l10n").get("source.jjwxc")

local Library = {}
local FILTERS = {
    { "xx", _("频道") }, { "yc", _("原创") }, { "sd", _("时代") }, { "lx", _("分类") },
    { "fw", _("价格") }, { "isfinish", _("状态") }, { "sortType", _("排序") },
}

local function node(params)
    local parts = {}
    for index, filter in ipairs(FILTERS) do parts[index] = tostring(params[filter[1]]) end
    return "cate:" .. table.concat(parts, ":")
end

---@param opts { node?: string, limit?: integer }
---@param cb fun(res: table|nil, err: string|nil)
---@return { cancel: fun() }
function Library.run(opts, cb)
    local limit = opts.limit or 60
    local value = opts.node or "cate:0:0:0:0:0:0:2"
    local parts = {}
    for part in value:sub(6):gmatch("[^:]+") do parts[#parts + 1] = part end
    if #parts ~= #FILTERS or value ~= "cate:" .. table.concat(parts, ":") then
        return SourceBase.defer(cb, nil, _("晋江分类条件无效"))
    end
    local params = { page = 1 }
    for index, filter in ipairs(FILTERS) do
        if not parts[index]:match("^%d+$") then return SourceBase.defer(cb, nil, _("晋江分类条件无效")) end
        params[filter[1]] = parts[index]
    end
    local cancelled, job, pending = false, nil, true
    local initial = Client.categoryAsync(params, function(first, err)
        pending = false
        if cancelled then return end
        if not first then cb(nil, err); return end
        local groups = {}
        for _index, filter in ipairs(FILTERS) do
            local key, title = filter[1], filter[2]
            local options = first.filters[key]
            if not options or #options == 0 then cb(nil, _("晋江分类响应无效")); return end
            local valid = false
            for _idx, option in ipairs(options) do
                if option.id == params[key] then valid = true end
            end
            if not valid then cb(nil, _("晋江分类条件无效")); return end
            local chips = {}
            for _idx, option in ipairs(options) do
                local copy = {}
                for name, current in pairs(params) do copy[name] = current end
                copy[key] = option.id
                if key == "xx" or key == "yc" then copy.lx, copy.sd = "0", "0" end
                chips[#chips + 1] = { id = node(copy), title = _(option.title) }
            end
            local group = Browse.group(chips, node(params))
            group.title = title
            groups[#groups + 1] = group
        end
        groups[#groups + 1] = { title = _("排行榜"), chips = { { id = "1:1", title = _("排行榜") } } }
        job = Browse.pages(function(page, done)
            local function loaded(data, reason)
                if not data then done(nil, reason); return end
                if data.page ~= page or (#data.books == 0 and page < data.pages) then
                    done(nil, _("晋江分类响应无效")); return
                end
                done(data.books, nil, page < data.pages)
            end
            if page == 1 then loaded(first); return end
            params.page = page
            return Client.categoryAsync(params, loaded)
        end, limit, groups, function(result, reason)
            if cancelled then return end
            if not result then cb(nil, reason); return end
            local more = #result.data > limit or params.page < first.pages
            while #result.data > limit do table.remove(result.data) end
            cb({ data = result.data, groups = result.groups, more = more }, reason)
        end)
    end)
    if pending then job = initial end
    return { cancel = function()
        cancelled = true
        if job then job.cancel() end
    end }
end

return Library
