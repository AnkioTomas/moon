--[[-- 阅读设置：行为一组，划词页只有「选区」（翻译、X-Ray 由 feature 追加）。 --]]

local Assert = require("support.assert")

package.preload["gettext"] = function() return function(text) return text end end
package.preload["l10n"] = function() return { apply = function() end } end
package.preload["ffi/util"] = function()
    return {
        template = function(text, value)
            return (text:gsub("%%1", tostring(value)))
        end,
    }
end
local reader_section = { reader_popup_seen = {}, western_font_id = "", western_font_name = "" }
local saved_section
package.preload["utils.settings"] = function()
    return {
        get = function() return reader_section end,
        save = function(name, values) saved_section = { name = name, values = values } end,
    }
end
package.preload["ui.themes.widgets.row"] = function()
    return { widget = function(opts) return opts end }
end
package.preload["ui/widget/infomessage"] = function() return {} end
package.preload["ui/widget/buttondialog"] = function() return {} end
require("support.theme_stubs").install()
package.preload["ui/uimanager"] = function() return {} end

local saved_settings = {}
_G.G_reader_settings = {
    isTrue = function(_, key) return saved_settings[key] == true end,
    readSetting = function(_, key) return saved_settings[key] end,
    saveSetting = function(_, key, value) saved_settings[key] = value end,
}
package.preload["ui/data/css_tweaks"] = function()
    return { DEFAULT_GLOBAL_STYLE_TWEAKS = { ["footnote-inpage_epub"] = true, ["footnote-inpage_fb2"] = true } }
end
package.preload["apps/reader/readerui"] = function()
    return { instance = nil }
end

local Settings = require("desktop.pages.setting.reader")
local updates = 0
local desktop = { updateView = function() updates = updates + 1 end }

