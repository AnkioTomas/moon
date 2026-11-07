--[[--
豆瓣设置开关必须重绘当前桌面，不能只写配置后留着旧的开关状态。

@module tests.source.douban.setting_spec
--]]
local Assert = require("support.assert")
local cfg, saved, refreshed = {}, 0, 0
package.preload["utils.settings"] = function()
    return {
        getSource = function() return cfg end,
        saveSource = function() saved = saved + 1 end,
        get = function() return {} end,
    }
end
package.preload["source.douban.client"] = function() return { loggedIn = function() return false end } end
package.preload["ui.themes.widgets.row"] = function() return { widget = function(opts) return opts end } end
local Setting = require("source.douban.setting")
local plugin = { desktop = { updateView = function() refreshed = refreshed + 1 end } }
local function find(title)
    for _idx, factory in ipairs(Setting.rows(plugin)) do
        local row = factory(540)
        if row.title == title then return row end
    end
    error("setting row missing: " .. title)
end
local row = find("显示段评")
Assert.eq(row.status, "关")
row.callback()
Assert.is_true(cfg.show_paragraph_reviews)
Assert.eq(refreshed, 1)
row = find("显示段评")
Assert.eq(row.status, "开")
row.callback()
Assert.eq(cfg.show_paragraph_reviews, false)
Assert.eq(refreshed, 2)
row = find("使用自定义分组代替分类")
Assert.eq(row.status, "开")
row.callback()
Assert.eq(cfg.category_as_group, false)
Assert.eq(refreshed, 3)
Assert.eq(find("使用自定义分组代替分类").status, "关")
Assert.eq(saved, 3)
