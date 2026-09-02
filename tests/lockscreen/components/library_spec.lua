--[[--
lockscreen 书库辅助：调用方指定的当前源是唯一源边界。

@module tests.lockscreen.components.library_spec
--]]

local Assert = require("support.assert")

package.preload["utils.settings"] = function()
    return { activeSourceId = function() return "moon" end }
end

package.preload["utils.paths"] = function()
    return {
        coverPath = function(stable_id, source_id)
            return source_id .. "/" .. stable_id .. ".png"
        end,
    }
end

package.preload["libs/libkoreader-lfs"] = function()
    return {
        attributes = function() return "file" end,
    }
end

package.loaded["lockscreen.components.library"] = nil
local Library = require("lockscreen.components.library")

Assert.eq(Library.activeSourceId(), "moon")
local book = Library.shelfBook({
    source_id = "wrong-source",
    stable_id = "book-1",
    title = "Book",
    percent = 30,
}, "moon")
Assert.eq(book.source_id, "moon")
Assert.eq(book.stable_id, "book-1")
Assert.eq(book.cover, "moon/book-1.png")
