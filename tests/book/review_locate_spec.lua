--[[-- 章末评论区不改原文坐标，并能离线升级旧缓存。 @module tests.book.review_locate_spec --]]
local Assert = require("support.assert")
local Config = require("support.config")
local Locate = require("book.review_locate")
local original = "<html><body><h1>标题</h1><p>第一段</p><p>第二段</p></body></html>"
local prepared = Locate.prepareChapterEnd(original)
Assert.matches(prepared, "<h1>标题</h1><p>第一段</p><p>第二段</p><div")
Assert.matches(prepared, 'id="moon%-chapter%-reviews"')
Assert.matches(prepared, "</div></body></html>$")
Assert.eq(Locate.prepareChapterEnd(prepared), prepared, "重复准备不增加段落或预留区域")

local path = Config.dir() .. "/qidian-review-locate.html"
local function write(html)
    local file = assert(io.open(path, "wb"))
    assert(file:write(html))
    assert(file:close())
end
local function read()
    local file = assert(io.open(path, "rb"))
    local html = assert(file:read("*a"))
    file:close()
    return html
end
write(original)
Assert.is_true(Locate.reuseChapterEnd(path))
Assert.eq(read(), prepared)
Assert.is_true(Locate.reuseChapterEnd(path))
Assert.eq(read(), prepared)

write(original)
local rename = os.rename
os.rename = function() return nil, "rename failed" end
Assert.errors(function() Locate.reuseChapterEnd(path) end, "rename failed")
os.rename = rename
Assert.eq(read(), original, "替换失败必须保留原缓存")
Assert.is_nil(io.open(path .. ".part", "rb"), "替换失败清理自己的临时文件")
os.remove(path)

local fetched
local Chapter = require("source.chapter")
local content = function(_book, _chapter, cb)
    cb("第一段", nil)
    return { cancel = function() end }
end
local identity, chapter = { source_id = "qidian", stable_id = "fixture" }, { uid = "fixture", title = "标题" }
Chapter.vipFetcher({ id = "qidian" }, content, false)(identity, chapter, function(value) fetched = value end)
Assert.is_false(fetched.html:find(Locate.CHAPTER_ANCHOR, 1, true) ~= nil, "其他源默认排版不变")
Chapter.vipFetcher({ id = "qidian" }, content, false, Locate.prepareChapterEnd)(
    identity, chapter, function(value) fetched = value end)
Assert.matches(fetched.html, 'id="moon%-chapter%-reviews"')
