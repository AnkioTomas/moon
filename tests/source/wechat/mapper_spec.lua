--[[--
source.wechat.mapper 离线用例

@module tests.source.wechat.mapper_spec
--]]

local Assert = require("support.assert")

package.preload["source.wechat.mapper"] = nil
package.loaded["source.wechat.mapper"] = nil
package.preload["source.contract"] = nil
-- contract 可能仍在 loaded，保留即可

local Mapper = require("source.wechat.mapper")

do
    local b, cover = Mapper.book({
        bookId = "wx-1",
        bookName = "三体",
        author = "刘慈欣",
        cover = "http://x/c.jpg",
        progressPercent = 42,
    })
    Assert.eq(b.source_id, "wechat")
    Assert.eq(b.stable_id, "wx-1")
    Assert.eq(b.title, "三体")
    Assert.eq(b.percent, 42)
    Assert.eq(cover, "http://x/c.jpg")
    Assert.is_nil(b.id)
end

-- 微信作品完结 finished=1 不当作用户读完
do
    local b = Mapper.book({ bookId = "1", finished = 1, progress = 20 })
    Assert.eq(b.percent, 20)
end

do
    local shelf = {
        books = { { bookId = "1", title = "A" } },
        bookProgress = { { bookId = "1", progress = 33 } },
        albums = {},
    }
    local list = Mapper.shelfList(shelf)
    Assert.eq(#list.data, 1)
    Assert.eq(list.data[1].percent, 33)
end

do
    local chapters = Mapper.chapters({
        data = {
            {
                bookId = "1",
                updated = {
                    { chapterIdx = 2, chapterUid = "u2", title = "二", wordCount = 10 },
                    { chapterIdx = 1, chapterUid = "u1", title = "一", wordCount = 10 },
                    { chapterIdx = 3, chapterUid = "u3", title = "封面", wordCount = 10 },
                },
            },
        },
    }, "1")
    Assert.eq(#chapters, 2)
    Assert.eq(chapters[1].idx, 1)
    Assert.eq(chapters[1].uid, "u1")
    Assert.eq(chapters[2].title, "二")
end

do
    local chapters = Mapper.chapters({
        data = {
            {
                bookId = "1",
                updated = {
                    { chapterIdx = 1, chapterUid = "u1", title = "图章", wordCount = 10, tar = "/web/tar/1" },
                },
            },
        },
    }, "1")
    Assert.eq(chapters[1].tar, "/web/tar/1")
end

do
    local pos = Mapper.progress({ progress = 50, chapterUid = "u1" })
    Assert.eq(pos.fraction, 0.5)
end

do
    local pos, uid = Mapper.progress({
        bookId = "42",
        book = { chapterUid = "u7", progress = 77, chapterOffset = 5000 },
    })
    Assert.eq(uid, "u7")
    Assert.eq(pos.fraction, 0.77)
    Assert.is_true(math.abs(pos.chapter_fraction - 0.5) < 0.001)
end

do
    local list = Mapper.searchList({
        books = {
            {
                searchIdx = 1,
                bookInfo = {
                    bookId = "22946457",
                    title = "围城",
                    author = "钱钟书",
                    cover = "http://x/c.jpg",
                },
            },
        },
        totalCount = 40,
        hasMore = 1,
    })
    Assert.eq(#list.data, 1)
    Assert.eq(list.data[1].stable_id, "22946457")
    Assert.eq(list.data[1].title, "围城")
    Assert.eq(list.data[1].authors, "钱钟书")
end
