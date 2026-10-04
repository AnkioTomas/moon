---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

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
package.preload["ui.themes"] = function()
    return { scale = function() return 120 end }
end
package.preload["ui.widgets.cover"] = function()
    return { gridCols = function() return 4 end }
end
--- 分组页：逐组逐行按页宽构建，记下分组标题。
local section_titles = {}
package.preload["ui.themes.widgets.sections"] = function()
    return {
        widget = function(opts)
            for _, section in ipairs(opts.sections) do
                section_titles[#section_titles + 1] = section.title
                for _, row in ipairs(section.rows) do row(opts.width) end
            end
            return { sections = opts.sections }, 1, 1
        end,
    }
end
package.preload["ui.themes.widgets.row"] = function()
    return {
        widget = function(opts)
            built_rows[#built_rows + 1] = opts
            return opts
        end,
    }
end
package.preload["utils.settings"] = function()
    return {
        activeSourceId = function() return "local" end,
        get = function() return { reader_popup_buttons = {}, ai_model = "" } end,
        feature = function(name) return require("features." .. name .. ".setting").defaults end,
        openOnStart = function() return false end,
    }
end
package.preload["ui.fonts"] = function()
    return { currentName = function() return "Noto Sans" end }
end
package.preload["features.lockscreen.settings"] = function()
    return { isCompose = function() return false end }
end
package.preload["features.remote"] = function()
    return { isRunning = function() return false end, status = function() return "关" end }
end
package.preload["source.registry"] = function()
    return {
        list = function() return { { id = "local", name = "本地" } } end,
        listEnabled = function() return { { id = "local", name = "本地" } } end,
    }
end
package.preload["ui/language"] = function()
    return { getLanguageName = function() return "简体中文" end }
end
package.preload["desktop.pages.setting.overlay"] = function()
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
package.preload["features.bars.preview"] = function()
    return { build = function() return { dimen = { h = 20 } } end }
end

package.preload["desktop.pages.setting.source"] = function()
    return {
        scopeSections = function() return {} end,
        configSections = function() return {} end,
        displayName = function(name) return name end,
    }
end
package.preload["desktop.pages.setting.display"] = function()
    return { rows = function() return {} end }
end
package.preload["features.lockscreen.page"] = function()
    return {
        rows = function() return {} end,
        preview = function() return { dimen = { h = 20 } } end,
    }
end
package.preload["desktop.pages.setting.desktop"] = function()
    return { rows = function() return {} end }
end
package.preload["desktop.pages.setting.topbar"] = function()
    return {
        rows = function() return {} end,
        preview = function() return { dimen = { h = 20 } } end,
    }
end
package.preload["desktop.pages.setting.language"] = function()
    return { sections = function() return {} end }
end
package.preload["desktop.pages.setting.ai"] = function()
    return { rows = function() return {} end }
end
package.preload["http.proxy.setting"] = function()
    return {
        entry = function()
            return {
                icon = "lan", title = "网络", subtitle = "HTTP 代理", status = "直连",
                page = { id = "network", title = "网络", sections = function() return {} end },
            }
        end,
    }
end
package.preload["desktop.pages.setting.reader"] = function()
    return {
        sections = function() return { { title = "行为", rows = {} } } end,
        lookupSections = function() return {} end,
        popupRows = function() return {} end,
    }
end
package.preload["features.bars.page"] = function()
    return {
        page = function()
            return { preview = function() return {} end, sections = {} }
        end,
    }
end
package.preload["features.remote.ui"] = function() return { menuRows = function() return {} end } end
package.preload["features.ime"] = function()
    return { isEnabled = function() return false end }
end
package.preload["features.animation"] = function()
    return { isEnabled = function() return false end }
end
package.preload["features.panel.settings"] = function()
    return {
        desktopEnabledCount = function() return 3 end,
        readerEnabledCount = function() return 2 end,
        desktopRows = function() return {} end,
        readerRows = function() return {} end,
        preview = function() return { dimen = { h = 20 } } end,
    }
end
package.preload["desktop.pages.setting.maintenance"] = function()
    local function row(title)
        return function(width)
            return require("ui.themes.widgets.row").widget({
                width = width, chevron = false, kind = "action", title = title,
            })
        end
    end
    return {
        cacheRow = function() return row("清理缓存") end,
        clearStatsRow = function() return row("清除当前源统计") end,
        debugLogRow = function() return row("调试日志") end,
        autoUpdateRow = function() return row("自动检查更新") end,
        updateRow = function() return row("检查更新") end,
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
    contentHeight = function() return 800 end,
    updateView = function() end,
}
local settings = require("desktop.pages.setting"):new{ desktop = desktop }
desktop.settings = settings
settings:updateView()
Assert.len(built_rows, 27)
Assert.eq(table.concat(section_titles, ","), "书库,桌面,阅读,系统,维护")

local expected = {
    { title = "书籍来源", id = "sources" },
    { title = "账号与登录", id = "source_config" },
    { title = "界面显示", id = "display" },
    { title = "桌面顶栏", id = "topbar" },
    { title = "桌面快捷面板", id = "quickpanel_desktop" },
    { title = "锁屏壁纸", id = "feature:lockscreen:main" },
    { title = "阅读行为", id = "reader_behavior" },
    { title = "划词与查询", id = "lookup" },
    { title = "阅读快捷面板", id = "quickpanel_reader" },
    { title = "阅读页顶栏", id = "feature:bars:top" },
    { title = "阅读页底栏", id = "feature:bars:bottom" },
    { title = "侧栏手势", id = "feature:sidebar:main" },
    { title = "翻页动画", id = "feature:animation:main" },
    { title = "月读词典", id = "feature:dictionary:main" },
    { title = "百度百科", id = "feature:baike:main" },
    { title = "语言", id = "language" },
    { title = "AI 接口", id = "ai" },
    { title = "网络", id = "network" },
    { title = "中文输入法增强", id = "feature:ime:main" },
    { title = "远程管理", id = "feature:remote:main" },
}
local nav = 1
for _, row in ipairs(built_rows) do
    local item = expected[nav]
    if item and row.title == item.title and row.kind == "nav" then
        Assert.is_true(type(row.subtitle) == "string" and row.subtitle ~= "", item.title .. " 缺副标题")
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

local behavior = settings:spec("reader_behavior")
Assert.eq(behavior.title, "阅读行为")
Assert.is_nil(behavior.preview)
Assert.eq(#behavior.sections(), 1)

local lookup = settings:spec("lookup")
Assert.eq(lookup.title, "划词与查询")
Assert.is_nil(lookup.preview)
Assert.eq(#lookup.sections(), 1)

local display = settings:spec("display")
Assert.eq(display.title, "界面显示")
Assert.is_nil(display.preview)

_G.G_reader_settings = previous_settings

return true
