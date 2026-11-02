--[[--
source.kindle.plugin_update：kindle.koplugin 目标描述（固定 armv7 包、装在月读同级目录）。流程本身由 features.update 的 spec 覆盖。

@module tests.source.kindle.plugin_update_spec
--]]
---@diagnostic disable: undefined-field, missing-fields

local Assert = require("support.assert")

local Update = require("source.kindle.plugin_update")
local target = Update.target

Assert.eq(target.repo, "kaikozlov/kindle.koplugin", "仓库")
Assert.eq(target.asset("v0.0.11"), "kindle-koplugin-armv7.zip", "资产名固定，不随 tag 变")

Assert.eq(target.name, "kindle.koplugin", "包内目录名")
