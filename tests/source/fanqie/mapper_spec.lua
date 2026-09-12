--[[--
番茄小说官方 wire 映射离线用例。

@module tests.source.fanqie.mapper_spec
--]]

local Assert = require("support.assert")
local Mapper = require("source.fanqie.mapper")

do
    local result = Mapper.shelfList({
        data = { detail_list = {{
            book_id = 123,
            book_name = "测试书",
            author_name = "作者",
            read_progress = 5000,
            thumb_url = "//example.test/cover.jpg",
        }} },
    })
    Assert.eq(result.count, 1)
    Assert.eq(result.data[1].source_id, "fanqie")
    Assert.eq(result.data[1].stable_id, "123")
    Assert.eq(result.data[1].percent, 50)
    Assert.eq(result.data[1].in_library, true)
    Assert.eq(result.data[1].cover, "https://example.test/cover.jpg")
end

do
    local toc = Mapper.chapters({
        data = { chapter_list = {
            { item_id = 11, title = "第一章", chapter_index = 0 },
            { item_id = 12, title = "第二章", chapter_index = 1 },
        } },
    })
    Assert.len(toc, 2)
    Assert.eq(toc[1].uid, "11")
    Assert.eq(toc[2].idx, 2)
end

do
    local payload = Mapper.content({
        data = { title = "正文", content = "<p>一</p>" },
    }, "备用标题")
    Assert.eq(payload.title, "正文")
    Assert.matches(payload.html, "<p>一</p>")
end

do
    local pos, uid = Mapper.progress({
        data = {{ book_id = "123", item_id = 12, read_progress = 2500, index = 1 }},
    })
    Assert.eq(pos.fraction, 0.25)
    Assert.eq(uid, "12")
end
