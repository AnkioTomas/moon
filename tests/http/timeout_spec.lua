--[[-- http.timeout：设置为秒数，代码里写倍率；默认值下与改动前完全一致，调高调低对称。 --]]

local Assert = require("support.assert")

local cfg = { http = {}, ai = {} }
package.preload["utils.settings"] = function()
    return { get = function(name) return cfg[name] end, save = function() end }
end
local Timeout = require("http.timeout")

-- 默认：网络 30、AI 120；各处倍率换算回原先写死的秒数。
Assert.eq(Timeout.networkSeconds(), 30)
Assert.eq(Timeout.aiSeconds(), 120)
Assert.eq(Timeout.net(), 30)
Assert.eq(Timeout.net(10), 300, "下载")
Assert.eq(Timeout.net(0.5), 15, "番茄")
Assert.eq(Timeout.net(2 / 3), 20, "连接 / 百科")
Assert.eq(Timeout.net(1 / 3), 10, "更新探测")
Assert.eq(Timeout.ai(), 120)
Assert.eq(Timeout.ai(0.5), 60, "解释")
Assert.eq(Timeout.ai(0.75), 90, "摘要")
Assert.eq(Timeout.ai(1.5), 180, "报告 / X-Ray")

local t, c = Timeout.resolve({}, 1)
Assert.eq(t, 30); Assert.eq(c, 20)
t, c = Timeout.resolve({}, 6)
Assert.eq(t, 180); Assert.eq(c, 20, "stream 缺省")
t, c = Timeout.resolve({ timeout = 15, connect_timeout = 10 }, 1)
Assert.eq(t, 15); Assert.eq(c, 10, "调用方换算好的原样用")
t, c = Timeout.resolve({ timeout = 5 }, 1)
Assert.eq(c, 5, "连接超时不超过整包")

-- 调高 / 调低对称：所有倍率按同一比例变化，没有只放大不缩小的特例。
Timeout.setNetworkSeconds(60)
Assert.eq(Timeout.net(10), 600)
Assert.eq(Timeout.net(0.5), 30)
t, c = Timeout.resolve({}, 1)
Assert.eq(t, 60); Assert.eq(c, 40)
Timeout.setNetworkSeconds(15)
Assert.eq(Timeout.net(10), 150)
Assert.eq(Timeout.net(1 / 3), 5)
t, c = Timeout.resolve({}, 6)
Assert.eq(t, 90); Assert.eq(c, 10)
Assert.eq(Timeout.ai(), 120, "AI 不受网络超时影响")

-- AI 只用 AI 设置。
Timeout.setAiSeconds(60)
Assert.eq(Timeout.ai(0.5), 30)
Assert.eq(Timeout.ai(1.5), 90)
Assert.eq(Timeout.net(), 15, "网络不受 AI 影响")

-- 范围与 1 秒下限。
Timeout.setNetworkSeconds(1)
Assert.eq(Timeout.networkSeconds(), 5)
Assert.eq(Timeout.net(0.01), 1, "最小 1 秒")
Timeout.setNetworkSeconds(9999)
Assert.eq(Timeout.networkSeconds(), 300)
Timeout.setAiSeconds(1)
Assert.eq(Timeout.aiSeconds(), 10)
Timeout.setAiSeconds(9999)
Assert.eq(Timeout.aiSeconds(), 600)

return true
