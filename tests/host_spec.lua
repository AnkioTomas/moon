--[[--
Host：首次安装种 start_with；已种过则不覆盖用户选择。

@module tests.host_spec
--]]

local Assert = require("support.assert")

local saved = {}
_G.G_reader_settings = {
    readSetting = function(_, key, default)
        if saved[key] ~= nil then return saved[key] end
        return default
    end,
    saveSetting = function(_, key, value)
        saved[key] = value
    end,
}

local moon_cfg = { start_with_seeded = false }
local settings_saves = {}

package.preload["utils.settings"] = function()
    return {
        get = function() return moon_cfg end,
        save = function(values)
            settings_saves[#settings_saves + 1] = values
            for k, v in pairs(values or {}) do
                moon_cfg[k] = v
            end
        end,
    }
end
package.preload["dispatcher"] = function()
    return { registerAction = function() end }
end
package.preload["ui/uimanager"] = function()
    return { nextTick = function(_, fn) fn() end }
end
package.preload["apps/filemanager/filemanagermenu"] = function()
    return {
        getStartWithMenuTable = function()
            return { sub_item_table = {} }
        end,
    }
end
package.preload["utils.font"] = function()
    return { applyCurrent = function() end }
end
package.preload["ui.components.icon"] = function()
    return { ensure = function() end }
end
package.preload["gettext"] = function()
    return setmetatable({}, { __call = function(_, t) return t end })
end
package.preload["ffi/util"] = function()
    return { template = function(fmt, a) return tostring(fmt):gsub("%%1", tostring(a), 1) end }
end
package.preload["utils.log"] = function()
    return { info = function() end, warn = function() end, dbg = function() end }
end

package.loaded["host"] = nil
package.loaded["utils.settings"] = nil
local Host = require("host")

-- 系统默认 filemanager → 首次 attach 强制月读并开桌面
saved.start_with = "filemanager"
local opened = 0
Host.onCreate({
    ui = {},
    openDesktop = function() opened = opened + 1 end,
})

Assert.eq(saved.start_with, Host.OPEN_ON_START_ID)
Assert.is_true(moon_cfg.start_with_seeded)
Assert.eq(#settings_saves, 1)
Assert.eq(opened, 1)

-- 用户改回 filemanager；再次 attach 不得覆盖
saved.start_with = "filemanager"
local seeded_saves = #settings_saves
opened = 0
Host.onCreate({
    ui = {},
    openDesktop = function() opened = opened + 1 end,
})
Assert.eq(saved.start_with, "filemanager")
Assert.eq(#settings_saves, seeded_saves)
Assert.eq(opened, 0)
