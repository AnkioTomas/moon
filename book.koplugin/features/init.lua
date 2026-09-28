--[[--
Feature 生命周期分发。

`list` 是唯一登记处：条目为目录名，对应模块 `features.<name>.init`；顺序即调用顺序
（monkey-patch 同一 KOReader 方法的 feature 靠它定先后），不扫目录。

钩子都是可选的模块函数，参数统一为插件实例：

  onCreate(plugin)   每个插件实例 init 时（FM / Reader 各一份），feature 自行防重入
  onPause(plugin)    休眠前
  onResume(plugin)   唤醒后
  onDestroy(plugin)  KOReader 退出

钩子抛错直接上抛。

@module koplugin.book.features
--]]

local Features = {}

Features.list = { "tpl" }

---@param hook string
---@param plugin BookPlugin
function Features.emit(hook, plugin)
    for _, name in ipairs(Features.list) do
        local fn = require("features." .. name .. ".init")[hook]
        if fn then fn(plugin) end
    end
end

return Features
