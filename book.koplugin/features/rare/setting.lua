--[[--
生僻字注音 / WordWise 释义设置：主页分「功能 / 显示 / 词库」三组；词库进二级页管理。
注音与释义可同时启用（按文字类型分流）；两份英文释义词库互斥。

@module koplugin.book.features.rare.setting
--]]

local _ = require("gettext")
local T = require("ffi/util").template

local Setting = {}

-- rare_ruby / rare_wordwise：注音与释义独立开关；rare_enabled 为二者或（兼容旧逻辑）；
-- rare_level / rare_size / rare_color / rare_min_spacing / rare_vocab / rare_lexicons / rare_built_at 同前。
-- rare_mode 已废弃；rare_split_migrated 标记已从旧 rare_enabled 迁过。
Setting.defaults = {
    rare_ruby = false,
    rare_wordwise = false,
    rare_enabled = false,
    rare_level = "rare",
    rare_size = 0.5,
    rare_color = "gray", -- gray=深灰（默认，跟正文区分）；black=黑色（墨水屏小字更利索）
    rare_min_spacing = 140,
    rare_lookup_source = "",
    rare_lexicons = {},
    rare_built_at = {},
    rare_vocab = false,
}

--- 无默认值的持久键：查词面板词典；遗留 rare_mode；迁移标记。
Setting.keys = { "rare_lookup_dict", "rare_mode", "rare_split_migrated" }

local function levels()
    return {
        { value = "rarest", text = _("最生僻") },
        { value = "rare", text = _("生僻") },
        { value = "all", text = _("全部") },
    }
end

local function sizes()
    return {
        { value = 0.4, text = "40%" },
        { value = 0.5, text = "50%" },
        { value = 0.6, text = "60%" },
        { value = 0.7, text = "70%" },
    }
end

local function colors()
    return {
        { value = "gray", text = _("灰色") },
        { value = "black", text = _("黑色") },
    }
end

local function spacings()
    return {
        { value = 0, text = _("不设") },
        { value = 100, text = "100%" },
        { value = 110, text = "110%" },
        { value = 120, text = "120%" },
        { value = 140, text = "140%" },
        { value = 160, text = "160%" },
        { value = 180, text = "180%" },
    }
end

---@param key string
---@param value any
local function save(desktop, key, value)
    local MoonSettings = require("utils.settings")
    local s = MoonSettings.get("features.rare")
    s[key] = value
    MoonSettings.save("features.rare", s)
    require("features.rare.overlay").invalidate()
    -- 抬高下限时，当前打开的书若行距不够就跟着抬（只升不降）。
    if key == "rare_min_spacing" then
        local ui = require("apps/reader/readerui").instance
        if ui then require("features.rare").ensureLineSpacing(ui) end
    end
    desktop:updateView()
end

--- 单选行：选中写配置；范围选「全部」时提醒性能。
---@param desktop BookDesktop
---@param iw number
---@param icon string
---@param title string
---@param items table[]
---@param key string
local function pickRow(desktop, iw, icon, title, items, key)
    return require("ui.themes.widgets.row").choice({
        width = iw, icon = icon, title = title,
        items = items, current = require("utils.settings").get("features.rare")[key],
        on_select = function(value)
            save(desktop, key, value)
            if key == "rare_level" and value == "all" then
                require("ui.themes.widgets.toast"):new{
                    text = _("全部范围标注每页命中很多，可能拖慢翻页，一般建议用“生僻”"),
                    timeout = 4,
                }:show()
            end
        end,
    })
end

---@param desktop BookDesktop
---@param item table 词库清单项
local function download(desktop, item)
    local Catalog = require("features.rare.catalog")
    local Toast = require("ui.themes.widgets.toast")
    require("workers.ui.task_dialog").start{
        key = "rare:" .. item.id,
        kind = "download",
        title = T(_("词库：%1"), item.label),
        run = function(report, done)
            Catalog.download(item.id, function(ok, err)
                done({ ok = ok, err = err })
            end, function(stage, done_bytes, total)
                if stage == "part" then
                    report(nil, done_bytes, total)
                elseif stage == "assemble" then
                    report(_("拼接校验词库…"), done_bytes, total)
                end
            end)
        end,
        on_done = function(result)
            Toast:new{
                text = result.ok and _("词库已就绪")
                    or T(_("下载失败: %1"), tostring(result.err or _("未知错误"))),
                timeout = 2,
            }:show()
            require("features.rare.overlay").invalidate()
            if desktop.closed then return end
            desktop:updateView()
        end,
    }
end

