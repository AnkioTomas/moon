--[[--
lockscreen.components.util：章节名清洗。

@module tests.lockscreen.components.util_spec
--]]

local Assert = require("support.assert")

package.loaded["lockscreen.components.util"] = nil
local U = require("lockscreen.components.util")
local Text = require("utils.text")

Assert.eq(U.cleanChapterTitle("第12章：序章"), "序章")
Assert.eq(U.cleanChapterTitle("Chapter 3. Hello"), "Hello")
Assert.eq(U.cleanChapterTitle("Ch. 9 Foo"), "Foo")
Assert.eq(U.cleanChapterTitle("无前缀标题"), "无前缀标题")
Assert.eq(U.chapterLine({ chapter_title = "第1章 开篇" }), "开篇")
Assert.eq(U.chapterLine({ chapter_count = 10, chapter_idx = 2 }), "第 2 / 10 章")
local truncated = Text.truncateUtf8("中文测试文本", 5)
Assert.is_true(Text.isValidUtf8(truncated))
Assert.eq(truncated, "中")
