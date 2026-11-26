--[[-- X-Ray / 翻译设置：往「查词」页追加分节，开关落盘到各自 feature 分区。 --]]

local Assert = require("support.assert")

package.preload["gettext"] = function() return function(text) return text end end
package.preload["ffi/util"] = function()
    return { template = function(text, value) return (text:gsub("%%1", tostring(value))) end }
end
package.preload["ui.themes.widgets.row"] = function()
    return {
        widget = function(opts) return opts end,
        -- 单选行替身：与 Row.choice 同约定，真实现由 row_spec 测
        choice = function(opts)
            opts.callback = function()
                require("ui.themes.widgets.list"):new{
                    title = opts.title, items = opts.items, current = opts.current,
                    on_select = function(v) if v ~= nil and v ~= opts.current then opts.on_select(v) end end,
                }:show()
            end
            return opts
        end,
    }
end
local lists = {}
package.preload["ui.themes.widgets.list"] = function()
    return {
        new = function(_self, opts)
            lists[#lists + 1] = opts
            return { show = function() end }
        end,
    }
end
local conf = {
    xray = { book_xray_enabled = true, book_xray_show_marks = true, book_xray_mark_style = "dashed", book_xray_mark_gray = 73, book_xray_mark_opacity = 100, book_xray_mark_offset = 0, book_xray_quality = "standard" },
    translate = { edge_translation_enabled = false },
}
local saved = {}
package.preload["utils.settings"] = function()
    return {
        get = function(owner) return conf[owner:match("[^.]+$")] end,
        save = function(owner) saved[#saved + 1] = owner end,
    }
end
local invalidated = 0
package.preload["features.xray.marks"] = function()
    return { invalidate = function() invalidated = invalidated + 1 end }
end
package.preload["apps/reader/readerui"] = function() return {} end

local updates = 0
local desktop = { updateView = function() updates = updates + 1 end }

package.loaded["features.xray.setting"] = nil
local xray = require("features.xray.setting").entries(desktop)
Assert.len(xray, 1)
Assert.eq(xray[1].group, "reader")
Assert.eq(xray[1].order, 13)
local sections = xray[1].page.sections()
local section, marks = sections[1], sections[2]
Assert.eq(section.title, "识别")
Assert.eq(marks.title, "画线")
Assert.len(section.rows, 4)
Assert.len(marks.rows, 5)
local quality_row = section.rows[4](600)
Assert.eq(quality_row.current, "standard")
Assert.len(quality_row.items, 3)
Assert.eq(quality_row.items[1].value, "save")
Assert.eq(quality_row.items[2].value, "standard")
Assert.eq(quality_row.items[3].value, "high")
quality_row.callback()
Assert.len(lists, 1)
Assert.eq(lists[1].current, "standard")
lists[1].on_select("high")
Assert.eq(conf.xray.book_xray_quality, "high")
Assert.eq(saved[#saved], "features.xray")
Assert.eq(invalidated, 0, "档位不影响画线")
Assert.eq(updates, 1)
Assert.eq(marks.rows[2](600).status, "虚线")
marks.rows[2](600).callback()
Assert.eq(conf.xray.book_xray_mark_style, "solid")
Assert.eq(saved[#saved], "features.xray")
Assert.eq(invalidated, 0, "样式只重画，不作废扫描缓存")
Assert.eq(updates, 2)
Assert.eq(marks.rows[3](600).status, "+0 px")
Assert.eq(marks.rows[4](600).status, "73%")
Assert.eq(marks.rows[5](600).status, "100%")
Assert.eq(require("reader.mark_style").resolve(conf.xray, require("features.xray.setting").KEYS),
    "solid", "换算出样式")
invalidated = 1
section = xray[1].page.sections()[1]
section.rows[1](600).callback()
Assert.is_false(conf.xray.book_xray_enabled)
Assert.eq(invalidated, 2)
marks = xray[1].page.sections()[2]
marks.rows[1](600).callback()
Assert.eq(invalidated, 2, "X-Ray 关闭时画线开关不响应")

package.loaded["features.translate.setting"] = nil
local translate = require("features.translate.setting").entries(desktop)
Assert.eq(translate[1].group, "reader")
Assert.eq(translate[1].order, 14)
section = translate[1].page.sections()[1]
Assert.eq(section.title, "翻译")
Assert.len(section.rows, 1, "关闭时不显示常用语言")
section.rows[1](600).callback()
Assert.is_true(conf.translate.edge_translation_enabled)
Assert.eq(saved[#saved], "features.translate")
Assert.len(translate[1].page.sections()[1].rows, 2)

-- 双语样式是一张表单：只有颜色和字号。对照方式在翻译时选，不写进设置。
local forms = {}
package.preload["ui.themes.widgets.settings"] = function()
    return {
        new = function(_self, opts)
            forms[#forms + 1] = opts
            return { show = function() end }
        end,
    }
end
local bilingual = translate[1].page.sections()[2]
Assert.eq(bilingual.title, "双语对照")
Assert.len(bilingual.rows, 1)
Assert.eq(bilingual.rows[1](600).status, "跟随原文 · 跟随原文")
bilingual.rows[1](600).callback()
Assert.len(forms, 1)
local items = forms[1].items()
Assert.eq(items[1].title, "双语译文颜色")
Assert.eq(items[2].title, "双语译文字号")
Assert.eq(items[1].current, "")
Assert.eq(items[2].current, 0)
local saved_before = #saved
local updates_before = updates
local page = { closed = false, close = function(self) self.closed = true end }
items[1].on_select("#555555")
forms[1].buttons(page)[1].callback()
Assert.is_true(page.closed)
Assert.eq(#saved, saved_before, "取消不落盘")
Assert.is_nil(conf.translate.bilingual_color)
bilingual.rows[1](600).callback()
items = forms[2].items()
items[1].on_select("#555555")
items[2].on_select(90)
page = { closed = false, close = function(self) self.closed = true end }
forms[2].buttons(page)[2].callback()
Assert.is_true(page.closed)
Assert.eq(conf.translate.bilingual_color, "#555555")
Assert.eq(conf.translate.bilingual_scale, 90)
Assert.is_nil(conf.translate.bilingual_unit, "对照方式不进设置")
Assert.eq(saved[#saved], "features.translate")
Assert.eq(updates, updates_before + 1)
