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
    Assert.eq(b.ref.source_id, "moon")
    Assert.eq(b.ref.stable_id, "a.epub")
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
    local list = Mapper.list({
        count = 1,
        data = { { filename = "a.epub", title = "t" } },
    })
    Assert.eq(list.count, 1)
    Assert.eq(list.data[1].ref.stable_id, "a.epub")
end

do
    local pos = Mapper.progress({ data = 0.25 })
    Assert.eq(pos.fraction, 0.25)
end

do
    local pos = Mapper.progress({ data = { percent = 80, spine = 2 } })
    Assert.eq(pos.fraction, 0.8)
    Assert.eq(pos.chapter_idx, 2)
end

Assert.is_nil(Mapper.book(nil))
Assert.is_nil(Mapper.book({ title = "no id" }))
