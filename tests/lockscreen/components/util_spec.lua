--[[--
lockscreen.components.util：章节名清洗与进度文案。

@module tests.lockscreen.components.util_spec
--]]

local Assert = require("support.assert")

package.loaded["lockscreen.components.util"] = nil
local U = require("lockscreen.components.util")

Assert.eq(U.chapterLine({ chapter_title = "第1章 开篇" }), "第1章 开篇")
Assert.eq(U.chapterLine({ chapter_count = 10, chapter_idx = 2 }), "第 2 / 10 章")
local pct, pages = U.progress({ percent = 35, page = 70, total_pages = 200 })
Assert.eq(pct, 35)
Assert.eq(pages, "70 / 200 页")
local _, no_pages = U.progress({ percent = 10, page = 0, total_pages = 0 })
Assert.eq(no_pages, "页数暂无")

local empty = U.emptyBlocks({
    x = 10, y = 20, w = 300, h = 200,
    text_x = 30, text_w = 260, pad = 20, radius = 8,
}, "标题", "说明")
Assert.eq(empty[2].size, 20)
Assert.is_true(empty[2].bold)
Assert.eq(empty[4].size, 16)
Assert.is_true(empty[2].size > empty[4].size)
