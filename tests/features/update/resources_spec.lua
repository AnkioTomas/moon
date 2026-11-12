--[[--
features.update.resources：findStale 逐项查版本，只收有更新的。

@module tests.features.update.resources_spec
--]]

local Assert = require("support.assert")

local Download = {
    outdated = function(spec, cb) cb(spec.installed ~= "new") end,
    downloading = function() return false end,
}
package.preload["features.ime.download"] = function() return Download end
local settings = { auto_check = false, resource_last_checked_at = 0 }
package.preload["utils.settings"] = function()
    return { get = function() return settings end, save = function() end }
end
package.preload["ui/network/manager"] = function()
    return { isConnected = function() return true end }
end
local prompts = 0
package.preload["ui.themes.widgets.confirm"] = function()
    return { new = function(_self, opts)
        opts.show = function() prompts = prompts + 1 end
        return opts
    end }
end

local Resources = require("features.update.resources")

local function dictSpec(version)
    return { name = "test", base_path = "assets/test", dest = "unused",
        installed = version, on_installed = function() end }
end
local got
Resources.findStale({
    { label = "a", spec = dictSpec("old") },
    { label = "b", spec = dictSpec("new") },
    { label = "c", spec = dictSpec("older") },
}, function(stale) got = stale end)
Assert.len(got, 2)
Assert.eq(got[1].label, "a")
Assert.eq(got[2].label, "c")

Resources.findStale({}, function(stale) got = stale end)
Assert.len(got, 0)

local scans = 0
Resources.installed = function()
    scans = scans + 1
    return {{ label = "a", spec = dictSpec("old") }}
end
Resources.autoCheck()
Assert.eq(scans, 0, "关闭开关不查询词库更新")
Assert.eq(settings.resource_last_checked_at, 0)
settings.auto_check = true
Resources.autoCheck()
Assert.eq(scans, 1)
Assert.eq(prompts, 1)

local pending
Download.outdated = function(_spec, cb) pending = cb end
settings.resource_last_checked_at = 0
Resources.autoCheck()
settings.auto_check = false
pending(true)
Assert.eq(prompts, 1, "关闭开关后迟到的结果不再提醒")
