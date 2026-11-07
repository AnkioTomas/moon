--[[-- 起点旧榜单节点的聚合分页与失败。 @module tests.source.qidian.rank_spec --]]
local Assert = require("support.assert")
local pages, fail = {}, false
package.preload["source.qidian.client"] = function()
    return {
        rankPageAsync = function(key, cat, page, cb)
            pages[#pages + 1] = { key = key, cat = cat, page = page }
            if fail and page == 2 then cb(nil, "offline")
            else
                local rows = {}
                for i = 1, 20 do rows[i] = { bid = (page - 1) * 20 + i, bName = "测试" .. i } end
                cb({ records = rows, isLast = 0 })
            end
            return { cancel = function() end }
        end,
    }
end
local source = require("source.qidian").new()
local result, err
source:browseAsync({ node = "yuepiao:-1", limit = 60 }, function(value, reason) result, err = value, reason end)
Assert.is_nil(err)
Assert.len(result.data, 60)
Assert.eq(result.data[60].stable_id, "60")
Assert.len(pages, 3)
Assert.eq(pages[3].page, 3)
Assert.eq(pages[1].cat, "-1")
Assert.eq(result.groups[1].chips[1].title, "分类书库")

fail, pages = true, {}
source:browseAsync({ node = "readindex:21", limit = 60 }, function(value, reason) result, err = value, reason end)
Assert.is_nil(result, "后续页失败不能把榜单第一页报成完整结果")
Assert.eq(err, "offline")
Assert.len(pages, 2)
Assert.eq(pages[1].key, "readindex")
Assert.eq(pages[1].cat, "21")
