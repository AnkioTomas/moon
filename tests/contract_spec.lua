--[[--
source.contract 离线用例

@module tests.contract_spec
--]]

local Assert = require("support.assert")
local Contract = require("source.contract")

-- defaultCapabilities
do
    local c = Contract.defaultCapabilities()
    Assert.is_false(c.store)
    Assert.is_false(c.chapters)
    Assert.is_false(c.stats)
end

-- hasChapters
Assert.is_false(Contract.hasChapters(nil))
Assert.is_false(Contract.hasChapters({}))
Assert.is_false(Contract.hasChapters({ chapters = false }))
Assert.is_true(Contract.hasChapters({ chapters = true }))

-- normalizeBook：别名 → 契约字段
do
    local b = Contract.normalizeBook({
        bookId = "wx-1",
        bookName = "三体",
        author = "刘慈欣",
        cover = "http://x/c.jpg",
        progressPercent = 42,
    })
    Assert.eq(b.id, "wx-1")
    Assert.eq(b.title, "三体")
    Assert.eq(b.authors, "刘慈欣")
    Assert.eq(b.cover_id, "http://x/c.jpg")
    Assert.eq(b.progress, 42)
    Assert.is_false(b.finished)
end

-- normalizeBook：读完
do
    local b = Contract.normalizeBook({ filename = "a.epub", progressPercent = "100" })
    Assert.eq(b.id, "a.epub")
    Assert.is_true(b.finished)
end

-- normalizeBook：非 table 原样返回
Assert.is_nil(Contract.normalizeBook(nil))
Assert.eq(Contract.normalizeBook("x"), "x")

-- normalizeList：data / list / books
do
    local res = Contract.normalizeList({
        data = {
            { bookId = "1", bookName = "A" },
            { filename = "b.epub", name = "B" },
        },
    })
    Assert.eq(res.data[1].id, "1")
    Assert.eq(res.data[1].title, "A")
    Assert.eq(res.data[2].id, "b.epub")
    Assert.eq(res.data[2].title, "B")
end

do
    local res = Contract.normalizeList({
        list = { { bookId = "9", title = "Z" } },
    })
    Assert.eq(res.list[1].id, "9")
end
