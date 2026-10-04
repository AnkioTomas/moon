--[[--
lockscreen 高亮：只读取当前源数据库书籍和 notes 快照。

@module tests.features.lockscreen.components.highlight_spec
--]]

local Assert = require("support.assert")

local collect_args
local pick_args
local settings = { lock_screen_quote_index = 0 }

package.preload["features.lockscreen.components.current"] = function()
    return {
        book = function()
            return {
                source_id = "moon",
                stable_id = "book-1",
                chapter_idx = 3,
            }
        end,
    }
end

package.preload["book.highlights"] = function()
    return {
        collect = function(...)
            collect_args = { ... }
            return { { text = "A" }, { text = "B" } }
        end,
        pick = function(...)
            pick_args = { ... }
            return "数据库高亮", "数据库章节"
        end,
    }
end

package.preload["utils.settings"] = function()
    return {
        feature = function(name) assert(name == "lockscreen"); return settings end,
        saveSection = function(name) assert(name == "lockscreen") end,
    }
end

package.preload["features.lockscreen.components.quote_panel"] = function()
    return { blocks = function() return {} end }
end

package.preload["features.lockscreen.components.util"] = function()
    return { FALLBACK_MESSAGE = "fallback" }
end

package.preload["reader.session"] = function()
    error("lockscreen highlight must not read ReaderSession")
end

package.loaded["features.lockscreen.components.highlight"] = nil
local Highlight = require("features.lockscreen.components.highlight")
local text, source = Highlight.next()

Assert.eq(text, "数据库高亮")
Assert.eq(source, "数据库章节")
Assert.eq(collect_args[1], "moon")
Assert.eq(collect_args[2], "book-1")
Assert.eq(collect_args[3], 3)
Assert.eq(#collect_args, 3)
Assert.eq(pick_args[1], "moon")
Assert.eq(pick_args[2], "book-1")
Assert.eq(pick_args[3], 3)
Assert.eq(pick_args[4], 1)
Assert.eq(#pick_args, 4)
Assert.eq(settings.lock_screen_quote_index, 1)
