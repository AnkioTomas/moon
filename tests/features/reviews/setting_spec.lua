--[[-- 段评设置：各账号的显示开关写该源的 show_paragraph_reviews，下划线样式落盘到 features.reviews。 --]]

local Assert = require("support.assert")

package.preload["ui.themes.widgets.row"] = function()
    return {
        widget = function(opts) return opts end,
        -- 与生产 Row.choice 相同：居中单选列表，选了与 current 不同的值才回调。
        choice = function(opts)
            if opts.status == nil then
                for _idx, item in ipairs(opts.items or {}) do
                    if item.value == opts.current then opts.status = item.text end
                end
            end
            opts.kind = opts.kind or "nav"
            opts.callback = function()
                require("ui.themes.widgets.list"):new{
                    title = opts.title, items = opts.items, current = opts.current, centered = true,
                    on_select = function(value)
                        if value == nil or value == opts.current then return end
                        opts.on_select(value)
                    end,
                }:show()
            end
            return opts
        end,
    }
end
local conf = { book_reviews_mark_style = "dashed", mark_gray = 73, mark_opacity = 100, bubble_opacity = 100, mark_offset = 0, font_scale = 100 }
local sources = { wechat = {}, qidian = { show_paragraph_reviews = true }, zhihu = {} }
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
                { id = "zhihu", name = "知乎盐选", abilities = { "他人段评" } },
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
Assert.eq(Setting.defaults.bubble_opacity, 100)
local entries = Setting.entries(desktop)
Assert.len(entries, 1)
Assert.eq(entries[1].group, "reader")
Assert.eq(entries[1].order, 15)
local sections = entries[1].page.sections()
Assert.eq(sections[1].title, "账号")
Assert.len(sections[1].rows, 3, "知乎真实能力声明使它出现在阅读→段评设置")
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
Assert.len(style.rows, 7)
Assert.eq(style.rows[1](600).status, "虚线")

style.rows[1](600).callback()
Assert.eq(conf.book_reviews_mark_style, "solid")
Assert.eq(saved[#saved], "features.reviews")
Assert.eq(updates, 2)
Assert.eq(entries[1].page.sections()[2].rows[1](600).status, "实线")

entries[1].page.sections()[2].rows[1](600).callback()
Assert.eq(conf.book_reviews_mark_style, "dotted")
Assert.eq(entries[1].page.sections()[2].rows[1](600).status, "点状")

entries[1].page.sections()[2].rows[1](600).callback()
Assert.eq(conf.book_reviews_mark_style, "dashed")

Assert.eq(style.rows[2](600).status, "+0 px")
Assert.eq(style.rows[3](600).status, "73%")
Assert.eq(style.rows[4](600).status, "100%")
Assert.eq(style.rows[5](600).title, "段评气泡透明度")
Assert.eq(style.rows[5](600).status, "100%")

local size = entries[1].page.sections()[2].rows[6](600)
Assert.eq(size.status, "100%")
local spin
package.preload["ui.themes.widgets.spin"] = function()
    return { new = function(_, o) spin = o; o.show = function() end; return o end }
end
size.callback()
Assert.eq(spin.fields[1].value, 100)
spin.callback(140)
Assert.eq(conf.font_scale, 140)

local zhihu = entries[1].page.sections()[1].rows[3](600)
Assert.eq(zhihu.title, "知乎盐选")
Assert.eq(zhihu.kind, "toggle")
Assert.eq(zhihu.status, "关")
zhihu.callback()
Assert.is_true(sources.zhihu.show_paragraph_reviews)
Assert.eq(entries[1].page.sections()[1].rows[3](600).status, "开")

local pos = entries[1].page.sections()[2].rows[7](600)
Assert.eq(pos.title, "回复按钮位置")
Assert.eq(pos.status, "左侧")
Assert.eq(pos.kind, "nav")

local list, shown
package.loaded["ui.themes.widgets.list"] = nil
package.preload["ui.themes.widgets.list"] = function()
    return {
        new = function(_, o)
            list = o
            o.show = function() shown = true end
            return o
        end,
    }
end
local updates_before = updates
pos.callback()
Assert.is_true(shown)
Assert.is_true(list.centered, "回复按钮位置用居中小弹窗，不是全屏列表")
Assert.eq(list.title, "回复按钮位置")
Assert.eq(list.current, "left")
list.on_select("left")
Assert.is_nil(conf.replies_pos, "选当前值不写回")
list.on_select("right")
Assert.eq(conf.replies_pos, "right")
Assert.eq(saved[#saved], "features.reviews")
Assert.eq(dirty[1], reader.dialog)
Assert.eq(updates, updates_before + 1, "选定后刷新设置页状态")
Assert.eq(entries[1].page.sections()[2].rows[7](600).status, "右侧")
