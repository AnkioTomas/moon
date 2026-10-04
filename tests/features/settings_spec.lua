--[[--
Feature 设置收集：缺文件跳过、id 前缀、分组与页校验。

@module tests.features.settings_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

local Assert = require("support.assert")
local Features = require("features")

local saved = Features.list
local sections = function() return {} end

local function setting(name, entries)
    package.preload["features." .. name .. ".setting"] = function()
        return { entries = function() return entries end }
    end
end

-- 没有 setting.lua 的 feature 不产生入口（panel 是真实登记，文件不存在）
Features.list = { "panel" }
Assert.len(Features.settings({}), 0)

-- list 顺序；显式 id 与省略 id（序号）；group 原样保留
setting("b", {
    { id = "main", group = "reader", title = "乙", page = { title = "乙", sections = sections } },
})
setting("a", {
    { group = "desktop", title = "甲", page = { title = "甲", sections = sections } },
})
Features.list = { "panel", "b", "a" }
local rows = Features.settings({})
Assert.len(rows, 2)
Assert.eq(rows[1].id, "feature:b:main")
Assert.eq(rows[1].group, "reader")
Assert.eq(rows[1].page.id, "feature:b:main")
Assert.eq(rows[1].page.title, "乙")
Assert.eq(rows[1].page.sections, sections)
Assert.eq(rows[2].id, "feature:a:1")
Assert.eq(rows[2].group, "desktop")

-- 重复收集不改调用方的 id（根页每次重建都会再收集一次）
local again = Features.settings({})
Assert.eq(again[1].id, "feature:b:main")
Assert.eq(again[2].id, "feature:a:1")

-- 误返回单条设置表
setting("bare", { group = "reader", title = "裸", page = { title = "裸", sections = sections } })
Features.list = { "bare" }
Assert.errors(function() Features.settings({}) end, "must return a list")

-- 未知分组
setting("badgroup", {
    { group = "nope", title = "x", page = { title = "x", sections = sections } },
})
Features.list = { "badgroup" }
Assert.errors(function() Features.settings({}) end, "unknown group")

-- 缺 sections
setting("badpage", {
    { group = "system", title = "x", page = { title = "x" } },
})
Features.list = { "badpage" }
Assert.errors(function() Features.settings({}) end, "sections")

Features.list = saved
