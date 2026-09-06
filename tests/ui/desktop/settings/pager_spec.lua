--[[-- 设置页 Pager.pack 必须扣除内容区内边距，避免裁切却仍显示 1/1。 --]]

local Assert = require("support.assert")

local packed_h

package.preload["gettext"] = function() return function(text) return text end end
package.preload["ffi/util"] = function()
    return { template = function(text, value) return (text:gsub("%%1", tostring(value))) end }
end
package.preload["ffi/blitbuffer"] = function() return { COLOR_WHITE = 1 } end
package.preload["ui/geometry"] = function()
    return { new = function(_, opts) return opts end }
end

for _, name in ipairs({
    "ui/widget/container/framecontainer",
    "ui/widget/container/leftcontainer",
    "ui/widget/verticalgroup",
    "ui/widget/verticalspan",
    "ui/widget/textwidget",
}) do
    package.preload[name] = function()
        return { new = function(_, opts) return opts or {} end }
    end
end

package.preload["ui.components.bookui"] = function()
    return {
        sz = function(value) return value end,
        sectionGap = function() return 12 end,
        pagePad = function() return 16 end,
        face = function() return {} end,
        muted = function() return 0 end,
        getScale = function() return 120 end,
        getGridMaxCols = function() return 4 end,
    }
end
package.preload["ui.components.pager"] = function()
    return {
        bandH = function() return 50 end,
        pack = function(items, height)
            packed_h = height
            return { items }
        end,
        clamp = function() return 1 end,
        frame = function(_, _, opts) return opts end,
    }
end
package.preload["ui.components.settingrow"] = function()
    return { build = function(_, opts) return opts end }
end
package.preload["utils.settings"] = function()
    return { activeSourceId = function() return "local" end }
end
package.preload["utils.font"] = function()
    return { currentName = function() return "Noto Sans" end }
end
package.preload["lockscreen.settings"] = function()
    return { isCompose = function() return false end }
end
package.preload["remote.init"] = function()
    return { isRunning = function() return false end }
end
package.preload["source.registry"] = function()
    return { list = function() return { { id = "local", name = "本地" } } end }
end
package.preload["host"] = function() return { OPEN_ON_START_ID = "book" } end
package.preload["ui/language"] = function()
    return { getLanguageName = function() return "简体中文" end }
end
package.preload["ui.desktop.settings.source"] = function() return { sections = function() return {} end } end
package.preload["ui.desktop.settings.display"] = function() return { rows = function() return {} end } end
package.preload["ui.desktop.settings.lockscreen"] = function() return { rows = function() return {} end } end
package.preload["ui.desktop.settings.desktop"] = function() return { rows = function() return {} end } end
package.preload["ui.desktop.settings.home"] = function() return { sections = function() return {} end } end
package.preload["ui.desktop.settings.topbar"] = function() return { rows = function() return {} end } end
package.preload["ui.desktop.settings.language"] = function() return { rows = function() return {} end } end
package.preload["ui.desktop.settings.ai"] = function() return { rows = function() return {} end } end
package.preload["ui.desktop.settings.reader"] = function()
    return { sections = function() return {} end, popupRows = function() return {} end }
end
package.preload["remote.ui"] = function() return { menuRows = function() return {} end } end
package.preload["ui.panel.settings"] = function()
    return {
        desktopEnabledCount = function() return 1 end,
        readerEnabledCount = function() return 1 end,
        desktopRows = function() return {} end,
        readerRows = function() return {} end,
    }
end
package.preload["ui.desktop.settings.maintenance"] = function()
    local function row()
        return function() return {} end
    end
    return {
        cacheRow = row, debugLogRow = row, autoUpdateRow = row,
        updateRow = row, aboutRow = row, closeRow = row,
    }
end

local previous_settings = _G.G_reader_settings
_G.G_reader_settings = {
    readSetting = function() return nil end,
}

require("ui.desktop.settings").build({
    plugin = {},
    dimen = { w = 600 },
    _settings_page = 1,
    contentHeight = function() return 800 end,
    showSettingsSub = function() end,
})

-- 800 内容高 - 50 分页带 - 16 顶边距 - 4 底边距
Assert.eq(packed_h, 730)

_G.G_reader_settings = previous_settings

return true
