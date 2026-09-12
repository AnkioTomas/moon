--[[-- 旧 home_layout / recent_list_mode 迁移为 home_widgets。 --]]

local Assert = require("support.assert")

local stores

package.preload["utils.paths"] = function()
    return {
        ensureSettings = function() end,
        commonPath = function() return "common" end,
        sectionPath = function(section) return section end,
        sourcePath = function(id) return "source-" .. tostring(id) end,
    }
end
package.preload["luasettings"] = function()
    return {
        open = function(_, path)
            stores[path] = stores[path] or {}
            local file = { data = stores[path] }
            function file:flush() end
            function file:reset(values)
                self.data = values
                stores[path] = values
            end
            return file
        end,
    }
end

local function migrate(mode)
    stores = {
        common = {},
        home = {
            home_layout = { "clock", "recent_list", "stats" },
            home_recent_list_mode = mode,
        },
    }
    package.loaded["utils.settings"] = nil
    local Settings = require("utils.settings")
    return Settings.get("home")
end

local home = migrate("hero_grid")
Assert.is_nil(home.home_recent_list_mode)
Assert.is_nil(home.home_layout)
Assert.eq(home.home_widgets[1].id, "clock")
Assert.eq(home.home_widgets[2].id, "recent_hero")
Assert.eq(home.home_widgets[3].id, "recent_list")
Assert.eq(home.home_widgets[4].id, "stats")
Assert.eq(home.home_widgets[1].page, 1)
Assert.eq(home.home_widgets[1].height, "default")
Assert.is_true(home.home_widgets_need_split)

home = migrate("list_only")
Assert.is_nil(home.home_layout)
Assert.eq(home.home_widgets[1].id, "clock")
Assert.eq(home.home_widgets[2].id, "recent_list")
Assert.eq(home.home_widgets[3].id, "stats")
Assert.is_true(home.home_widgets_need_split)

return true
