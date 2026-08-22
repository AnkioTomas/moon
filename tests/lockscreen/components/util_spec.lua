--[[--
lockscreen.components.util：章节名清洗与进度文案。

@module tests.lockscreen.components.util_spec
--]]

local Assert = require("support.assert")

package.loaded["lockscreen.components.util"] = nil
local U = require("lockscreen.components.util")

Assert.eq(U.cleanChapterTitle("第12章：序章"), "序章")
Assert.eq(U.cleanChapterTitle("Chapter 3. Hello"), "Hello")
Assert.eq(U.cleanChapterTitle("Ch. 9 Foo"), "Foo")
Assert.eq(U.cleanChapterTitle("无前缀标题"), "无前缀标题")
Assert.eq(U.chapterLine({ chapter_title = "第1章 开篇" }), "开篇")
Assert.eq(U.chapterLine({ chapter_count = 10, chapter_idx = 2 }), "第 2 / 10 章")
local pct, pages = U.progress({ percent = 35, page = 70, total_pages = 200 })
Assert.eq(pct, 35)
Assert.eq(pages, "70 / 200 页")
local _, no_pages = U.progress({ percent = 10, page = 0, total_pages = 0 })
Assert.eq(no_pages, "页数暂无")
