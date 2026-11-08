--[[--
潇湘动态分类、标签、完整分页及取消。

@module tests.source.xiaoxiang.browse_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch

local A = require("support.assert")
local null = function() end
local JSON = require("support.json_stub")
package.loaded["json"] = { decode = function(wire)
    if wire == "null" then return null end
    return JSON.decode(wire)
end }
local calls, waiting, stopped, mode = {}, nil, false, "sync"
---@type {id: integer, name: string, labelClassList: {name?: string, tagInfoList?: (fun())|string|{tagId: integer, tagName: string}[]}[]}[]
local categories = {
    { id = 0, name = "全部", labelClassList = {} },
    { id = 30013, name = "古代言情", labelClassList = {
        { name = "全部标签", tagInfoList = null },
        { tagInfoList = { { tagId = 61000007, tagName = "女强" }, { tagId = 61000007, tagName = "女强" } } },
    } },
    { id = 30020, name = "现代言情", labelClassList = {} },
}
local function reply(index, cb)
    if mode == "error" and index == 2 then cb(nil, "网络失败"); return end
    local rows = {}
    for i = 1, 20 do rows[i] = { cbId = tostring((index - 1) * 20 + i), bookName = "书" } end
    cb({ data = { categoryList = categories, bookList = rows, total = 100 } })
end
package.loaded["source.xiaoxiang.client"] = {
    libraryAsync = function(params, index, cb)
        calls[#calls + 1] = { params = params, index = index }
        if mode == "waiting" and index == 2 then waiting = cb else reply(index, cb) end
        return { cancel = function() stopped = true end }
    end,
}
package.loaded["source.xiaoxiang.browse"] = nil
local Library = require("source.xiaoxiang.browse")
local result, err
Library.run({}, function(data, reason) result, err = data, reason end)
A.is_nil(err)
A.len(result.data, 60)
A.len(calls, 3)
A.eq(result.data[60].stable_id, "60")
A.eq(result.groups[1].title, "分类")
local chosen = result.groups[1].chips[2].id
A.eq(chosen, "cate:-1:-1:-1:-1:10:30013:-1")
Library.run({ node = chosen }, function(data) result = data end)
A.eq(result.groups[2].title, "标签")
A.len(result.groups[2].chips, 2, "重复标签不重复显示")
local tagged = result.groups[2].chips[2].id
Library.run({ node = tagged, limit = 20 }, function(data) result = data end)
A.eq(calls[#calls].params.tag, 61000007)
A.eq(result.groups[1].chips[3].id, "cate:-1:-1:-1:-1:10:30020:-1", "换分类清标签")
Library.run({ node = "cate:1:0:2:25:6:30013:-1", limit = 20 }, function(data) result = data end)
A.eq(calls[#calls].params.state, 1)
A.eq(calls[#calls].params.charge, 0)
A.eq(calls[#calls].params.words, 25)
A.len(result.data, 20)
for _idx, invalid in ipairs({ "invalid", function() end }) do
    categories[2].labelClassList[1].tagInfoList = invalid
    Library.run({ node = chosen }, function(data, reason) result, err = data, reason end)
    A.is_nil(result, "未知函数和坏类型不能冒充 JSON null")
    A.eq(err, "响应无效")
end
categories[2].labelClassList[1].tagInfoList = null
mode = "error"
Library.run({}, function(data, reason) result, err = data, reason end)
A.is_nil(result, "中间页失败不能伪装完整列表")
A.eq(err, "网络失败")
mode, stopped, result = "waiting", false, nil
local handle = Library.run({}, function(data) result = data end)
handle.cancel()
A.is_true(stopped, "同步第一页不能覆盖第二页取消句柄")
reply(2, waiting)
A.is_nil(result)
mode = "sync"
Library.run({ node = "cate:-1:-1:-1:-1:99:0:-1" }, function(data, reason) result, err = data, reason end)
require("support.stubs").flush()
A.is_nil(result)
A.eq(err, "潇湘分类条件无效")
