--[[--
source.contract / source.error 离线用例

@module tests.source.contract_spec
--]]

local Assert = require("support.assert")
local Contract = require("source.contract")
local SourceError = require("source.error")

do
    local c = Contract.defaultCapabilities()
    Assert.is_false(c.store)
    Assert.is_false(c.chapters)
    Assert.is_false(c.insight)
    Assert.is_false(c.stats_import)
    Assert.is_false(c.whole_book)
    Assert.is_nil(c.stats)
end

do
    local ref = Contract.makeRef("moon", "a.epub")
    Assert.eq(ref.source_id, "moon")
    Assert.eq(ref.stable_id, "a.epub")
    Assert.eq(type(ref.book_key), "string")
    Assert.is_true(#ref.book_key > 0)
    local ref2 = Contract.makeRef("wechat", "a.epub")
    Assert.is_true(ref.book_key ~= ref2.book_key)
end

Assert.eq(Contract.clampPercent(42), 42)
Assert.eq(Contract.clampPercent(0.5), 50)
Assert.eq(Contract.clampPercent(12, true), 100)
Assert.eq(Contract.clampFraction(0.42), 0.42)
Assert.eq(Contract.clampFraction(42), 0.42)

do
    local list = Contract.emptyList()
    Assert.eq(list.count, 0)
    Assert.eq(#list.data, 0)
end

do
    local err = SourceError.unsupported("nope")
    Assert.eq(err.code, "unsupported")
    Assert.eq(SourceError.message(err), "nope")
    Assert.eq(SourceError.code(err), "unsupported")
end
