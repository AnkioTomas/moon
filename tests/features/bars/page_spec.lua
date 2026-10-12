---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

--[[-- 阅读页栏组合页：预览 + 替代/开启 + 组件。 --]]

local Assert = require("support.assert")

package.preload["gettext"] = function() return function(text) return text end end
package.preload["ffi/util"] = function()
    return { template = function(text, value) return (text:gsub("%%1", tostring(value))) end }
end
package.preload["ui.themes.widgets.row"] = function()
    return { widget = function(opts) return opts end }
end
package.preload["ui/widget/buttondialog"] = function()
    return { new = function(_, o) return o end }
end
require("support.theme_stubs").install()
package.preload["ui/uimanager"] = function()
    return { show = function() end, close = function() end, setDirty = function() end }
end
local bottom_calls = {}
package.preload["features.bars"] = function()
    return {
        topBarPreference = function() return true end,
        bottomBarPreference = function() return false end,
        setTopBarPreference = function() end,
        setBottomBarPreference = function(enabled, ui)
            bottom_calls[#bottom_calls + 1] = { enabled = enabled, ui = ui }
        end,
    }
end
local ReaderUIStub = { instance = nil }
package.preload["apps/reader/readerui"] = function() return ReaderUIStub end
package.preload["features.bars.items"] = function()
    return {
        catalog = function(which)
            if which == "top" then
                return { { id = "chapter", label = "章节", icon = "menu_book" } }
            end
            return { { id = "percent", label = "进度", icon = "percent" } }
        end,
    }
end
local icons_on = true
package.preload["features.bars.layout"] = function()
    return {
        icons = function() return icons_on end,
        setIcons = function(on) icons_on = on end,
        replace = function() return true end,
        setReplace = function() end,
        get = function() return { { id = "chapter", align = "left" } } end,
        slot = function(_, id)
            if id == "chapter" then return 1, "left" end
            return nil, nil
        end,
        toggle = function() end,
        move = function() end,
        setAlign = function() end,
    }
end
package.preload["features.bars.preview"] = function()
    return { build = function(width, which) return { kind = "preview", width = width, which = which } end }
end

local ReaderBar = require("features.bars.page")
local desktop = { updateView = function() end, settings = {} }
local page = ReaderBar:page(desktop, "top")
Assert.eq(page.preview(600).kind, "preview")
Assert.eq(page.preview(600).which, "top")
Assert.eq(#page.sections, 2)
Assert.eq(page.sections[1].title, "显示")
Assert.eq(page.sections[1].rows[1](600).title, "替代系统顶栏")
Assert.eq(page.sections[1].rows[2](600).title, "开启顶栏")
Assert.is_true(page.sections[1].rows[2](600).status_on)
Assert.eq(page.sections[1].rows[3](600).title, "组件图标")
Assert.is_true(page.sections[1].rows[3](600).status_on)
page.sections[1].rows[3](600).callback()
Assert.is_false(icons_on, "点一下关掉图标")
Assert.is_false(page.sections[1].rows[3](600).status_on)
Assert.eq(page.sections[2].title, "组件")
Assert.eq(page.sections[2].rows[1](600).title, "章节")
Assert.eq(page.sections[2].rows[1](600).status, "左 · 第 1 位")

local bottom = ReaderBar:page(desktop, "bottom")
Assert.eq(bottom.sections[1].rows[1](600).title, "替代系统底栏")
Assert.eq(bottom.sections[1].rows[2](600).title, "开启底栏")
Assert.is_false(bottom.sections[1].rows[2](600).status_on)

-- 关书时 closeDocument 已清 document、instance 尚未清：不得把半死的 ReaderUI 交给底栏
-- （否则 ReaderFooter:genFooterText 索引 ui.document 崩溃）；偏好仍照常写入
ReaderUIStub.instance = { document = nil, dialog = {} }
bottom.sections[1].rows[2](600).callback()
Assert.len(bottom_calls, 1)
Assert.is_true(bottom_calls[1].enabled)
Assert.is_nil(bottom_calls[1].ui)

local live = { document = {}, dialog = {} }
ReaderUIStub.instance = live
bottom.sections[1].rows[2](600).callback()
Assert.eq(bottom_calls[2].ui, live)

return true
