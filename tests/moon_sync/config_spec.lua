--[[--
月读同步配置：WebDAV 连接在 moon_sync，本地源不再存一份。

@module tests.moon_sync.config_spec
--]]

local Assert = require("support.assert")

local moon = {
    sync_fonts = false,
    webdav_url = "https://dav.example/dav",
    webdav_username = "user",
    webdav_password = "secret",
    webdav_path = "Books",
}
local local_cfg = { webdav_upload_local = false }
local saved_moon, saved_local, replaced = 0, 0, 0

package.preload["utils.settings"] = function()
    return {
        get = function() return moon end,
        save = function() saved_moon = saved_moon + 1 end,
        getSource = function() return local_cfg end,
        saveSource = function() saved_local = saved_local + 1 end,
    }
end
package.preload["utils.text"] = function()
    return {
        trim = function(value)
            return type(value) == "string" and value:gsub("^%s+", ""):gsub("%s+$", "") or ""
        end,
    }
end
package.preload["source.logout"] = function()
    return {
        replaceWebdav = function(save)
            replaced = replaced + 1
            save()
            return true
        end,
    }
end
package.preload["source.registry"] = function()
    return { invalidate = function() end }
end
package.preload["gettext"] = function()
    return setmetatable({}, { __call = function(_, text) return text end })
end
package.loaded["utils.settings"] = nil
package.loaded["utils.text"] = nil
package.loaded["source.logout"] = nil
package.loaded["source.registry"] = nil
package.loaded["gettext"] = nil
package.loaded["moon_sync"] = nil

local MoonSync = require("moon_sync")

Assert.is_true(MoonSync.configured())
Assert.eq(MoonSync.path(""), "Apps/Books")
Assert.eq(MoonSync.path("/Apps/Books/"), "Apps/Books")
Assert.eq(saved_moon, 0, "读连接不落盘")
Assert.eq(saved_local, 0)

local changed = MoonSync.applyRemote(moon, { webdav_password = "next" })
Assert.is_true(changed)
Assert.eq(moon.webdav_password, "next")
Assert.eq(replaced, 0, "只改密码不换库")
Assert.eq(saved_moon, 1)
Assert.eq(saved_local, 0)
Assert.eq(local_cfg.webdav_upload_local, false, "上传开关仍在本地源")

moon.webdav_path = ""
Assert.is_false(MoonSync.applyRemote(moon, { webdav_path = "Apps/Books" }))
Assert.eq(moon.webdav_path, "")
Assert.eq(replaced, 0, "默认目录和空目录是同一条路径")
