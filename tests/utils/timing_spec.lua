--[[--
utils.timing：节流 / 防抖

@module tests.utils.timing_spec
--]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")

Stubs.install()

package.loaded["utils.timing"] = nil
local Timing = require("utils.timing")

-- debounce：多次调用只执行最后一次
do
    Stubs.reset()
    local seen = {}
    local d = Timing.debounce(function(v)
        seen[#seen + 1] = v
    end, 0.3)
    d("a")
    d("b")
    d("c")
    Assert.len(seen, 0)
    Stubs.flush()
    Assert.len(seen, 1)
    Assert.eq(seen[1], "c")
end

-- debounce：cancel 取消挂起
do
    Stubs.reset()
    local called = false
    local d = Timing.debounce(function()
        called = true
    end, 0.3)
    d()
    d:cancel()
    Stubs.flush()
    Assert.is_true(not called)
end

-- throttle：窗口内第二次丢弃；flush 解锁后可再跑
do
    Stubs.reset()
    local n = 0
    local t = Timing.throttle(function()
        n = n + 1
        return n
    end, 1)
    Assert.eq(t(), 1)
    Assert.is_nil(t())
    Assert.eq(n, 1)
    Stubs.flush()
    Assert.eq(t(), 2)
    Assert.eq(n, 2)
end

-- throttle：cancel 解除锁定
do
    Stubs.reset()
    local n = 0
    local t = Timing.throttle(function()
        n = n + 1
    end, 1)
    t()
    Assert.eq(n, 1)
    t:cancel()
    t()
    Assert.eq(n, 2)
end

-- 非法参数
Assert.errors(function()
    Timing.debounce("x", 1)
end)
Assert.errors(function()
    Timing.throttle(function() end, -1)
end)
