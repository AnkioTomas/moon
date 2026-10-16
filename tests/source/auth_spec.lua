-- source.auth：登录失效状态与单次提示。

local Assert = require("support.assert")
local Auth = require("source.auth")

local calls = {}
Auth.onExpired(function(id, msg) calls[#calls + 1] = { id = id, msg = msg } end)

do
    Assert.is_false(Auth.expired("moon"))
    Assert.eq("bad", Auth.expire("moon", "bad"))
    Assert.is_true(Auth.expired("moon"))
    Assert.eq(1, #calls)
    Assert.eq("moon", calls[1].id)
    Assert.eq("bad", calls[1].msg)
    -- 同一源再次失效不再提示
    Auth.expire("moon", "bad again")
    Assert.eq(1, #calls)
    -- 成功清标记，但本次运行不重复弹
    Auth.ok("moon")
    Assert.is_false(Auth.expired("moon"))
    Auth.expire("moon", "x")
    Assert.is_true(Auth.expired("moon"))
    Assert.eq(1, #calls)
    -- 别的源独立
    Auth.expire("wechat", "w")
    Assert.eq(2, #calls)
    -- 重新登录（reset）后重新判定并可再提示
    Auth.reset()
    Assert.is_false(Auth.expired("moon"))
    Auth.expire("moon", "y")
    Assert.eq(3, #calls)
end

do
    -- handler 出错不影响调用方
    Auth.reset()
    Auth.onExpired(function() error("boom") end)
    Assert.eq("m", Auth.expire("fanqie", "m"))
    Assert.is_true(Auth.expired("fanqie"))
    Auth.onExpired(nil)
    Auth.reset()
end

print("auth_spec ok")
