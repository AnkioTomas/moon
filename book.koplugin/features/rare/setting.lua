--[[--
生僻字注音设置：阅读分组下一页，开关、档位、字号、注音词库（下载 / 启用 / 删除）。

@module koplugin.book.features.rare.setting
--]]

local _ = require("gettext")
local T = require("ffi/util").template

local Setting = {}

-- rare_level：rarest / rare / all，对应词库 levels 三档；rare_size：注音字号 / 正文字号（全屏统一）；rare_lookup_source：查词面板上次用的来源；
-- rare_lexicons：已启用词库 id → true；rare_built_at：已装词库版本（manifest built_at）；
-- rare_vocab：KOReader 生字本里的字词不看档位也注音。
Setting.defaults = {
    rare_enabled = false,
    rare_level = "rare",
    rare_size = 0.5,
    rare_lookup_source = "",
    rare_lexicons = {},
    rare_built_at = {},
    rare_vocab = false,
}

--- 无默认值的持久键：查词面板上次用的词典。
Setting.keys = { "rare_lookup_dict" }

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

---@param items table[]
---@param value any
---@return string
local function label(items, value)
    for _idx, item in ipairs(items) do
        if item.value == value then return item.text end
    end
    return tostring(value)
end

---@param key string
---@param value any
local function save(desktop, key, value)
    local MoonSettings = require("utils.settings")
    local s = MoonSettings.get("features.rare")
    s[key] = value
    MoonSettings.save("features.rare", s)
    require("features.rare.overlay").invalidate()
    desktop:updateView()
end

---@param desktop BookDesktop
---@param title string
---@param items table[]
---@param key string
local function pick(desktop, title, items, key)
    require("ui.themes.widgets.list"):new{
        title = title,
        items = items,
        current = require("utils.settings").get("features.rare")[key],
        centered = true,
        on_select = function(value)
            save(desktop, key, value)
            if key == "rare_level" and value == "all" then
                require("ui.themes.widgets.toast"):new{
                    text = _("全部范围注音每页命中很多，可能拖慢翻页，一般建议用“生僻”"),
                    timeout = 4,
                }:show()
            end
        end,
    }:show()
end

---@param desktop BookDesktop
---@param item table 词库清单项
local function download(desktop, item)
    local Catalog = require("features.rare.catalog")
    local Toast = require("ui.themes.widgets.toast")
    require("workers.ui.task_dialog").start{
        key = "rare:" .. item.id,
        kind = "download",
        title = T(_("注音词库：%1"), item.label),
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
                text = result.ok and _("注音词库已就绪")
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

---@param desktop BookDesktop
---@return table[]
local function sections(desktop)
    local Row = require("ui.themes.widgets.row")
    local Catalog = require("features.rare.catalog")
    local s = require("utils.settings").get("features.rare")
    local lexicon_rows = {}
    for _idx, item in ipairs(Catalog.list()) do
        lexicon_rows[#lexicon_rows + 1] = function(iw)
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
    return {
        {
            title = _("生僻字注音"),
            rows = {
                function(iw)
                    return Row.widget({
                        width = iw, chevron = false, kind = "toggle", icon = "translate",
                        title = _("生僻字注音"),
                        status = s.rare_enabled and _("开") or _("关"), status_on = s.rare_enabled,
                        callback = function()
                            if not s.rare_enabled and #Catalog.active() == 0 then
                                require("ui.themes.widgets.toast"):new{
                                    text = _("请先在下方下载注音词库"), timeout = 2,
                                }:show()
                                return
                            end
                            save(desktop, "rare_enabled", not s.rare_enabled)
                        end,
                    })
                end,
                function(iw)
                    return Row.widget({
                        width = iw, chevron = true, kind = "nav", icon = "tune",
                        title = _("注音范围"), status = label(levels(), s.rare_level), status_on = true,
                        callback = function() pick(desktop, _("注音范围"), levels(), "rare_level") end,
                    })
                end,
                function(iw)
                    return Row.widget({
                        width = iw, chevron = false, kind = "toggle", icon = "bookmark",
                        title = _("生字本也注音"), subtitle = _("KOReader 生字本里的字词不看范围也注音"),
                        status = s.rare_vocab and _("开") or _("关"), status_on = s.rare_vocab,
                        callback = function() save(desktop, "rare_vocab", not s.rare_vocab) end,
                    })
                end,
                function(iw)
                    return Row.widget({
                        width = iw, chevron = true, kind = "nav", icon = "format_size",
                        title = _("注音字号"), status = label(sizes(), s.rare_size), status_on = true,
                        callback = function() pick(desktop, _("注音字号"), sizes(), "rare_size") end,
                    })
                end,
            },
        },
        { title = _("注音词库"), rows = lexicon_rows },
    }
end

---@param desktop BookDesktop
---@return BookSettingEntry[]
function Setting.entries(desktop)
    local on = require("utils.settings").get("features.rare").rare_enabled
    return {
        {
            id = "main",
            group = "reader",
            order = 200,
            icon = "translate",
            title = _("生僻字注音"),
            subtitle = _("拼音、英语音标"),
            status = on and _("开") or _("关"),
            status_on = on,
            page = {
                title = _("生僻字注音"),
                sections = function() return sections(desktop) end,
            },
        },
    }
end

return Setting
