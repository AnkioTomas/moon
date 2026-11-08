--[[--
豆瓣进度按正文分段索引上传；专栏只写章节 article，不伪造整部作品进度。

@module tests.source.douban.progress_spec
--]]
---@diagnostic disable: undefined-field, missing-fields
local Assert = require("support.assert")
package.preload["json"] = function() return require("support.json_stub") end
local Mapper = require("source.douban.mapper")
local article = { posts = {
    { contents = { { type = "illus", id = 8 }, { type = "headline", id = 10 }, { type = "paragraph", id = 11, data = { text = "甲" } } } },
    { contents = { { type = "pagebreak", id = 20 }, { type = "paragraph", id = 22, data = { text = "乙" } } } },
} }
local position = Mapper.progressPosition(article, "22")
Assert.eq(position.part_sequence, 1)
Assert.eq(position.part_paragraph_sequence, 1)
Assert.eq(Mapper.progressPosition(article, "10").part_paragraph_sequence, 2)
Assert.is_nil(Mapper.progressPosition(article, "10", "11"))
Assert.is_nil(Mapper.progressPosition(article, "missing"))

local writes, fail_article = {}, false
package.preload["source.douban.client"] = function()
    return {
        loggedIn = function() return true end,
        articleAsync = function(_aid, cb)
            cb(not fail_article and article or nil, fail_article and "network failed" or nil)
            return { cancel = function() end }
        end,
        putProgressAsync = function(works_id, pid, _idx, _total, percentage, cb, actual)
            writes[#writes + 1] = { works_id = works_id, pid = pid, percentage = percentage, position = actual }
            cb(true)
            return { cancel = function() end }
        end,
    }
end
local source = require("source.douban").new()
local slice = false
function source:loadTocAsync(_identity, cb)
    cb({
        { uid = "10", content_url = "200" },
        { uid = slice and "22" or "200", content_url = "200", slice = slice },
    })
    return { cancel = function() end }
end
local ok, failure
source:putProgressAsync({ stable_id = "book", chapter_idx = 2 }, {}, function(value, err) ok, failure = value, err end)
Assert.is_true(ok)
Assert.is_nil(failure)
Assert.eq(#writes, 1)
Assert.eq(writes[1].works_id, "200")
Assert.eq(writes[1].pid, "11")
Assert.eq(writes[1].position.part_sequence, 0)
Assert.eq(writes[1].position.part_paragraph_sequence, 2)
Assert.eq(writes[1].percentage, false)
slice = true
source:putProgressAsync({ stable_id = "ebook", chapter_idx = 2 }, {}, function(value) ok = value end)
Assert.eq(writes[2].works_id, "ebook")
Assert.eq(writes[2].pid, "22")
Assert.eq(writes[2].position.part_paragraph_sequence, 1)
Assert.is_true(writes[2].percentage)
fail_article = true
source:putProgressAsync({ stable_id = "ebook", chapter_idx = 2 }, {}, function(value, err) ok, failure = value, err end)
Assert.is_nil(ok)
Assert.eq(failure, "network failed")
Assert.eq(#writes, 2)
