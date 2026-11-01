--[[-- 段评设置：各账号的显示开关写该源的 show_paragraph_reviews，下划线样式落盘到 features.reviews。 --]]

local Assert = require("support.assert")

package.preload["gettext"] = function() return function(text) return text end end
package.preload["ui.themes.widgets.row"] = function()
    return { widget = function(opts) return opts end }
end
local conf = { book_reviews_mark_style = "dashed" }
local sources = { wechat = {}, qidian = { show_paragraph_reviews = true } }
local saved = {}
package.preload["utils.settings"] = function()
    return {
        get = function(owner) assert(owner == "features.reviews"); return conf end,
        save = function(owner) saved[#saved + 1] = owner end,
        getSource = function(id) return sources[id] end,
        saveSource = function(id, cfg) sources[id] = cfg end,
    }
end
package.preload["source.registry"] = function()
    return {
        listEnabled = function()
            return {
                { id = "wechat", name = "微信读书", abilities = { "他人段评" } },
                { id = "local", name = "本地书籍", abilities = { "书架同步" } },
                { id = "qidian", name = "起点读书", abilities = { "书架同步", "他人段评" } },
            }
        end,
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
Assert.eq(entries[1].group, "reader")
Assert.eq(entries[1].order, 15)
local sections = entries[1].page.sections()
Assert.eq(sections[1].title, "账号")
Assert.len(sections[1].rows, 2)
local wechat = sections[1].rows[1](600)
local qidian = sections[1].rows[2](600)
Assert.eq(wechat.title, "微信读书")
Assert.eq(wechat.kind, "toggle")
Assert.eq(wechat.status, "关")
Assert.eq(qidian.title, "起点读书")
Assert.eq(qidian.status, "开")

wechat.callback()
Assert.eq(sources.wechat.show_paragraph_reviews, true)
Assert.eq(dirty[1], reader.dialog, "打开中的阅读页立即重画")
Assert.eq(updates, 1)
Assert.eq(entries[1].page.sections()[1].rows[1](600).status, "开")

local style = sections[2]
Assert.eq(style.title, "段评")
Assert.len(style.rows, 1)
Assert.eq(style.rows[1](600).status, "虚线")

style.rows[1](600).callback()
Assert.eq(conf.book_reviews_mark_style, "solid")
Assert.eq(saved[#saved], "features.reviews")
Assert.eq(updates, 2)
Assert.eq(entries[1].page.sections()[2].rows[1](600).status, "实线")

entries[1].page.sections()[2].rows[1](600).callback()
Assert.eq(conf.book_reviews_mark_style, "dashed")
