--[[--
扩展点注册表：只认已声明的挂点；list 按登记顺序给副本；last / call 取最后登记的单一提供者；
emit 逐项调用且一项出错不影响其余。
@module tests.utils.extension_spec
--]]
local Assert = require("support.assert")
local reported = {}
package.loaded["ui.guard"] = {
    call = function(label, fn, ...)
        local ok, err = pcall(fn, ...)
        if not ok then reported[#reported + 1] = label .. ":" .. tostring(err):match("[^:]+$") end
        return ok
    end,
}
local Ext = require("utils.extension")

Assert.errors(function() Ext.add("nope.point", function() end) end, "unknown extension point")
Assert.errors(function() Ext.list("subscribe.enabled") end, "unknown extension point")
Assert.errors(function() Ext.add("desktop.opened", nil) end, "item is nil")

Assert.is_nil(Ext.call("quickpanel.show", "desktop"), "没人登记返回 nil")
Assert.len(Ext.list("desktop.tabs"), 0)

Ext.add("quickpanel.show", function(scope) return "a:" .. scope end)
Ext.add("quickpanel.show", function(scope) return "b:" .. scope end)
Assert.eq(Ext.call("quickpanel.show", "reader"), "b:reader", "单一提供者取最后登记的")

local seen = {}
Ext.add("desktop.activated", function(d) seen[#seen + 1] = "1" .. d end)
Ext.add("desktop.activated", function() error("boom") end)
Ext.add("desktop.activated", function(d) seen[#seen + 1] = "3" .. d end)
Ext.emit("desktop.activated", "x")
Assert.eq(table.concat(seen, ","), "1x,3x", "出错的一项不拦后面")
Assert.len(reported, 1)

local list = Ext.list("desktop.activated")
list[1] = nil
Assert.len(Ext.list("desktop.activated"), 3, "list 给副本")

-- 声明的挂点都以下层命名空间开头
for point in pairs(Ext.POINTS) do
    Assert.not_nil(point:match("^(%a+)%."), point)
end

Ext.reset()
Assert.len(Ext.list("desktop.activated"), 0)
