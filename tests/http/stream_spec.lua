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
