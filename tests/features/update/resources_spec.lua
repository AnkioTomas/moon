--[[--
features.update.resources：findStale 逐项查版本，只收有更新的。

@module tests.features.update.resources_spec
--]]

local Assert = require("support.assert")

package.preload["features.ime.download"] = function()
    return {
        outdated = function(spec, cb) cb(spec.installed ~= "new") end,
    }
end
package.preload["utils.settings"] = function() return {} end

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