local sections = Settings:sections(desktop)
Assert.eq(#sections, 1)
Assert.eq(sections[1].title, "行为")
Assert.eq(sections[1].rows[1](600).title, "脚注弹窗")
Assert.is_false(sections[1].rows[1](600).toggle)
Assert.eq(sections[1].rows[1](600).subtitle, "开：点按弹窗，不在页底；关：注文显示在页面底部")
-- 开弹窗：关页内脚注；关弹窗：开页内脚注（互斥）。
sections[1].rows[1](600).callback()
Assert.is_true(saved_settings.footnote_link_in_popup)
Assert.is_nil(saved_settings.style_tweaks["footnote-inpage_epub"])
Assert.is_true(saved_settings.style_tweaks["footnote-inpage_fb2"], "写 style_tweaks 时保留其它默认项")
Assert.is_true(Settings:sections(desktop)[1].rows[1](600).toggle)
Settings:sections(desktop)[1].rows[1](600).callback()
Assert.is_false(saved_settings.footnote_link_in_popup)
Assert.is_true(saved_settings.style_tweaks["footnote-inpage_epub"])
Assert.eq(updates, 2, "脚注开关来回各刷一次桌面")
Assert.len(sections[1].rows, 6, "阅读行为不再提供独立西文字体入口")
local auto_mark = sections[1].rows[2](600)
Assert.eq(auto_mark.title, "读到 99% 自动标记已读")
Assert.is_false(auto_mark.toggle)
auto_mark.callback()
Assert.is_true(reader_section.auto_mark_read_at_99)
local notice = sections[1].rows[3](600)
Assert.eq(notice.title, "显示换章提示")
Assert.is_true(notice.toggle)
local margin_popup = sections[1].rows[4](600)
Assert.eq(margin_popup.title, "边距调整弹出提示")
Assert.is_false(margin_popup.toggle)
Assert.eq(saved_section.name, "reader")
Assert.eq(updates, 3)
local back = sections[1].rows[5](600)
Assert.eq(back.title, "返回键回月读")
Assert.is_false(back.toggle)
back.callback()
Assert.is_true(reader_section.back_to_desktop)
Assert.eq(saved_section.name, "reader")
Assert.is_true(Settings:sections(desktop)[1].rows[5](600).toggle)
local mixed = Settings:sections(desktop)[1].rows[6](600)
Assert.eq(mixed.title, "中西文字体分开")
Assert.is_false(require("reader.setting").defaults.mixed_fonts, "中西文字体分开默认关闭")
Assert.is_false(mixed.toggle)
mixed.callback()
Assert.is_true(reader_section.mixed_fonts)
Assert.eq(saved_section.name, "reader")
local enabled = Settings:sections(desktop)[1].rows
Assert.len(enabled, 6, "开启后阅读行为页仍没有西文字体入口")
Assert.is_true(enabled[6](600).toggle)
enabled[6](600).callback()
Assert.is_false(reader_section.mixed_fonts)
reader_section = { reader_popup_seen = {} }

local lookup = Settings:lookupSections(desktop)
local titles = {}
for _, section in ipairs(lookup) do
    titles[#titles + 1] = section.title
end
Assert.eq(table.concat(titles, ","), "选区")
Assert.eq(lookup[1].rows[1](600).title, "划词手柄")
Assert.is_true(lookup[1].rows[1](600).toggle)

local popup_rows = Settings:popupRows(desktop)
Assert.len(popup_rows, 12)
Assert.eq(popup_rows[1](600).title, "选择")
Assert.eq(popup_rows[9](600).title, "AI 解释")
Assert.eq(popup_rows[12](600).title, "搜索")

-- 旧配置缺键：设置页显示的位次必须和实际弹窗顺序（HighlightMenu.order）一致。
reader_section = { reader_popup_button_order = { "copy" }, reader_popup_seen = {} }
local order = require("reader.highlight_menu").order()
local dictionary_pos
for i, key in ipairs(order) do
    if key == "dictionary" then dictionary_pos = i end
end
Assert.eq(popup_rows[6](600).title, "词典")
Assert.eq(popup_rows[6](600).status, "第 " .. dictionary_pos .. " 位")

-- 扫描到的按钮：内置按钮之后列出，标题用扫描到的文字，副标题写来源；还没扫到来源的不写
reader_section = {
    reader_popup_seen = {
        ["12_0_make_handmade_toc_item"] = { title = "开始目录章节 ⊡", origin = "koreader" },
        qrcode = { title = "生成二维码", origin = "plugin:qrclipboard" },
        ai_explain = { title = "AI 解释", origin = "book" },
        ["13_patch_button"] = { origin = "patch:2-my-button" },
    },
}
popup_rows = Settings:popupRows(desktop)
Assert.len(popup_rows, 14)
Assert.is_nil(popup_rows[1](600).subtitle)
Assert.eq(popup_rows[9](600).subtitle, "来自：月读")
Assert.eq(popup_rows[11](600).subtitle, "来自：插件 qrclipboard")
local toc_row = popup_rows[13](600)
Assert.eq(toc_row.title, "开始目录章节 ⊡")
Assert.eq(toc_row.icon, "extension")
Assert.eq(toc_row.subtitle, "来自：KOReader 自带")
Assert.eq(popup_rows[14](600).title, "13_patch_button", "没扫到文字时显示原键")
Assert.eq(popup_rows[14](600).subtitle, "来自：用户补丁 2-my-button")

-- 停用扫描到的按钮：按原键写进 reader_popup_buttons
toc_row.callback()
local sheet = require("support.theme_stubs").last("sheet")
Assert.eq(sheet.title, "开始目录章节 ⊡")
Assert.eq(sheet.items[1].text, "停用")
sheet.items[1].callback()
Assert.is_false(reader_section.reader_popup_buttons["12_0_make_handmade_toc_item"])
Assert.eq(saved_section.name, "reader")

-- 设为第几位：输入框默认当前位次，确认后插到目标位，越界截断
reader_section = { reader_popup_seen = {} }
popup_rows = Settings:popupRows(desktop)
popup_rows[3](600).callback()
local position_item
for _idx, item in ipairs(require("support.theme_stubs").last("sheet").items) do
    if item.text == "设为第几位…" then position_item = item end
end
Assert.not_nil(position_item)
position_item.callback()
local input = require("support.theme_stubs").last("input")
local copy_pos
for i, key in ipairs(require("reader.highlight_menu").order()) do
    if key == "copy" then copy_pos = i end
end
Assert.eq(input.fields[1].text, tostring(copy_pos))
input.callback("1")
Assert.eq(reader_section.reader_popup_button_order[1], "copy")
input.callback("abc")
Assert.eq(reader_section.reader_popup_button_order[1], "copy", "非数字忽略")

return true
