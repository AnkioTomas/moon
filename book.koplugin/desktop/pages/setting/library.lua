--[[-- 图书馆页设置（每行数量 + settings/ui.lua 的 library_*）；挂在桌面「页面」三级页。
@module koplugin.book.desktop.pages.setting.library
--]]

local Row = require("ui.themes.widgets.row")
local MoonSettings = require("utils.settings")
local _ = require("gettext")

---@class BookSettingsLibrary
local Library = {}

local STYLES = {
    { value = "kindle", text = _("Kindle") },
    { value = "kobo", text = _("Kobo") },
}
local COVER_RADII = {
    { value = "theme", text = _("跟随主题") },
    { value = "round", text = _("圆角") },
    { value = "square", text = _("直角") },
}
local COVER_MODES = {
    { value = "image", text = _("加载封面") },
    { value = "text", text = _("仅文字封面") },
}
local TEXT_COVER_STYLES = {
    { value = "color", text = _("彩色底") },
    { value = "plain", text = _("白底黑字") },
}
local RANDOM_SCOPES = {
    { value = "new", text = _("未读") },
    { value = "reading", text = _("未读 + 阅读中") },
}
local TAPS = {
    { value = "open", text = _("打开书籍") },
    { value = "detail", text = _("进入详情") },
}
local MORES = {
    { value = "none", text = _("关闭") },
    { value = "detail", text = _("进入详情") },
    { value = "menu", text = _("弹出菜单") },
}
local EXTRA_ACTIONS = {
    { value = "none", text = _("无动作") },
    { value = "open", text = _("打开书籍") },
    { value = "detail", text = _("进入详情") },
}

---@param desktop table
---@param key string settings/ui.lua 里的键
---@param icon string
---@param title string
---@param subtitle string
---@return fun(iw: number): table
local function toggleRow(desktop, key, icon, title, subtitle)
    return function(iw)
        local conf = MoonSettings.get("ui")
        return Row.widget({
            width = iw, icon = icon, title = title, subtitle = subtitle,
            toggle = conf[key],
            callback = function()
                conf[key] = not conf[key]
                MoonSettings.save("ui", conf)
                desktop:updateView()
            end,
        })
    end
end

---@param desktop table
---@param key string
---@param icon string
---@param title string
---@param subtitle string
---@param items table[] { value, text }
---@return fun(iw: number): table
local function choiceRow(desktop, key, icon, title, subtitle, items)
    return function(iw)
        local conf = MoonSettings.get("ui")
        return Row.choice({
            width = iw, icon = icon, title = title, subtitle = subtitle,
            items = items, current = conf[key],
            on_select = function(value)
                conf[key] = value
                MoonSettings.save("ui", conf)
                desktop:updateView()
            end,
        })
    end
end

--- 首页文字封面：仅在书库已选「仅文字封面」时可开；关闭时首页仍显示真实封面。
---@param desktop table
---@return fun(iw: number): table
local function homeTextCoverRow(desktop)
    return function(iw)
        local conf = MoonSettings.get("ui")
        local enabled = conf.library_cover_mode == "text"
        return Row.widget({
            width = iw, icon = "home", title = _("首页也使用文字封面"),
            subtitle = _("默认首页显示真实封面；仅在书库选择「仅文字封面」时可用"),
            toggle = enabled and conf.home_text_cover == true,
            enabled = enabled,
            callback = function()
                conf.home_text_cover = not conf.home_text_cover
                MoonSettings.save("ui", conf)
                desktop:updateView()
            end,
        })
    end
end

