--[[--
Feature 分发：按 list 顺序调钩子、缺钩子跳过、参数透传、抛错上抛。

@module tests.features.init_spec
--]]

local Assert = require("support.assert")

package.preload["utils.log"] = function()
    return { dbg = function() end }
end

local seen = {}
local function feature(name, hooks)
    local mod = {}
    for _, hook in ipairs(hooks) do
        mod[hook] = function(plugin) seen[#seen + 1] = name .. ":" .. hook .. ":" .. plugin.id end
    end
    package.preload["features." .. name .. ".init"] = function() return mod end
end
feature("b", { "onCreate", "onPause" })
feature("a", { "onCreate" })

local Features = require("features.init")

-- 真实 list 的每个条目都能加载，且全部钩子可调
for _, hook in ipairs({ "onCreate", "onPause", "onResume", "onDestroy" }) do
    Features.emit(hook, { id = "real", ui = {} })
end
Assert.eq(Features.list[1], "tpl")

-- 顺序即 list 顺序（不按字母）；缺钩子的 feature 跳过
Features.list = { "b", "a" }
local plugin = { id = "p" }
Features.emit("onCreate", plugin)
Features.emit("onPause", plugin)
Features.emit("onResume", plugin)
Assert.eq(table.concat(seen, ","), "b:onCreate:p,a:onCreate:p,b:onPause:p")

-- 空列表不调任何东西
seen = {}
Features.list = {}
Features.emit("onCreate", plugin)
Assert.len(seen, 0)

-- 钩子抛错不吞
package.preload["features.bad.init"] = function()
    return { onCreate = function() error("boom") end }
end
Features.list = { "bad" }
Assert.errors(function() Features.emit("onCreate", plugin) end)
