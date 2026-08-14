--[[--
utils.promise 离线用例（UIManager stub + flush）

@module tests.promise_spec
--]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")
local Promise = require("utils.promise")

Stubs.reset()

-- 成功：next(result)
do
    local got
    Promise:new(function()
        return 42
    end):next(function(v)
        got = v
    end)
    Stubs.flush()
    Assert.eq(got, 42)
end

-- requireAsync：task 内通过，外层抛错
do
    Assert.is_false(Promise.inAsync())
    local ok_out, err = pcall(Promise.requireAsync, "test")
    Assert.is_false(ok_out)
    Assert.is_true(tostring(err):find("must run inside Promise", 1, true) ~= nil)

    local saw
    Promise:new(function()
        Assert.is_true(Promise.inAsync())
        Promise.requireAsync("test")
        saw = true
        return 1
    end)
    Stubs.flush()
    Assert.is_true(saw)
    Assert.is_false(Promise.inAsync())
end

-- next/fail 不算 inAsync（只认 task）
do
    local in_next = true
    Promise:new(function()
        return 1
    end):next(function()
        in_next = Promise.inAsync()
    end)
    Stubs.flush()
    Assert.is_false(in_next)
end

-- 失败：return nil, err
do
    local got
    Promise:new(function()
        return nil, "boom"
    end):fail(function(err)
        got = err
    end)
    Stubs.flush()
    Assert.eq(got, "boom")
end

-- task 抛错 → fail
do
    local got
    Promise:new(function()
        error("explode", 0)
    end):fail(function(err)
        got = tostring(err)
    end)
    Stubs.flush()
    Assert.is_true(got:find("explode", 1, true) ~= nil)
end

-- cancel：不再回调
do
    local called = false
    local p = Promise:new(function()
        return 1
    end):next(function()
        called = true
    end)
    p:cancel()
    Stubs.flush()
    Assert.is_false(called)
end

-- cancelAll
do
    local n = 0
    Promise:new(function()
        return 1
    end):next(function()
        n = n + 1
    end)
    Promise:new(function()
        return 2
    end):next(function()
        n = n + 1
    end)
    Promise.cancelAll()
    Stubs.flush()
    Assert.eq(n, 0)
end
