--[[--
QQ阅读官网动态分类与筛选，兼容旧 cate:分类号节点。

@module source.qqreader.browse
--]]

local Browse = require("source.browse")
local Client = require("source.qqreader.client")
local SourceBase = require("source.base")
local _ = require("l10n").get("source.qqreader")

local Library = {}
local KEYS = { "categoryId2", "categoryId3", "finishStatus", "priceStatus", "words", "updateTime", "orderBy", "pageNo" }

local function path(params)
    local parts = {}
    for idx, key in ipairs(KEYS) do parts[idx] = tostring(params[key]) end
    return table.concat(parts, "-")
end

local function change(params, key, value)
    local copy = {}
    for name, current in pairs(params) do copy[name] = current end
    copy[key], copy.pageNo = value, 1
    if key == "categoryId2" then copy.categoryId3 = 0 end
    return "cate:" .. path(copy)
end

local function groups(data)
    local params, out = data.params, {}
    local current = "cate:" .. path(params)
    for _idx, category in ipairs(data.categoryList) do
        local chips = {}
        for _item, item in ipairs(category.subCategories) do
            if item.value ~= 0 then chips[#chips + 1] = { id = change(params, "categoryId2", item.value), title = _(item.text) } end
        end
        local group = Browse.group(chips, current)
        group.title = _(category.name) .. _("分类")
        out[#out + 1] = group
    end
    local filters = { { id = "rank:male-sell", title = _("排行榜") }, { id = "cate:0", title = _("全部") } }
    for _idx, key in ipairs({ "categoryId3", "finishStatus", "priceStatus", "words", "updateTime", "orderBy" }) do
        local filter = data[key]
        if type(filter) ~= "table" or type(filter.items) ~= "table" then return nil end
        for _item, item in ipairs(filter.items) do
            filters[#filters + 1] = {
                id = change(params, key, item.value),
                title = (key == "orderBy" and _("排序") or _(filter.title)) .. "：" .. _(item.text)
                    .. (item.value == params[key] and " ✓" or ""),
            }
        end
    end
    local group = Browse.group(filters, current)
    group.title = _("筛选")
    out[#out + 1] = group
    return out
end

---@param opts { node?: string, limit?: integer }
---@param cb fun(res: table|nil, err: string|nil)
---@return HttpJob
function Library.run(opts, cb)
    local value = (opts.node or "cate:0"):sub(6)
    local parts = {}
    for part in value:gmatch("[^-]+") do
        if not part:match("^%d+$") then return SourceBase.defer(cb, nil, _("QQ阅读分类条件无效")) end
        parts[#parts + 1] = tonumber(part)
    end
    if (#parts ~= 1 and #parts ~= 8) or value:find("--", 1, true)
        or value:sub(1, 1) == "-" or value:sub(-1) == "-" then
        return SourceBase.defer(cb, nil, _("QQ阅读分类条件无效"))
    end
    local params = {}
    for idx, key in ipairs(KEYS) do params[key] = parts[idx] or (key == "pageNo" and 1 or 0) end
    params.pageNo = 1
    local cancelled, job, pending = false, nil, true
    local inner = Client.categoryAsync(path(params), function(first, err)
        pending = false
        if cancelled then return end
        if not first then cb(nil, err); return end
        local chips = groups(first)
        if not chips then cb(nil, _("QQ阅读分类响应无效")); return end
        -- JSON books 不稳定，元数据可用；书卡沿用官网 SSR，实测限制见 README。
        job = Browse.pages(function(page, done)
            params.pageNo = page
            return Client.listAsync("/book-cate/" .. path(params), done)
        end, opts.limit or 60, chips, function(result, reason)
            if not cancelled then cb(result, reason) end
        end)
    end)
    if pending then job = inner end
    return { cancel = function()
        cancelled = true
        if job then job.cancel() end
    end }
end

return Library
