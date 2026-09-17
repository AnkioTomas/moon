--[[--
lockscreen 书库辅助：范围走 Catalog.libraryScope；封面用行内 source_id。

@module tests.lockscreen.components.library_spec
--]]

local Assert = require("support.assert")

package.preload["utils.settings"] = function()
    return {
        activeSourceId = function() return "moon" end,
        libraryMixed = function() return false end,
    }
end
package.preload["book.catalog"] = function()
    return { libraryScope = function(id) return id end }
end
package.preload["utils.paths"] = function()
    return {
        coverPath = function(stable_id, source_id)
            return source_id .. "/" .. stable_id .. ".png"
        end,
    }
end
package.preload["libs/libkoreader-lfs"] = function()
    return { attributes = function() return "file" end }
end

package.loaded["lockscreen.components.library"] = nil
local Library = require("lockscreen.components.library")

Assert.eq(Library.activeSourceId(), "moon")

local book = Library.shelfBook({
    source_id = "wechat",
    stable_id = "book-1",
    title = "Book",
    percent = 30,
}, "moon")
Assert.eq(book.source_id, "wechat")
Assert.eq(book.cover, "wechat/book-1.png")
