--[[-- book.reflow 离线用例。
@module tests.book.reflow_spec
--]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")

Stubs.install()
Stubs.reset()

local Reflow = require("book.reflow")
local Text2Epub = require("convert.text2epub")

local function identity(path)
    return {
        source_id = "local",
        stable_id = path,
        source = { id = "local", replaceBook = function() end },
        book = { title = "测试", authors = "作者" },
    }
end

Assert.is_true(Reflow.canReflow(identity("/books/a.txt")))
Assert.is_true(Reflow.canReflow(identity("/books/a.mobi")))
Assert.is_false(Reflow.canReflow(identity("/books/a.epub")))
Assert.is_false(Reflow.canReflow({ source_id = "moon", stable_id = "/books/a.txt" }))

local parsed = Text2Epub.parse("第一章 开始\n正文\n\n第二章 继续\n更多", {
    title = "测试",
    reflow = true,
})
local titles = Reflow._tocTitles(parsed)
Assert.len(titles, 2)
Assert.eq(titles[1], "第一章 开始")
Assert.eq(titles[2], "第二章 继续")

local analyze_done = false
local preview_path = os.tmpname() .. ".txt"
local preview_file = io.open(preview_path, "w")
preview_file:write("第一章 开始\n正文\n\n第二章 继续\n更多")
preview_file:close()
Reflow.analyzeAsync(identity(preview_path), function(titles_out, err)
    analyze_done = true
    Assert.is_nil(err)
    Assert.len(titles_out, 2)
    Assert.eq(titles_out[1], "第一章 开始")
end)
Stubs.flush()
Assert.is_true(analyze_done)
os.remove(preview_path)
