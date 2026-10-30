---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

--[[-- 设置根页：搜索 + 分组目录；点分组进叠层列条目，阅读组再分三类。 --]]

local Assert = require("support.assert")

local built_rows = {}
local opened

package.preload["gettext"] = function()
    return setmetatable({ current_lang = "C", translation = {} }, {
        __call = function(_self, text) return text end,
    })
end
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
        get = function(owner)
            if owner:match("^features%.") then return require(owner .. ".setting").defaults end
            return { reader_popup_buttons = {}, ai_model = "" }
        end,
    }
end
package.preload["menu"] = function()
    return { openOnStart = function() return false end }
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
        activeId = function() return "local" end,
        list = function() return { { id = "local", name = "本地" } } end,
        listEnabled = function() return { { id = "local", name = "本地" } } end,
        registerHidden = function() end,
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
            opened = spec
        end,
        push = function(_, spec)
            opened = spec
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
        configSections = function() return {} end,
        displayName = function(name) return name end,
    }
end
package.preload["desktop.pages.setting.display"] = function()
    return { appearanceRows = function() return {} end, screenRows = function() return { function() end } end }
end
package.preload["features.nightmode.page"] = function()
    return { rows = function() return {} end }
end
package.preload["features.lockscreen.page"] = function()
    return {
        rows = function() return {} end,
        preview = function() return { dimen = { h = 20 } } end,
    }
end
package.preload["features.wallpaper"] = function()
    return { anyEnabled = function() return false end }
