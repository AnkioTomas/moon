---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

--[[-- source.base：插件生命周期与业务事件默认空操作，不起任何同步。 --]]

local Assert = require("support.assert")

package.preload["gettext"] = function()
    return function(text) return text end
end

local SourceBase = require("source.base")
local calls = 0
local source = setmetatable({
    id = "test",
    configured = function() return true end,
    syncBooksAsync = function() calls = calls + 1 end,
    syncStatsAsync = function() calls = calls + 1 end,
}, { __index = SourceBase })

for _idx, hook in ipairs({ "onCreate", "onSuspend", "onResume", "onExit" }) do
    Assert.is_nil(source[hook](source, {}))
end
for _idx, event in ipairs({ "page_changed", "chapter_changed", "book_meta_changed", "desktop_open" }) do
    Assert.is_nil(source:onEvent(event, { identity = { stable_id = "a" } }))
end
Assert.eq(calls, 0)

return true
