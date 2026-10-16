--[[--
快捷面板注册表：内置顺序不变，feature 开关接在对应 scope 末尾。

@module tests.features.panel.registry_spec
--]]
---@diagnostic disable: undefined-field, missing-fields

local Assert = require("support.assert")

package.preload["l10n"] = function() return { apply = function() end } end
package.preload["gettext"] = function() return function(s) return s end end

local DESKTOP = {
    "night", "wifi", "rotate", "refresh", "screenshot", "frontlight", "suspend",
}
local READER = {
    "toc", "font", "highlights", "bookorbit", "push_progress", "pull_progress", "save_default",
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
-- feature 自己的开关经 features/<name>/panel.lua 追加在内置项之后，按目录名顺序。
Assert.eq(table.concat(desktop, ",", #DESKTOP + 1), "bluetooth,bluetooth_devices,autolight,remote")
Assert.eq(table.concat(reader, ","), table.concat(READER, ",") .. ",ai_recap,ai_report,ai_ask,page_turn,reflow,wechat_reviews_link,bilingual,xray,xray_refresh")
Assert.eq(Registry.get("page_turn").scope, "reader")
Assert.is_nil(Registry.get("missing"))

-- 和内置 id 冲突直接报错，不能盖住 night。
package.loaded["features.panel.actions.registry"] = nil
package.loaded["features.remote.panel"] = nil
package.preload["features.remote.panel"] = function()
    return {
        actions = function()
            return { { id = "night", title = "冲突", icon = "x", scope = "desktop", event = "X" } }
        end,
    }
end
Registry = require("features.panel.actions.registry")
Assert.errors(function() Registry.desktopOrder() end, "already registered")

-- feature 开关校验：经 Features.scan 收集，非法条目直接报错
local function withPanel(actions)
    package.loaded["features.panel.actions.registry"] = nil
    package.loaded["features"] = nil
    package.preload["features"] = function() return { scan = function() return { "fake" } end, external = function() return {}, true end } end
    package.loaded["features.fake.panel"] = nil
    package.preload["features.fake.panel"] = function() return { actions = function() return actions end } end
    return require("features.panel.actions.registry")
end
Assert.errors(function()
    withPanel({ id = "bare", title = "裸", icon = "tune", scope = "desktop" }).desktopOrder()
end, "must return a list")
Assert.errors(function()
    withPanel({ { id = "x", title = "x", icon = "tune", scope = "library" } }).desktopOrder()
end, "unknown scope")
Assert.errors(function() withPanel({ { id = "x", title = "x", scope = "reader" } }).desktopOrder() end, "title and icon")
Assert.errors(function() withPanel({ { title = "x", icon = "tune", scope = "reader" } }).desktopOrder() end, "needs id")
Assert.errors(function()
    withPanel({
        { id = "same", title = "甲", icon = "tune", scope = "desktop", event = "X" },
        { id = "same", title = "乙", icon = "tune", scope = "reader", event = "X" },
    }).desktopOrder()
end, "already registered")
Assert.errors(function()
    withPanel({ { id = "x", title = "x", icon = "tune", scope = "reader" } }).readerOrder()
end, "run or event")
local ok = withPanel({ { id = "extra", title = "额外", icon = "tune", scope = "reader", run = function() end } })
Assert.eq(ok.readerOrder()[#READER + 1], "extra")
