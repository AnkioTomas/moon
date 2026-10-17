--[[--
浏览器授权登录：AES-GCM 解密（用扩展 moon-cookie-storage 真实产出的信封）、ticket 流程与幂等。

@module tests.features.cookie_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch

local Assert = require("support.assert")
local Gcm = require("crypto.gcm")

local TICKET = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"
local ENV = {
    v = 1,
    ticketId = "6oZqdX5MOLq_qBJ8vppAnT4fk6AP8UiP9zX8-Rev_9A",
    salt = "S7vHgME3qzoLPFrMTHk9NQ",
    iv = "1Va5mic3LQ0V_a7h",
    data = "dNXgKRGMObeWANuLPT1MYM63YfUnYucRHdWGpQ5Wtqtl9ShOPtgKrWY8ipR2huK9BnIj7q7CtnirK_CP8r6jHsfaw5rFFlLxsgColooi8HpfAm8_QdPUqg9GXXnieQBBe_0NNC9zWn2Yn10lTk_5HysVZL3ikA0jWew5a7fNePg1G7e7OBv3Xf_GEpWFJM_UoTVsf6G3gaFs-dYYcpsuiuVDTIMfyIo53WYF5rNXbLRrP1ctiwuaMilU8jVQkYbl6SNAjeSv42Wx3t47s2Gp-NrB6PXwVP17y37NVJN2ISnajfrs2Kq7XF6LCVXOSL9ni-jm",
}

local Text = require("utils.text")
local function unb64(s)
    s = s:gsub("-", "+"):gsub("_", "/")
    return Text.base64Decode(s .. string.rep("=", (4 - #s % 4) % 4))
end

local key = Gcm.hkdf(TICKET, unb64(ENV.salt), "moon-cookie-storage/v1", 32)
local plain = Gcm.decrypt(key, unb64(ENV.iv), TICKET, unb64(ENV.data))
Assert.is_true(plain ~= nil and plain:find('"domain":"www.qimao.com"', 1, true) ~= nil, "gcm decrypts extension envelope")
Assert.is_nil(Gcm.decrypt(key, unb64(ENV.iv), TICKET .. "x", unb64(ENV.data)), "wrong aad is rejected")
local tampered = unb64(ENV.data)
tampered = string.char((tampered:byte(1) + 1) % 256) .. tampered:sub(2)
Assert.is_nil(Gcm.decrypt(key, unb64(ENV.iv), TICKET, tampered), "tampered ciphertext is rejected")

-- ticket 流程：随机源固定成 0..31 字节，ticket 即上面信封用的那个。
local real_open = io.open
local random_bytes
io.open = function(path, mode)
    if path == "/dev/urandom" then
        return { read = function() return random_bytes end, close = function() end }
    end
    return real_open(path, mode)
end

local applied, authorized = 0, false
package.preload["desktop.pages.setting.source"] = function()
    return {
        loadSetting = function()
            return { browser = {
                domain = "www.qimao.com", scope = "local", login = "https://www.qimao.com/login",
                check = "https://www.qimao.com/user/bookshelf",
                icon = "https://cdn-front.qimao.com/global/static/images/favicon2022.ico",
                isAuthorized = function() return authorized end,
                apply = function(payload, cb) applied = applied + 1; cb(payload["local"] ~= nil) end,
            } }
        end,
    }
end
package.preload["source.registry"] = function()
    return { list = function() return { { id = "qimao", name = "七猫小说" } } end }
end
package.preload["utils.json"] = function()
    return { decode = require("support.json_stub").decode }
end

local Remote = require("features.cookie.remote")
local function call(method, action, params)
    local status, body, extra
    Remote.handle(method, action, params, function(s, b, h) status, body, extra = s, b, h end)
    return status, body, extra
end

local _s, sources = call("GET", "sources", {})
Assert.eq(sources.sources[1].id, "qimao")
Assert.eq(sources.sources[1].icon, "https://cdn-front.qimao.com/global/static/images/favicon2022.ico")
Assert.is_false(sources.sources[1].authorized)

random_bytes = string.rep(string.char(0xfb), 32)
local odd_status, odd_ticket = call("POST", "ticket", { source = "qimao" })
Assert.eq(odd_status, 200)
Assert.is_true(odd_ticket.ticket:find("+", 1, true) == nil, "ticket uses base64url alphabet")
Assert.is_true(odd_ticket.ticket:find("/", 1, true) == nil, "ticket is slash-free")

authorized = true
local _status, authorized_sources = call("GET", "sources", {})
Assert.is_true(authorized_sources.sources[1].authorized)
Assert.eq((call("POST", "ticket", { source = "qimao" })), 409)
authorized = false

random_bytes = {}
for i = 0, 31 do random_bytes[#random_bytes + 1] = string.char(i) end
random_bytes = table.concat(random_bytes)
local status, req = call("POST", "ticket", { source = "qimao" })
Assert.eq(status, 200)
Assert.eq(req.ticket, TICKET)
Assert.eq(req.domain, "www.qimao.com")
Assert.eq(req.callback, "/api/cookie/login")
Assert.eq((call("POST", "ticket", { source = "nope" })), 404)

local json = require("support.json_stub").encode
local s1, ok1, headers = call("GET", "login", { data = json(ENV) })
Assert.eq(s1, 200)
Assert.is_true(ok1.ok and ok1.close, "confirm closes tabs")
Assert.eq(ok1.ticketId, ENV.ticketId)
Assert.eq(headers[1], "Cache-Control: no-store")
local s2 = call("GET", "login", { data = json(ENV) })
Assert.eq(s2, 200)
Assert.eq(applied, 1, "repeat callback is idempotent")
Assert.eq((call("GET", "login", { data = json({ v = 1, ticketId = "zzz" }) })), 400)

io.open = real_open
