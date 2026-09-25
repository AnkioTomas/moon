--[[--
Lifecycle：Resume/Destroy 按状态补全；其余阶段单步进入。
@module tests.ui.lifecycle_spec
--]]
local Assert = require("support.assert")
local Lifecycle = require("ui.lifecycle")
local Child = setmetatable({}, Lifecycle)
Child.__index = Child
local calls = {}
for _, stage in ipairs({ "Create", "Resume", "Pause", "Destroy" }) do
    Child["on" .. stage] = function(self)
        Assert.eq(self.state, stage)
        calls[#calls + 1] = stage
    end
end

local first, second = Child:new(), Child:new()
Assert.is_false(first:uiReady())
Assert.eq(first.state, "new")

-- 显示：从 new 直接 Resume，补 Create。
calls = {}
first:onResume()
Assert.eq(first.state, "Resume")
Assert.eq(table.concat(calls, ","), "Create,Resume")
Assert.is_true(first:uiReady())

-- 已 Resume 再 Resume：只再进一次，不重放 Create。
calls = {}
first:onResume()
Assert.eq(table.concat(calls, ","), "Resume")

-- 暂停后恢复：不补 Create。
calls = {}
first:onPause()
first:onResume()
Assert.eq(table.concat(calls, ","), "Pause,Resume")

-- 销毁：从 Resume 补 Pause。
calls = {}
first:onDestroy()
Assert.eq(first.state, "Destroy")
Assert.eq(table.concat(calls, ","), "Pause,Destroy")
Assert.is_false(first:uiReady())

-- 已 Destroy 再 Destroy：无操作。
calls = {}
first:onDestroy()
Assert.eq(#calls, 0)
Assert.eq(first.state, "Destroy")

-- 已 Destroy 不可 Resume。
Assert.errors(function() first:onResume() end)
Assert.eq(first.state, "Destroy")

-- 第二实例互不影响。
Assert.eq(second.state, "new")
calls = {}
second:onDestroy()
Assert.eq(table.concat(calls, ","), "Destroy")
Assert.eq(second.state, "Destroy")

-- Create 后直接 Destroy：不补 Pause。
local mid = Child:new()
calls = {}
mid:onCreate()
mid:onDestroy()
Assert.eq(table.concat(calls, ","), "Create,Destroy")

-- Pause 后直接 Destroy：不补 Pause。
local paused = Child:new()
calls = {}
paused:onResume()
paused:onPause()
calls = {}
paused:onDestroy()
Assert.eq(table.concat(calls, ","), "Destroy")

local parent = { marker = true }
local owner = setmetatable({ state = { books = {} } }, { __index = parent })
local data = owner.state
local count = 0
function owner:onCreate()
    Assert.eq(self, owner)
    Assert.eq(self.lifecycle.state, "Create")
    count = count + 1
end
owner.lifecycle = Lifecycle.attach(owner)
owner:onCreate()
Assert.eq(count, 1)
Assert.eq(owner.state, data)
Assert.is_true(owner.marker)

-- 直接调用覆写方法同样记录状态，保留参数、返回值与 owner 身份。
local Direct = setmetatable({}, Lifecycle)
Direct.__index = Direct
function Direct:onResume(value)
    Assert.eq(self.state, "Resume")
    Assert.is_true(self:uiReady())
    return value, "result"
end
local direct = Direct:new()
local value, result = direct:onResume(42)
Assert.eq(value, 42)
Assert.eq(result, "result")
direct:onPause()
Assert.eq(direct.state, "Pause")
Assert.is_false(direct:uiReady())
direct:onEvent("Changed")
Assert.eq(direct.state, "Pause")

local composed = { state = { books = {} } }
local original_state = composed.state
function composed:onResume(value)
    Assert.eq(self.lifecycle.state, "Resume")
    return value
end
composed.lifecycle = Lifecycle.attach(composed)
Assert.eq(composed:onResume(7), 7)
Assert.is_true(composed.lifecycle:uiReady())
Assert.eq(composed.state, original_state)
composed:onDestroy()
Assert.eq(composed.lifecycle.state, "Destroy")
Assert.is_false(composed.lifecycle:uiReady())
composed:onDestroy()
Assert.eq(composed.lifecycle.state, "Destroy")

local queries = {
    uiReady = "Resume",
}
local probe = Lifecycle:new()
local owner_probe = {}
local attached = Lifecycle.attach(owner_probe)
for _, stage in ipairs({ "new", "Create", "Resume", "Pause", "Destroy" }) do
    if stage ~= "new" then
        probe["on" .. stage](probe)
        owner_probe["on" .. stage](owner_probe)
    end
    for method, expected in pairs(queries) do
        Assert.eq(probe[method](probe), stage == expected)
        Assert.eq(attached[method](attached), stage == expected)
    end
end

-- Pause 取消 http；表被清空。
local http_cancelled = 0
local worker = Lifecycle:new()
worker:addHttp({ cancel = function() http_cancelled = http_cancelled + 1 end })
Assert.eq(#worker.http, 1)
worker:onPause()
Assert.eq(http_cancelled, 1)
Assert.eq(#worker.http, 0)

-- 组合模式：owner:onPause 取消的是 lifecycle 上的表。
local host_http = 0
local host = {}
host.lifecycle = Lifecycle.attach(host)
host.lifecycle:addHttp({ cancel = function() host_http = host_http + 1 end })
host:onPause()
Assert.eq(host_http, 1)
Assert.eq(#host.lifecycle.http, 0)

-- Destroy 补 Pause 时同样 abort。
local dying = Lifecycle:new()
local dying_http = 0
dying:onResume()
dying:addHttp({ cancel = function() dying_http = dying_http + 1 end })
dying:onDestroy()
Assert.eq(dying_http, 1)
Assert.eq(#dying.http, 0)

-- 阶段入口带 name/id 日志主体；无 name 时仍可走完不炸。
local named = Lifecycle:new({ name = "probe" })
named:onCreate()
Assert.eq(named.state, "Create")
named:onResume()
Assert.eq(named.state, "Resume")

-- new(init)：拷贝业务字段，不改写调用方表；框架字段覆盖 init 同名键。
local seed = { desktop = "desk", state = "bogus", http = { "leak" }, tag = 1 }
local seeded = Lifecycle:new(seed)
Assert.eq(seeded.desktop, "desk")
Assert.eq(seeded.tag, 1)
Assert.eq(seeded.state, "new")
Assert.eq(#seeded.http, 0)
Assert.eq(seed.state, "bogus")
Assert.eq(seed.http[1], "leak")
Assert.is_nil(getmetatable(seed))

-- 未走 bind 的实例自己 abortWork。
local loose = setmetatable({ http = {} }, Lifecycle)
local loose_http = 0
loose:addHttp({ cancel = function() loose_http = loose_http + 1 end })
loose:abortWork()
Assert.eq(loose_http, 1)
Assert.eq(#loose.http, 0)
