--[[--
番茄目录：读缓存和刷新都不再扫章节 HTML；锚点只在新下正文时写入，刷新时按 uid 保留。

@module tests.source.fanqie.toc_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

local Assert = require("support.assert")
local Stubs = require("support.stubs")
local Paths = require("utils.paths")
local Toc = require("source.toc")

local html_reads = 0
local open = io.open
io.open = function(path, mode, ...)
    if type(path) == "string" and path:match("/%d+%.html$") and (mode == nil or tostring(mode):match("^r")) then
        html_reads = html_reads + 1
    end
    return open(path, mode, ...)
end

local directory, content
local src = require("source.fanqie").new()
src.client.fetchChapterDirectoryAsync = function(_self, _id, cb)
    require("ui/uimanager"):nextTick(function() cb(directory) end)
    return { cancel = function() end }
end
src.client.officialGetContentAsync = function(_self, _bid, _iid, cb)
    require("ui/uimanager"):nextTick(function() cb(content) end)
    return { cancel = function() end }
end

local identity = { source_id = "fanqie", stable_id = "fanqie-toc-anchors" }
local poison = '<h2 id="toc_99">不该扫到</h2><p>旧正文</p>'

local function writeChapterHtml(idx, html)
    Paths.ensureBookWork(identity.stable_id, identity.source_id)
    local file = assert(open(Paths.chapterPath(identity.stable_id, idx, identity.source_id), "w"))
    file:write(html)
    file:close()
end

local function loadToc()
    local toc, err
    src:loadTocAsync(identity, function(value, reason) toc, err = value, reason end)
    Stubs.flush()
    return toc, err
end

local function refreshToc()
    local toc, err
    src:refreshTocAsync(identity, function(value, reason) toc, err = value, reason end)
    Stubs.flush()
    return toc, err
end

local function fetchContent(chapter)
    local Chapter = require("source.chapter")
    local ops
    local orig = Chapter.openAsync
    Chapter.openAsync = function(_source, _identity, _book, _opts, options, cb)
        ops = options
        if cb then cb("ok") end
        return { cancel = function() end }
    end
    src:openBookAsync(identity, { chapter_idx = 1 }, function() end)
    Chapter.openAsync = orig
    local payload, err
    ops.fetchContent(identity, chapter, function(value, reason) payload, err = value, reason end)
    Stubs.flush()
    return payload, err
end

Toc.drop(identity.source_id, identity.stable_id)
writeChapterHtml(1, poison)
writeChapterHtml(2, poison)

-- 有缓存时 loadToc 直接返回，不读章节 HTML，也不为回填锚点写库。
Assert.is_true(Toc.put(identity.source_id, identity.stable_id, {
    { idx = 1, uid = "10", title = "正文", depth = 1 },
    { idx = 2, uid = "20", title = "第二章", depth = 1 },
}))
html_reads = 0
local puts = 0
local orig_put = Toc.put
Toc.put = function(...)
    puts = puts + 1
    return orig_put(...)
end
local cached, load_err = loadToc()
Toc.put = orig_put
Assert.is_nil(load_err)
Assert.eq(cached[1].uid, "10")
Assert.is_nil(cached[1].anchors, "读缓存不能靠扫 HTML 补锚点")
Assert.is_nil(cached[2].anchors)
Assert.eq(html_reads, 0, "有缓存时不能打开章节 HTML")
Assert.eq(puts, 0, "读缓存目录不必 Toc.put")

-- 刷新保留库里已有的 HTML 锚点，同时收下官方锚点，且不扫 HTML。
Assert.is_true(orig_put(identity.source_id, identity.stable_id, {
    {
        idx = 1, uid = "10", title = "正文", depth = 1,
        anchors = {
            { title = "已缓存第一节", depth = 2, id = "toc_1" },
            { title = "HTML锚点", depth = 2, id = "toc_8" },
        },
    },
    { idx = 2, uid = "20", title = "第二章", depth = 1, anchors = { { title = "旧章锚点", depth = 2, id = "toc_9" } } },
}))
directory = { data = { chapterList = {
    { itemId = "10", title = "正文", children = {
        { title = "官方第一节", anchor = "toc_1" },
        { title = "官方第二节", id = "toc_2" },
    } },
    { itemId = "20", title = "第二章" },
    { itemId = "30", title = "第三章" },
} } }
html_reads = 0
local refreshed, refresh_err = refreshToc()
Assert.is_nil(refresh_err)
Assert.eq(html_reads, 0, "刷新目录不能打开章节 HTML")
Assert.len(refreshed, 3)
Assert.eq(refreshed[1].anchors[1].title, "官方第一节", "同 id 保留官方标题")
Assert.eq(refreshed[1].anchors[2].id, "toc_2")
Assert.eq(refreshed[1].anchors[3].id, "toc_8", "库里已有的 HTML 锚点不能被刷新冲掉")
Assert.eq(refreshed[1].anchors[3].title, "HTML锚点")
Assert.len(refreshed[1].anchors, 3)
Assert.eq(refreshed[2].anchors[1].id, "toc_9")
Assert.eq(refreshed[2].anchors[1].title, "旧章锚点")
Assert.is_nil(refreshed[3].anchors, "新章没有旧锚点")
local stored = Toc.read(identity.source_id, identity.stable_id)
Assert.eq(stored[1].anchors[1].title, "官方第一节")
Assert.eq(stored[1].anchors[3].id, "toc_8")
Assert.eq(stored[2].anchors[1].id, "toc_9")

-- 拉正文后 persistAnchorsFromHtml 仍按章把锚点写进目录。
content = { title = "第二章", content = '<h2 id="toc_3">新下的节</h2><p>新正文</p><h2 id="toc_4"></h2>' }
html_reads = 0
local payload, fetch_err = fetchContent({ idx = 2, uid = "20", title = "第二章", depth = 1 })
Assert.is_nil(fetch_err)
Assert.matches(payload.html, "新下的节")
local after = Toc.read(identity.source_id, identity.stable_id)
Assert.eq(after[2].anchors[1].id, "toc_9", "按章写入不能丢掉已有锚点")
Assert.eq(after[2].anchors[2].id, "toc_3")
Assert.eq(after[2].anchors[2].title, "新下的节")
Assert.eq(after[2].anchors[3].id, "toc_4")
Assert.eq(after[2].anchors[3].title, "#4")
Assert.eq(after[1].anchors[3].id, "toc_8", "只写本章，不动其它章")
Assert.eq(html_reads, 0, "按章写入走内存 HTML，不必再读落盘文件")

Toc.drop(identity.source_id, identity.stable_id)
io.open = open