end
package.preload["features.wallpaper.page"] = function()
    return {
        spec = function() return { title = "wallpaper", sections = function() return {} end } end,
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
    return {
        row = function()
            return function(width)
                return require("ui.themes.widgets.row").widget({ width = width, kind = "nav", title = "语言" })
            end
        end,
    }
end
package.preload["desktop.pages.setting.ai"] = function()
    return { rows = function() return {} end }
end
package.preload["desktop.pages.setting.device"] = function()
    return { rows = function() return {} end }
end
package.preload["http.proxy.setting"] = function()
    return {
        entry = function()
            return {
                id = "network", icon = "lan", title = "网络", subtitle = "HTTP 代理", status = "直连",
                page = { title = "网络", sections = function() return {} end },
            }
        end,
    }
end
package.preload["desktop.pages.setting.reader"] = function()
    return {
        sections = function() return { { title = "行为", rows = {} } } end,
        lookupSections = function() return { { title = "选区", rows = {} } } end,
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
package.preload["features.ime"] = function()
    return { isEnabled = function() return false end }
end
package.preload["features.animation"] = function()
    return { isEnabled = function() return false end }
end
package.preload["features.panel.settings"] = function()
    return {
        enabledCount = function(scope) return scope == "desktop" and 3 or 2 end,
        rows = function() return {} end,
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
        clearStatsRow = function() return row("清除当前源统计") end,
        importKoreaderStatsRow = function() return row("导入 KOReader 统计") end,
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
    nilOrTrue = function() return true end,
}

local desktop = {
    plugin = { path = _G.BOOK_TEST_ROOT .. "/book.koplugin" },
    dimen = { w = 600 },
    contentHeight = function() return 800 end,
    updateView = function() end,
}
-- 真机由 main.lua 调 features 加载器：订阅分组由订阅 init 登记，设置条目由加载器代登记
require("features.subscribe")
require("features").registerConventions()
local settings = require("desktop.pages.setting"):new{ desktop = desktop }
desktop.settings = settings
settings:updateView()
-- 根页：搜索 + 8 个分组（含订阅扩展组），条目不直接铺开。
Assert.eq(table.concat(section_titles, ","), "搜索,分类")
Assert.len(built_rows, 9)
Assert.eq(built_rows[1].title, "搜索设置")
local root_groups = {}
for i = 2, #built_rows do root_groups[#root_groups + 1] = built_rows[i].title end
Assert.eq(table.concat(root_groups, ","), "书库,订阅,外观,桌面,阅读,系统,安全,维护")

local function sectionTitles(page)
    local titles = {}
    for _, section in ipairs(page.sections()) do titles[#titles + 1] = section.title end
    return table.concat(titles, ",")
end

local function openRoot(title)
    for _, row in ipairs(built_rows) do
        if row.title == title then
            row.callback()
            return opened
        end
    end
    error("missing root group " .. title)
end

local function buildSectionRows(page)
    local before = #built_rows
    for _, section in ipairs(page.sections()) do
        for _, build in ipairs(section.rows) do build(600) end
    end
    local rows = {}
    for i = before + 1, #built_rows do rows[#rows + 1] = built_rows[i] end
    return rows
end

-- 书库组：当前书库 / 账号 / 书架显示（功能开关在维护）
local library = openRoot("书库")
Assert.eq(library.id, "group:library")
local library_rows = buildSectionRows(library)
local library_titles = {}
for _, row in ipairs(library_rows) do library_titles[#library_titles + 1] = row.title end
Assert.eq(table.concat(library_titles, ","), "当前书库,账号,书架显示")

-- 订阅组：两行开关仍在组内（不再铺在根页）
local subscribe = openRoot("订阅")
Assert.eq(subscribe.id, "group:subscribe")
local sub_rows = buildSectionRows(subscribe)
Assert.eq(sub_rows[1].title .. "," .. sub_rows[2].title, "启用订阅,下载文章图片")

-- 阅读组：先出三类目录
local reader = openRoot("阅读")
Assert.eq(reader.id, "group:reader")
Assert.eq(sectionTitles(reader), "分类")
local reader_folders = buildSectionRows(reader)
local folder_titles = {}
for _, row in ipairs(reader_folders) do folder_titles[#folder_titles + 1] = row.title end
Assert.eq(table.concat(folder_titles, ","), "阅读界面,划词与词典,智能")

-- 阅读界面：含字体映射开关与阅读行为等
reader_folders[1].callback()
Assert.eq(opened.id, "group:reader:ui")
local ui_rows = buildSectionRows(opened)
local fontmap_row, behavior_row
local ui_titles = {}
for _, row in ipairs(ui_rows) do
    ui_titles[#ui_titles + 1] = row.title
    if row.title == "书内字体映射" then fontmap_row = row end
    if row.title == "阅读行为" then behavior_row = row end
end
Assert.is_true(fontmap_row ~= nil, "阅读界面应含字体映射")
Assert.eq(fontmap_row.kind, "toggle")
Assert.eq(fontmap_row.status_on, false)
Assert.is_true(behavior_row ~= nil)
Assert.is_true(table.concat(ui_titles, ","):find("翻页动画", 1, true) ~= nil)
Assert.is_true(table.concat(ui_titles, ","):find("阅读快捷面板", 1, true) ~= nil)
Assert.is_nil((function()
    for _, t in ipairs(ui_titles) do if t == "查词" or t == "X-Ray" or t == "AI 接口" then return t end end
end)())

-- 划词与词典 / 智能 分类内容
reader_folders[2].callback()
Assert.eq(opened.id, "group:reader:lookup")
local lookup_rows = buildSectionRows(opened)
local lookup_titles = {}
for _, row in ipairs(lookup_rows) do lookup_titles[#lookup_titles + 1] = row.title end
Assert.eq(table.concat(lookup_titles, ","), "翻译,词典,百科,文字识别（OCR）,查词,划词菜单,生僻字注音")

reader_folders[3].callback()
Assert.eq(opened.id, "group:reader:smart")
local smart_rows = buildSectionRows(opened)
local smart_titles = {}
for _, row in ipairs(smart_rows) do smart_titles[#smart_titles + 1] = row.title end
Assert.eq(table.concat(smart_titles, ","), "X-Ray,段评,AI 接口")

-- 组内导航 push 进具体页面，第三层分节仍在
behavior_row.callback()
Assert.eq(opened.id, "reader_behavior")
Assert.eq(opened.title, "阅读行为")
Assert.is_nil(opened.preview)
Assert.eq(sectionTitles(opened), "行为")

-- 外观组里的屏幕页仍带夜间分节；维护组含更新与关闭桌面
local appearance = openRoot("外观")
local appearance_rows = buildSectionRows(appearance)
local display_row
for _, row in ipairs(appearance_rows) do
    if row.title == "屏幕" then display_row = row end
end
display_row.callback()
Assert.eq(opened.id, "display")
Assert.eq(sectionTitles(opened), "屏幕,夜间与亮度")

local maintenance = openRoot("维护")
local maintenance_rows = buildSectionRows(maintenance)
local maintenance_titles = {}
for _, row in ipairs(maintenance_rows) do maintenance_titles[#maintenance_titles + 1] = row.title end
Assert.eq(maintenance_titles[1], "功能开关", "功能开关排在维护组最前")
for _, title in ipairs({
    "功能开关", "存储空间", "清除当前源统计", "导入 KOReader 统计", "自动检查更新", "检查更新", "调试日志", "关于", "关闭桌面",
}) do
    Assert.is_true(table.concat(maintenance_titles, ","):find(title, 1, true) ~= nil, title)
end

_G.G_reader_settings = previous_settings

return true
