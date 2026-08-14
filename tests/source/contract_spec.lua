-- 拆分后的领域类型契约离线用例。

local Assert = require("support.assert")
local BookTypes = require("types.book")
local SourceCapabilities = require("types.book_source").SourceCapabilities
local ProgressPosition = require("types.book_progress")
local BookListResult = require("types.book_list")

do
    local c = SourceCapabilities.defaults()
    Assert.is_false(c.store)
    Assert.is_false(c.chapters)
    Assert.is_false(c.insight)
    Assert.is_false(c.stats_import)
    Assert.is_false(c.whole_book)
    Assert.is_nil(c.stats)
end

do
    local ref = BookTypes.BookRef.new("moon", "a.epub")
    Assert.eq(ref.source_id, "moon")
    Assert.eq(ref.stable_id, "a.epub")
    Assert.eq(type(ref.book_key), "string")
    Assert.is_true(#ref.book_key > 0)
    local ref2 = BookTypes.BookRef.new("wechat", "a.epub")
    Assert.is_true(ref.book_key ~= ref2.book_key)
end

Assert.eq(BookTypes.Book.clampPercent(42), 42)
Assert.eq(BookTypes.Book.clampPercent(0.5), 50)
Assert.eq(BookTypes.Book.clampPercent(12, true), 100)
Assert.eq(ProgressPosition.clampFraction(0.42), 0.42)
Assert.eq(ProgressPosition.clampFraction(42), 0.42)

do
    local list = BookListResult.empty()
    Assert.eq(list.count, 0)
    Assert.eq(#list.data, 0)
end
