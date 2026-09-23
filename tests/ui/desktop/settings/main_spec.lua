--[[-- 设置根页按功能分组，点击打开叠层。 --]]

local Assert = require("support.assert")

local built_rows = {}
local opened

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
    "ui/widget/verticalgroup",
    "ui/widget/verticalspan",
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
        frame = function(w, h, opts)
            opts.getSize = function() return { w = w, h = h } end
            return opts
        end,
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
        get = function() return { reader_popup_buttons = {}, ai_model = "" } end,
    }
end
package.preload["utils.font"] = function()
    return { currentName = function() return "Noto Sans" end }
end
package.preload["lockscreen.settings"] = function()
    return { isCompose = function() return false end }
end
package.preload["remote.init"] = function()
    return { isRunning = function() return false end, status = function() return "关" end }
end
package.preload["source.registry"] = function()
    return {
        list = function() return { { id = "local", name = "本地" } } end,
        listEnabled = function() return { { id = "local", name = "本地" } } end,
    }
end
package.preload["host"] = function() return { OPEN_ON_START_ID = "book" } end
package.preload["ui/language"] = function()
    return { getLanguageName = function() return "简体中文" end }
end
package.preload["ui.desktop.settings.overlay"] = function()
    return {
        appendSection = function(_, _, _, row_builders)
            for _, build in ipairs(row_builders or {}) do
                build(600)
            end
        end,
        open = function(_, spec)
            opened = spec and spec.id
        end,
        close = function() end,
        previewBox = function() return { dimen = { h = 20 } } end,
        previewPlaceholder = function() return { dimen = { h = 20 } } end,
    }
end
package.preload["ui.reader.bars.preview"] = function()
    return { build = function() return { dimen = { h = 20 } } end }
end

local function pageMod(api)
    return { new = function() return api end }
end
package.preload["ui.desktop.settings.source"] = function()
    return {
        new = function()
            return {
                scopeSections = function() return {} end,
                configSections = function() return {} end,
            }
        end,
        displayName = function(name) return name end,
    }
end
package.preload["ui.desktop.settings.display"] = function()
    return pageMod({ rows = function() return {} end })
end
package.preload["ui.desktop.settings.lockscreen"] = function()
    return pageMod({
        rows = function() return {} end,
        preview = function() return { dimen = { h = 20 } } end,
    })
end
package.preload["ui.desktop.settings.desktop"] = function()
    return pageMod({ rows = function() return {} end })
end
package.preload["ui.desktop.settings.topbar"] = function()
    return pageMod({
        rows = function() return {} end,
        preview = function() return { dimen = { h = 20 } } end,
    })
end
package.preload["ui.desktop.settings.language"] = function()
    return pageMod({ sections = function() return {} end })
end
package.preload["ui.desktop.settings.ai"] = function()
    return pageMod({ rows = function() return {} end })
end
package.preload["ui.desktop.settings.reader"] = function()
    return pageMod({
        sections = function() return {} end,
        lookupSections = function() return {} end,
        popupRows = function() return {} end,
    })
end
package.preload["ui.desktop.settings.reader_bar"] = function()
    return pageMod({
        page = function()
            return { preview = function() return {} end, sections = {} }
        end,
    })
end
package.preload["remote.ui"] = function() return { menuRows = function() return {} end } end
package.preload["ui.panel.settings"] = function()
    return {
        desktopEnabledCount = function() return 3 end,
        readerEnabledCount = function() return 2 end,
        desktopRows = function() return {} end,
        readerRows = function() return {} end,
        preview = function() return { dimen = { h = 20 } } end,
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
    return pageMod({
        cacheRow = function() return row("清理缓存") end,
        debugLogRow = function() return row("调试日志") end,
        autoUpdateRow = function() return row("自动检查更新") end,
        updateRow = function() return row("检查更新") end,
        aboutRow = function() return row("关于") end,
        closeRow = function() return row("关闭桌面") end,
    })
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
    contentHeight = function() return 800 end,
    updateView = function() end,
}
local settings = require("ui.desktop.settings"):new{ desktop = desktop }
desktop.settings = settings
settings:updateView()
Assert.len(built_rows, 19)

local expected = {
    { title = "书籍来源", id = "sources" },
    { title = "账号", id = "source_config" },
    { title = "显示", id = "display" },
    { title = "顶栏", id = "topbar" },
    { title = "锁屏", id = "lockscreen" },
    { title = "快捷", id = "quickpanel_desktop" },
    { title = "顶栏", id = "reader_top" },
    { title = "底栏", id = "reader_bottom" },
    { title = "划词", id = "lookup" },
    { title = "快捷", id = "quickpanel_reader" },
    { title = "语言", id = "language" },
    { title = "AI", id = "ai" },
    { title = "远程", id = "remote" },
}
local nav = 1
for _, row in ipairs(built_rows) do
    local item = expected[nav]
    if item and row.title == item.title and row.kind == "nav" then
        row.callback()
        Assert.eq(opened, item.id)
        nav = nav + 1
    end
end
Assert.eq(nav, #expected + 1)

for _, title in ipairs({
    "清理缓存", "调试日志", "自动检查更新", "检查更新", "关于", "关闭桌面",
}) do
    local found = false
    for _, row in ipairs(built_rows) do
        if row.title == title then found = true break end
    end
    Assert.is_true(found)
end

local spec = settings:spec("reader_top")
Assert.eq(spec.title, "顶栏")
Assert.not_nil(spec.preview)
Assert.not_nil(spec.sections)
Assert.eq(#spec.sections(), 0)

local lookup = settings:spec("lookup")
Assert.eq(lookup.title, "划词")
Assert.is_nil(lookup.preview)
Assert.eq(#lookup.sections(), 1)

local display = settings:spec("display")
Assert.eq(display.title, "显示")
Assert.is_nil(display.preview)

_G.G_reader_settings = previous_settings

return true
