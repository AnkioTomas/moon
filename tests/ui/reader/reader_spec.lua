--[[-- ui.reader：阅读图标动作与 ReaderUI 接线。 --]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")
Stubs.install()
Stubs.reset()

local native_ui
package.preload["ui.reader.native"] = function()
    return { install = function(ui) native_ui = ui end }
end

local active = true
package.preload["ui.reader.session"] = function()
    return {
        current = function()
            return active and { identity = { source = {} } } or nil
        end,
        toc = function() return nil end,
    }
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
Assert.len(actions, 13)
Assert.eq(actions[1].id, "toc")
Assert.eq(actions[1].icon, "toc")
Assert.eq(actions[2].id, "bookmark")
Assert.eq(actions[3].id, "highlights")
Assert.eq(actions[4].id, "sync")
Assert.eq(actions[5].id, "ocr")
Assert.eq(actions[6].id, "dictionary")
Assert.eq(actions[7].id, "ai_analysis")
Assert.eq(actions[8].id, "ai_summary")
Assert.eq(actions[9].id, "ai_graph")
Assert.eq(actions[10].id, "xray_characters")
Assert.eq(actions[11].id, "xray_locations")
Assert.eq(actions[12].id, "xray_timeline")
Assert.eq(actions[13].id, "xray_lookup")

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

Reader.attach(plugin)
Assert.eq(native_ui, ui)
Assert.eq(registered_module.name, "book_bars")
Assert.is_nil(ui._zones, "不应注册覆盖原生菜单的触摸区")

native_ui = nil
Reader.attach(plugin)
Assert.is_nil(native_ui, "同一 ReaderUI 不应重复安装")
