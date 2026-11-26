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

-- 作者和书名一起搜：第三参交给来源，回来再按作者收窄。只填作者时用作者当关键字。
do
    local calls = {}
    local source = {
        searchBooksAsync = function(_, keyword, cb, author)
            calls[#calls + 1] = { keyword, author }
            cb({
                { book_id = "1", title = "活着", author = "余华" },
                { book_id = "2", title = "活着", author = "别人" },
                { book_id = "3", title = "Harry Potter", author = "J.K. Rowling" },
            })
        end,
    }
    local got
    Lender.search(source, "活着", function(books) got = books end, "余华")
    Assert.eq(calls[1][1], "活着")
    Assert.eq(calls[1][2], "余华")
    Assert.len(got, 1)
    Assert.eq(got[1].book_id, "1")
    Lender.search(source, "  ", function(books) got = books end, "rowling")
    Assert.eq(calls[2][1], "rowling")
    Assert.is_nil(calls[2][2])
    Assert.eq(got[1].book_id, "3")
    Lender.search(source, "", function(books) got = books end, "  ")
    Assert.len(got, 0)
    Assert.len(calls, 2)
end
