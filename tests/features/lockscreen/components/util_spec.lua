--[[--
features.lockscreen.components.util：章节名清洗与进度文案。

@module tests.features.lockscreen.components.util_spec
--]]

local Assert = require("support.assert")

package.loaded["features.lockscreen.components.util"] = nil
local U = require("features.lockscreen.components.util")

Assert.eq(U.chapterLine({ chapter_title = "第1章 开篇" }), "第1章 开篇")
Assert.eq(U.chapterLine({ chapter_count = 10, chapter_idx = 2 }), "第 2 / 10 章")
local pct, pages = U.progress({ percent = 35, page = 70, total_pages = 200 })
Assert.eq(pct, 35)
Assert.eq(pages, "70 / 200 页")
local _, no_pages = U.progress({ percent = 10, page = 0, total_pages = 0 })
Assert.eq(no_pages, "页数暂无")

-- 百分比：不足 10% 保留一位小数，整数去掉 .0；越界夹住。
Assert.eq(U.percentText(0.26), "0.3%")
Assert.eq(U.percentText(0), "0%")
Assert.eq(U.percentText(5), "5%")
Assert.eq(U.percentText(55.7), "55%")
Assert.eq(U.percentText(120), "100%")
Assert.eq(U.percentText(nil), "0%")

-- 进度条：浅灰轨（不是深灰），按比例画黑色填充。
local bar, bar_h = U.progressBlocks(0, 0, 200, 25)
Assert.eq(bar_h, 6)
Assert.eq(bar[1].color, U.TRACK)
Assert.eq(bar[2].width, 50)

-- 书卡文字头：按实测行高逐行下移，不写死偏移；长书名压成单行；空作者跳过。
-- 替身：每字宽 = 字号，行高 = 字号 × 1.5，超宽就折行（高度翻倍）。
package.loaded["features.lockscreen.render"] = {
    measureText = function(text, width, size)
        local chars = select(2, tostring(text):gsub("[^\128-\191]", ""))
        return math.ceil(chars * size / width) * math.floor(size * 1.5)
    end,
}
local head, bottom = U.bookHead({ title = string.rep("长", 40), authors = "作者" }, "章节 · 一", 10, 100, 200)
Assert.len(head, 3)
Assert.eq(head[1].y, 100)
Assert.is_true(head[1].bold)
Assert.matches(head[1].text, "…$")
Assert.eq(head[2].y, 100 + math.floor(head[1].size * 1.5) + 4, "作者紧跟书名实测行高")
Assert.eq(head[3].y, head[2].y + 21 + 4, "章节紧跟作者实测行高")
Assert.eq(bottom, head[3].y + 21 + 4)
head = U.bookHead({ title = "书" }, nil, 0, 0, 200)
Assert.len(head, 1, "无作者无副标题只剩书名")
package.loaded["features.lockscreen.render"] = nil

local empty = U.emptyBlocks({
    x = 10, y = 20, w = 300, h = 200,
    text_x = 30, text_w = 260, pad = 20, radius = 8,
}, "标题", "说明")
Assert.eq(empty[2].size, 20)
Assert.is_true(empty[2].bold)
Assert.eq(empty[4].size, 16)
Assert.is_true(empty[2].size > empty[4].size)
