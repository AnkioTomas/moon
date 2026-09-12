--[[--
版本门槛：月发号 vYYYY.MM（无 point）必须放行。

@module tests.version.adapter_spec
--]]

local Assert = require("support.assert")

local calls = {}
local version_current = 202607000000
local short_version = "2026.07"

package.preload["ui/uimanager"] = function()
    return {
        show = function(_, widget) calls.dialog = widget end,
    }
end
package.preload["ui/widget/confirmbox"] = function()
    return {
        new = function(_, fields) return fields end,
    }
end
package.preload["gettext"] = function()
    return function(text) return text end
end
package.preload["version"] = function()
    return {
        getNormalizedCurrentVersion = function() return version_current end,
        getShortVersion = function() return short_version end,
    }
end

local Adapter = require("version.adapter")

Assert.is_true(Adapter.checkKOReaderVersion(), "v2026.07 归一 202607000000 必须通过")
Assert.is_nil(calls.dialog)

version_current = 202607010000
short_version = "2026.07.1"
Assert.is_true(Adapter.checkKOReaderVersion(), "point release 也必须通过")

version_current = 202606000000
short_version = "2026.06"
Assert.is_true(not Adapter.checkKOReaderVersion(), "更旧月发必须拒绝")
Assert.eq(calls.dialog.text, "月读需要 KOReader 2026.07 或更高版本。\n\n当前版本：2026.06 (202606000000)")
