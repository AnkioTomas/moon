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

-- 连续软换行合并为一个段落，空行仍保留段落边界
do
    local book = Text2Epub.parse("这是第一行\n这是第二行\n\n这是第二段", {
        title = "测试",
        reflow = true,
    })
    Assert.is_true(book.chapters[1].html:find("<p>这是第一行这是第二行</p>", 1, true) ~= nil)
    Assert.is_true(book.chapters[1].html:find("<p>这是第二段</p>", 1, true) ~= nil)
end

do
    local book = Text2Epub.parse("测试\nhello,\nworld", { title = "测试", reflow = true })
    Assert.is_true(book.chapters[1].html:find("hello, world", 1, true) ~= nil)
end

-- 超长章节切成多个物理片，但目录只保留首片
do
    local book = Text2Epub.parse("第一章\naaa\n\nbbb\n\nccc", {
        max_part_chars = 4,
        reflow = true,
    })
    Assert.eq(#book.chapters, 3)
    Assert.is_true(book.chapters[1].toc)
    Assert.is_false(book.chapters[2].toc)
    Assert.is_false(book.chapters[3].toc)
end

-- 单一超长段落也必须在 UTF-8 字符边界切片
do
    local book = Text2Epub.parse("第一章\n" .. string.rep("甲", 8), {
        max_part_chars = 8,
        reflow = true,
    })
    Assert.eq(#book.chapters, 4)
    Assert.is_true(book.chapters[1].html:find("甲甲", 1, true) ~= nil)
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
    Assert.is_true(Text2Epub._isChapterTitle("最终章 归途"))
    Assert.is_true(Text2Epub._isChapterTitle("Chapter IV - Return"))
    Assert.is_true(Text2Epub._isChapterTitle("Section 12: Return"))
    Assert.is_true(Text2Epub._isChapterTitle("===第001章 养母婉娘==="))
    Assert.is_true(Text2Epub._isChapterTitle("第一部 风起"))
    Assert.is_false(Text2Epub._isChapterTitle("第一部门负责审批"))
    Assert.is_false(Text2Epub._isChapterTitle("第二天傍晚，我来到夜总会"))
    Assert.is_false(Text2Epub._isChapterTitle("这只是普通正文"))
end

-- 带装饰符的章节标题应去掉装饰后写入目录。
do
    local book = Text2Epub.parse("《测试》\n===第001章 开始===\n正文\n第二天继续写正文")
    Assert.len(book.chapters, 1)
    Assert.eq(book.chapters[1].title, "第001章 开始")
    Assert.is_true(book.chapters[1].html:find("<p>第二天继续写正文</p>", 1, true) ~= nil)
end

-- 知轩藏书式文件名可补全元数据；调用方显式提供的值仍优先。
do
    local book = Text2Epub.parse("第一章\n正文", {
        source = "/books/《希灵帝国》（校对版全本）作者：远瞳.txt",
    })
    Assert.eq(book.title, "希灵帝国")
    Assert.eq(book.author, "远瞳")

    book = Text2Epub.parse("第一章\n正文", {
        source = "/books/《希灵帝国》作者：远瞳.txt",
        title = "自定义书名",
        author = "自定义作者",
    })
    Assert.eq(book.title, "自定义书名")
    Assert.eq(book.author, "自定义作者")
end

-- build 拒绝非 UTF-8，不能悄悄生成损坏 XHTML
do
    local ok, err
    Text2Epub.build({
        dest = "/tmp/invalid.epub",
        text = "\255",
    }, function(value, reason)
        ok, err = value, reason
    end)
    Stubs.flush()
    Assert.is_nil(ok)
    Assert.eq(err, "仅支持 UTF-8 编码的文本")
end
