--[[--
ui.reader.layout：阅读风格预设落盘与 apply。
--]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")
Stubs.install()
Stubs.reset()

local css_written
local settings_data = { book_reader_layout_id = "book" }
local g_settings = {}

package.preload["datastorage"] = function()
    return {
        getDataDir = function() return "/tmp/book-layout-test" end,
    }
end
package.preload["utils.settings"] = function()
    return {
        get = function() return settings_data end,
        save = function(values) settings_data = values end,
    }
end
package.preload["util"] = function()
    return {
        makePath = function() return true end,
    }
end
package.preload["ui/widget/notification"] = function()
    return { notify = function() end }
end
package.preload["ui/widget/infomessage"] = function()
    return { new = function(_, opts) return opts end }
end
package.preload["ui/event"] = function()
    return {
        new = function(_, name, a, b)
            return { name = name, arg = a, arg2 = b }
        end,
    }
end
package.preload["device"] = function()
    return {
        screen = {
            scaleBySize = function(_, n) return n end,
            getWidth = function() return 600 end,
            getHeight = function() return 800 end,
        },
    }
end

local old_open = io.open
io.open = function(path, mode)
    if type(path) == "string" and path:find("book_layout%.css$") and mode == "w" then
        local buf = {}
        return {
            write = function(_, chunk) buf[#buf + 1] = chunk end,
            close = function()
                css_written = table.concat(buf)
                return true
            end,
        }
    end
    return old_open(path, mode)
end

G_reader_settings = {
    saveSetting = function(_, key, value) g_settings[key] = value end,
    readSetting = function(_, key, default) return g_settings[key] or default end,
}

package.loaded["ui.reader.layout"] = nil
local Layout = require("ui.reader.layout")

Assert.eq(#Layout.presets(), 4)
Assert.eq(Layout.get("book").title, "纸书")
Assert.eq(Layout.get("column").h_margins[1], 42)
Assert.is_true(Layout.get("initial").css:find("first%-letter") ~= nil)
Assert.is_true(Layout.get("essay").css:find("text%-indent: 0") ~= nil)
-- 预设改用 non-float 的 initial-letter 做首字下沉，避免 CREngine 因 float
-- 变化把 DOM 标记为 stale，导致每次应用预设都弹「重新加载文档」。
Assert.is_nil(Layout.get("initial").css:find("float"))
Assert.is_nil(Layout.get("book").css:find("float"))
Assert.is_true(Layout.get("initial").css:find("initial%-letter") ~= nil)

-- 脚注类全局项不被清掉
g_settings.style_tweaks = {
    ["footnote-inpage_epub"] = true,
    margin_body_0 = true,
}
local preset = Layout.get("column")
Layout.saveDefaults(preset, nil)
Assert.eq(g_settings.copt_font_size, 22)
Assert.eq(g_settings.copt_line_spacing, 145)
Assert.eq(g_settings.copt_h_page_margins[1], 42)
Assert.eq(g_settings.copt_t_page_margin, 14)
Assert.is_true(g_settings.style_tweaks["footnote-inpage_epub"])
Assert.is_true(g_settings.style_tweaks.margin_body_0)
Assert.is_true(g_settings.style_tweaks["book_layout.css"])
Assert.is_nil(g_settings.style_tweaks.paragraph_first_no_indent)
Assert.is_true(css_written ~= nil and css_written:find("text%-indent: 2em") ~= nil)
Assert.eq(settings_data.book_reader_layout_id, "column")

-- apply：排版 + CSS
local events = {}
local update_css_calls = 0
local ui = {
    rolling = {},
    document = {
        setFontSize = function() end,
        setInterlineSpacePercent = function() end,
        setFontBaseWeight = function() end,
    },
    font = {
        configurable = {
            font_size = 22,
            line_spacing = 100,
            font_base_weight = 0,
            h_page_margins = { 10, 10 },
            t_page_margin = 10,
            b_page_margin = 10,
        },
    },
    styletweak = {
        enabled = true,
        global_tweaks = g_settings.style_tweaks,
        doc_tweaks = { ["footnote-inpage_epub"] = true },
        updateCssText = function(self, apply)
            update_css_calls = update_css_calls + 1
            Assert.is_true(apply)
        end,
    },
    handleEvent = function(_, event) events[#events + 1] = event end,
}

Assert.is_true(Layout.apply(ui, "initial"))
Assert.eq(ui.font.configurable.font_size, 22)
Assert.eq(ui.font.configurable.line_spacing, 155)
Assert.eq(ui.styletweak.book_style_tweak_enabled, true)
Assert.is_true(ui.styletweak.book_style_tweak:find("initial%-letter") ~= nil)
Assert.eq(ui.styletweak.doc_tweaks["book_layout.css"], false)
Assert.is_true(ui.styletweak.doc_tweaks.paragraph_first_no_indent)
Assert.is_true(ui.styletweak.doc_tweaks["footnote-inpage_epub"])
Assert.eq(update_css_calls, 1)

local names = {}
for _, event in ipairs(events) do
    names[#names + 1] = event.name
end
Assert.is_true(table.concat(names, ","):find("SetPageHorizMargins") ~= nil)
Assert.is_true(table.concat(names, ","):find("UpdatePos") ~= nil)

-- 非 reflowable
Assert.is_false(Layout.apply({}, "book"))

-- 关闭：清 CSS / 托管 tweak，保留脚注，不改字号
settings_data.book_reader_layout_id = "initial"
ui.font.configurable.font_size = 22
ui.font.configurable.line_spacing = 155
ui.styletweak.doc_tweaks = {
    ["footnote-inpage_epub"] = true,
    margin_body_0 = true,
    ["book_layout.css"] = false,
    paragraph_first_no_indent = true,
}
ui.styletweak.book_style_tweak = "h1{}"
ui.styletweak.book_style_tweak_enabled = true
g_settings.style_tweaks = {
    ["footnote-inpage_epub"] = true,
    margin_body_0 = true,
    ["book_layout.css"] = true,
}
Assert.is_true(Layout.apply(ui, "off"))
Assert.eq(settings_data.book_reader_layout_id, "off")
Assert.eq(Layout.matchId(ui), "off")
Assert.is_nil(ui.styletweak.book_style_tweak)
Assert.eq(ui.styletweak.book_style_tweak_enabled, false)
Assert.is_true(ui.styletweak.doc_tweaks["footnote-inpage_epub"])
Assert.is_nil(ui.styletweak.doc_tweaks.margin_body_0)
Assert.is_nil(g_settings.style_tweaks.margin_body_0)
Assert.is_nil(g_settings.style_tweaks["book_layout.css"])
Assert.is_true(g_settings.style_tweaks["footnote-inpage_epub"])
Assert.eq(ui.font.configurable.font_size, 22)
Assert.eq(ui.font.configurable.line_spacing, 155)
Assert.is_true(css_written:find("disabled") ~= nil)

io.open = old_open
print("ui.reader.layout_spec: ok")
