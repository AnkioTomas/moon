--[[--
text2epub 文本解析用例。

@module tests.text2epub_spec
--]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")

Stubs.install()
Stubs.reset()

local Text2Epub = require("convert.text2epub")

-- 元数据、中文章节和 XHTML 排版
do
    local book = Text2Epub.parse([[
书名：测试小说
作者：测试作者

作品简介

第一章 开始
第一段。
第二段包含 <特殊字符> & 内容。

第二章 继续
新的内容。
]])

    Assert.eq(book.title, "测试小说")
    Assert.eq(book.author, "测试作者")
    Assert.len(book.chapters, 3)
    Assert.eq(book.chapters[1].title, "前言")
    Assert.eq(book.chapters[2].title, "第一章 开始")
    Assert.eq(book.chapters[3].title, "第二章 继续")
    Assert.is_true(book.chapters[2].html:find("<h1>第一章 开始</h1>", 1, true) ~= nil)
    Assert.is_true(book.chapters[2].html:find("<p>第一段。</p>", 1, true) ~= nil)
    Assert.is_true(book.chapters[2].html:find("&lt;特殊字符&gt; &amp; 内容", 1, true) ~= nil)
end

-- 正文中的“作者：”不是元数据，不能被误删
do
    local book = Text2Epub.parse("书名：对话\n第一章\n作者：你是谁？")
    Assert.eq(book.author, nil)
    Assert.is_true(book.chapters[1].html:find("<p>作者：你是谁？</p>", 1, true) ~= nil)
end

-- 文件名作为书名；无章节文本生成单章
do
    local book = Text2Epub.parse("第一段\n第二段", {
        source = "/books/没有标题.txt",
    })
    Assert.eq(book.title, "没有标题")
    Assert.len(book.chapters, 1)
    Assert.eq(book.chapters[1].title, "没有标题")
    Assert.is_true(book.chapters[1].html:find("<p>第一段</p>", 1, true) ~= nil)
end

-- 文件名与正文首行相同时，不重复生成书名段落
do
    local book = Text2Epub.parse("没有标题\n\n第一章 开始\n正文", {
        source = "/books/没有标题.txt",
    })
    Assert.len(book.chapters, 1)
    Assert.eq(book.chapters[1].title, "第一章 开始")
end

-- 没有文件名时，首个非空行作为书名
do
    local book = Text2Epub.parse("\239\187\191我的书\n\nChapter 1: Start\nBody")
    Assert.eq(book.title, "我的书")
    Assert.len(book.chapters, 1)
    Assert.eq(book.chapters[1].title, "Chapter 1: Start")
    Assert.is_true(book.chapters[1].html:find("<p>Body</p>", 1, true) ~= nil)
end

-- 常见独立章节名
do
    Assert.is_true(Text2Epub._isChapterTitle("第十二卷 风起"))
    Assert.is_true(Text2Epub._isChapterTitle("序章"))
    Assert.is_true(Text2Epub._isChapterTitle("Chapter IV - Return"))
    Assert.is_false(Text2Epub._isChapterTitle("这只是普通正文"))
end
