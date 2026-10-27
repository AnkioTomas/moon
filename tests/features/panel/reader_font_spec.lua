--[[-- 阅读字体快捷动作离线用例。
@module tests.features.panel.reader_font_spec
--]]

local Assert = require("support.assert")
local reader_settings = { mixed_fonts = false }
package.preload["utils.settings"] = function() return { get = function() return reader_settings end } end

package.preload["l10n"] = function() return { apply = function() end } end
package.preload["gettext"] = function() return function(value) return value end end
package.preload["ffi/util"] = function()
    return { template = function(fmt, a1) return fmt:gsub("%%1", tostring(a1)) end }
end

local picker_opts
package.preload["ui.widgets.fontpicker"] = function()
    return { open = function(opts) picker_opts = opts end }
end

local applied
package.preload["ui.fonts.reader"] = function()
    return {
        supports = function(ui)
            return ui and ui.font ~= nil and type(ui.document) == "table"
                and type(ui.document.setFontFace) == "function"
        end,
        currentId = function() return "demo.ttf" end,
        westernPickerOpts = function(ui) return { title = "西文字体", ui = ui } end,
        apply = function(_ui, id, name)
            applied = { id = id, name = name }
            return true
        end,
    }
end

local captured
package.preload["reader.prefs"] = function()
    return { captureAndSave = function(ui) captured = ui end }
end

package.preload["ui/uimanager"] = function()
    return { show = function() end }
end
local Themed = require("support.theme_stubs")
Themed.install()

package.loaded["features.panel.actions.reader.font"] = nil
package.loaded["ui.widgets.fontpicker"] = nil
local FontAction = require("features.panel.actions.reader.font")

local reader_ui = {
    font = {},
    document = { setFontFace = function() end },
    doc_settings = {},
}

Assert.is_true(FontAction.available({ ui = reader_ui }))
Assert.is_true(FontAction.available({ ui = nil }))
Assert.is_false(FontAction.available({ ui = { document = {} } }))

FontAction.run({ ui = reader_ui })
Assert.eq(picker_opts.title, "阅读字体", "关闭分开时直接打开普通字体列表")
Assert.is_nil(Themed.last("sheet"), "关闭时没有中西文选择菜单")
reader_settings.mixed_fonts = true
FontAction.run({ ui = reader_ui })
local sheet = Themed.last("sheet")
Assert.eq(sheet.items[1].text, "中文字体")
Assert.eq(sheet.items[2].text, "西文字体")
sheet.items[1].callback()
Assert.eq(picker_opts.title, "中文字体")
Assert.eq(picker_opts.current_id(), "demo.ttf")
picker_opts.on_select({ id = "demo.ttf", name = "Demo" }, "demo.ttf", "Demo")
Assert.eq(applied.id, "demo.ttf")
Assert.eq(applied.name, "Demo")
-- 应用成功后由动作（而不是 ui 层）把全书排版偏好落库
Assert.eq(captured, reader_ui)
sheet.items[2].callback()
Assert.eq(picker_opts.title, "西文字体")
Assert.eq(picker_opts.ui, reader_ui)
reader_settings.mixed_fonts = false
Assert.eq(FontAction.pickerOpts(reader_ui).title, "阅读字体", "再次关闭后回到普通字体入口")
