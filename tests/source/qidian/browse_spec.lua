--[[-- 起点分类：动态菜单、男 / 女频筛选、去重分页、错误与取消。 @module tests.source.qidian.browse_spec --]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch

local Assert = require("support.assert")
local requests, pages, failure, delayed, late, cancelled = {}, {}, nil, false, nil, nil
local metadata = {
    orderBy = { items = { { text = "人气", value = "" }, { text = "时间", value = "4" } } },
    filters = {
        { key = "subCatId", title = "子分类", items = { { text = "全部", value = "" }, { text = "东方玄幻", value = 8 } } },
        { key = "isvip", title = "资费", items = { { text = "全部", value = "" }, { text = "VIP", value = 1 } } },
        { key = "isfinish", title = "状态", items = { { text = "全部", value = "" }, { text = "完本", value = 1 } } },
    },
}
package.preload["source.qidian.client"] = function()
    return {
        categoryAsync = function(cat, cb)
            requests[#requests + 1] = cat or "index"
            cb(cat and metadata or { info = { { catId = 21, catName = "玄幻" }, { catId = 22, catName = "仙侠" } } })
            return { cancel = function() cancelled = "metadata" end }
        end,
        categoryListAsync = function(params, cb)
            requests[#requests + 1] = params
            local function done()
                if failure == params.pageNum then cb(nil, "offline")
                else cb({ records = pages[params.pageNum] or {}, pageNum = params.pageNum,
                    isLast = params.pageNum >= #pages and 1 or 0, pageMax = 50 }) end
            end
            if delayed then late = done else done() end
            return { cancel = function() cancelled = "page" end }
        end,
    }
end
local Library = require("source.qidian.browse")
local function row(id) return { bid = id, bName = "书" .. id } end
local function reset()
    requests, failure, delayed, late, cancelled = {}, nil, false, nil, nil
    pages = { { row(1), row(2) }, { row(2), row(3) }, { row(4), row(5) } }
end

do
    reset()
    local source, result = {}, nil
    Library.run(source, { limit = 5 }, function(value) result = value end)
    Assert.len(result.data, 5, "合并后续页并按稳定身份去重")
    Assert.eq(result.data[3].stable_id, "3")
    Assert.eq(requests[1], "index")
    Assert.eq(requests[2], "21")
    Assert.eq(requests[5].pageNum, 3)
    Assert.len(source.category_info, 2, "动态分类归源实例所有")
    Assert.len(result.groups, 5, "排序、子分类与筛选复用两行折叠菜单")
    Assert.eq(result.groups[5].title, "筛选")
    Assert.eq(result.groups[1].chips[3].id, "yuepiao:-1", "分类页仍可进入原榜单")
    Assert.matches(result.groups[2].chips[2].id, "catId=22")
end

do
    reset()
    local result
    Library.run({}, { node = "category?catId=80&gender=female&isvip=1&isfinish=1&orderBy=4", limit = 2 },
        function(value) result = value end)
    Assert.eq(requests[3].gender, "female")
    Assert.eq(requests[3].catId, "80")
    Assert.eq(requests[3].isvip, "1")
    Assert.eq(requests[3].isfinish, "1")
    Assert.eq(requests[3].orderBy, "4")
    Assert.eq(result.groups[2].chips[1].title, "古代言情")
    Assert.matches(result.groups[1].chips[1].id, "catId=21")
    Assert.matches(result.groups[1].chips[1].id, "isvip=1", "跨频道保留兼容条件")
end

do
    reset()
    failure = 2
    local result, err
    Library.run({}, { limit = 5 }, function(value, reason) result, err = value, reason end)
    Assert.is_nil(result, "中间页失败不能伪装成完整列表")
    Assert.eq(err, "offline")
end

do
    reset()
    pages = { { row(1) }, { row(1) }, { row(2) } }
    local result, err
    Library.run({}, { limit = 5 }, function(value, reason) result, err = value, reason end)
    Assert.is_nil(result, "源重复整页不能无限循环")
    Assert.is_true(err ~= nil)
end

do
    reset()
    delayed = true
    local called = false
    local job = Library.run({}, { limit = 5 }, function() called = true end)
    job.cancel()
    Assert.eq(cancelled, "page", "同步目录回调不能覆盖在飞分页的句柄")
    late()
    Assert.is_false(called)
    Assert.len(requests, 3)
end

do
    reset()
    pages = { {} }
    local result
    Library.run({}, { limit = 60 }, function(value) result = value end)
    Assert.len(result.data, 0)
    Assert.len(requests, 3)
end
