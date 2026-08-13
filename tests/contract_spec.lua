--[[--
source.contract 离线用例

@module tests.contract_spec
--]]

local Assert = require("support.assert")
local Contract = require("source.contract")

-- defaultCapabilities：只有页面真查的能力位
do
    local c = Contract.defaultCapabilities()
    Assert.is_false(c.store)
    Assert.is_false(c.chapters)
    Assert.is_false(c.stats)
    Assert.is_nil(c.progress_sync)
    Assert.is_nil(c.search)
end

-- hasChapters
Assert.is_false(Contract.hasChapters(nil))
Assert.is_false(Contract.hasChapters({}))
Assert.is_false(Contract.hasChapters({ chapters = false }))
Assert.is_true(Contract.hasChapters({ chapters = true }))

-- normalizeBook：wire 别名 → 契约字段；死字段不进结果
do
    local b = Contract.normalizeBook({
        bookId = "wx-1",
        bookName = "三体",
        author = "刘慈欣",
        cover = "http://x/c.jpg",
        progressPercent = 42,
        publisher = "重庆",
        extra = { kind = "x" },
    })
    Assert.eq(b.id, "wx-1")
    Assert.eq(b.title, "三体")
    Assert.eq(b.authors, "刘慈欣")
    Assert.eq(b.percent, 42)
    Assert.is_nil(b.cover)
    Assert.is_nil(b.cover_id)
    Assert.is_nil(b.finished)
    Assert.is_nil(b.publisher)
    Assert.is_nil(b.extra)
    Assert.is_nil(b.progressPercent)
end

-- normalizeBook：用户读完 → percent=100（无 finished 字段）
do
    local b = Contract.normalizeBook({ filename = "a.epub", finishReading = 1, progress = 12 })
    Assert.eq(b.id, "a.epub")
    Assert.eq(b.percent, 100)
end

-- normalizeBook：微信作品完结 finished=1 不当作用户读完
do
    local b = Contract.normalizeBook({ bookId = "1", finished = 1, progress = 20 })
    Assert.eq(b.percent, 20)
end

-- normalizeBook：非 table → nil
Assert.is_nil(Contract.normalizeBook(nil))
Assert.is_nil(Contract.normalizeBook("x"))

-- normalizeBookDetail：只多 intro
do
    local d = Contract.normalizeBookDetail({
        bookId = "1",
        title = "t",
        intro = "简介",
        isbn = "978",
        wordCount = 9,
    })
    Assert.eq(d.intro, "简介")
    Assert.is_nil(d.isbn)
    Assert.is_nil(d.word_count)
end

-- normalizeProgress：只要进度跳转需要的字段
do
    local p = Contract.normalizeProgress({
        progress = 80,
        chapterUid = "c1",
        chapterOffset = 3,
        isStartReading = 1,
    }, "bid")
    Assert.eq(p.percent, 80)
    Assert.eq(p.chapter_uid, "c1")
    Assert.is_nil(p.id)
    Assert.is_nil(p.finished)
    Assert.is_nil(p.chapter_offset)
    Assert.is_nil(p.is_start_reading)
end

-- normalizeChapter
do
    local ch = Contract.normalizeChapter({
        chapterUid = "u",
        chapterIdx = 3,
        title = "章",
        wordCount = 10,
        paid = 1,
    }, 1)
    Assert.eq(ch.idx, 1)
    Assert.eq(ch.uid, "u")
    Assert.eq(ch.title, "章")
    Assert.is_nil(ch.source_idx)
    Assert.is_nil(ch.word_count)
    Assert.is_nil(ch.paid)
end

-- normalizeInsight：无 breakdown / 秒数字段
do
    local insight = Contract.normalizeInsight({
        hasData = true,
        readingActivity = {
            hasData = true,
            kpi = {
                totalReadingTime = "10h",
                last7DaysReadTime = "1h",
                longestDay = "2h",
                totalPagesRead = 3,
            },
            perMonth = { { label = "1月", pct = 10 } },
        },
        perDay = {
            ["2026-08-01"] = {
                duration = 60,
                durationText = "1m",
                books = { { bookId = "x", title = "b", author = "a", progress = 5 } },
            },
        },
        initialYm = "2026-08",
    })
    Assert.is_true(insight.has_data)
    Assert.is_nil(insight.breakdown)
    Assert.eq(insight.total.total_text, "10h")
    Assert.eq(insight.total.total_pages, 3)
    Assert.is_nil(insight.total.total_seconds)
    Assert.eq(insight.calendar.initial_ym, "2026-08")
    Assert.eq(insight.calendar.days["2026-08-01"].duration_text, "1m")
    Assert.eq(insight.calendar.days["2026-08-01"].books[1].id, "x")
end

-- normalizeList：统一到 data[]
do
    local res = Contract.normalizeList({
        data = {
            { bookId = "1", bookName = "A" },
            { filename = "b.epub", name = "B" },
        },
    })
    Assert.eq(res.count, 2)
    Assert.eq(res.data[1].id, "1")
    Assert.eq(res.data[1].title, "A")
    Assert.eq(res.data[2].id, "b.epub")
    Assert.eq(res.data[2].title, "B")
    Assert.is_nil(res.code)
end

do
    local res = Contract.normalizeList({
        list = { { bookId = "9", title = "Z" } },
    })
    Assert.eq(res.data[1].id, "9")
end
