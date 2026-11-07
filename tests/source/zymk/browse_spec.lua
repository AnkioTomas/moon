--[[--
知音漫客分类：动态分组、组合筛选、排序、limit 和异常响应。

@module tests.source.zymk.browse_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch

local Assert = require("support.assert")
local Page = require("source.zymk.page")
local filters = Page.filters([[
<dt class="attr-hd">题材</dt><dd class="attr-bd"><a data-tag="5" title="热血">热血</a><a data-tag="7" title="玄幻">玄幻</a></dd>
<dt class="attr-hd">进度</dt><dd class="attr-bd"><a data-tag="23" title="连载">连载</a><a data-tag="24" title="完结">完结</a></dd>
]])
Assert.len(filters, 2)
Assert.eq(filters[1].items[2].id, "7")
Assert.is_nil(Page.filters("<html>风控页</html>"))

local wire = { filters = filters, rows = {
    { comic_id = 1, comic_name = "热血连载", class_idlist = ",5,23,", update_time = "2026-11-07", total_click = 5, pingfen = "9.8" },
    { comic_id = 2, comic_name = "玄幻完结", class_idlist = ",7,24,", update_time = "2026-11-06", total_click = 30, pingfen = "9.7" },
    { comic_id = 3, comic_name = "双题材完结", class_idlist = ",5,7,24,", update_time = "2026-11-05", total_click = 10, pingfen = "9.9" },
} }
package.loaded["source.zymk.client"] = {
    libraryAsync = function(cb) cb(wire); return { cancel = function() end } end,
}
local Library = require("source.zymk.browse")
local function load(opts)
    local result, reason
    Library.run(opts or {}, function(data, err) result, reason = data, err end)
    return result, reason
end
local result = load({ limit = 2 })
Assert.len(result.data, 2)
Assert.eq(result.data[1].stable_id, "1")
Assert.len(result.groups, 3)
Assert.eq(result.groups[2].title, "题材")
local category_node = result.groups[2].chips[2].id
result = load({ node = category_node })
Assert.len(result.data, 2)
Assert.eq(result.groups[2].active, category_node)
local finished_node = result.groups[3].chips[3].id
result = load({ node = finished_node })
Assert.len(result.data, 1)
Assert.eq(result.data[1].stable_id, "3")
Assert.eq(result.groups[3].active, finished_node)

result = load({ node = "library?sort=total_click" })
Assert.eq(result.data[1].stable_id, "2")
result = load({ node = "library?sort=pingfen" })
Assert.eq(result.data[1].stable_id, "3")
result = load({ node = "library?tag1=7&tag2=23" })
Assert.len(result.data, 0)
Assert.is_nil(load({ node = "library?tag1=999" }))
Assert.is_nil(load({ node = "library?sort=invalid" }))
Assert.is_nil(load({ node = "library?account=1" }))
wire.rows = { { comic_name = "坏行" } }
local broken, err = load()
Assert.is_nil(broken)
Assert.eq(err, "响应无效")
require("source.zymk.client").libraryAsync = function(cb) cb(nil, "网络故障") end
broken, err = load()
Assert.is_nil(broken)
Assert.eq(err, "网络故障")
