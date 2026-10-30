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
        storeSections = function() return { { title = "书城", rows = {} } } end,
        displayName = function(name) return name end,
    }
end
package.preload["desktop.pages.setting.display"] = function()
    return { appearanceSections = function() return {} end, screenRows = function() return { function() end } end }
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
    return {
        rows = function() return {} end,
        tabbarLabelsRow = function()
            return function(width)
                return require("ui.themes.widgets.row").widget({
                    width = width, icon = "label", title = "底部导航名称", toggle = true,
                })
            end
        end,
    }
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
-- 真机由 main.lua 调 features 加载器：订阅设置条目由加载器代登记（挂桌面组）
require("features.subscribe")
require("features").registerConventions()
local settings = require("desktop.pages.setting"):new{ desktop = desktop }
desktop.settings = settings
settings:updateView()
-- 根页：搜索 + 非空分组（空的「游戏」组不显示），条目不直接铺开。
Assert.eq(table.concat(section_titles, ","), "搜索,分类")
Assert.len(built_rows, 8)
Assert.eq(built_rows[1].title, "搜索设置")
local root_groups = {}
for i = 2, #built_rows do root_groups[#root_groups + 1] = built_rows[i].title end
Assert.eq(table.concat(root_groups, ","), "书库,外观,桌面,阅读,系统,安全,维护")

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

-- 书库组：启用的书源（多选）/ 当前书库 / 账号（书架显示已迁到桌面 → 图书馆）
local library = openRoot("书库")
Assert.eq(library.id, "group:library")
local library_rows = buildSectionRows(library)
local library_titles = {}
for _, row in ipairs(library_rows) do library_titles[#library_titles + 1] = row.title end
Assert.eq(table.concat(library_titles, ","), "启用的书源,当前书库,账号")

-- 阅读组：同一页三个分节，不再多点一层分类
local reader = openRoot("阅读")
Assert.eq(reader.id, "group:reader")
Assert.eq(sectionTitles(reader), "阅读界面,划词与词典,智能")
local fontmap_row, behavior_row, lookup_titles, smart_titles = nil, nil, {}, {}
local section_of = {}
for _, section in ipairs(reader.sections()) do
    for _, build in ipairs(section.rows) do
        local row = build(600)
        section_of[row.title] = section.title
        if section.title == "阅读界面" then
            if row.title == "书内字体映射" then fontmap_row = row end
            if row.title == "阅读行为" then behavior_row = row end
        elseif section.title == "划词与词典" then
            lookup_titles[#lookup_titles + 1] = row.title
        else
            smart_titles[#smart_titles + 1] = row.title
        end
    end
end
Assert.is_true(fontmap_row ~= nil, "阅读界面应含字体映射")
Assert.eq(fontmap_row.kind, "toggle")
Assert.eq(fontmap_row.status_on, false)
Assert.is_true(behavior_row ~= nil)
Assert.eq(section_of["段评"], "阅读界面")
Assert.eq(section_of["翻译"], "智能")
Assert.eq(table.concat(lookup_titles, ","), "词典,百科,文字识别（OCR）,查词,划词菜单,行间标注")
Assert.eq(table.concat(smart_titles, ","), "X-Ray,翻译,AI 接口")

behavior_row.callback()
Assert.eq(opened.id, "reader_behavior")
Assert.eq(opened.title, "阅读行为")
Assert.is_nil(opened.preview)
Assert.eq(sectionTitles(opened), "行为")

-- 外观平铺；桌面 / 系统 / 维护是分节平铺（不是分类导航）
local appearance = openRoot("外观")
local appearance_rows = buildSectionRows(appearance)
local appearance_titles, display_row = {}, nil
for _, row in ipairs(appearance_rows) do
    appearance_titles[#appearance_titles + 1] = row.title
    if row.title == "屏幕" then display_row = row end
end
Assert.is_true(table.concat(appearance_titles, ","):find("主题与字体", 1, true) ~= nil)
display_row.callback()
Assert.eq(opened.id, "display")
Assert.eq(sectionTitles(opened), "屏幕,夜间与亮度")

local desk = openRoot("桌面")
Assert.eq(desk.id, "group:desktop")
Assert.eq(sectionTitles(desk), "顶栏与底栏,页面,快捷面板")
local desk_by_section = {}
for _, section in ipairs(desk.sections()) do
    local titles = {}
    for _, build in ipairs(section.rows) do titles[#titles + 1] = build(600).title end
    desk_by_section[section.title] = table.concat(titles, ",")
end
Assert.eq(desk_by_section["顶栏与底栏"]:sub(1, #"底部导航名称"), "底部导航名称")
Assert.is_true(desk_by_section["顶栏与底栏"]:find("桌面顶栏", 1, true) ~= nil)
Assert.eq(desk_by_section["页面"], "图书馆,订阅,书城,统计")
Assert.is_true(desk_by_section["快捷面板"]:find("桌面快捷面板", 1, true) ~= nil)

-- 订阅是三级页：点开才见开关
local sub_nav
for _, section in ipairs(desk.sections()) do
    if section.title == "页面" then
        for _, build in ipairs(section.rows) do
            local row = build(600)
            if row.title == "订阅" then sub_nav = row end
        end
    end
end
Assert.is_true(sub_nav ~= nil)
sub_nav.callback()
Assert.eq(opened.id, "feature:subscribe:main")
Assert.eq(opened.title, "订阅")
local sub_rows = {}
for _, build in ipairs(opened.sections()[1].rows) do sub_rows[#sub_rows + 1] = build(600).title end
Assert.eq(table.concat(sub_rows, ","), "启用订阅,下载文章图片")

local system = openRoot("系统")
Assert.eq(system.id, "group:system")
Assert.eq(sectionTitles(system), "连接,本机,状态")
local system_titles = {}
for _, row in ipairs(buildSectionRows(system)) do system_titles[#system_titles + 1] = row.title end
Assert.is_true(table.concat(system_titles, ","):find("启动与按键", 1, true) ~= nil)
Assert.is_true(table.concat(system_titles, ","):find("设备", 1, true) ~= nil)
Assert.is_true(table.concat(system_titles, ","):find("网络", 1, true) ~= nil)

local maintenance = openRoot("维护")
Assert.eq(maintenance.id, "group:maintenance")
Assert.eq(sectionTitles(maintenance), "功能与更新,数据,其它")
local maintenance_titles = {}
for _, row in ipairs(buildSectionRows(maintenance)) do maintenance_titles[#maintenance_titles + 1] = row.title end
Assert.eq(maintenance_titles[1], "功能开关")
Assert.is_true(table.concat(maintenance_titles, ","):find("检查更新", 1, true) ~= nil)
Assert.is_true(table.concat(maintenance_titles, ","):find("关闭桌面", 1, true) ~= nil)

_G.G_reader_settings = previous_settings

return true
