--[[--
番茄 PUA 解码：真实章节片段必须解成可读中文。

@module tests.source.fanqie.content_spec
--]]

local Assert = require("support.assert")

package.loaded["source.fanqie.content"] = nil
local Content = require("source.fanqie.content")

-- /api/reader/full 第1章首段原始字节（含 PUA）
local sample = "\227\128\144\238\144\178\232\176\162\230\130\168\238\146\168\229\135\187\238\147\184\238\147\186\233\152\133\232\175\187\239\188\140\238\147\175\238\146\142\238\147\179\238\147\131\238\148\170\238\145\138\238\144\182\239\188\140\231\174\128\228\187\139\238\145\141\238\144\142\238\146\128\227\128\145"
local decoded = Content.decode_pua_content(sample)
Assert.eq(decoded, "【感谢您点击进来阅读，其他的就不说了，简介里都有】")

-- 官方目录：分卷二维数组优先，平铺且跳过没有 itemId 的行
local by_volume = Content.normalize_chapters({ data = {
    chapterListWithVolume = {
        { { itemId = "1", title = "封面" }, { itemId = "2", title = "第1章" } },
        { { title = "无 id" }, { itemId = "3", title = "第2章" } },
    },
    chapterList = { { itemId = "x" } },
} })
Assert.len(by_volume, 3)
Assert.eq(by_volume[3].itemId, "3")
Assert.eq(by_volume[1].depth, 1, "无卷名时不编造卷标题，章仍为第 1 层")
Assert.eq(by_volume[3].depth, 1)
Assert.len(Content.readable_chapters(by_volume), 2)

-- 没有分卷时用 chapterList
local flat = Content.normalize_chapters({ data = { chapterListWithVolume = {}, chapterList = { { itemId = "9" } } } })
Assert.eq(flat[1].itemId, "9")
Assert.eq(flat[1].depth, 1)

-- 只有 allItemIds：按序号起标题
local ids = Content.normalize_chapters({ data = { allItemIds = { "7", "8" } } })
Assert.eq(ids[2].itemId, "8")
Assert.eq(ids[2].title, "第2章")
Assert.eq(ids[2].depth, 1)

-- 回包缺 data：空目录
Assert.len(Content.normalize_chapters({ code = 0 }), 0)
Assert.len(Content.normalize_chapters(nil), 0)

-- normalize 保留上游字数字段（有则估全书页码）
do
    local rows = Content.normalize_chapters({ data = { chapterList = {
        { itemId = "1", title = "A", wordCount = 1200 },
        { itemId = "2", title = "B", word_count = 800 },
    } } })
    Assert.eq(tonumber(rows[1].wordCount), 1200)
    Assert.eq(tonumber(rows[2].word_count), 800)
end


-- 有卷名：章 depth=2 并带 volume，不额外占 idx
do
    local rows = Content.normalize_chapters({ data = {
        chapterListWithVolume = {
            { volumeName = "第一卷", chapterList = { { itemId = "1", title = "第1章" }, { itemId = "2", title = "第2章" } } },
            { volume_name = "第二卷", { itemId = "3", title = "第3章" } },
        },
    } })
    Assert.len(rows, 3)
    Assert.eq(rows[1].depth, 2)
    Assert.eq(rows[1].volume, "第一卷")
    Assert.eq(rows[2].volume, "第一卷")
    Assert.eq(rows[3].itemId, "3")
    Assert.eq(rows[3].depth, 2)
    Assert.eq(rows[3].volume, "第二卷")
end

-- 官方子节点收成 anchors，不另开一章
do
    local rows = Content.normalize_chapters({ data = { chapterList = {
        { itemId = "10", title = "正文", children = {
            { title = "第一节", anchor = "toc_1" },
            { title = "第二节", id = "toc_2" },
        } },
    } } })
    Assert.len(rows, 1)
    Assert.len(rows[1].anchors, 2)
    Assert.eq(rows[1].anchors[1].title, "第一节")
    Assert.eq(rows[1].anchors[1].id, "toc_1")
    Assert.eq(rows[1].anchors[1].depth, 2)
    Assert.eq(rows[1].anchors[2].id, "toc_2")
end

-- HTML toc_*：有可见标题用原文，纯图片锚点回退 #N
do
    local html = [[<h1>正文</h1>
    <h2 id="toc_1">第一节 相遇</h2><p>文字</p>
    <p class="picture" id="toc_2"><img src="a.jpg"/></p>
    <p id="toc_11"><img src="b.jpg"/></p>
    <p id="toc_2">重复 id 忽略</p>]]
    local anchors = Content.html_anchors(html, 2)
    Assert.len(anchors, 3)
    Assert.eq(anchors[1].id, "toc_1")
    Assert.eq(anchors[1].title, "第一节 相遇")
    Assert.eq(anchors[1].depth, 2)
    Assert.eq(anchors[2].id, "toc_2")
    Assert.eq(anchors[2].title, "#2")
    Assert.eq(anchors[3].id, "toc_11")
    Assert.eq(anchors[3].title, "#11")
    Assert.len(Content.html_anchors(""), 0)
    Assert.len(Content.html_anchors(nil), 0)
end

-- merge_anchors：按 id 去重，已有标题不被回退覆盖
do
    local chapter = { idx = 3, title = "正文", anchors = { { title = "官方第一节", depth = 2, id = "toc_1" } } }
    Assert.is_true(Content.merge_anchors(chapter, {
        { title = "#1", depth = 2, id = "toc_1" },
        { title = "#2", depth = 2, id = "toc_2" },
    }))
    Assert.len(chapter.anchors, 2)
    Assert.eq(chapter.anchors[1].title, "官方第一节")
    Assert.eq(chapter.anchors[2].id, "toc_2")
    Assert.is_false(Content.merge_anchors(chapter, { { title = "#2", depth = 2, id = "toc_2" } }))
end
