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
Assert.len(Content.readable_chapters(by_volume), 2)

-- 没有分卷时用 chapterList
local flat = Content.normalize_chapters({ data = { chapterListWithVolume = {}, chapterList = { { itemId = "9" } } } })
Assert.eq(flat[1].itemId, "9")

-- 只有 allItemIds：按序号起标题
local ids = Content.normalize_chapters({ data = { allItemIds = { "7", "8" } } })
Assert.eq(ids[2].itemId, "8")
Assert.eq(ids[2].title, "第2章")

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
