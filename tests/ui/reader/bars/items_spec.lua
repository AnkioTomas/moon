--[[--
阅读页栏组件：目录过滤与文案。
--]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")
Stubs.install()
Stubs.reset()

package.preload["gettext"] = function()
    return function(text) return text end
end
package.preload["l10n"] = function()
    return { apply = function() end }
end

package.loaded["ui.reader.bars.items"] = nil
local Items = require("ui.reader.bars.items")

local top = Items.catalog("top")
local bottom = Items.catalog("bottom")
local top_ids, bottom_ids = {}, {}
for i = 1, #top do top_ids[top[i].id] = true end
for i = 1, #bottom do bottom_ids[bottom[i].id] = true end
Assert.is_true(top_ids.chapter)
Assert.is_true(top_ids.clock)
Assert.is_nil(top_ids.progress_bar)
Assert.is_true(bottom_ids.progress_bar)
Assert.is_true(bottom_ids.percent)

local ctx = Items.sampleContext()
Assert.eq(Items.text("chapter", ctx), "第三章 初见")
Assert.eq(Items.text("title", ctx), "示例书名")
Assert.eq(Items.text("clock", ctx), "12:34")
Assert.eq(Items.text("percent", ctx), "42%")
Assert.eq(Items.text("chapter_idx", ctx), "第 3/10 章")
Assert.eq(Items.text("page", ctx), "120/320")
Assert.eq(Items.text("remaining", ctx), "约 30 分钟")
Assert.eq(Items.text("progress_bar", ctx), "")
Assert.eq(Items.text("percent", { percent = 150 }), "100%")
Assert.eq(Items.text("percent", { percent = -3 }), "0%")
Assert.eq(Items.text("page", { page = 1 }), "")
Assert.eq(Items.text("chapter_idx", { chapter_idx = 3 }), "")

return true
