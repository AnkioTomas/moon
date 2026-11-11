--[[-- QQ阅读动态分类、筛选、旧节点、多页和取消回归。 @module tests.source.qqreader.browse_spec --]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch

local Assert = require("support.assert")
local Stubs = require("support.stubs")
local requests, cancelled, delayed, late = {}, {}, false, nil
local KEYS = { "categoryId2", "categoryId3", "finishStatus", "priceStatus", "words", "updateTime", "orderBy", "pageNo" }
package.preload["source.qqreader.client"] = function()
    return { categoryAsync = function(path, cb)
        requests[#requests + 1] = path
        local idx = #requests
        local params, position = {}, 0
        for value in path:gmatch("[^-]+") do position = position + 1; params[KEYS[position]] = tonumber(value) end
        local data = { total = 0, params = params, books = {}, categoryList = {
            { name = "男生", subCategories = { { value = 20001, text = "玄幻" } } },
            { name = "女生", subCategories = { { value = 30013, text = "古言" } } },
            { name = "出版", subCategories = { { value = 13100, text = "小说" } } },
        } }
        for _idx, key in ipairs({ "categoryId3", "finishStatus", "priceStatus", "words", "updateTime", "orderBy" }) do
            data[key] = { title = key == "priceStatus" and "属性" or key, items = {
                { value = 0, text = "全部" }, { value = 3, text = "付费" },
            } }
        end
        cb(data)
        return { cancel = function() cancelled[idx] = true end }
    end,
    listAsync = function(url, cb)
        local path = url:match("^/book%-cate/(.+)$")
        requests[#requests + 1] = path
        local idx, page = #requests, tonumber(path:match("(%d+)$"))
        local books = {}
        for item = 1, 20 do books[item] = { source_id = "qqreader", stable_id = tostring((page - 1) * 20 + item) } end
        if delayed and page == 2 then late = function() cb(books) end else cb(books) end
        return { cancel = function() cancelled[idx] = true end }
    end }
end
local Library = require("source.qqreader.browse")

do
    local result, err
    Library.run({ node = "cate:20001", limit = 60 }, function(value, reason) result, err = value, reason end)
    Assert.is_nil(err)
    Assert.len(result.data, 60)
    Assert.len(requests, 4)
    Assert.eq(requests[1], "20001-0-0-0-0-0-0-1")
    Assert.eq(requests[4], "20001-0-0-0-0-0-0-3")
    Assert.eq(result.groups[1].title, "男生分类")
    Assert.eq(result.groups[2].title, "女生分类")
    Assert.eq(result.groups[3].title, "出版分类")
    Assert.eq(result.groups[4].title, "筛选")
    local found = false
    for _idx, group in ipairs(result.groups) do
        if group.title == "属性" then
            for _i, chip in ipairs(group.chips) do
                if chip.title == "付费" then
                    found = true
                    Assert.eq(chip.id, "cate:20001-0-0-3-0-0-0-1")
                end
            end
        end
    end
    Assert.is_true(found, "属性筛选项单独成组，标题不再拼选中标记")
end

do
    requests, cancelled, delayed = {}, {}, true
    local called = false
    local job = Library.run({ node = "cate:20001-20002-1-3-2-1-2-1" }, function() called = true end)
    Assert.eq(requests[1], "20001-20002-1-3-2-1-2-1")
    job.cancel()
    Assert.is_true(cancelled[3])
    late()
    Assert.is_false(called)
    Assert.len(requests, 3)
end

do
    requests = {}
    local result, err
    Library.run({ node = "cate:20001--0" }, function(value, reason) result, err = value, reason end)
    Stubs.flush()
    Assert.is_nil(result)
    Assert.matches(err, "分类条件无效")
    Assert.len(requests, 0)
end
