--[[--
书库封面设置：首页文字封面为独立选项，默认关；仅在书库选择「仅文字封面」时可开。
@module tests.desktop.settings.library_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, inject-field

local Assert = require("support.assert")

package.preload["gettext"] = function() return function(text) return text end end
package.preload["ui.themes.widgets.row"] = function()
    return {
        widget = function(opts) return opts end,
        choice = function(opts) return opts end,
    }
end
package.preload["ui.widgets.cover"] = function()
    return {
        gridCols = function() return 4 end,
        gridColsMin = function() return 3 end,
        gridColsMax = function() return 8 end,
        setGridCols = function(n) return n end,
    }
end
package.preload["ui.themes.widgets.spin"] = function()
    return { new = function(_, opts) return { show = function() end, opts = opts } end }
end
package.preload["ui.themes.widgets.list"] = function()
    return { new = function(_, opts) return { show = function() end, opts = opts } end }
end

local settings = {
    library_cover_mode = "image",
    library_text_cover_style = "plain",
    home_text_cover = false,
    library_title = true,
    library_author = false,
    library_style = "kindle",
    library_cover_radius = "theme",
    library_text_cover_truncate = true,
    library_tabs = { "books" },
    library_tap = "open",
    library_double_tap = "none",
    library_hold = "none",
    library_more = "detail",
    library_random = true,
    random_scope = "new",
}
local saved = 0
package.preload["utils.settings"] = function()
    return {
        get = function() return settings end,
        save = function() saved = saved + 1 end,
    }
end

package.loaded["desktop.pages.setting.library"] = nil
local Library = require("desktop.pages.setting.library")

local updated = 0
local desktop = { updateView = function() updated = updated + 1 end }

local function coverRows()
    local sections = Library:sections(desktop)
    Assert.eq(sections[1].title, "封面")
    local out = {}
    for _idx, row in ipairs(sections[1].rows) do
        out[#out + 1] = row(400)
    end
    return out
end

local function homeRow()
    for _idx, row in ipairs(coverRows()) do
        if row.title == "首页也使用文字封面" then return row end
    end
end

local row = homeRow()
Assert.not_nil(row, "封面分区有首页文字封面选项")
Assert.eq(row.icon, "home")
Assert.is_false(row.enabled, "书库未开仅文字封面时选项不可用")
Assert.is_false(row.toggle, "不可用时显示为关，避免误导")
Assert.eq(saved, 0)
Assert.eq(updated, 0)
Assert.is_false(row.enabled and settings.home_text_cover)
Assert.is_false(settings.home_text_cover, "置灰时不改已存值")

settings.library_cover_mode = "text"
row = homeRow()
Assert.is_true(row.enabled, "书库仅文字封面时选项可用")
Assert.is_false(row.toggle, "默认首页仍用真实封面")
row.callback()
Assert.is_true(settings.home_text_cover, "开启后持久化")
Assert.eq(saved, 1)
Assert.eq(updated, 1, "切换后刷新桌面，首页与设置同步")
row = homeRow()
Assert.is_true(row.toggle)
row.callback()
Assert.is_false(settings.home_text_cover, "关闭后恢复首页真实封面")
Assert.eq(saved, 2)
Assert.eq(updated, 2)

-- 先打开再把书库改回加载封面：选项重新置灰，已存值保留以便再打开时恢复。
settings.home_text_cover = true
settings.library_cover_mode = "image"
row = homeRow()
Assert.is_false(row.enabled)
Assert.is_false(row.toggle, "未生效时显示为关")
Assert.is_true(settings.home_text_cover, "不改写已存的首页选项")
settings.library_cover_mode = "text"
row = homeRow()
Assert.is_true(row.enabled)
Assert.is_true(row.toggle, "书库再次启用仅文字封面后恢复已存的开启状态")

return true
