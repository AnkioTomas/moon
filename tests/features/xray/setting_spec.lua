--[[-- X-Ray / 翻译设置：往「查词」页追加分节，开关落盘到各自 feature 分区。 --]]

local Assert = require("support.assert")

package.preload["gettext"] = function() return function(text) return text end end
package.preload["ffi/util"] = function()
    return { template = function(text, value) return (text:gsub("%%1", tostring(value))) end }
end
package.preload["ui.themes.widgets.row"] = function()
    return { widget = function(opts) return opts end }
end
local conf = {
    xray = { book_xray_enabled = true, book_xray_show_marks = true, book_xray_mark_style = "dashed" },
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
Assert.eq(xray[1].parent, "lookup")
Assert.eq(xray[1].order, 40)
local section = xray[1].sections()[1]
Assert.eq(section.title, "X-Ray")
Assert.len(section.rows, 3)
Assert.eq(section.rows[3](600).status, "虚线")
section.rows[3](600).callback()
Assert.eq(conf.xray.book_xray_mark_style, "solid")
Assert.eq(saved[#saved], "features.xray")
Assert.eq(invalidated, 1)
Assert.eq(updates, 1)
section = xray[1].sections()[1]
section.rows[1](600).callback()
Assert.is_false(conf.xray.book_xray_enabled)
Assert.eq(invalidated, 2)
section = xray[1].sections()[1]
section.rows[2](600).callback()
Assert.eq(invalidated, 2, "X-Ray 关闭时画线开关不响应")

package.loaded["features.translate.setting"] = nil
local translate = require("features.translate.setting").entries(desktop)
Assert.eq(translate[1].parent, "lookup")
Assert.eq(translate[1].order, 30)
section = translate[1].sections()[1]
Assert.eq(section.title, "翻译")
Assert.len(section.rows, 1, "关闭时不显示常用语言")
section.rows[1](600).callback()
Assert.is_true(conf.translate.edge_translation_enabled)
Assert.eq(saved[#saved], "features.translate")
Assert.len(translate[1].sections()[1].rows, 2)
