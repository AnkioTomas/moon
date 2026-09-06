--[[-- 设置主菜单只暴露六个按任务归类的入口。 --]]

local Assert = require("support.assert")

local built_rows = {}
local shown_sub

package.preload["gettext"] = function() return function(text) return text end end
package.preload["ffi/util"] = function()
    return {
        template = function(text, value)
            return (text:gsub("%%1", tostring(value)))
        end,
    }
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
        pagePad = function() return 0 end,
        face = function() return {} end,
        muted = function() return 0 end,
        getScale = function() return 120 end,
        getGridMaxCols = function() return 4 end,
    }
end
package.preload["ui.components.pager"] = function()
    return {
        bandH = function() return 0 end,
        pack = function(items) return { items } end,
        clamp = function() return 1 end,
        frame = function(_, _, opts) return opts end,
    }
end
package.preload["ui.components.settingrow"] = function()
    return {
        build = function(_, opts)
            built_rows[#built_rows + 1] = opts
            return opts
        end,
    }
end
package.preload["utils.settings"] = function()
    return {
        activeSourceId = function() return "local" end,
    }
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
    return {
        sections = function() return {} end,
        popupRows = function() return {} end,
    }
end
package.preload["remote.ui"] = function() return { menuRows = function() return {} end } end
package.preload["ui.panel.settings"] = function()
    return {
        desktopEnabledCount = function() return 3 end,
        readerEnabledCount = function() return 2 end,
        desktopRows = function() return {} end,
        readerRows = function() return {} end,
    }
end
package.preload["ui.desktop.settings.maintenance"] = function()
    local function row(title)
        return function(width)
            return require("ui.components.settingrow").build(width, {
                kind = "action", title = title,
            })
        end
    end
    return {
        cacheRow = function() return row("清理缓存") end,
        debugLogRow = function() return row("调试日志") end,
        aboutRow = function() return row("关于") end,
        closeRow = function() return row("关闭桌面") end,
    }
end

local previous_settings = _G.G_reader_settings
_G.G_reader_settings = {
    readSetting = function(_, key)
        if key == "language" then return "zh_CN" end
        return nil
    end,
}

local desktop = {
    plugin = {},
    dimen = { w = 600 },
    _settings_page = 1,
    contentHeight = function() return 800 end,
    showSettingsSub = function(_, sub) shown_sub = sub end,
}

require("ui.desktop.settings").build(desktop)
Assert.len(built_rows, 10)

local expected = {
    ["书库与账号"] = "sources",
    ["阅读与工具"] = "reader",
    ["界面与首页"] = "appearance",
    ["锁屏"] = "lockscreen",
    ["语言与输入"] = "language",
    ["连接与服务"] = "services",
}
local categories = 0
for _, row in ipairs(built_rows) do
    local sub = expected[row.title]
    if sub then
        categories = categories + 1
        row.callback()
        Assert.eq(shown_sub, sub)
    end
end
Assert.eq(categories, 6)

for _, title in ipairs({ "清理缓存", "调试日志", "关于", "关闭桌面" }) do
    local found = false
    for _, row in ipairs(built_rows) do
        if row.title == title then found = true break end
    end
    Assert.is_true(found)
end

local function assertSubpageLink(page, title, target)
    built_rows = {}
    desktop._settings_sub = page
    require("ui.desktop.settings").build(desktop)
    for _, row in ipairs(built_rows) do
        if row.title == title then
            row.callback()
            Assert.eq(shown_sub, target)
            return
        end
    end
    Assert.is_true(false, "缺少设置入口: " .. title)
end

assertSubpageLink("reader", "阅读快捷面板", "quickpanel_reader")
assertSubpageLink("appearance", "桌面快捷面板", "quickpanel_desktop")

_G.G_reader_settings = previous_settings

return true
