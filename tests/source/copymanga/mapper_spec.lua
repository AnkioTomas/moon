--[[--
source.copymanga.mapper 离线用例

@module tests.source.copymanga.mapper_spec
--]]

local Assert = require("support.assert")

package.preload["source.copymanga.mapper"] = nil
package.loaded["source.copymanga.mapper"] = nil

local Mapper = require("source.copymanga.mapper")

do
    local b, cover = Mapper.book({
        name = "链锯人",
        path_word = "chainsaw-man",
        author = { { name = "藤本树" } },
        cover = "https://x/c.jpg",
    })
    Assert.eq(b.source_id, "copymanga")
    Assert.eq(b.stable_id, "chainsaw-man")
    Assert.eq(b.title, "链锯人")
    Assert.eq(b.authors, "藤本树")
    Assert.eq(cover, "https://x/c.jpg")
end

do
    local list = Mapper.list({
        results = {
            total = 1,
            list = { { name = "A", path_word = "a" } },
        },
    })
    Assert.eq(list.count, 1)
    Assert.eq(#list.data, 1)
    Assert.eq(list.data[1].stable_id, "a")
end

do
    local book, groups = Mapper.detail({
        results = {
            comic = {
                path_word = "spy-family",
                name = "间谍过家家",
                author = { { name = "远藤达哉" } },
                brief = "搞笑家庭",
                cover = "https://x/spy.jpg",
            },
            groups = {
                default = { name = "连载", path_word = "default" },
            },
        },
    })
    Assert.eq(book.stable_id, "spy-family")
    Assert.eq(book.title, "间谍过家家")
    Assert.eq(#groups, 1)
    Assert.eq(groups[1].path_word, "default")
end

do
    local page, total = Mapper.chapterPage({
        results = {
            total = 2,
            list = {
                { uuid = "u1", name = "第1话" },
                { uuid = "u2", name = "第2话" },
            },
        },
    })
    Assert.eq(total, 2)
    Assert.eq(#page, 2)
    Assert.eq(page[1].id, "u1")
end

do
    local chapters = Mapper.chapters({
        { id = "u1", name = "第1话" },
        { id = "u2", name = "第2话" },
    })
    Assert.eq(#chapters, 2)
    Assert.eq(chapters[1].idx, 1)
    Assert.eq(chapters[1].uid, "u1")
end

do
    local urls = Mapper.chapterPages({
        results = {
            chapter = {
                contents = {
                    { url = "https://img/1.c800x.webp" },
                    { url = "https://img/2.c800x.webp" },
                },
                words = { 1, 0 },
            },
        },
    })
    Assert.eq(#urls, 2)
    Assert.eq(urls[1], "https://img/2.c1500x.webp")
    Assert.eq(urls[2], "https://img/1.c1500x.webp")
end
