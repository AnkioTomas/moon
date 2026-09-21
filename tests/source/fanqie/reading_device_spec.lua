--[[--
番茄设备身份：本地画像唯一 + device_register 落盘（HTTP 打桩）。

@module tests.source.fanqie.reading_device_spec
--]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")

local state = {
    cfg = {},
    saved = nil,
    request_impl = nil,
}

package.preload["utils.settings"] = function()
    return {
        getSource = function() return state.cfg end,
        saveSource = function(_, value)
            state.saved = value
            state.cfg = value
        end,
    }
end

package.preload["http.request"] = function()
    return {
        ok = function(code)
            local n = tonumber(code)
            return n ~= nil and n >= 200 and n < 300
        end,
        header = function() return nil end,
        request = function(opts, cb)
            return state.request_impl(opts, cb)
        end,
    }
end

package.preload["json"] = function()
    return {
        encode = function(t)
            -- 足够 register body 冒烟：只要发出去
            Assert.eq(type(t), "table")
            Assert.eq(t.magic_tag, "ss_app_log")
            return '{"magic_tag":"ss_app_log"}'
        end,
        decode = function(s)
            if type(s) ~= "string" or s == "" then error("empty") end
            -- 极简：只解析我们罐装的响应
            local did = s:match('"device_id_str"%s*:%s*"(%d+)"')
                or s:match('"device_id"%s*:%s*(%d+)')
            local iid = s:match('"install_id_str"%s*:%s*"(%d+)"')
                or s:match('"install_id"%s*:%s*(%d+)')
            if not did or not iid then error("bad json") end
            return {
                device_id = tonumber(did),
                install_id = tonumber(iid),
                device_id_str = did,
                install_id_str = iid,
                new_user = 1,
            }
        end,
    }
end

for _, name in ipairs({
    "utils.settings", "http.request", "json",
    "source.fanqie.reading.device", "source.fanqie.settings",
}) do
    package.loaded[name] = nil
end

local Device = require("source.fanqie.reading.device")
local Settings = require("source.fanqie.settings")

-- normalize：缺 id 一律拒绝（禁止半残共享身份）
Assert.is_nil(Device.normalize(nil))
Assert.is_nil(Device.normalize({}))
Assert.is_nil(Device.normalize({ device_id = "1" }))
Assert.is_nil(Device.normalize({ install_id = "1" }))

-- 本地画像每次唯一
local a = Device.newLocalProfile()
local b = Device.newLocalProfile()
Assert.is_true(a.cdid ~= b.cdid)
Assert.is_true(a.openudid ~= b.openudid)
Assert.eq(#a.openudid, 16)
Assert.matches(a.cdid, "^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$")
Assert.is_nil(a.device_id)
Assert.is_nil(a.install_id)

local ok = Device.normalize({
    device_id = "123",
    install_id = "456",
    device_profile = { device_type = "Pixel", cdid = a.cdid, openudid = a.openudid },
})
Assert.eq(ok.device_id, "123")
Assert.eq(ok.install_id, "456")
Assert.eq(ok.device_type, "Pixel")
Assert.eq(ok.cdid, a.cdid)
Assert.is_nil(Device.DEFAULT)

-- registerAsync：打桩 HTTP，校验 URL / 落盘
state.cfg = {}
state.saved = nil
local settings = Settings:new()
local seen_url
state.request_impl = function(opts, cb)
    seen_url = opts.url
    Assert.eq(opts.method, "POST")
    Assert.matches(opts.url, "log%.snssdk%.com/service/2/device_register/")
    Assert.matches(opts.url, "aid=1967")
    Assert.matches(opts.url, "app_name=novelapp")
    Assert.eq(opts.headers["Content-Type"], "application/json; charset=utf-8")
    require("ui/uimanager"):nextTick(function()
        cb({
            code = 200,
            body = '{"device_id_str":"516130687997515","install_id_str":"516130688001611","new_user":1}',
        })
    end)
    return { cancel = function() end }
end

local got, reg_err
Device.registerAsync(settings, function(device, err)
    got, reg_err = device, err
end)
Stubs.flush()
Assert.is_nil(reg_err)
Assert.eq(got.device_id, "516130687997515")
Assert.eq(got.install_id, "516130688001611")
Assert.is_true(type(got.cdid) == "string" and got.cdid ~= "")
Assert.matches(seen_url, "openudid=")
Assert.eq(state.saved.reading_device.device_id, "516130687997515")
Assert.eq(state.saved.reading_device.install_id, "516130688001611")

-- ensureAsync：已有身份不再请求网络
local net_hits = 0
state.request_impl = function(_, cb)
    net_hits = net_hits + 1
    cb(nil, "should not call")
    return { cancel = function() end }
end
local cached, cache_err
Device.ensureAsync(settings, function(device, err)
    cached, cache_err = device, err
end)
Stubs.flush()
Assert.is_nil(cache_err)
Assert.eq(cached.device_id, "516130687997515")
Assert.eq(net_hits, 0)

-- ensureAsync：无身份则注册
state.cfg = {}
state.saved = nil
settings = Settings:new()
state.request_impl = function(_, cb)
    require("ui/uimanager"):nextTick(function()
        cb({
            code = 200,
            body = '{"device_id":999001,"install_id":999002,"new_user":1}',
        })
    end)
    return { cancel = function() end }
end
local ensured
Device.ensureAsync(settings, function(device, err)
    ensured, cache_err = device, err
end)
Stubs.flush()
Assert.is_nil(cache_err)
Assert.eq(ensured.device_id, "999001")
Assert.eq(ensured.install_id, "999002")

-- 传输错误：res 表还在，但 err 才是超时原因，不能报成 HTTP nil
state.cfg = {}
state.saved = nil
settings = Settings:new()
state.request_impl = function(_, cb)
    require("ui/uimanager"):nextTick(function()
        cb({ error = { code = -6, message = "Request timed out after 20 secs" } },
            "Request timed out after 20 secs")
    end)
    return { cancel = function() end }
end
local timed
Device.registerAsync(settings, function(device, err)
    timed = err
    Assert.is_nil(device)
end)
Stubs.flush()
Assert.eq(timed, "Request timed out after 20 secs")
Assert.is_nil(state.saved)
