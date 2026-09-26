--[[--
source.wechat.eink 离线用例：设备 ID、登录签名与请求体、版本/鉴权请求头、
401 / -2012 续期重放语义、-2041 不重试、令牌落网页会话字段（wr_vid/wr_skey）。

@module tests.wechat_eink_spec
--]]

local Assert = require("support.assert")
local JsonStub = require("support.json_stub")
local sha256 = require("ffi/sha2").sha256

local state = { cfg = {}, requests = {}, responder = nil }

package.preload["utils.settings"] = function()
    return {
        getSource = function() return state.cfg end,
        saveSource = function(_, c) state.cfg = c end,
    }
end
package.preload["http.request"] = function()
    return {
        ok = function(code) return code ~= nil and code >= 200 and code < 300 end,
        request = function(opts, cb)
            state.requests[#state.requests + 1] = opts
            local res = state.responder(opts)
            cb(res)
            return { cancel = function() end }
        end,
    }
end
package.preload["json"] = function()
    return { encode = JsonStub.encode, decode = JsonStub.decode }
end
for _, name in ipairs({ "json", "http.request", "utils.settings", "source.wechat.eink" }) do
    package.loaded[name] = nil
end

local Eink = require("source.wechat.eink")

local function reply(code, body)
    return { code = code, body = JsonStub.encode(body) }
end

local function reset(cfg)
    state.cfg = cfg or {}
    state.requests = {}
end

local function logged_in()
    reset({ wr_vid = "42", wr_skey = "at-1", eink = { refresh_token = "rt-1", device_id = "dev-1" } })
end

-- 设备 ID：前缀 + 19 位数字，首次生成后落盘并复用。
do
    reset()
    local id = Eink.deviceId()
    Assert.matches(id, "^eink334691225%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d$")
    Assert.eq(Eink.deviceId(), id, "设备 ID 落盘后复用")
    Assert.eq(state.cfg.eink.device_id, id)
end

-- 签名 = sha256(毫秒时间戳 .. deviceId .. random)，时间戳不能出现科学计数法。
do
    Assert.eq(Eink.signature(1790000000123, "dev", 7), sha256("1790000000123dev7"))
end

-- 扫码换令牌：请求体字段与签名自洽，令牌落 wr_vid/wr_skey，续期令牌落 cfg.eink。
do
    reset({ eink = { device_id = "dev-9" } })
    state.responder = function()
        return reply(200, { vid = 1001, accessToken = "at", refreshToken = "rt" })
    end
    local user
    Eink.completeQrLoginAsync({ wx_code = "code-1" }, function(u) user = u end)
    local req = state.requests[1]
    Assert.eq(req.url, "https://i.weread.qq.com/login")
    Assert.eq(req.method, "POST")
    Assert.eq(req.headers.basever, "2.1.2.10245900")
    Assert.matches(req.headers["User-Agent"], "wr_eink")
    local body = JsonStub.decode(req.body)
    Assert.eq(body.code, "code-1")
    Assert.eq(body.deviceId, "dev-9")
    Assert.eq(body.deviceType, 3)
    Assert.eq(body.isFromQrcode, 1)
    Assert.eq(body.signature, Eink.signature(body.timestamp, "dev-9", body.random))
    Assert.eq(user.user_id, "1001")
    Assert.eq(state.cfg.wr_skey, "at")
    Assert.eq(state.cfg.wr_vid, "1001")
    Assert.eq(state.cfg.user_id, "1001")
    Assert.eq(state.cfg.eink.refresh_token, "rt")
    Assert.eq(state.cfg.eink.device_id, "dev-9")
    Assert.eq(Eink.credentials().access_token, "at")
end

-- 登录回包缺令牌按失败，不落盘。
do
    reset({ eink = { device_id = "dev-9" } })
    state.responder = function() return reply(200, { errCode = -1, errMsg = "bad" }) end
    local user, err
    Eink.completeQrLoginAsync({ wx_code = "c" }, function(u, e) user, err = u, e end)
    Assert.is_nil(user)
    Assert.matches(err, "bad")
    Assert.is_nil(state.cfg.wr_skey)
    Assert.is_false(Eink.hasSession())
end

-- 正常调用：带 vid/accessToken 与版本头，query 拼进 URL。
do
    logged_in()
    state.responder = function() return reply(200, { books = {} }) end
    local data, err, meta
    Eink.callAsync("GET", "/shelf/sync", { query = { synckey = 0 } }, function(d, e, m)
        data, err, meta = d, e, m
    end)
    local req = state.requests[1]
    Assert.eq(req.url, "https://i.weread.qq.com/shelf/sync?synckey=0")
    Assert.eq(req.headers.vid, "42")
    Assert.eq(req.headers.accessToken, "at-1")
    Assert.eq(req.headers.appver, "2.1.2.10245900")
    Assert.is_nil(err)
    Assert.not_nil(data.books)
    Assert.eq(meta.status, 200)
end

-- GET 遇 -2012：续期（refreshToken + kickType）后用新令牌重放一次，新凭据落盘。
do
    logged_in()
    local calls = 0
    state.responder = function(opts)
        if opts.url:find("/login", 1, true) then
            return reply(200, { vid = 42, accessToken = "at-2", refreshToken = "rt-2" })
        end
        calls = calls + 1
        if calls == 1 then return reply(200, { errCode = -2012, errMsg = "expired" }) end
        return reply(200, { ok = 1 })
    end
    local data
    Eink.callAsync("GET", "/book/getProgress", { query = { bookId = "b" } }, function(d) data = d end)
    Assert.eq(#state.requests, 3, "原请求 + 续期 + 重放")
    local mint = JsonStub.decode(state.requests[2].body)
    Assert.eq(mint.refreshToken, "rt-1")
    Assert.eq(mint.kickType, 1)
    Assert.eq(mint.signature, Eink.signature(mint.timestamp, "dev-1", mint.random))
    Assert.eq(state.requests[3].headers.accessToken, "at-2")
    Assert.eq(data.ok, 1)
    Assert.eq(state.cfg.wr_skey, "at-2")
    Assert.eq(state.cfg.eink.refresh_token, "rt-2")
    Assert.eq(state.cfg.eink.device_id, "dev-1")
end

-- POST 遇 401：只续期不重放（写可能已落地），回调失败。
do
    logged_in()
    state.responder = function(opts)
        if opts.url:find("/login", 1, true) then
            return reply(200, { vid = 42, accessToken = "at-2", refreshToken = "rt-2" })
        end
        return { code = 401, body = "" }
    end
    local data, err
    Eink.callAsync("POST", "/book/read", { body = { a = 1 } }, function(d, e) data, err = d, e end)
    Assert.eq(#state.requests, 2, "原请求 + 续期，不重放")
    Assert.is_nil(data)
    Assert.not_nil(err)
    Assert.eq(state.cfg.wr_skey, "at-2", "续期仍然落盘，下个请求可用")
    Assert.eq(state.requests[1].headers["Content-Type"], "application/json; charset=UTF-8")
end

-- -2041 人机验证：不续期、不重试。
do
    logged_in()
    state.responder = function() return reply(200, { errCode = -2041 }) end
    local err, meta
    Eink.callAsync("GET", "/shelf/sync", nil, function(_, e, m) err, meta = e, m end)
    Assert.eq(#state.requests, 1)
    Assert.matches(err, "%-2041")
    Assert.eq(meta.errcode, -2041)
end

-- 未登录直接失败，不发请求；退出登录保留设备 ID。
-- 只有网页会话、没有 refresh_token 也不算 Eink 会话（网页扫码的老用户）。
do
    reset({ wr_vid = "42", wr_skey = "web" })
    Assert.is_false(Eink.hasSession())
end

do
    logged_in()
    Eink.clearSession()
    Assert.is_false(Eink.hasSession())
    Assert.eq(state.cfg.eink.device_id, "dev-1")
    Assert.is_nil(state.cfg.eink.refresh_token)
    local err
    Eink.callAsync("GET", "/shelf/sync", nil, function(_, e) err = e end)
    Assert.not_nil(err)
    Assert.eq(#state.requests, 0)
end
