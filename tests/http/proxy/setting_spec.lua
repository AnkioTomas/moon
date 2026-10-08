--[[--
http.setting：网络设置页（HTTP 代理）的开关、编辑、校验与实测。
@module tests.http.setting_spec
--]]

local Assert = require("support.assert")
local Themed = require("support.theme_stubs")
Themed.install()

package.preload["ui.themes.widgets.row"] = function()
    return { widget = function(opts) return opts end }
end
package.loaded["ui.themes.widgets.row"] = nil

local requests = {}
package.preload["http.request"] = function()
    return { request = function(opts, cb) requests[#requests + 1] = { opts = opts, cb = cb } end }
end
package.loaded["http.request"] = nil

local proxy_calls = {}
local store = {}
package.preload["ui/network/manager"] = function()
    return {
        setHTTPProxy = function(_self, url)
            proxy_calls[#proxy_calls + 1] = url or false
            if url then store.http_proxy = url end
            store.http_proxy_enabled = url ~= nil
        end,
    }
end
package.loaded["ui/network/manager"] = nil

local previous_settings = _G.G_reader_settings
_G.G_reader_settings = {
    readSetting = function(_self, key) return store[key] end,
    isTrue = function(_self, key) return store[key] == true end,
    delSetting = function(_self, key) store[key] = nil end,
}

package.loaded["http.proxy.setting"] = nil
local Setting = require("http.proxy.setting")

local views = 0
local desktop = { updateView = function() views = views + 1 end }

local function rows()
    local out = {}
    for i, build in ipairs(Setting.rows(desktop)) do out[i] = build(600) end
    return out
end

-- 未设置：入口显示直连；开关打开时先去填地址
local entry = Setting.entry(desktop)
Assert.eq(entry.status, "直连")
Assert.eq(entry.id, "network")
Assert.eq(#entry.page.sections()[1].rows, 2)
local r = rows()
Assert.eq(r[1].status, "关")
Assert.eq(r[2].status, "未设置")
r[1].callback()
local input = Themed.last("input")
Assert.eq(input.fields[1].text, "http://")
Assert.len(proxy_calls, 0, "没有地址不能启用")

-- 格式错：不发请求，提示错误并带原文重开
input.callback("https://secure.proxy:443")
Assert.len(requests, 0)
Assert.eq(Themed.last("toast").text, "只支持 http:// 代理")
Assert.eq(Themed.last("input").fields[1].text, "https://secure.proxy:443")
Themed.last("input").callback("http://host:99999")
Assert.eq(Themed.last("toast").text, "代理地址格式不正确")
Assert.len(requests, 0)

-- 测试按钮：经候选代理（规范化后）实测，不保存
Themed.last("input").actions[1].callback(" 10.0.0.2:3128 ")
Assert.len(requests, 1)
Assert.eq(requests[1].opts.proxy, "http://10.0.0.2:3128")
Assert.matches(requests[1].opts.url, "^https://")
local loading = Themed.last("toast")
Assert.eq(loading.dismissable, false, "实测期间提示不可点掉")
requests[1].cb({ code = 404 }, nil)
Assert.is_true(loading.closed)
Assert.eq(Themed.last("toast").text, "代理可用", "任何 HTTP 应答都算代理可用")
Assert.len(proxy_calls, 0, "测试不保存")

-- 保存：实测通过即保存并启用
Themed.last("input").callback("http://u:p@10.0.0.2:3128")
requests[2].cb({ code = 200 }, nil)
Assert.eq(proxy_calls[1], "http://u:p@10.0.0.2:3128")
Assert.eq(Themed.last("toast").text, "代理可用，已保存并启用")
entry = Setting.entry(desktop)
Assert.eq(entry.status, "10.0.0.2:3128", "状态不显示账号密码")
Assert.is_true(entry.status_on)

-- 保存：实测失败先确认，确认后才保存
Setting.rows(desktop)[2](600).callback()
Themed.last("input").callback("http://10.0.0.9:8080")
requests[3].cb(nil, "Could not connect: connection refused")
local confirm = Themed.last("confirm")
Assert.matches(confirm.text, "connection refused")
Assert.len(proxy_calls, 1, "确认前不保存")
confirm.ok_callback()
Assert.eq(proxy_calls[2], "http://10.0.0.9:8080")

-- 开关：关闭保留地址，再打开直接启用已存地址（不再实测）
r = rows()
Assert.eq(r[1].status, "开")
r[1].callback()
Assert.eq(proxy_calls[3], false)
Assert.eq(store.http_proxy, "http://10.0.0.9:8080")
Assert.eq(Setting.entry(desktop).status, "直连")
rows()[1].callback()
Assert.eq(proxy_calls[4], "http://10.0.0.9:8080")
Assert.len(requests, 3)

-- 清空地址：关闭并删除
Setting.rows(desktop)[2](600).callback()
Themed.last("input").callback("   ")
Assert.eq(proxy_calls[5], false)
Assert.is_nil(store.http_proxy)
Assert.is_true(views > 0)

_G.G_reader_settings = previous_settings
