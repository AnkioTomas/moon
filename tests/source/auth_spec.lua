-- source.auth：登录失效状态与单次提示。

local Assert = require("support.assert")
local Auth = require("source.auth")

local calls = {}
Auth.onExpired(function(id, msg) calls[#calls + 1] = { id = id, msg = msg } end)

do
    local current = Auth.currentAccount("sync-account-test")
    Auth.beginLogin("sync-account-test")
    Auth.reset()
    Assert.is_true(current(), "登录尝试和提示重置不能丢掉旧账号已上传的确认")
    Auth.changeAccount("unrelated-account")
    Assert.is_true(current())
    Auth.changeAccount("sync-account-test")
    Assert.is_false(current(), "成功换账号后旧同步确认失效")
    Assert.is_true(Auth.currentAccount("sync-account-test")())
end

do
    local first = Auth.beginLogin("version-test")
    Auth.ok("version-test")
    Assert.is_true(first(), "普通接口成功不使登录尝试失效")
    local second = Auth.beginLogin("version-test")
    Assert.is_false(first(), "新登录尝试使旧回包失效")
    Assert.is_true(second())
    Auth.beginLogin("another-source")
    Auth.reset()
    Assert.is_true(second(), "别的源登录和重载只重置失效提示，不改变本源账号版本")
    Auth.beginLogin("version-test")
    Assert.is_false(second(), "退出使用同一版本边界")
end

do
    local manager = package.loaded["ui/uimanager"]
    local preload = package.preload["ui/uimanager"]
    package.loaded["ui/uimanager"] = nil
    package.preload["ui/uimanager"] = function() error("UI initialization failed") end
    Assert.errors(function() Auth.ok("load-failure") end, "UI initialization failed")
    package.loaded["ui/uimanager"] = manager
    package.preload["ui/uimanager"] = preload
end

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

do
    -- 接口原文不能进弹窗；中文说明可以
    Assert.is_true(Auth.isTechnical("NOT.LOGIN"))
    Assert.is_true(Auth.isTechnical("NOT_LOGIN"))
    Assert.is_true(Auth.isTechnical("HTTP 401"))
    Assert.is_true(Auth.isTechnical("code=-2012"))
    Assert.is_true(Auth.isTechnical("login failed"))
    Assert.is_true(Auth.isTechnical(""))
    Assert.is_true(Auth.isTechnical(nil))
    Assert.is_nil(Auth.userDetail("NOT.LOGIN"))
    Assert.eq(Auth.userDetail("京东读书登录已失效，请重新扫码登录"),
        "京东读书登录已失效，请重新扫码登录")
    Assert.is_false(Auth.isTechnical("长佩登录已失效。网页 Cookie 登录无法自动续期，请改用扫码登录"))
end

print("auth_spec ok")
