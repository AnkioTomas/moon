--[[--
source.moon.mapper 离线用例：wire 形状即 PHP book 服务端响应。

@module tests.source.moon.mapper_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

local Assert = require("support.assert")
local Mapper = require("source.moon.mapper")

--- /index/book/list 的一行：BookModel 字段 + progressPercent + hasReadTag。
local function row(fields)
    local out = {
        bookName = "", author = "", description = "", category = "", filename = "",
        coverUrl = "", favorite = "", series = "", progressPercent = 0.0, hasReadTag = false,
    }
    for k, v in pairs(fields) do out[k] = v end
    return out
end

do
    local b = Mapper.book(row{ filename = "a.epub", bookName = "三体", author = "刘慈欣", progressPercent = 42 })
    Assert.eq(b.source_id, "moon")
    Assert.eq(b.stable_id, "a.epub")
    Assert.eq(b.title, "三体")
    Assert.eq(b.authors, "刘慈欣")
    Assert.eq(b.percent, 42)
    Assert.is_nil(b.intro, "空简介不写 intro")
    Assert.is_nil(b.id)
end

-- 已读标签：进度按 100%
do
    local b = Mapper.book(row{
        filename = "x.epub", favorite = "小说", category = "标签", description = "简介",
        coverUrl = "https://img.test/x.jpg", hasReadTag = true, progressPercent = 12,
    })
    Assert.eq(b.category, "小说", "分类取收藏夹标签 favorite")
    Assert.eq(b.intro, "简介")
    Assert.eq(b.cover, "https://img.test/x.jpg")
    Assert.eq(b.percent, 100)
end

-- 没有 filename 的行不是书
Assert.is_nil(Mapper.book(row{ bookName = "no id" }))

do
    local list = Mapper.list({
        count = 3,
        data = { row{ filename = "a.epub" }, row{}, row{ filename = "b.epub" } },
    })
    Assert.eq(list.count, 3)
    Assert.len(list.data, 2)
    Assert.eq(list.data[2].stable_id, "b.epub")
end

-- /index/book/progress
do
    local pos = Mapper.progress({
        code = 200,
        data = { percent = 80, spine = 2, page = 9, offset = 3, locator = "/p[2]", timestamp = 1700000000000 },
    })
    Assert.eq(pos.fraction, 0.8)
    Assert.eq(pos.chapter_idx, 2)
    Assert.eq(pos.page, 9)
    Assert.eq(pos.extra.offset, 3)
    Assert.eq(pos.locator, "/p[2]")
    Assert.eq(pos.updated_at, 1700000000)

    pos = Mapper.progress({
        code = 200, data = { percent = 62.5, spine = 0, page = 0, offset = 0, locator = "", timestamp = 0 },
    })
    Assert.eq(pos.fraction, 0.625)
    Assert.is_nil(pos.locator, "过期 locator 的空串归一成 nil")
end

-- 云端没有进度：data 为 null（luajson 解成非表哨兵或 nil）
Assert.is_nil(Mapper.progress({ code = 200 }))
Assert.is_nil(Mapper.progress({ code = 200, data = function() end }))
