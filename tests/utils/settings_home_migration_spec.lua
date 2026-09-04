--[[-- 旧首页组合模式无损迁移为两个独立组件。 --]]

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
Assert.eq(home.home_layout[1], "clock")
Assert.eq(home.home_layout[2], "recent_hero")
Assert.eq(home.home_layout[3], "recent_list")
Assert.eq(home.home_layout[4], "stats")

home = migrate("list_only")
Assert.is_nil(home.home_recent_list_mode)
Assert.eq(home.home_layout[1], "clock")
Assert.eq(home.home_layout[2], "recent_list")
Assert.eq(home.home_layout[3], "stats")

return true
