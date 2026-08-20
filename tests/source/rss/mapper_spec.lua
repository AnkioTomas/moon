local Assert = require("support.assert")
local Mapper = require("source.rss.mapper")

local parsed = {
    title = "Feed title",
    intro = "Intro",
    items = {
        {
            uid = "g1",
            title = "Newest",
            link = "https://example.com/1",
            content = "<p>one</p>",
        },
        {
            uid = "g2",
            title = "Older",
            link = "https://example.com/2",
            content = "",
        },
    },
}

do
    local result = Mapper.library({
        { url = "EXAMPLE.COM/feed/", title = "Override" },
        { url = "https://example.com/feed" },
        { url = "" },
    })
    Assert.eq(result.count, 1)
    Assert.eq(result.data[1].source_id, "rss")
    Assert.eq(result.data[1].stable_id, "https://example.com/feed")
    Assert.eq(result.data[1].title, "Override")
end

do
    local book = Mapper.book({ url = "https://example.com/feed" }, parsed)
    Assert.eq(book.title, "Feed title")
    Assert.eq(book.intro, "Intro")
    Assert.eq(book.category, "RSS")
end

do
    local chapters = Mapper.chapters(parsed)
    Assert.eq(#chapters, 2)
    Assert.eq(chapters[1].idx, 1)
    Assert.eq(chapters[1].uid, "g1")
    Assert.eq(chapters[2].idx, 2)

    local payload = Mapper.chapterContent(parsed, chapters[1])
    Assert.eq(payload.title, "Newest")
    Assert.eq(payload.html, "<p>one</p>")

    local fallback = Mapper.chapterContent(parsed, chapters[2])
    Assert.eq(fallback.text, "https://example.com/2")
end
