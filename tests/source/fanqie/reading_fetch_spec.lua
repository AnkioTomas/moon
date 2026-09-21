--[[--
番茄 reading.fetchAsync：ensure 设备 → registerkey → batch_full（全打桩）。

@module tests.source.fanqie.reading_fetch_spec
--]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")

local state = {
    cfg = {
        reading_device = {
            device_id = "516130687997515",
            install_id = "516130688001611",
            device_profile = {
                channel = "43536163a",
                version_code = "73733",
                version_name = "7.3.7.33",
                device_type = "P30",
                device_brand = "HUAWEI",
                language = "zh",
                os_api = "31",
                os_version = "12",
                resolution = "1280*720",
                dpi = "240",
                host_abi = "arm64-v8a",
                cdid = "8550abb6-a07b-4b77-9edd-6710f414828b",
                openudid = "733b78130c0d0098",
                rom_version = "S643.217451.03386707",
            },
        },
    },
    urls = {},
}

package.preload["utils.settings"] = function()
    return {
        getSource = function() return state.cfg end,
        saveSource = function(_, value) state.cfg = value end,
    }
end

-- registerkey / batch_full 都要编解码 JSON
package.preload["json"] = function()
    local J = require("support.json_stub")
    return { encode = J.encode, decode = J.decode }
end
package.loaded["json"] = nil

-- 用真实 crypto 解一把已知向量，给 fetch 罐装响应
package.loaded["crypto.aes"] = nil
package.loaded["source.fanqie.reading.crypto"] = nil
local Aes = require("crypto.aes")
local Crypto = require("source.fanqie.reading.crypto")
local Text = require("utils.text")

-- 构造假 v1_key 与假章节密文
local v1_bin = Aes.from_hex("00112233445566778899aabbccddeeff")
local v1_hex = Aes.to_hex(v1_bin):upper()
local iv = "0123456789abcdef"
local plain = "<?xml version=\"1.0\"?><html><body>第776章 养女如母 测试正文内容足够长</body></html>"
-- compress_status=0：不解压
local enc = Aes.cbc_encrypt(plain, v1_bin, iv, true)
local content_b64 = Text.base64Encode(iv .. enc)
local key_blob = Text.base64Encode(iv .. Aes.cbc_encrypt(v1_bin, Aes.from_hex(Crypto.HARDCODED_KEY_HEX), iv, true))

package.preload["http.request"] = function()
    return {
        ok = function(code)
            local n = tonumber(code)
            return n ~= nil and n >= 200 and n < 300
        end,
        header = function() return nil end,
        request = function(opts, cb)
            state.urls[#state.urls + 1] = opts.url
            require("ui/uimanager"):nextTick(function()
                if opts.url:find("/reading/crypt/registerkey", 1, true) then
                    Assert.eq(opts.method, "POST")
                    Assert.is_true(opts.headers["X-Argus"] ~= nil)
                    Assert.is_true(opts.headers["X-Ladon"] ~= nil)
                    cb({
                        code = 200,
                        body = '{"code":0,"data":{"key":"' .. key_blob .. '","keyver":1},"message":"ok"}',
                    })
                    return
                end
                if opts.url:find("/reading/reader/batch_full", 1, true) then
                    Assert.eq(opts.method, "GET")
                    Assert.matches(opts.url, "item_ids=7463695105224884760")
                    Assert.matches(opts.url, "book_id=7342475219212192830")
                    Assert.is_true(not opts.url:find("%%2C", 1, true))
                    cb({
                        code = 200,
                        body = '{"code":0,"data":{"7463695105224884760":{'
                            .. '"title":"第776章 养女如母",'
                            .. '"crypt_status":0,"compress_status":0,'
                            .. '"content":"' .. content_b64 .. '"}}}',
                    })
                    return
                end
                cb(nil, "unexpected url " .. tostring(opts.url))
            end)
            return { cancel = function() end }
        end,
    }
end

for _, name in ipairs({
    "http.request", "utils.settings", "json",
    "source.fanqie.reading",
    "source.fanqie.reading.device", "source.fanqie.settings",
    "source.fanqie.reading.sign",
}) do
    package.loaded[name] = nil
end

local Reading = require("source.fanqie.reading")
local Settings = require("source.fanqie.settings")

local row, fetch_err
Reading.fetchAsync(Settings:new(), "7342475219212192830", "7463695105224884760", function(data, err)
    row, fetch_err = data, err
end)
Stubs.flush()

Assert.is_nil(fetch_err)
Assert.eq(row.title, "第776章 养女如母")
Assert.eq(row.source, "reading_batch_full")
Assert.matches(row.content, "养女如母")
Assert.eq(#state.urls, 2)
Assert.matches(state.urls[1], "registerkey")
Assert.matches(state.urls[2], "batch_full")

-- 无设备身份时先走 device_register
state.cfg = {}
state.urls = {}
package.loaded["source.fanqie.reading"] = nil
package.loaded["source.fanqie.reading.device"] = nil
package.loaded["source.fanqie.settings"] = nil

local register_hits = 0
package.preload["http.request"] = function()
    return {
        ok = function(code)
            local n = tonumber(code)
            return n ~= nil and n >= 200 and n < 300
        end,
        header = function() return nil end,
        request = function(opts, cb)
            state.urls[#state.urls + 1] = opts.url
            require("ui/uimanager"):nextTick(function()
                if opts.url:find("device_register", 1, true) then
                    register_hits = register_hits + 1
                    cb({
                        code = 200,
                        body = '{"device_id_str":"111","install_id_str":"222","new_user":1}',
                    })
                    return
                end
                if opts.url:find("registerkey", 1, true) then
                    cb({
                        code = 200,
                        body = '{"code":0,"data":{"key":"' .. key_blob .. '","keyver":1}}',
                    })
                    return
                end
                if opts.url:find("batch_full", 1, true) then
                    cb({
                        code = 200,
                        body = '{"code":0,"data":{"1":{"title":"T","crypt_status":0,"compress_status":0,"content":"'
                            .. content_b64 .. '"}}}',
                    })
                    return
                end
                cb(nil, "bad url")
            end)
            return { cancel = function() end }
        end,
    }
end
package.loaded["http.request"] = nil

Reading = require("source.fanqie.reading")
Settings = require("source.fanqie.settings")
row, fetch_err = nil, nil
Reading.fetchAsync(Settings:new(), "99", "1", function(data, err)
    row, fetch_err = data, err
end)
Stubs.flush()
Assert.is_nil(fetch_err)
Assert.eq(register_hits, 1)
Assert.eq(row.title, "T")
Assert.eq(state.cfg.reading_device.device_id, "111")

-- registerkey 超时：res 非 nil，err 必须原样回到打开流程
state.urls = {}
package.preload["http.request"] = function()
    return {
        ok = function(code)
            local n = tonumber(code)
            return n ~= nil and n >= 200 and n < 300
        end,
        header = function() return nil end,
        request = function(opts, cb)
            state.urls[#state.urls + 1] = opts.url
            require("ui/uimanager"):nextTick(function()
                cb({ error = { code = -6 } }, "Request timed out after 20 secs")
            end)
            return { cancel = function() end }
        end,
    }
end
package.loaded["http.request"] = nil
package.loaded["source.fanqie.reading"] = nil
package.loaded["source.fanqie.reading.device"] = nil
package.loaded["source.fanqie.settings"] = nil
Reading = require("source.fanqie.reading")
Settings = require("source.fanqie.settings")
row, fetch_err = nil, nil
Reading.fetchAsync(Settings:new(), "99", "1", function(data, err)
    row, fetch_err = data, err
end)
Stubs.flush()
Assert.is_nil(row)
Assert.eq(fetch_err, "Request timed out after 20 secs")
Assert.eq(#state.urls, 1)
Assert.matches(state.urls[1], "registerkey")
