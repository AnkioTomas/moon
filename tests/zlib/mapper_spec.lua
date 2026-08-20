--[[-- Z-Library mapper 离线用例。 @module tests.zlib.mapper_spec --]]

local Assert = require("support.assert")
local Mapper = require("zlib.mapper")

Assert.eq(Mapper.identity(12, "abc"), "12:abc")
Assert.is_nil(Mapper.identity(nil, "abc"))
local id, hash = Mapper.parse("12:abc")
Assert.eq(id, "12")
Assert.eq(hash, "abc")

local book = Mapper.book({
    id = 12,
    hash = "abc",
    title = "书名",
    author = "作者",
    language = "Chinese",
    extension = "epub",
    filesize = "1234",
    cover = "https://img.example/a.jpg",
    description = "<p> 简介 </p>",
})
Assert.eq(book.source_id, "zlib")
Assert.eq(book.stable_id, "12:abc")
Assert.eq(book.authors, "作者")
Assert.eq(book.filesize, 1234)
Assert.eq(book.format, "epub")
Assert.eq(book.cover_url, "https://img.example/a.jpg")
Assert.eq(book.intro, "简介")

local result = Mapper.list({
    books = {
        { id = 1, hash = "a", title = "A" },
        { id = 2, hash = "b", title = "B" },
        { title = "缺身份" },
    },
    pagination = { total_items = 99 },
})
Assert.eq(result.count, 99)
Assert.len(result.data, 2)
Assert.eq(result.data[2].stable_id, "2:b")
