--[[--
source.moon.mapper 离线用例

@module tests.source.moon.mapper_spec
--]]

local Assert = require("support.assert")
local Mapper = require("source.moon.mapper")

do
    local b = Mapper.book({
        filename = "a.epub",
        title = "三体",
        author = "刘慈欣",
        progress = 42,
    })
    Assert.eq(b.source_id, "moon")
    Assert.eq(b.stable_id, "a.epub")
    Assert.eq(b.title, "三体")
    Assert.eq(b.authors, "刘慈欣")
    Assert.eq(b.percent, 42)
    Assert.is_nil(b.id)
end

do
    local b = Mapper.book({ filename = "x.epub", finishReading = 1, progress = 12 })
    Assert.eq(b.percent, 100)
end

do
    local b = Mapper.book({
        filename = "x.epub",
        favorite = "小说",
        category = "标签",
        description = "简介",
        coverUrl = "https://img.test/x.jpg",
        hasReadTag = true,
    })
    Assert.eq(b.category, "小说")
    Assert.eq(b.intro, "简介")
    Assert.eq(b.cover, "https://img.test/x.jpg")
    Assert.eq(b.percent, 100)
end

do
    local list = Mapper.list({
        count = 1,
        data = { { filename = "a.epub", title = "t" } },
    })
    Assert.eq(list.count, 1)
    Assert.eq(list.data[1].stable_id, "a.epub")
end

do
    local pos = Mapper.progress({ data = 0.25 })
    Assert.eq(pos.fraction, 0.25)
end

do
    local pos = Mapper.progress({
        data = { percent = 80, spine = 2, page = 9, offset = 3, timestamp = 1700000000000 },
    })
    Assert.eq(pos.fraction, 0.8)
    Assert.eq(pos.chapter_idx, 2)
    Assert.eq(pos.page, 9)
    Assert.eq(pos.extra.offset, 3)
    Assert.eq(pos.updated_at, 1700000000)
end

do
    local pos = Mapper.progress({ data = { frac = 0.42 } })
    Assert.eq(pos.fraction, 0.42)

    pos = Mapper.progress({ data = { percent = "62.50%" } })
    Assert.eq(pos.fraction, 0.625)
end

Assert.is_nil(Mapper.book(nil))
Assert.is_nil(Mapper.book({ title = "no id" }))
