--[[--
借段评来源：可登记多个，关联按 source_id 取来源，旧关联按第一个登记者算。

@module tests.features.reviews.lender_spec
--]]

local Assert = require("support.assert")
local Ext = require("utils.extension")
Ext.add("reader.paragraph_lender", { id = "ext.a", label = "甲" })
Ext.add("reader.paragraph_lender", { id = "ext.b", label = "乙" })
package.loaded["source.registry"] = { resolve = function(id) return { id = id } end }
local Lender = require("features.reviews.lender")

Assert.len(Lender.list(), 2)
Assert.is_true(Lender.registered())
Assert.eq(Lender.idOf(nil), "ext.a")
Assert.eq(Lender.idOf({ book_id = "1" }), "ext.a", "旧关联按第一个登记者")
Assert.eq(Lender.idOf({ source_id = "ext.b" }), "ext.b")
Assert.eq(Lender.get("ext.b").id, "ext.b")
Assert.is_nil(Lender.get("ext.none"))
Assert.eq(Lender.label("ext.b"), "乙")

-- 没有 searchBooksAsync 的源退到书城搜索，Book 映射成关联书目。
do
    local got
    local source = { searchAsync = function(_, _, cb)
        cb({ data = { { stable_id = 12, title = "书", authors = { "甲", "乙" } }, { stable_id = "3", title = "二", author = "丙" } } })
    end }
    Lender.search(source, "书", function(books) got = books end)
    Assert.eq(got[1].book_id, "12")
    Assert.eq(got[1].author, "甲 / 乙")
    Assert.eq(got[2].author, "丙")
    local direct
    Lender.search({ searchBooksAsync = function(_, _, cb) cb({ { book_id = "9" } }) end }, "x", function(books) direct = books end)
    Assert.eq(direct[1].book_id, "9")
end