--- 书库显示哪些分组页签：多选弹窗，勾选即存，书籍页签恒显示。
---@param desktop table
---@return fun(iw: number): table
local function tabsRow(desktop)
    return function(iw)
        local conf = MoonSettings.get("ui")
        return Row.widget({
            width = iw, kind = "nav", icon = "tab", title = _("书库页签"),
            subtitle = _("选择书库顶部显示哪些分组；文件夹页签仅本地书库有"),
            status = tostring(#conf.library_tabs), status_on = true,
            callback = function()
                local chosen, items = {}, {}
                for _idx, id in ipairs(conf.library_tabs) do chosen[id] = true end
                for _idx, tab in ipairs(require("desktop.pages.library").tabOptions()) do
                    items[#items + 1] = { text = tab.text, value = tab.id,
                        checked = tab.id == "books" or chosen[tab.id] == true, enabled = tab.id ~= "books" }
                end
                require("ui.themes.widgets.list"):new{
                    title = _("书库页签"), multi = true, items = items, centered = true,
                    close_callback = function()
                        local ids = {}
                        for _idx, item in ipairs(items) do
                            if item.checked then ids[#ids + 1] = item.value end
                        end
                        conf.library_tabs = ids
                        MoonSettings.save("ui", conf)
                        desktop:updateView()
                    end,
                }:show()
            end,
        })
    end
end

---@param desktop table
---@return BookThemeSection[]
function Library:sections(desktop)
    local function gridRow(iw)
        local CoverCell = require("ui.widgets.cover")
        return Row.widget({
            width = iw, kind = "nav", icon = "grid_view", title = _("书架每行数量"),
            subtitle = _("调整书库和 Z站 每行显示的卡片数"),
            status = tostring(CoverCell.gridCols()), status_on = true,
            callback = function()
                require("ui.themes.widgets.spin"):new{
                    title = _("书架每行数量"),
                    fields = { { value = CoverCell.gridCols(), min = CoverCell.gridColsMin(),
                        max = CoverCell.gridColsMax() } },
                    callback = function(v)
                        CoverCell.setGridCols(v)
                        desktop:updateView()
                    end,
                }:show()
            end,
        })
    end
    return {
        { title = _("封面"), rows = {
            gridRow,
            choiceRow(desktop, "library_style", "style", _("封面风格"),
                _("Kindle：状态叠在封面上；Kobo：封面干净，下载状态、进度和更多收在封面下方"), STYLES),
            choiceRow(desktop, "library_cover_radius", "rounded_corner", _("封面圆角"),
                _("只改书封四角；跟随主题时与界面风格一致"), COVER_RADII),
            choiceRow(desktop, "library_cover_mode", "image", _("封面来源"),
                _("选「仅文字封面」则不加载封面图，全部用书名生成封面"), COVER_MODES),
            choiceRow(desktop, "library_text_cover_style", "palette", _("文字封面风格"),
                _("彩色底：按书名取色；白底黑字：简洁朴素"), TEXT_COVER_STYLES),
            homeTextCoverRow(desktop),
            toggleRow(desktop, "library_text_cover_truncate", "content_cut", _("文字封面截断标题"),
                _("标题过长时自动截断为四字；关闭则自动转到下一列显示")),
            toggleRow(desktop, "library_title", "title", _("显示名称"), _("封面下方显示书名")),
            toggleRow(desktop, "library_author", "person", _("显示作者"), _("书名下方显示作者")),
            toggleRow(desktop, "library_source_tag", "dns", _("混合模式显示书源"), _("混合模式下封面左上角显示书从哪个书源来")),
        } },
        { title = _("书库"), rows = {
            tabsRow(desktop),
            choiceRow(desktop, "library_tap", "touch_app", _("点击书籍"), _("点封面时的动作"), TAPS),
            choiceRow(desktop, "library_double_tap", "touch_app", _("双击书籍"),
                _("开启后书库里的单击会多等一瞬，以区分双击"), EXTRA_ACTIONS),
            choiceRow(desktop, "library_hold", "touch_app", _("长按书籍"), _("长按封面时的动作"), EXTRA_ACTIONS),
            choiceRow(desktop, "library_more", "more_horiz", _("更多按钮"),
                _("封面或列表行上「更多」的动作；弹出菜单即详情页右上角那份"), MORES),
        } },
        { title = _("随机一本"), rows = {
            toggleRow(desktop, "library_random", "casino", _("显示随机一本"),
                _("书库工具栏显示骰子，优先从未读的书里随机抽一本")),
            choiceRow(desktop, "random_scope", "casino", _("随机范围"),
                _("书库与首页的随机一本从哪些书里抽，已读完的不会抽到"), RANDOM_SCOPES),
        } },
    }
end

return Library
