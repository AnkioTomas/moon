--[[-- 长佩分类、筛选、多页与取消。 @module tests.source.changpei.browse_spec --]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch

local Assert = require("support.assert")
local pages, query, late, cancelled = {}, nil, nil, false
local bad_page, delayed = false, false
package.preload["source.changpei.client"] = function()
    return {
        typesAsync = function(id, cb)
            local rows = id and { { id = 1, type_name = "现代" }, { id = 3, type_name = "古代" } }
                or { { id = 75, type_name = "纯爱" }, { id = 74, type_name = "言情" } }
            cb({ data = { list = rows } })
            return { cancel = function() error("finished category request cancelled") end }
        end,
        libraryAsync = function(params, page, cb)
            query = params
            pages[#pages + 1] = page
            local function done()
                if bad_page and page == 2 then cb(nil, "network"); return end
                local list = {}
                for idx = 1, 10 do
                    list[idx] = { novel_id = (page - 1) * 10 + idx, novel_name = "书", novel_author = "作者",
                        novel_info = "分类简介", novel_type = "" }
                end
                cb({ data = { list = list, count = 50 } })
            end
            if delayed then late = done else done() end
            return { cancel = function() cancelled = true end }
        end,
    }
end
local Library = require("source.changpei.browse")
local result, err
Library.run({ limit = 30 }, function(value, reason) result, err = value, reason end)
Assert.len(result.data, 30)
Assert.eq(#pages, 3)
Assert.eq(result.data[1].intro, "分类简介")
Assert.eq(result.groups[1].title, "频道")
Assert.eq(query.field, 8)
Assert.is_nil(query.sell)

Library.run({ node = "cate:75:1:2:0:3:4", limit = 10 }, function(value) result = value end)
Assert.eq(query.tid, 1)
Assert.eq(query.process, 2)
Assert.eq(query.sell, 0, "免费不是未设置")
Assert.eq(query.number, 3)
Assert.eq(query.field, 4)
Assert.eq(result.groups[2].active, "cate:75:1:2:0:3:4")
Assert.eq(result.groups[1].active, "cate:75:1:2:0:3:4")
Assert.eq(result.groups[1].chips[2].id, result.groups[1].active, "当前频道保留子分类并显示选中")
local switched = result.groups[1].chips[3].id
Assert.eq(switched, "cate:74:0:2:0:3:4", "换频道清分类，保留通用筛选")

bad_page = true
Library.run({ limit = 30 }, function(value, reason) result, err = value, reason end)
Assert.is_nil(result)
Assert.eq(err, "network", "中间页失败不能伪装成完整结果")

bad_page, delayed = false, true
local called = false
local handle = Library.run({ limit = 30 }, function() called = true end)
handle.cancel()
Assert.is_true(cancelled, "同步导航不能覆盖后续分页的取消句柄")
late()
Assert.is_false(called)
