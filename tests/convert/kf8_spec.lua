--[[-- convert.kf8：独立 KF8 重建 HTML / 资源 / 目录 / 元数据 --]]

local Assert = require("support.assert")
local Fixture = require("support.kf8_fixture")
local Config = require("support.config")

package.loaded["convert.kf8"] = nil
local Kf8 = require("convert.kf8")

local root = Config.dir() .. "/kf8_spec"
os.execute("rm -rf '" .. root .. "' && mkdir -p '" .. root .. "'")

local function readFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

local function has(s, sub)
    Assert.is_true(s ~= nil and s:find(sub, 1, true) ~= nil, "missing: " .. sub)
end

local function extract(name, opts)
    local book = root .. "/" .. name .. ".azw3"
    local dir = root .. "/" .. name
    os.execute("mkdir -p '" .. dir .. "'")
    Fixture.write(book, opts)
    return Kf8.extract(book, dir), dir
end

local function checkBook(info, dir)
    Assert.eq(info.html, "book.html")
    Assert.eq(info.cover, "res0001.jpg")
    Assert.eq(info.metadata.title, Fixture.TITLE)
    Assert.eq(info.metadata.author, Fixture.AUTHOR)
    Assert.is_nil(info.metadata.cover_offset, "内部字段不外泄")

    local html = readFile(dir .. "/book.html")
    has(html, "<title>测试书</title>")
    has(html, '<link rel="stylesheet" type="text/css" href="flow0001.css"/>')
    has(html, '<a id="azwfid0000"></a><p>第一章 开头 Hello Hello Hello</p><img src="res0001.jpg"/>')
    -- 第二部分插入点落在 <body> 标签里，按 aid 修到标签之后
    has(html, '<a id="azwfid0001"></a><p>第二章 <a href="#azwfid0000">回到开头</a></p>')
    Assert.is_nil(html:find("kindle:", 1, true), "不残留 kindle: 引用")
    Assert.is_nil(html:find("<head><link", 1, true), "各部分的 head 不进正文")

    Assert.eq(readFile(dir .. "/res0001.jpg"), "\255\216\255\224fake-jpeg")
    has(readFile(dir .. "/flow0001.css"), "url(res0001.jpg)")

    -- NCX 按层级存，输出按正文顺序：同一位置父级在前
    Assert.len(info.toc, 3)
    Assert.eq(info.toc[1].title, "第一章")
    Assert.eq(info.toc[1].depth, 1)
    Assert.eq(info.toc[1].anchor, "#azwfid0000")
    Assert.eq(info.toc[2].title, "第一节")
    Assert.eq(info.toc[2].depth, 2)
    Assert.eq(info.toc[3].title, "第二章")
    Assert.eq(info.toc[3].anchor, "#azwfid0001")
end

-- 无压缩
do
    local info, dir = extract("plain", { compression = 1 })
    checkBook(info, dir)
end

-- PalmDOC + 多字节尾巴：解压结果与无压缩一致
do
    local info, dir = extract("palmdoc", { compression = 2, extra_flags = 1 })
    checkBook(info, dir)
    Assert.eq(readFile(dir .. "/book.html"), readFile(root .. "/plain/book.html"))
end

-- MOBI6 / 合并文件：不是独立 KF8，交回 CREngine
do
    local info, dir = extract("mobi6", { version = 6 })
    Assert.is_nil(info)
    Assert.is_nil(readFile(dir .. "/book.html"), "不写任何产物")
end

-- DRM：明确报错
do
    Assert.errors(function() extract("drm", { encryption = 2 }) end, "DRM")
end

-- 非 MOBI / 截断文件：报错而不是产出坏 HTML
do
    local junk = root .. "/junk.azw3"
    local f = assert(io.open(junk, "wb"))
    f:write("PK\3\4 not a mobi")
    f:close()
    Assert.errors(function() Kf8.extract(junk, root) end, "BOOKMOBI")

    local book = root .. "/cut.azw3"
    Fixture.write(book)
    local raw = readFile(book)
    f = assert(io.open(book, "wb"))
    f:write(raw:sub(1, 400))
    f:close()
    Assert.errors(function() Kf8.extract(book, root) end)
end

os.execute("rm -rf '" .. root .. "'")
return true
