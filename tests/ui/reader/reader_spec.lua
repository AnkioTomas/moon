--[[-- ui.reader：阅读图标动作与 ReaderUI 接线。 --]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")
Stubs.install()
Stubs.reset()

package.preload["l10n"] = function() return { apply = function() end } end
package.preload["gettext"] = function() return function(value) return value end end

package.preload["l10n"] = function() return { apply = function() end } end
package.preload["gettext"] = function() return function(value) return value end end
package.preload["device"] = function()
    return {
        screen = {
            getWidth = function() return 600 end,
            getHeight = function() return 800 end,
            getDPI = function() return 160 end,
            scaleBySize = function(_, n) return n end,
        },
        hasWifiToggle = function() return true end,
    }
end
package.preload["ui/network/manager"] = function()
    return { isWifiOn = function() return false end }
end
package.preload["ui/event"] = function()
    return { new = function(_, name) return { name = name } end }
end

local native_ui
package.preload["ui.panel.native"] = function()
    return { install = function(ui) native_ui = ui end }
end

local active = true
local sync_source = { id = "moon" }
local current = { identity = { source_id = "moon", stable_id = "b1", source = sync_source } }
package.preload["ui.reader.session"] = function()
    return {
        current = function()
            return active and current or nil
        end,
        toc = function() return nil end,
    }
end
package.preload["ui.reader.ocr"] = function()
    return { open = function() end }
end
package.preload["ui.reader.dictionary"] = function()
    return { open = function() end }
end

local sync_calls = {}
package.preload["book.progress"] = function()
    return { save = function(snapshot, cb)
        sync_calls[#sync_calls + 1] = { "save_progress", snapshot }
        cb(true)
    end }
end
package.preload["book.note"] = function()
    return { save = function(saved_ui, identity, cb)
        sync_calls[#sync_calls + 1] = { "save_notes", saved_ui, identity }
        cb(true)
    end }
end
package.preload["book.sync"] = function()
    return { runAsync = function(source, opts, cb)
        sync_calls[#sync_calls + 1] = { "sync", source, opts }
        cb({ pulled = 0, pushed = 2 })
        return { cancel = function() end }
    end }
end
package.preload["ui/widget/infomessage"] = function()
    return { new = function(_, opts) return opts end }
end

local registered_module
package.preload["ui.reader.bars"] = function()
    return { startClock = function() end }
end
package.preload["lockscreen.init"] = function()
    return { refreshInBackground = function() end }
end

local bookmarked, toggles = false, 0
local ui = {
    dialog = {},
    toc = { onShowToc = function() end },
    bookmark = {
        isPageBookmarked = function() return bookmarked end,
        onToggleBookmark = function()
            bookmarked = not bookmarked
            toggles = toggles + 1
        end,
        onShowBookmark = function() end,
    },
    dictionary = {
        onShowDictionaryLookup = function() end,
        showDictionariesMenu = function() end,
    },
    view = {
        registerViewModule = function(_, name, module)
            registered_module = { name = name, module = module }
        end,
    },
}
local plugin = { ui = ui }

local Reader = require("ui.reader")
local actions = Reader.actions(ui)
Assert.len(actions, 6)
Assert.eq(actions[1].id, "toc")
Assert.eq(actions[1].icon, "menu_book")
Assert.eq(actions[2].id, "bookmark")
Assert.eq(actions[3].id, "highlights")
Assert.eq(actions[4].id, "sync")
Assert.eq(actions[5].id, "dictionary")
Assert.eq(actions[6].id, "ocr")

local closed, refreshed = 0, 0
Assert.is_true(Reader.executeAction("bookmark", ui, {
    close = function() closed = closed + 1 end,
    refresh = function() refreshed = refreshed + 1 end,
}))
Assert.eq(toggles, 1)
Assert.eq(closed, 0)
Assert.eq(refreshed, 1)
Assert.is_true(Reader.actions(ui)[2].active)
Assert.eq(Reader.actions(ui)[2].icon, "bookmark")
Assert.is_false(Reader.executeAction("missing", ui))

Assert.is_true(Reader.executeAction("sync", ui))
Assert.eq(sync_calls[1][1], "save_progress")
Assert.eq(sync_calls[2][1], "save_notes")
Assert.eq(sync_calls[3][1], "sync")
Assert.eq(sync_calls[3][2], sync_source)
Assert.eq(sync_calls[3][3].identity, current.identity)
Assert.is_true(sync_calls[3][3].skip_books)

Reader.attach(plugin)
Assert.eq(native_ui, ui)
Assert.eq(registered_module.name, "book_bars")
Assert.is_nil(ui._zones, "不应注册覆盖原生菜单的触摸区")

native_ui = nil
Reader.attach(plugin)
Assert.is_nil(native_ui, "同一 ReaderUI 不应重复安装")
