--[[-- 当前页书签动作：设置页可选、原生切换与激活态、默认隐藏。 --]]

local Assert = require("support.assert")

package.preload["l10n"] = function() return { apply = function() end } end
package.preload["gettext"] = function() return function(text) return text end end

local action = require("features.panel.actions.reader.bookmark")
Assert.is_true(action.available({}))
Assert.is_false(action.active({}))
Assert.is_false(action.available({ ui = {} }) == true)

local bookmarked, calls = false, 0
local bookmark = {}
bookmark.isPageBookmarked = function() return bookmarked end
bookmark.onToggleBookmark = function(self)
    Assert.eq(self, bookmark)
    calls = calls + 1
    bookmarked = not bookmarked
end
local ctx = { ui = { bookmark = bookmark } }
Assert.is_true(action.available(ctx))
Assert.is_false(action.active(ctx))
action.run(ctx)
Assert.is_true(action.active(ctx))
action.run(ctx)
Assert.is_false(action.active(ctx))
Assert.eq(calls, 2)

for _idx, id in ipairs(require("features.panel.setting").defaults.quick_panel_reader_actions) do
    Assert.is_false(id == action.id, "新旧用户均须手动启用书签按钮")
end
