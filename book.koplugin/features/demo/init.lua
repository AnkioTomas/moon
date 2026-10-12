--[[--
Feature 模板：演示 `features/init.lua` 的钩子约定，只打日志。

新 feature 复制本目录，在 `features/init.lua` 的 `list` 里登记目录名；用不到的钩子直接不写。

@module koplugin.book.features.demo
--]]

local logger = require("utils.log")

local Demo = {}

---@param plugin BookPlugin
function Demo.onCreate(plugin)
    logger.dbg("feature demo create", plugin.ui.document and "reader" or "desktop")
end

function Demo.onSuspend()
    logger.dbg("feature demo suspend")
end

function Demo.onResume()
    logger.dbg("feature demo resume")
end

function Demo.onExit()
    logger.dbg("feature demo destroy")
end

return Demo
