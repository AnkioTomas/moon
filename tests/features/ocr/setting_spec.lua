--[[-- features.ocr.setting：「查词」页词典之后追加「文字识别（OCR）」分节。 --]]

local Assert = require("support.assert")

package.preload["gettext"] = function() return function(text) return text end end
package.preload["ui.themes.widgets.row"] = function() return { widget = function(opts) return opts end } end
local installed = {}
local forced = false
package.preload["features.ocr.manager"] = function()
    return {
        dataDir = function() return "/tess" end,
        installed = function() return installed end,
        forcedOcr = function() return forced end,
        setForcedOcr = function(on) forced = on end,
    }
end
local calls = {}
package.preload["features.ocr.ui"] = function()
    return {
        download = function() calls[#calls + 1] = "download" end,
        manage = function() calls[#calls + 1] = "manage" end,
    }
end

local updates = 0
local desktop = { updateView = function() updates = updates + 1 end }
---@cast desktop BookDesktop
local entry = require("features.ocr.setting").entries(desktop)[1]
Assert.eq(entry.group, "reader")
Assert.eq(entry.order, 18)
local section = entry.page.sections()[1]
Assert.eq(section.title, "文字识别（OCR）")
-- 第一行：KOReader「Forced OCR」开关，读写同一设置并刷新页面。
Assert.eq(section.rows[1](600).title, "强制文字识别")
Assert.is_false(section.rows[1](600).status_on)
section.rows[1](600).callback()
Assert.is_true(forced)
Assert.eq(updates, 1)
Assert.is_true(entry.page.sections()[1].rows[1](600).status_on)
Assert.eq(section.rows[2](600).title, "下载识别语言")
Assert.eq(section.rows[2](600).subtitle, "仅对扫描版 PDF / DjVu 生效，长按文字即可识别")
Assert.eq(section.rows[3](600).status, "未安装")
section.rows[2](600).callback()
section.rows[3](600).callback()
Assert.eq(table.concat(calls, ","), "download,manage")
installed = { "chi_sim", "eng" }
Assert.eq(entry.page.sections()[1].rows[3](600).status, "2")

return true
