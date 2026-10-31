--[[--
侧栏票根：PNG 路径跟书籍身份走，换书不会写成同一个 ticket.png。

@module tests.features.sidebar.ticket_spec
--]]

local Assert = require("support.assert")

local hashed = {}

package.preload["l10n"] = function() return { apply = function() end } end
package.preload["gettext"] = function() return function(s) return s end end
package.preload["ffi/blitbuffer"] = function() return {} end
package.preload["ffi/util"] = function() return { template = function(s) return s end } end
package.preload["ui/geometry"] = function() return { new = function(_, o) return o end } end
local function plain() return { new = function(_, o) return o or {} end } end
package.preload["ui/widget/container/centercontainer"] = plain
package.preload["ui/widget/imagewidget"] = plain
package.preload["ui/widget/verticalgroup"] = plain
package.preload["ui.themes"] = function() return { px = function(n) return n end, current = function() return {} end } end
package.preload["ui.themes.widgets.button"] = plain
package.preload["ui.themes.widgets.text"] = function() return { line = function() return {} end } end
package.preload["utils.paths"] = function()
    return { screensaverDir = function() return "/tmp/moon-screensaver" end }
end
package.preload["ffi/sha2"] = function()
    return {
        md5 = function(s)
            hashed[#hashed + 1] = s
            local n = 0
            for i = 1, #s do n = (n * 33 + s:byte(i)) % 4294967296 end
            return string.format("%08x", n)
        end,
    }
end
package.preload["features.sidebar.info"] = function()
    return { book = function(snapshot) return snapshot.book end }
end
package.preload["features.lockscreen.components.current"] = function()
    return { snapshot = function(fields) return fields end }
end
package.preload["features.lockscreen.layout"] = function()
    return {
        portraitSize = function() return 100, 200 end,
        panel = function(rect) return rect end,
    }
end
package.preload["features.lockscreen.components.receipt"] = function()
    return { preferred_height = 0.5, blocks = function() return {} end }
end
package.preload["reader.session"] = function()
    return {
        bookPages = function() return 1, 10 end,
        chapterIndex = function() end,
        chapterTitle = function() end,
    }
end
package.preload["ui.themes.widgets.image"] = function()
    return { await = function(_widgets, cb) cb(); return { cancel = function() end } end }
end
package.preload["features.lockscreen.render"] = function()
    return { write = function() return true end }
end

local Ticket = require("features.sidebar.ticket")

local function open(book)
    return Ticket.new({ book = book }, function() end)
end

local first = open({ source_id = "local", stable_id = "book-a", title = "第一本" })
local again = open({ source_id = "local", stable_id = "book-a", title = "第一本" })
local second = open({ source_id = "local", stable_id = "book-b", title = "第二本" })
local other_source = open({ source_id = "wechat", stable_id = "book-a", title = "第一本" })

Assert.eq(first.path, again.path, "同一本书重复打开仍是同一个文件")
Assert.is_true(first.path ~= second.path, "换书必须换文件，不能再共用 ticket.png")
Assert.is_true(first.path ~= other_source.path, "不同源的同一 stable_id 不能撞文件")
Assert.matches(first.path, "^/tmp/moon%-screensaver/ticket%-%x+%.png$")
Assert.is_nil(first.path:find("/ticket.png", 1, true), "不能再写固定的 ticket.png")
Assert.eq(hashed[1], "local\0book-a")
Assert.eq(hashed[3], "local\0book-b")
Assert.eq(hashed[4], "wechat\0book-a")

return true
