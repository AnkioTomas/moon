--[[--
起点分类书库：动态男频分类、官网筛选、匿名分页。节点保留全部已选条件。

@module source.qidian.browse
--]]

local Client = require("source.qidian.client")
local Mapper = require("source.qidian.mapper")
local Browse = require("source.browse")
local Text = require("utils.text")
local _ = require("l10n").get("source.qidian")

local Library = {}
-- 官网动态标签：预译已知标签，未知标签仍沿用 gettext 的原文回退。
local LABELS = {
    ["100~200万"] = _("100~200万"), ["200万以上"] = _("200万以上"),
    ["30~50万"] = _("30~50万"), ["30万以下"] = _("30万以下"), ["50~100万"] = _("50~100万"),
    ["VIP"] = _("VIP"), ["一月内"] = _("一月内"), ["七日内"] = _("七日内"), ["三日内"] = _("三日内"),
    ["东方玄幻"] = _("东方玄幻"), ["二级分类"] = _("二级分类"), ["人气"] = _("人气"),
    ["半月内"] = _("半月内"), ["品质"] = _("品质"), ["完本"] = _("完本"), ["属性"] = _("属性"),
    ["异世大陆"] = _("异世大陆"), ["月票"] = _("月票"), ["点击"] = _("点击"),
    ["王朝争霸"] = _("王朝争霸"), ["签约作品"] = _("签约作品"), ["精品小说"] = _("精品小说"),
    ["连载"] = _("连载"), ["高武世界"] = _("高武世界"),
}
local KEYS = { catId = true, subCatId = true, isvip = true, size = true, isfinish = true,
    sign = true, update = true, orderBy = true, gender = true }
-- m.qdmm.com 的分类目录目前返回风控页；这些是电脑官网 /all/ 实际公布的女频分类。
local FEMALE = {
    { catId = 80, catName = "古代言情" }, { catId = 81, catName = "仙侠奇缘" },
    { catId = 82, catName = "现代言情" }, { catId = 83, catName = "浪漫青春" },
    { catId = 84, catName = "玄幻言情" }, { catId = 85, catName = "悬疑推理" },
    { catId = 30083, catName = "短篇" }, { catId = 86, catName = "科幻空间" },
    { catId = 88, catName = "游戏竞技" }, { catId = 87, catName = "轻小说" },
    { catId = 30120, catName = "现实生活" },
}

local function node(params)
    return "category?" .. Text.formEncode(params)
end

local function change(params, key, value)
    local out = {}
    for name, current in pairs(params) do out[name] = current end
    out[key] = value == "" and nil or tostring(value)
    if key == "catId" then out.subCatId = nil end
    if key == "gender" then
        out.catId = value == "female" and "80" or "21"
        out.subCatId = nil
    end
    return node(out)
end

local function groups(params, categories, data)
    local current = node(params)
    local channels = Browse.group({
        { id = params.gender == "male" and current or change(params, "gender", "male"), title = _("男频") },
        { id = params.gender == "female" and current or change(params, "gender", "female"), title = _("女频") },
        { id = "yuepiao:-1", title = _("排行榜") },
    }, current)
    channels.title = _("频道")
    local cats = {}
    for _idx, cat in ipairs(params.gender == "female" and FEMALE or categories) do
        cats[#cats + 1] = { id = change(params, "catId", cat.catId), title = _(cat.catName) }
    end
    local category = Browse.group(cats, current)
    category.title = _("分类")
    local out = { channels, category }
    local sorts = {}
    for _idx, item in ipairs(data.orderBy.items) do
        sorts[#sorts + 1] = { id = change(params, "orderBy", item.value), title = LABELS[item.text] or _(item.text) }
    end
    local sort = Browse.group(sorts, current)
    sort.title = _("排序")
    out[#out + 1] = sort
    local filters = {}
    for _idx, filter in ipairs(data.filters) do
        local chips = {}
        for _item, item in ipairs(filter.items) do
            local value = tostring(item.value)
            chips[#chips + 1] = {
                id = change(params, filter.key, value),
                title = filter.key == "subCatId" and (LABELS[item.text] or _(item.text))
                    or ((LABELS[filter.title] or _(filter.title)) .. "：" .. (LABELS[item.text] or _(item.text))
                        .. (value == (params[filter.key] or "") and " ✓" or "")),
            }
        end
        if filter.key == "subCatId" then
            local sub = Browse.group(chips, current)
            sub.title = _("子分类")
            out[#out + 1] = sub
        else
            for _item, chip in ipairs(chips) do filters[#filters + 1] = chip end
        end
    end
    local filter = Browse.group(filters, current)
    filter.title = _("筛选")
    out[#out + 1] = filter
    return out
end

---@param self QidianSource
---@param opts { node?: string, limit?: integer }
---@param cb fun(res: table|nil, err: string|nil)
---@return HttpJob
function Library.run(self, opts, cb)
    local params = { gender = "male", catId = "21" }
    if opts.node then
        for key, value in opts.node:sub(10):gmatch("([^&=]+)=([^&]*)") do
            if not KEYS[key] or (key ~= "gender" and not value:match("^%d*$")) then
                return require("source.base").defer(cb, nil, _("起点分类条件无效"))
            end
            params[key] = Text.urlDecode(value)
        end
    end
    if params.gender ~= "male" and params.gender ~= "female" then
        return require("source.base").defer(cb, nil, _("起点分类条件无效"))
    end
    local cancelled, job = false, nil
    local function load(categories)
        local pending = true
        local inner = Client.categoryAsync(params.catId, function(data, err)
            pending = false
            if cancelled then return end
            if not data then cb(nil, err); return end
            if type(data.filters) ~= "table" or type(data.orderBy) ~= "table"
                or type(data.orderBy.items) ~= "table" then cb(nil, _("起点分类响应无效")); return end
            job = Browse.pages(function(page, done)
                local query = {}
                for key, value in pairs(params) do query[key] = value end
                query.pageNum = page
                return Client.categoryListAsync(query, function(list, reason)
                    if not list then done(nil, reason); return end
                    local more = list.isLast ~= 1 and list.isLast ~= true
                        and (not tonumber(list.pageMax) or page < tonumber(list.pageMax))
                    done(Mapper.rank(list), nil, more)
                end)
            end, opts.limit or 60, groups(params, categories, data), function(result, reason)
                if not cancelled then cb(result, reason) end
            end)
        end)
        if pending then job = inner end
    end
    if self.category_info then
        load(self.category_info)
    else
        local pending = true
        local inner = Client.categoryAsync(nil, function(data, err)
            pending = false
            if cancelled then return end
            if not data then cb(nil, err); return end
            if type(data.info) ~= "table" or #data.info == 0 then cb(nil, _("起点分类响应无效")); return end
            self.category_info = data.info
            load(data.info)
        end)
        if pending then job = inner end
    end
    return { cancel = function()
        cancelled = true
        if job then job.cancel() end
    end }
end

return Library
