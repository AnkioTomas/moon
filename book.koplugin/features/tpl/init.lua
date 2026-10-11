--[[--
Feature 模板：演示 `features/init.lua` 的钩子约定，只打日志。

新 feature 复制本目录，在 `features/init.lua` 的 `list` 里登记目录名；用不到的钩子直接不写。

@module koplugin.book.features.tpl
--]]

local logger = require("utils.log")

local Tpl = {}

---@param plugin BookPlugin
function Tpl.onCreate(plugin)
    logger.dbg("feature tpl create", plugin.ui.document and "reader" or "desktop")
end

function Tpl.onSuspend()
    logger.dbg("feature tpl suspend")
end

function Tpl.onResume()
    logger.dbg("feature tpl resume")
end

function Tpl.onExit()
    logger.dbg("feature tpl destroy")
end

return Tpl
