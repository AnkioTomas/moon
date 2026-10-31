--[[--
书源设置页的「使用自定义分组代替分类」开关（微信 / 起点 / 番茄共用）。

缺省开。开：书架分类只用平台自定义分组名，没进组的书归未分类，不用题材。
关：书架分类只用题材 / 频道，忽略自定义分组。
两种模式互斥，不再混合进同一套分类。
未写过这个键视为开；显式 false 才是关。微信升级见 syncBooksAsync：缺省从关改开时清增量游标，否则旧题材会被增量当成分组名留住。

@module koplugin.book.source.category_setting
--]]

local _ = require("gettext")

local CategorySetting = {}

---@param source_id string
---@return boolean
function CategorySetting.enabled(source_id)
    return require("utils.settings").getSource(source_id).category_as_group ~= false
end

--- 按开关决定落进 books.category 的值：开 → 分组名或 nil；关 → 题材（可空）。
---@param source_id string
---@param genre string|nil 题材 / 频道
---@param group_name string|nil 自定义分组名
---@return string|nil
function CategorySetting.apply(source_id, genre, group_name)
    if CategorySetting.enabled(source_id) then
        if type(group_name) == "string" and group_name ~= "" then return group_name end
        return nil
    end
    if type(genre) == "string" and genre ~= "" then return genre end
    return nil
end

--- 设置页的一行（`Row.widget` 工厂）。
---@param source_id string
---@param plugin table|nil
---@return fun(iw: integer): table
function CategorySetting.row(source_id, plugin)
    return function(iw)
        local on = CategorySetting.enabled(source_id)
        return require("ui.themes.widgets.row").widget({
            width = iw, chevron = false, kind = "toggle", icon = "folder_copy",
            title = _("使用自定义分组代替分类"),
            subtitle = _("开：分类只用书架分组；关：分类只用题材。下次同步书架后生效"),
            status = on and _("开") or _("关"), status_on = on,
            callback = function()
                local settings = require("utils.settings")
                local cfg = settings.getSource(source_id)
                cfg.category_as_group = not on
                -- 微信增量会保留本地分类；清游标逼下次全量，才能按新开关重写分类。
                if source_id == "wechat" then cfg.shelf_cursor = nil end
                settings.saveSource(source_id, cfg)
                if plugin and plugin.desktop then plugin.desktop:updateView() end
            end,
        })
    end
end

return CategorySetting
