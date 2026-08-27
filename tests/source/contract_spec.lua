-- 拆分后的领域类型契约离线用例。

local Assert = require("support.assert")
local BookTypes = require("types.book")
local SourceCapabilities = require("types.book_source").SourceCapabilities
local ProgressPosition = require("types.book_progress")
local BookListResult = require("types.book_list")

do
    local c = SourceCapabilities.defaults()
    Assert.is_false(c.store)
    Assert.is_false(c.insight)
    Assert.is_false(c.scrape)
    Assert.is_nil(c.library)
    Assert.is_nil(c.detail)
    Assert.is_nil(c.filters)
    Assert.is_nil(c.recent)
    Assert.is_nil(c.cover)
    Assert.is_nil(c.whole_book)
    Assert.is_nil(c.chapters)
    Assert.is_nil(c.progress_pull)
    Assert.is_nil(c.progress_push)
    Assert.is_nil(c.stats_import)
    Assert.is_false(SourceCapabilities.supportsScrape(nil))
    Assert.is_false(SourceCapabilities.supportsScrape({ capabilities = function()
        return { scrape = false }
    end }))
    Assert.is_true(SourceCapabilities.supportsScrape({ capabilities = function()
        return { scrape = true }
    end }))
end

do
    local identity = { source_id = "moon", stable_id = "a.epub" }
    Assert.eq(identity.source_id, "moon")
    Assert.eq(identity.stable_id, "a.epub")
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
