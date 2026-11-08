--[[-- 长佩书评与真正章评，分页、归属和坏响应。 @module tests.source.changpei.reviews_spec --]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch

local Assert = require("support.assert")
local Mapper = require("source.changpei.mapper")
local rows = {}
for idx = 1, 10 do
    rows[idx] = { replay_id = idx, replay_module = "novel_chapter", replay_cid = 123,
        replay_content = "评论", replay_nickname = "读者", child_comment_number = 2 }
end
local page = Mapper.comments({ data = { list = rows, count = 0 } }, "chapter", "123", 1)
Assert.len(page.items, 10)
Assert.is_true(page.more, "官网 count=0 不代表没有评论")
Assert.eq(page.items[1].replies, 2)
Assert.eq(page.max_idx, 1)
local ending = Mapper.comments({ data = { list = { rows[1] }, count = 0 } }, "chapter", "123", 2)
Assert.eq(ending.total, 11)
Assert.is_false(ending.more)
Assert.len(Mapper.comments({ data = { list = {}, count = 0 } }, "chapter", "123", 1).items, 0)
Assert.is_nil((Mapper.comments({ data = {} }, "chapter", "123", 1)))
Assert.is_nil((Mapper.comments({ data = { list = rows } }, "chapter", "124", 1)), "不把旧章评论挂到新章")
Assert.is_nil((Mapper.comments({ data = { list = rows } }, "novel", "123", 1)), "章评不能冒充书评")
local mixed = { replay_id = 9, replay_module = "novel_chapter", replay_cid = 123, novel_id = 7,
    novel_chapter_name = "第二章", replay_content = "章末讨论" }
local book_page = Mapper.comments({ data = { list = { mixed }, count = 0 } }, "novel", "7", 1)
Assert.eq(book_page.items[1].reply_to, "第二章", "全书列表汇总章评时保留章节归属")
Assert.is_nil((Mapper.comments({ data = { list = { mixed } } }, "novel", "8", 1)))

local late, cancelled
local WithUid = require("source.with_chapter_uid")
local called = false
local job = WithUid.run({ loadTocAsync = function(_self, _identity, cb)
    cb({ { uid = "123" } })
    return { cancel = function() error("stale toc cancelled") end }
end }, { chapter_idx = 1 }, "missing", function(uid, cb)
    Assert.eq(uid, "123")
    late = cb
    return { cancel = function() cancelled = true end }
end, function() called = true end)
job.cancel()
Assert.is_true(cancelled)
late({})
Assert.is_false(called)

local detail = Mapper.detail({ data = { novel_id = 1, novel_name = "书", author_nickname = "作者",
    novel_info = "长简介", novel_desc = "短简介", type_names = "纯爱" } })
Assert.eq(detail.intro, "长简介")
Assert.eq(detail.authors, "作者")
local toc = Mapper.toc({ data = { list = {
    { type = "volume", name = "上卷" }, { type = "item", id = 1, name = "第一章", price = 0 },
    { type = "volume", name = "下卷" }, { type = "item", id = 2, name = "第二章", price = 2, is_sub = true },
} } })
Assert.eq(toc[2].uid, "2", "跨卷仍按官网顺序连续编号")
Assert.is_true(toc[2].paid)
Assert.is_nil((Mapper.toc({ data = {} })))
local history = Mapper.history({ data = { list = {
    { list = { { novel_id = 1, latest_read_cid = 20 } } },
    { list = { { novel_id = 1, latest_read_cid = 10 } } },
} } })
Assert.eq(history["1"], "20", "旧日期记录不能覆盖最新进度")
