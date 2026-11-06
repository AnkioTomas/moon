--[[--
知乎书城榜单与分类节点，长篇目录接入。

@module tests.source.zhihu.browse_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch

local Assert = require("support.assert")
local selected, failure, called, cancelled
local catalog = {
    data = { { id = "22", title = "第一章", is_free = true, section_cell = { type = "article" } } },
    extra = { title = "长篇标题", tab_artwork = "https://img/column.jpg" },
}
package.loaded["source.zhihu.client"] = {
    browseAsync = function(rank, filter, cb)
        selected = rank .. ":" .. filter
        cb(not failure and { { source_id = "zhihu", stable_id = "1/2", title = "条目" } } or nil, failure, {
            { key = "0", name = "全部" }, { key = "12", name = " 脑洞 " }, { key = "999", name = "新分类" },
        })
        return { cancel = function() cancelled = true end }
    end,
    catalogAsync = function(id, cb) called = id; cb(catalog); return {} end,
    detailAsync = function(id, cb)
        called = "detail:" .. id
        cb({ source_id = "zhihu", stable_id = id, title = "长篇标题", authors = "作者",
            cover = "https://img/column.jpg", intro = "完整简介", meta = { rating = { score = 8.9, by = "zhihu" } } })
        return {}
    end,
    simpleAsync = function() error("长篇不能调用单节接口") end,
}
local saved
package.loaded["source.toc"] = {
    read = function() end,
    put = function(source_id, stable_id, chapters)
        saved = { source_id = source_id, stable_id = stable_id, chapters = chapters }
        return true
    end,
}
package.loaded["book.store"] = { rememberDetail = function(book) return book end }
local source = require("source.zhihu").new()
local result, err
source:browseAsync(nil, function(value, reason) result, err = value, reason end)
Assert.eq(selected, "recommend:0")
Assert.eq(result.groups[1].active, "recommend:0")
Assert.eq(result.groups[2].active, "recommend:0")
Assert.len(result.data, 1)
local handle = source:browseAsync({ node = "hot_search:12" }, function(value, reason) result, err = value, reason end)
Assert.eq(selected, "hot_search:12")
Assert.eq(result.groups[1].active, "hot_search:0")
Assert.eq(result.groups[2].active, "hot_search:12")
Assert.eq(result.groups[2].chips[2].title, "脑洞")
Assert.eq(result.groups[2].chips[3].id, "hot_search:999", "分类使用官网配置，不维护第二份分类表")
handle.cancel()
Assert.is_true(cancelled)
source:browseAsync({ node = "unknown:0" }, function(value) result = value end)
Assert.eq(selected, "recommend:0")
failure = "network failed"
source:browseAsync({ node = "well:0" }, function(value, reason) result, err = value, reason end)
Assert.is_nil(result)
Assert.eq(err, failure)
failure = nil

local identity = { source_id = "zhihu", stable_id = "11" }
source:loadTocAsync(identity, function(value) result = value end)
Assert.eq(called, "11")
Assert.eq(result[1].uid, "22")
Assert.eq(saved.stable_id, "11")
Assert.eq(saved.source_id, "zhihu")
source:getDetailAsync(identity, function(value) result = value end)
Assert.eq(called, "detail:11", "详情走书籍接口，不用目录的精简元数据或榜单片段")
Assert.eq(result.stable_id, "11")
Assert.eq(result.title, "长篇标题")
Assert.eq(result.cover, "https://img/column.jpg")
Assert.eq(result.authors, "作者")
Assert.eq(result.intro, "完整简介")
Assert.eq(result.meta.rating.score, 8.9)
