--[[--
KOReader 宿主版本门槛：月发号 vYYYY.MM（无 point）必须放行。

@module tests.ko_version_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

local Assert = require("support.assert")

local calls = {}
local version_current = 202607000000
local short_version = "2026.07"

package.preload["ui/uimanager"] = function()
    return {
        show = function(_, widget) calls.dialog = widget end,
    }
end
package.preload["ui/widget/infomessage"] = function()
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

local KOVersion = require("ko_version")
local Container = { extend = function(_, fields) return fields end }

Assert.is_true(KOVersion.supported(), "v2026.07 归一 202607000000 必须通过")

version_current = 202607010000
Assert.is_true(KOVersion.supported(), "point release 也必须通过")

version_current = 202606000000
short_version = "2026.06"
Assert.is_true(not KOVersion.supported(), "更旧月发必须拒绝")
local stub = KOVersion.stub(Container)
stub.init()
Assert.eq(calls.dialog.text, "月读需要 KOReader 2026.07 或更高版本。\n\n当前版本：2026.06")
calls.dialog = nil
stub.init()
Assert.is_nil(calls.dialog, "同一进程只弹一次")

version_current = nil
Assert.is_true(not KOVersion.supported(), "无 git-rev 必须拒绝")
