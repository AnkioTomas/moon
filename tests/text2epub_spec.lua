--[[--
text2epub 文本解析用例。

@module tests.text2epub_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

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

-- 原文档目录标题：整行命中即切章；书开头内嵌目录（表头 + 一串标题）不切出空章；只出现一次的空卷标题保留。
do
    local book = Text2Epub.parse(table.concat({
        "目录", "Contents", "（1970）双剑交锋（1）", "（1971）亮出底牌（1）",
        "上卷", "（1970）双剑交锋（1）", "春天。", "（1971）亮出底牌（1）", "北戴河。",
    }, "\n"), { title = "风雨路", reflow = true, headings = { " （1970）双剑交锋（1） ", "（1971）亮出底牌（1）", "上卷" } })
    local titles = {}
    for _idx, chapter in ipairs(book.chapters) do titles[#titles + 1] = chapter.title end
    Assert.eq(table.concat(titles, "|"), "上卷|（1970）双剑交锋（1）|（1971）亮出底牌（1）")
    Assert.is_true(book.chapters[2].html:find("<p>春天。</p>", 1, true) ~= nil)
    Assert.is_nil(book.chapters[1].html:find("目录", 1, true))

    -- 没有目录（既没给 headings、正文也没有内嵌目录）时行为不变：这种标题认不出来
    book = Text2Epub.parse("（1970）双剑交锋（1）\n春天。", { title = "风雨路" })
    Assert.len(book.chapters, 1)
    Assert.eq(book.chapters[1].title, "风雨路")
end

-- 不读 NCX 的 MOBI：只有正文里的内嵌目录。表头后的短行是条目，碰到重复（正文开始）就停，正文里的同名行不再收。
do
    local book = Text2Epub.parse(table.concat({
        "目录", "Content", "前言", "（1970）双剑交锋（1）", "（1971）亮出底牌（1）",
        "前言", "<毛泽东最后七年风雨路>",
        "（1970）双剑交锋（1）", " （1970）双剑交锋", "春天。",
        "（1971）亮出底牌（1）", "北戴河。",
    }, "\n"), { title = "风雨路" })
    local titles = {}
    for _idx, chapter in ipairs(book.chapters) do titles[#titles + 1] = chapter.title end
    Assert.eq(table.concat(titles, "|"), "前言|（1970）双剑交锋（1）|（1971）亮出底牌（1）")
    Assert.is_true(book.chapters[2].html:find("<p>（1970）双剑交锋</p>", 1, true) ~= nil, "正文小标题不是目录条目")

    -- 表头后紧跟长段落：不是目录，不收
    book = Text2Epub.parse("目录\n" .. string.rep("很长的正文", 20) .. "\n短句\n正文\n短句", { title = "书" })
    Assert.len(book.chapters, 1)

    -- 条目带页码、对不上正文：一直收到长行也没碰到重复，整批不算目录，正文短句不切章
    book = Text2Epub.parse(table.concat({
        "目录", "开端……1", "归来……9", "“嗯。”", "“你是谁？”", string.rep("很长的正文", 20),
        "“嗯。”", "又是一段。", "“嗯。”",
    }, "\n"), { title = "书" })
    Assert.len(book.chapters, 1)
end

-- 合集卷首 / 书末印的目录：条目写法对不上正文标题，连续三个以上空章还原成上一章的段落，不丢字；单个空卷名照旧成章
do
    local book = Text2Epub.parse(table.concat({
        "第一章", "甲。", "第一章　开端 Begin", "第二章　归来 Return", "第三章　远行 Away",
        "序", "丁。", "第二卷", "第一章", "乙。", "第二章", "丙。",
    }, "\n"), { title = "合集", reflow = true, headings = {
        "第一章　开端 Begin", "第二章　归来 Return", "第三章　远行 Away", "第二卷", "序",
    } })
    local titles = {}
    for _idx, chapter in ipairs(book.chapters) do titles[#titles + 1] = chapter.title end
    Assert.eq(table.concat(titles, "|"), "第一章|序|第二卷|第一章|第二章")
    Assert.is_true(book.chapters[1].html:find("<p>第三章　远行 Away</p>", 1, true) ~= nil)

    -- 开头就是目录页：收进前言
    book = Text2Epub.parse("一\n二\n三\n第一章\n正文。", {
        title = "书", reflow = true, headings = { "一", "二", "三" },
    })
    titles = {}
    for _idx, chapter in ipairs(book.chapters) do titles[#titles + 1] = chapter.title end
    Assert.eq(table.concat(titles, "|"), "前言|第一章")
    Assert.is_true(book.chapters[1].html:find("<p>二</p>", 1, true) ~= nil)
end

-- PDF 每页页眉就是章名：与本章标题相同的行不另起一章
do
    local book = Text2Epub.parse(table.concat({
        "开端", "第一页。", "开端", "第二页。", "归来", "第三页。", "归来", "第四页。",
    }, "\n"), { title = "书", headings = { "开端", "归来" } })
    local titles = {}
    for _idx, chapter in ipairs(book.chapters) do titles[#titles + 1] = chapter.title end
    Assert.eq(table.concat(titles, "|"), "开端|归来")
    Assert.is_true(book.chapters[1].html:find("第二页。", 1, true) ~= nil)
    Assert.is_nil(book.chapters[1].html:find("<p>开端</p>", 1, true), "页眉行丢掉")
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

-- read 拒绝缺失、空白和非 UTF-8，不能悄悄生成损坏 XHTML
do
    local path = os.tmpname()
    local function readBody(body)
        local file = assert(io.open(path, "wb"))
        file:write(body)
        file:close()
        return Text2Epub.read(path)
    end
    local text, err = readBody("第一章\n正文")
    Assert.eq(text, "第一章\n正文")
    Assert.is_nil(err)
    text, err = readBody("\255")
    Assert.is_nil(text)
    Assert.eq(err, "仅支持 UTF-8 编码的文本")
    text, err = readBody(" \n ")
    Assert.is_nil(text)
    Assert.eq(err, "无文本内容")
    os.remove(path)
    text, err = Text2Epub.read(path)
    Assert.is_nil(text)
    Assert.eq(err, "无法读取文本文件")
end

-- build：读文件、解析、打包都在子进程（workers.job）里；没给 text 就读 source，错误原样回调
do
    local saved_preload, saved_loaded = package.preload["workers.job"], package.loaded["workers.job"]
    local job_name, cancelled
    package.loaded["workers.job"] = nil
    package.preload["workers.job"] = function()
        return {
            run = function(worker, opts)
                job_name = opts.name
                opts.on_done(worker(function(value)
                    if opts.on_progress then opts.on_progress(value) end
                end))
                return { cancel = function() cancelled = true end }
            end,
        }
    end
    local Html2Epub = require("convert.html2epub")
    local original_write = Html2Epub.write
    local written, write_err
    Html2Epub.write = function(opts, progress)
        written = opts
        for i = 1, #opts.chapters do progress(i, #opts.chapters) end
        return write_err == nil or nil, write_err
    end

    local path = os.tmpname()
    local file = assert(io.open(path, "wb"))
    file:write("第一章 开始\nhello\nworld")
    file:close()
    local ok, err
    local steps = {}
    local handle = Text2Epub.build({ dest = "/tmp/out.epub", source = path, title = "书", reflow = true },
        function(o, e) ok, err = o, e end,
        function(text, done, total) steps[#steps + 1] = text .. " " .. done .. "/" .. total end)
    Assert.eq(job_name, "epub.text")
    Assert.is_true(ok)
    Assert.is_nil(err)
    Assert.eq(written.dest, "/tmp/out.epub")
    Assert.eq(written.chapters[1].title, "第一章 开始")
    Assert.matches(written.chapters[1].html, "hello world", "ASCII 断行合并补空格")
    Assert.eq(table.concat(steps, ","), "正在识别章节 1/1,正在写入 1/1", "识别、写入两段进度")
    handle.cancel()
    Assert.is_true(cancelled)

    -- chaptersAsync：只回传标题与 toc，正文不出子进程；进度按整数百分比节流
    local chapters
    steps = {}
    local many = {}
    for i = 1, 300 do many[#many + 1] = "第" .. i .. "章\n正文" end
    Text2Epub.chaptersAsync({ text = table.concat(many, "\n"), title = "书" },
        function(list, e) chapters, err = list, e end,
        function(text, done, total) steps[#steps + 1] = done end)
    Assert.eq(job_name, "epub.chapters")
    Assert.len(chapters, 300)
    Assert.eq(chapters[2].title, "第2章")
    Assert.is_true(chapters[2].toc)
    Assert.is_nil(chapters[2].html)
    Assert.eq(#steps, 101, "300 节只按 0..100% 报 101 次")

    -- 给了 text 就不读文件
    os.remove(path)
    ok, err = nil, nil
    Text2Epub.build({ dest = "/tmp/out.epub", source = path, text = "正文", title = "书" },
        function(o, e) ok, err = o, e end)
    Assert.is_true(ok)

    -- 读失败、写失败都回调错误
    Text2Epub.build({ dest = "/tmp/out.epub", source = path }, function(o, e) ok, err = o, e end)
    Assert.is_nil(ok)
    Assert.eq(err, "无法读取文本文件")
    write_err = "磁盘满"
    Text2Epub.build({ dest = "/tmp/out.epub", text = "正文" }, function(o, e) ok, err = o, e end)
    Assert.is_nil(ok)
    Assert.eq(err, "磁盘满")

    Html2Epub.write = original_write
    package.preload["workers.job"], package.loaded["workers.job"] = saved_preload, saved_loaded
end
