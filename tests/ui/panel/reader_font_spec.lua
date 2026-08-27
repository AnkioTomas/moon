--[[-- 阅读字体快捷动作离线用例。
@module tests.ui.panel.reader_font_spec
--]]

local Assert = require("support.assert")

package.preload["l10n"] = function() return { apply = function() end } end
package.preload["gettext"] = function() return function(value) return value end end
package.preload["ffi/util"] = function()
    return { template = function(fmt, a1) return fmt:gsub("%%1", tostring(a1)) end }
end

local picker_opts
package.preload["ui.components.fontpicker"] = function()
    return { open = function(opts) picker_opts = opts end }
end

local applied
package.preload["utils.font"] = function()
    return {
        supportsReader = function(ui)
            return ui and ui.font ~= nil and type(ui.document) == "table"
                and type(ui.document.setFontFace) == "function"
        end,
        readerCurrentId = function() return "demo.ttf" end,
        applyToReader = function(_ui, id, name)
            applied = { id = id, name = name }
            return true
        end,
    }
end

package.preload["ui/uimanager"] = function()
    return { show = function() end }
end
package.preload["ui/widget/infomessage"] = function()
    return { new = function() return {} end }
end

package.loaded["ui.panel.actions.reader.font"] = nil
package.loaded["ui.components.fontpicker"] = nil
local FontAction = require("ui.panel.actions.reader.font")

local reader_ui = {
    font = {},
    document = { setFontFace = function() end },
    doc_settings = {},
}

Assert.is_true(FontAction.available({ ui = reader_ui }))
Assert.is_true(FontAction.available({ ui = nil }))
Assert.is_false(FontAction.available({ ui = { document = {} } }))

FontAction.run({ ui = reader_ui })
Assert.eq(picker_opts.title, "阅读字体")
Assert.eq(picker_opts.current_id(), "demo.ttf")
picker_opts.on_select({ id = "demo.ttf", name = "Demo" }, "demo.ttf", "Demo")
Assert.eq(applied.id, "demo.ttf")
Assert.eq(applied.name, "Demo")
