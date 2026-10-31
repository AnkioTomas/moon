--[[--
起点书架分组：拉书架时记住自定义分组（默认分组 -100 不算，一本书多个组取第一个），
开「分组代替分类」时进组书的分类用分组名、没进组不写分类；移出分组后本地旧行也要落回题材。

@module tests.source.qidian.shelf_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch

local Assert = require("support.assert")

package.loaded["json"] = nil
package.preload["json"] = function()
    local stub = require("support.json_stub")
    return { decode = stub.decode, encode = stub.encode }
end
package.preload["source.qidian.fock"] = function() return {} end

local PAGES = {
    ["-100"] = '{"code":0,"data":{"count":3,"page":{"isLast":1},'
        .. '"groups":[{"groupId":-100,"groupName":"默认分组","bookCount":3},'
        .. '{"groupId":7,"groupName":"追更","bookCount":2}],'
        .. '"list":[{"bid":1,"bName":"甲","cateName":"玄幻"},{"bid":2,"bName":"乙","cateName":"都市"}]}}',
    ["7"] = '{"code":0,"data":{"count":2,"page":{"isLast":1},'
        .. '"groups":[{"groupId":7,"groupName":"追更","bookCount":2}],'
        .. '"list":[{"bid":2,"bName":"乙","cateName":"都市"},{"bid":3,"bName":"丙","cateName":"科幻"}]}}',
}
package.loaded["http.request"] = nil
package.preload["http.request"] = function()
    return {
        get = function(url, _opts, cb)
            local gid = url:match("gid=([^&]+)")
            cb(PAGES[gid] or PAGES["-100"])
            return { cancel = function() end }
        end,
    }
end
local cfg = { category_as_group = true }
package.loaded["utils.settings"] = nil
package.preload["utils.settings"] = function()
    return { getSource = function() return cfg end }
end
package.loaded["source.qidian.client"] = nil
package.loaded["source.qidian.mapper"] = nil
local Client = require("source.qidian.client")
local Mapper = require("source.qidian.mapper")

do -- 逐组拉取后按 bookId 记组：乙在默认组先出现，进了「追更」仍要记上
    local rows
    Client.shelfAsync("_csrfToken=tok; other=1", function(r, err)
        rows = r
        Assert.is_nil(err)
    end)
    Assert.len(rows, 3)
    Assert.is_nil(rows[1]._group_name, "只在默认组的书不算分组")
    Assert.eq(rows[2]._group_name, "追更")
    Assert.eq(rows[3]._group_name, "追更")

    local books = Mapper.shelfList(rows)
    Assert.is_nil(books[1].category, "开：没进组不写题材")
    Assert.eq(books[2].category, "追更")
    Assert.eq(books[3].category, "追更")
end

do -- 移出分组：本地旧行分类是旧分组名，书架行题材要把它刷新回来
    local books = Mapper.shelfList({
        { bid = 9, bName = "丁", cateName = "历史",
          local_book = { stable_id = "9", title = "丁", category = "追更", cover = "c" } },
        { bid = 10, bName = "戊", cateName = "游戏", _group_name = "在读",
          local_book = { stable_id = "10", title = "戊", category = "历史", cover = "c" } },
    })
    Assert.is_nil(books[1].category, "开：移出分组后不再沿用旧分组名")
    Assert.eq(books[2].category, "在读", "进了组用分组名覆盖本地旧分类")
end

do -- 分页没有页数上限：超过 50 页照样翻到末页
    local n = 0
    local list = {}
    for i = 1, 20 do list[#list + 1] = ('{"bid":%d,"bName":"书","cateName":"玄幻"}'):format(i) end
    package.loaded["http.request"] = nil
    package.preload["http.request"] = function()
        return { get = function(_url, _opts, cb)
            n = n + 1
            cb('{"code":0,"data":{"count":9999,"page":{"isLast":' .. (n > 60 and "1" or "0")
                .. '},"groups":[],"list":[' .. table.concat(list, ",") .. "]}}")
            return { cancel = function() end }
        end }
    end
    package.loaded["source.qidian.client"] = nil
    local Deep = require("source.qidian.client")
    local rows, err
    Deep.shelfAsync("_csrfToken=tok", function(r, e) rows, err = r, e end)
    Assert.is_nil(err)
    Assert.len(rows, 20)
    Assert.eq(n, 61)
end
