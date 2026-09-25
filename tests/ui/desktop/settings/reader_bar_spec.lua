--[[-- 阅读页栏组合页：预览 + 替代/开启 + 组件。 --]]

local Assert = require("support.assert")

package.preload["gettext"] = function() return function(text) return text end end
package.preload["ffi/util"] = function()
    return { template = function(text, value) return (text:gsub("%%1", tostring(value))) end }
end
package.preload["ui.components.settingrow"] = function()
    return { build = function(_, opts) return opts end }
end
package.preload["ui/widget/buttondialog"] = function()
    return { new = function(_, o) return o end }
end
package.preload["ui/uimanager"] = function()
    return { show = function() end, close = function() end, setDirty = function() end }
end
package.preload["ui.reader.bars"] = function()
    return {
        topBarPreference = function() return true end,
        bottomBarPreference = function() return false end,
        setTopBarPreference = function() end,
        setBottomBarPreference = function() end,
    }
end
package.preload["ui.reader.bars.items"] = function()
    return {
        catalog = function(which)
            if which == "top" then
                return { { id = "chapter", label = "章节", icon = "menu_book" } }
            end
            return { { id = "percent", label = "进度", icon = "percent" } }
        end,
    }
end
package.preload["ui.reader.bars.layout"] = function()
    return {
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
package.preload["ui.reader.bars.preview"] = function()
    return { build = function(width, which) return { kind = "preview", width = width, which = which } end }
end

local ReaderBar = require("ui.desktop.settings.reader_bar")
local desktop = { updateView = function() end, settings = {} }
local page = ReaderBar:page(desktop, "top")
Assert.eq(page.preview(600).kind, "preview")
Assert.eq(page.preview(600).which, "top")
Assert.eq(#page.sections, 2)
Assert.eq(page.sections[1].title, "显示")
Assert.eq(page.sections[1].rows[1](600).title, "替代系统顶栏")
Assert.eq(page.sections[1].rows[2](600).title, "开启顶栏")
Assert.is_true(page.sections[1].rows[2](600).status_on)
Assert.eq(page.sections[2].title, "组件")
Assert.eq(page.sections[2].rows[1](600).title, "章节")
Assert.eq(page.sections[2].rows[1](600).status, "左 · 第 1 位")

local bottom = ReaderBar:page(desktop, "bottom")
Assert.eq(bottom.sections[1].rows[1](600).title, "替代系统底栏")
Assert.eq(bottom.sections[1].rows[2](600).title, "开启底栏")
Assert.is_false(bottom.sections[1].rows[2](600).status_on)

return true