--- 点词库：未安装直接下载；已安装给出启用 / 停用、更新、删除。
---@param desktop BookDesktop
---@param item table
local function manage(desktop, item)
    local Catalog = require("features.rare.catalog")
    if not Catalog.installed(item.id) then
        download(desktop, item)
        return
    end
    local on = Catalog.enabled(item.id)
    local actions = { { value = "toggle", text = on and _("停用") or _("启用") } }
    if not item.custom then actions[#actions + 1] = { value = "update", text = _("检查更新") } end
    actions[#actions + 1] = { value = "delete", text = _("删除") }
    require("ui.themes.widgets.list"):new{
        title = item.label,
        items = actions,
        centered = true,
        on_select = function(action)
            if action == "update" then
                download(desktop, item)
                return
            end
            if action == "toggle" then
                Catalog.setEnabled(item.id, not on)
            else
                Catalog.delete(item.id)
            end
            require("features.rare.overlay").invalidate()
            desktop:updateView()
        end,
    }:show()
end

---@param items table[]
---@param kind string
---@return table[]
local function ofKind(items, kind)
    local out = {}
    for _idx, item in ipairs(items) do
        if (item.kind or "ruby") == kind then out[#out + 1] = item end
    end
    return out
end

---@param desktop BookDesktop
---@param items table[]
---@return function[]
local function lexiconRows(desktop, items)
    local Row = require("ui.themes.widgets.row")
    local Catalog = require("features.rare.catalog")
    local rows = {}
    for _idx, item in ipairs(items) do
        rows[#rows + 1] = function(iw)
            local installed = Catalog.installed(item.id)
            local on = installed and Catalog.enabled(item.id)
            return Row.widget({
                width = iw, chevron = true, kind = "nav", icon = "spellcheck",
                title = item.label,
                status = not installed and _("未下载") or (on and _("已启用") or _("已停用")),
                status_on = on,
                callback = function() manage(desktop, item) end,
            })
        end
    end
    return rows
end

--- 词库组状态：几个已启用 / 全未下载。
---@param items table[]
---@return string, boolean
local function lexiconGroupStatus(items)
    local Catalog = require("features.rare.catalog")
    local enabled, installed = 0, 0
    for _idx, item in ipairs(items) do
        if Catalog.installed(item.id) then
            installed = installed + 1
            if Catalog.enabled(item.id) then enabled = enabled + 1 end
        end
    end
    if installed == 0 then return _("未下载"), false end
    if enabled == 0 then return _("已停用"), false end
    return T(_("%1 个已启用"), enabled), true
end

--- 词库二级页。
---@param desktop BookDesktop
---@param title string
---@param items table[]
local function openLexicons(desktop, title, items)
    require("desktop.pages.setting.overlay").push(desktop, {
        title = title,
        sections = function()
            return { { title = title, rows = lexiconRows(desktop, items) } }
        end,
    })
end

---@param desktop BookDesktop
---@param kind "ruby"|"wordwise"
---@param title string
---@param icon string
---@return function
local function kindToggle(desktop, kind, title, icon)
    return function(iw)
        local Rare = require("features.rare")
        local on = Rare.kindOn(kind)
        return require("ui.themes.widgets.row").widget({
            width = iw, chevron = false, kind = "toggle", icon = icon,
            title = title,
            status = on and _("开") or _("关"), status_on = on,
            callback = function()
                Rare.toggleKind(kind, nil)
                desktop:updateView()
            end,
        })
    end
end

---@param desktop BookDesktop
---@return table[]
local function sections(desktop)
    local Catalog = require("features.rare.catalog")
    local s = require("features.rare").migrate()
    local list = Catalog.list()
    local ruby = ofKind(list, "ruby")
    local gloss = ofKind(list, "wordwise")
    local Row = require("ui.themes.widgets.row")
    return {
        {
            title = _("功能"),
            rows = {
                kindToggle(desktop, "ruby", _("生僻字注音"), "translate"),
                kindToggle(desktop, "wordwise", _("WordWise 释义"), "menu_book"),
            },
        },
        {
            title = _("显示"),
            rows = {
                function(iw) return pickRow(desktop, iw, "tune", _("标注范围"), levels(), "rare_level") end,
                function(iw) return pickRow(desktop, iw, "format_size", _("标注字号"), sizes(), "rare_size") end,
                function(iw) return pickRow(desktop, iw, "invert_colors", _("标注颜色"), colors(), "rare_color") end,
                function(iw) return pickRow(desktop, iw, "format_line_spacing", _("最小行距"), spacings(), "rare_min_spacing") end,
                function(iw)
                    return Row.widget({
                        width = iw, chevron = false, kind = "toggle", icon = "bookmark",
                        title = _("生字本也标注"),
                        subtitle = _("KOReader 生字本里的字词不看范围也标注"),
                        status = s.rare_vocab and _("开") or _("关"), status_on = s.rare_vocab,
                        callback = function() save(desktop, "rare_vocab", not s.rare_vocab) end,
                    })
                end,
            },
        },
        {
            title = _("词库"),
            rows = {
                function(iw)
                    local status, on = lexiconGroupStatus(ruby)
                    return Row.widget({
                        width = iw, chevron = true, kind = "nav", icon = "spellcheck",
                        title = _("注音词库"),
                        subtitle = _("拼音、音标"),
                        status = status, status_on = on,
                        callback = function() openLexicons(desktop, _("注音词库"), ruby) end,
                    })
                end,
                function(iw)
                    local status, on = lexiconGroupStatus(gloss)
                    return Row.widget({
                        width = iw, chevron = true, kind = "nav", icon = "menu_book",
                        title = _("释义词库"),
                        subtitle = _("WordWise 短释义"),
                        status = status, status_on = on,
                        callback = function() openLexicons(desktop, _("释义词库"), gloss) end,
                    })
                end,
            },
        },
    }
end

---@param desktop BookDesktop
---@return BookSettingEntry[]
function Setting.entries(desktop)
    local on = require("features.rare").anyOn()
    return {
        {
            id = "main",
            group = "reader",
            order = 70,
            icon = "translate",
            title = _("行间标注"),
            subtitle = _("注音与 WordWise 释义"),
            status = on and _("开") or _("关"),
            status_on = on,
            page = {
                title = _("行间标注"),
                sections = function() return sections(desktop) end,
            },
        },
    }
end

return Setting
