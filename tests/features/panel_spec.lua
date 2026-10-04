--[[--
Feature 快捷面板开关收集：缺文件跳过、scope 校验、重复 id。

@module tests.features.panel_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

local Assert = require("support.assert")
local Features = require("features")

local saved = Features.list

local function panel(name, actions)
    package.preload["features." .. name .. ".panel"] = function()
        return { actions = function() return actions end }
    end
end

-- 没有 panel.lua 的 feature 不产生开关
Features.list = { "no_such_feature" }
Assert.len(Features.panels(), 0)

panel("desk", {
    { id = "desk_switch", title = "桌面开关", icon = "dns", scope = "desktop" },
})
panel("read", {
    { id = "read_switch", title = "阅读开关", icon = "menu_book", scope = "reader" },
    { id = "read_more", title = "另一个", icon = "tune", scope = "reader" },
})
Features.list = { "desk", "read" }
local actions = Features.panels()
Assert.len(actions, 3)
Assert.eq(actions[1].id, "desk_switch")
Assert.eq(actions[1].scope, "desktop")
Assert.eq(actions[2].id, "read_switch")
Assert.eq(actions[3].id, "read_more")

-- 误返回单条动作表
panel("bare", { id = "bare", title = "裸", icon = "tune", scope = "desktop" })
Features.list = { "bare" }
Assert.errors(function() Features.panels() end, "must return a list")

-- 未知 scope
panel("badscope", {
    { id = "x", title = "x", icon = "tune", scope = "library" },
})
Features.list = { "badscope" }
Assert.errors(function() Features.panels() end, "unknown scope")

-- 缺图标
panel("noicon", {
    { id = "x", title = "x", scope = "reader" },
})
Features.list = { "noicon" }
Assert.errors(function() Features.panels() end, "title and icon")

-- 两个 feature 用了同一个 id
panel("one", { { id = "same", title = "甲", icon = "tune", scope = "desktop" } })
panel("two", { { id = "same", title = "乙", icon = "tune", scope = "reader" } })
Features.list = { "one", "two" }
Assert.errors(function() Features.panels() end, "duplicate id")

Features.list = saved
