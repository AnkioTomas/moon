--[[-- http.request.stream：无 Turbo 时 on_done 报错；cancel 可用。 --]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")

local Request = require("http.request")

-- Turbo 不可用路径
do
    local orig = Request.ensureTurbo
    Request.ensureTurbo = function() return false end
    local done_err
    Request.stream({ url = "https://example.test/" }, {
        on_done = function(err) done_err = err end,
    })
    Stubs.flush()
    Assert.eq(done_err, "turbo looper unavailable")
    Request.ensureTurbo = orig
end

-- cancel 在启动前
do
    local orig = Request.ensureTurbo
    Request.ensureTurbo = function() return false end
    local done_err
    local job = Request.stream({ url = "https://example.test/" }, {
        on_done = function(err) done_err = err end,
    })
    job.cancel()
    Stubs.flush()
    -- cancel 抢先 finish；或 turbo 不可用回调——两者都可接受已完成
    Assert.is_true(done_err == "cancelled" or done_err == "turbo looper unavailable")
    Request.ensureTurbo = orig
end

-- looper 可用但 Turbo 初始化失败：必须 on_done 收口，不能让输入超时引用泄漏。
do
    local UIManager = require("ui/uimanager")
    local orig = Request.ensureTurbo
    local resets = 0
    Request.ensureTurbo = function() return true end
    UIManager.setInputTimeout = function() end
    UIManager.resetInputTimeout = function() resets = resets + 1 end
    UIManager.looper = {
        add_callback = function(_, fn)
            local co = coroutine.create(fn)
            local ok, err = coroutine.resume(co)
            if not ok then error(err) end
        end,
    }
    package.loaded["turbo"] = nil
    package.preload["turbo"] = function()
        error("turbo load failed")
    end

    local done_err
    Request.stream({ url = "https://example.test/" }, {
        on_done = function(err) done_err = err end,
    })

    Request.ensureTurbo = orig
    package.preload["turbo"] = nil
    package.loaded["turbo"] = nil
    Assert.matches(tostring(done_err), "turbo load failed")
    Assert.eq(resets, 1)
end
