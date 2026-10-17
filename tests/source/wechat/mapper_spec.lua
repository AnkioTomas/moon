--[[--
source.wechat.mapper 离线用例

@module tests.source.wechat.mapper_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

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

-- 空封面必须视为缺失，不能参与远端 upsert 覆盖本地已有封面。
do
    local b, cover = Mapper.book({ bookId = "wx-empty", title = "保留封面", cover = "" })
    Assert.is_nil(b.cover)
    Assert.is_nil(cover)
end

-- bookInfo 扩展元数据原样交给 meta（规范化在 BookDB 入库时做），newRating 千分制折成十分制
do
    local b = Mapper.book({
        bookId = "wx-meta", publisher = "湖南文艺出版社", publishTime = "2022-01-01 00:00:00",
        isbn = "9787572606878", language = "zh", totalWords = 68000, newRating = 955,
    })
    Assert.eq(b.meta.publisher, "湖南文艺出版社")
    Assert.eq(b.meta.published, "2022-01-01 00:00:00")
    Assert.eq(b.meta.isbn, "9787572606878")
    Assert.eq(b.meta.language, "zh")
    Assert.eq(b.meta.words, 68000)
    Assert.eq(b.meta.rating.score, 9.55)
    Assert.eq(b.meta.rating.by, "weread")
end

-- 微信作品完结 finished=1 不当作用户读完
do
    local b = Mapper.book({ bookId = "1", finished = 1, progress = 20 })
    Assert.eq(b.percent, 20)
end

do
    local shelf = {
        books = { { bookId = "1", title = "A" } },
        recentBooks = { { bookId = "2", title = "B" } },
        finishReadBooks = { { bookId = "1", title = "A dup" }, { bookId = "3", title = "C" } },
        bookProgress = { { bookId = "1", progress = 33 } },
        albums = {},
    }
    local list = Mapper.shelfList(shelf)
    Assert.eq(#list.data, 3)
    local ids = {}
    for _, b in ipairs(list.data) do ids[b.stable_id] = b.title end
    Assert.eq(ids["1"], "A")
    Assert.eq(ids["2"], "B")
    Assert.eq(ids["3"], "C")
    Assert.eq(list.data[1].percent, 33)
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
                    { chapterIdx = 2, chapterUid = "u2", title = "二", wordCount = 10, level = 2 },
                    {
                        chapterIdx = 1, chapterUid = "u1", title = "一", wordCount = 10, level = 1,
                        anchors = { { title = "第一章", level = 2 } },
                    },
                    { chapterIdx = 3, chapterUid = "u3", title = "封面", wordCount = 10 },
                },
            },
        },
    }, "1")
    Assert.eq(#chapters, 2)
    Assert.eq(chapters[1].idx, 1)
    Assert.eq(chapters[1].uid, "u1")
    Assert.eq(chapters[1].depth, 1)
    Assert.eq(chapters[1].anchors[1].title, "第一章")
    Assert.eq(chapters[1].anchors[1].depth, 2)
    Assert.eq(chapters[1].toc_version, 4)
    Assert.not_nil(chapters[1].words, "带字数：关联书按篇幅对齐")
    Assert.eq(chapters[2].title, "二", "出版书（epub）章名原样")
    Assert.eq(chapters[2].depth, 2)
end

do
    -- 网文（book.format=txt，chapterInfos 实测字段）：按 chapterIdx 补「第 N 章」，已带序号的不重复补，空章名只留序号。
    local chapters = Mapper.chapters({
        data = {
            {
                bookId = "820954",
                book = { bookId = "820954", format = "txt" },
                updated = {
                    { chapterIdx = 1, chapterUid = 1, title = "万年之后", wordCount = 1290 },
                    { chapterIdx = 2, chapterUid = 2, title = "第二章 想整我？", wordCount = 1430 },
                    { chapterIdx = 3, chapterUid = 3, title = "第一次见面", wordCount = 10 },
                    { chapterIdx = 4, chapterUid = 4, title = "", wordCount = 10 },
                    { chapterIdx = 5, chapterUid = 5, title = "第12章", wordCount = 10 },
                },
            },
        },
    }, "820954")
    local titles = {}
    for i, ch in ipairs(chapters) do titles[i] = ch.title end
    Assert.eq(table.concat(titles, "|"), "第1章 万年之后|第二章 想整我？|第3章 第一次见面|第4章|第12章")
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
    local pos = Mapper.progress({ book = { chapterUid = "u7", progress = 1, chapterOffset = 1 } })
    Assert.eq(pos.chapter_fraction, 0.0001)
    pos = Mapper.progress({ book = { chapterUid = "u7", progress = 1, chapterOffset = 0 } })
    Assert.eq(pos.chapter_fraction, 0)
    pos = Mapper.progress({ book = { chapterUid = "u7", progress = 1 } })
    Assert.is_nil(pos.chapter_fraction)
end

-- 云端最近阅读时间：书行 readUpdateTime 与 bookProgress.updateTime 取较新的
do
    local b = Mapper.book({ bookId = "wx-r", title = "R", readUpdateTime = 1700000000 })
    Assert.eq(b.read_at, 1700000000)
    Mapper.applyProgress(b, { bookId = "wx-r", progress = 10, updateTime = 1700000500 })
    Assert.eq(b.read_at, 1700000500)
    Mapper.applyProgress(b, { bookId = "wx-r", progress = 10, updateTime = 1600000000 })
    Assert.eq(b.read_at, 1700000500, "旧的不覆盖新的")
    local list = Mapper.shelfList({
        books = { { bookId = "a", title = "A" } },
        bookProgress = { { bookId = "a", progress = 5, updateTime = 1234 } },
    })
    Assert.eq(list.data[1].read_at, 1234)

    -- 公众号只走订阅导入，书架同步不收进书库
    local mixed = Mapper.shelfList({ books = { { bookId = "a", title = "A" }, { bookId = "MP_WXS_1", title = "号" } } })
    Assert.len(mixed.data, 1)
    Assert.eq(mixed.data[1].stable_id, "a")
end
