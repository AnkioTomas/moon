--[[--
快捷面板注册表：内置顺序不变，feature 开关接在对应 scope 末尾。

@module tests.features.panel.registry_spec
--]]
---@diagnostic disable: undefined-field, missing-fields

local Assert = require("support.assert")

package.preload["l10n"] = function() return { apply = function() end } end
package.preload["gettext"] = function() return function(s) return s end end

local DESKTOP = {
    "night", "wifi", "rotate", "refresh", "screenshot", "frontlight", "autolight", "suspend",
}
local READER = {
    "toc", "font", "highlights", "bookorbit", "xray", "xray_refresh",
}
for _, id in ipairs(DESKTOP) do
    package.preload["features.panel.actions.desktop." .. id] = function()
        return { id = id, title = id, icon = "x", scope = "desktop" }
    end
end
for _, id in ipairs(READER) do
    package.preload["features.panel.actions.reader." .. id] = function()
        return { id = id, title = id, icon = "x", scope = "reader" }
    end
end

local Registry = require("features.panel.actions.registry")
local desktop = Registry.desktopOrder()
local reader = Registry.readerOrder()

Assert.eq(desktop[#desktop], "remote")
Assert.eq(table.concat(desktop, ",", 1, #DESKTOP), table.concat(DESKTOP, ","))
Assert.eq(Registry.get("remote").scope, "desktop")
Assert.eq(Registry.get("remote").icon, "dns")
-- reflow / page_turn 由 feature 追加在内置项之后，按 Features.list 顺序。
Assert.eq(table.concat(reader, ","), table.concat(READER, ",") .. ",reflow,page_turn")
Assert.eq(Registry.get("page_turn").scope, "reader")
Assert.is_nil(Registry.get("missing"))

-- 和内置 id 冲突直接报错，不能盖住 night。
package.loaded["features.panel.actions.registry"] = nil
package.loaded["features.remote.panel"] = nil
package.preload["features.remote.panel"] = function()
    return {
        actions = function()
            return { { id = "night", title = "冲突", icon = "x", scope = "desktop" } }
        end,
    }
end
Registry = require("features.panel.actions.registry")
Assert.errors(function() Registry.desktopOrder() end, "already registered")
