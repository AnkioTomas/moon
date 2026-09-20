-- 拆分后的领域类型契约离线用例。

local Assert = require("support.assert")
local Progress = require("book.progress")
local SourceCapabilities = require("source.base").SourceCapabilities
local Catalog = require("book.catalog")

do
    local c = SourceCapabilities.defaults()
    Assert.is_false(c.store)
    Assert.is_false(c.insight)
    Assert.is_false(c.stats_pull)
    Assert.is_false(c.scrape)
    Assert.is_false(c.edit)
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
    Assert.is_false(SourceCapabilities.supportsEdit(nil))
    Assert.is_false(SourceCapabilities.supportsEdit({ capabilities = function()
        return { edit = false }
    end }))
    Assert.is_true(SourceCapabilities.supportsEdit({ capabilities = function()
        return { edit = true }
    end }))
    Assert.is_false(SourceCapabilities.supportsStatsPull(nil))
    Assert.is_true(SourceCapabilities.supportsStatsPull({ capabilities = function()
        return { stats_pull = true }
    end }))
end

do
    local identity = { source_id = "moon", stable_id = "a.epub" }
    Assert.eq(identity.source_id, "moon")
    Assert.eq(identity.stable_id, "a.epub")
end

Assert.eq(Progress.clampPercent(42), 42)
Assert.eq(Progress.clampPercent(0.5), 50)
Assert.eq(Progress.clampPercent(12, true), 100)
Assert.eq(Progress.clampFraction(0.42), 0.42)
Assert.eq(Progress.clampFraction(42), 0.42)

do
    local list = Catalog.listResult()
    Assert.eq(list.count, 0)
    Assert.eq(#list.data, 0)
end
