--[[-- 段评设置：「查词」页追加「段评」分节，下划线样式落盘到 features.reviews 并重画阅读页。 --]]

local Assert = require("support.assert")

package.preload["gettext"] = function() return function(text) return text end end
package.preload["ui.themes.widgets.row"] = function()
    return { widget = function(opts) return opts end }
end
local conf = { book_reviews_mark_style = "dashed" }
local saved = {}
package.preload["utils.settings"] = function()
    return {
        get = function(owner) assert(owner == "features.reviews"); return conf end,
        save = function(owner) saved[#saved + 1] = owner end,
    }
end
local reader = { dialog = {} }
package.preload["apps/reader/readerui"] = function() return { instance = reader } end
local dirty
package.preload["ui/uimanager"] = function()
    return { setDirty = function(_self, widget, mode) dirty = { widget, mode } end }
end

local updates = 0
local desktop = { updateView = function() updates = updates + 1 end }

local Setting = require("features.reviews.setting")
Assert.eq(Setting.defaults.book_reviews_mark_style, "dashed")
local entries = Setting.entries(desktop)
Assert.len(entries, 1)
Assert.eq(entries[1].parent, "lookup")
Assert.eq(entries[1].order, 45, "排在 X-Ray（40）之后")
local section = entries[1].sections()[1]
Assert.eq(section.title, "段评")
Assert.len(section.rows, 1)
Assert.eq(section.rows[1](600).status, "虚线")

section.rows[1](600).callback()
Assert.eq(conf.book_reviews_mark_style, "solid")
Assert.eq(saved[#saved], "features.reviews")
Assert.eq(dirty[1], reader.dialog, "打开中的阅读页立即重画")
Assert.eq(updates, 1)
Assert.eq(entries[1].sections()[1].rows[1](600).status, "实线")

entries[1].sections()[1].rows[1](600).callback()
Assert.eq(conf.book_reviews_mark_style, "dashed")
