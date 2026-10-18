--[[--
source.wechat.auth 离线用例：会话请求头 / 登录门禁 / 自动续期重试。

每个用例用 freshAuth() 重 require 隔离。
登录态 = Eink 会话（wr_skey + eink.refresh_token），扫码与续期细节见 eink_spec。

@module tests.wechat_auth_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

local Assert = require("support.assert")

local original_json_preload = package.preload["json"]

-- 可变测试状态：settings / Request.request / json.decode 全部走这里
local state = {
    cfg = {},
    saved = nil,
    request_impl = nil,
    json_map = {},
}

package.preload["utils.settings"] = function()
    return {
        getSource = function()
            return state.cfg
        end,
        saveSource = function(_id, c)
            state.saved = c
        end,
    }
end

package.preload["http.request"] = function()
    return {
        -- 语义对齐 http/request.lua 的 Request.ok
        ok = function(code)
            local n = tonumber(code)
            return n ~= nil and n >= 200 and n < 300
        end,
        header = function(res, name)
            local headers = res and res.headers
            if not headers then
                return nil
            end
            return headers[name] or headers[name:lower()]
        end,
        request = function(opts, cb)
            return state.request_impl(opts, cb)
        end,
    }
end

package.preload["json"] = function()
    return {
        encode = function()
            return "{}"
        end,
        -- 罐装映射：未登记的串视为非法 JSON（与真实 decode 报错同路径）
        decode = function(s)
            local v = state.json_map[s]
            if v == nil then
                error("invalid json")
            end
            return v
        end,
    }
end

-- http.header 用真实模块（纯 Lua，header_spec 已验证可独立加载）

-- 全量跑时前面的 spec 可能已把 stub 版 json/http.request 留在 package.loaded，
-- 这里强制清掉，让上面的 package.preload 生效
for _, name in ipairs({ "json", "http.request", "utils.settings" }) do
    package.loaded[name] = nil
end

--- 重 require auth，重置包级续期状态；eink 为 nil 时用真实 source.wechat.eink。
---@param cfg table|nil
---@param eink table|nil
---@return table
local function freshAuth(cfg, eink)
    state.cfg = cfg or {}
    state.saved = nil
    package.loaded["source.wechat.auth"] = nil
    if eink and not eink.refreshing then
        -- 真实 Eink.refreshAsync 自带单飞（并发续期共用一次 /login）；桩照此包一层。
        local raw, waiters = eink.refreshAsync, nil
        eink.refreshing = function() return waiters ~= nil end
        eink.refreshAsync = function(cb)
            if waiters then waiters[#waiters + 1] = cb return end
            waiters = { cb }
            raw(function(ok, err, rejected)
                local list = waiters
                waiters = nil
                for _idx, w in ipairs(list) do w(ok, err, rejected) end
            end)
        end
    end
    package.loaded["source.wechat.eink"] = eink
    return require("source.wechat.auth")
end

--- Eink 扫码会话：wr_skey + refresh_token 才算登录。
---@param extra table|nil
---@return table
local function loggedIn(extra)
    local cfg = { wr_vid = "1", wr_skey = "s", eink = { refresh_token = "rt", device_id = "dev" } }
    for k, v in pairs(extra or {}) do cfg[k] = v end
    return cfg
end

------------------------------------------------------------------------
-- Auth.sessionHeaders：Cookie 只拼 Eink 会话的 wr_vid / wr_skey；旧网页残留字段不发
------------------------------------------------------------------------

do
    local auth = freshAuth(loggedIn({ wr_vid = "88", wr_skey = "sk", wr_gid = "g", wr_fp = "f", wr_rt = "r" }))
    local h = auth.sessionHeaders({ ["X-Custom"] = "c" })
    Assert.eq(h["Cookie"], "wr_vid=88; wr_skey=sk; wr_ql=0")
    Assert.eq(h["X-Vid"], "88")
    Assert.eq(h["X-Skey"], "sk")
    Assert.eq(h["X-Custom"], "c")
    -- 浏览器默认头
    Assert.eq(h["Referer"], "https://weread.qq.com/")
    Assert.not_nil(h["User-Agent"])

    -- extra 覆盖默认 Referer
    local h2 = auth.sessionHeaders({ ["Referer"] = "https://example.com/" })
    Assert.eq(h2["Referer"], "https://example.com/")

    -- 无 Eink 会话（含旧网页会话）：只有浏览器头
    for _, cfg in ipairs({ {}, { wr_vid = "1", wr_skey = "s", wr_gid = "g" } }) do
        local h3 = freshAuth(cfg).sessionHeaders()
        Assert.is_nil(h3["Cookie"])
        Assert.is_nil(h3["X-Vid"])
        Assert.is_nil(h3["X-Skey"])
        Assert.not_nil(h3["User-Agent"])
    end
end

------------------------------------------------------------------------
-- hasSession / userLabel
------------------------------------------------------------------------

do
    Assert.is_true(freshAuth(loggedIn()).hasSession())
    -- 只有网页会话（旧网页扫码登录）不算：必须重新 Eink 扫码
    Assert.is_false(freshAuth({ wr_skey = "s", wr_vid = "1" }).hasSession(), "旧网页会话需重新登录")
    Assert.is_false(freshAuth(loggedIn({ wr_skey = "" })).hasSession())
    Assert.is_false(freshAuth({ cookie = "wr_gid=1; wr_skey=abc" }).hasSession(), "整段 cookie 串不算会话")
    Assert.is_false(freshAuth({}).hasSession())

    Assert.eq(freshAuth({ user_name = "阿明", user_id = "9" }).userLabel(), "阿明")
    -- user_name 空 → 回退 user_id
    Assert.eq(freshAuth({ user_name = "", user_id = 9 }).userLabel(), "9")
    Assert.is_nil(freshAuth({}).userLabel())
end

------------------------------------------------------------------------
-- clearSession
------------------------------------------------------------------------

do
    local cfg = {
        wr_vid = "v", wr_skey = "s", wr_rt = "r",
        wr_gid = "g", wr_fp = "f", wr_ql = "1",
        user_id = "u", user_name = "n",
        api_key = "k", skill_version = "sv", cookie = "c", other = "keep",
    }
    local auth = freshAuth(cfg)
    auth.clearSession()
    for _, k in ipairs({
        "wr_vid", "wr_skey", "wr_rt",
        "wr_gid", "wr_fp", "wr_ql", "user_id", "user_name",
        "api_key", "skill_version", "cookie",
    }) do
        Assert.eq(cfg[k], "")
    end
    -- 无关字段不动
    Assert.eq(cfg.other, "keep")
    -- 已落盘
    Assert.eq(state.saved, cfg)
end

-- Eink 扫码会话：退出同时清 refresh_token，设备 ID 保留（重登沿用同一设备）
do
    local cfg = loggedIn()
    freshAuth(cfg).clearSession()
    Assert.is_nil(cfg.eink.refresh_token)
    Assert.eq(cfg.eink.device_id, "dev")
end

-- 退出清掉进程内 reader 状态：否则换号后同章不再发进入阅读，时长不计。
do
    local auth = freshAuth(loggedIn())
    local Context = require("source.wechat.context")
    Context.reader("b1", "c1").entered = true
    auth.clearSession()
    Assert.is_nil(Context.reader("b1", "c1").entered)
end

------------------------------------------------------------------------
-- webGetAsync：会话门禁 / 原文透传 / HTTP 错误
--
-- JSON 解码与 errcode 判定在 client 层，这里只确认回包原样透传。
------------------------------------------------------------------------

do
    -- 未登录：直接回调错误，不发请求
    local auth = freshAuth({})
    state.request_impl = function()
        error("request must not be called")
    end
    local data, err
    auth.webGetAsync("https://weread.qq.com/web/test", nil, function(d, e)
        data, err = d, e
    end)
    Assert.is_nil(data)
    Assert.eq(err, "请先扫码登录微信读书")

    -- 已登录：URL 拼接 + JSON 成功
    auth = freshAuth(loggedIn())
    local got_url
    state.json_map = { ['{"errcode":0,"ok":1}'] = { errcode = 0, ok = 1 } }
    state.request_impl = function(opts, cb)
        got_url = opts.url
        cb({ code = 200, body = '{"errcode":0,"ok":1}' })
        return { cancel = function() end }
    end
    data, err = nil, nil
    auth.webGetAsync("https://weread.qq.com/web/test?x=1", nil, function(d, e)
        data, err = d, e
    end)
    Assert.is_nil(err)
    Assert.eq(got_url, "https://weread.qq.com/web/test?x=1")
    Assert.eq(data, '{"errcode":0,"ok":1}')

    -- HTTP 非 2xx
    state.request_impl = function(_opts, cb)
        cb({ code = 500, body = "x" })
        return { cancel = function() end }
    end
    data, err = nil, nil
    auth.webGetAsync("https://weread.qq.com/web/t", nil, function(d, e)
        data, err = d, e
    end)
    Assert.is_nil(data)
    Assert.eq(err, "HTTP 500")

    -- 网络错误透传
    state.request_impl = function(_opts, cb)
        cb(nil, "timeout")
        return { cancel = function() end }
    end
    data, err = nil, nil
    auth.webGetAsync("https://weread.qq.com/web/t", nil, function(d, e)
        data, err = d, e
    end)
    Assert.is_nil(data)
    Assert.eq(err, "timeout")
end

------------------------------------------------------------------------
-- webPostAsync：Content-Type 默认
------------------------------------------------------------------------

do
    local auth = freshAuth(loggedIn())
    local got_opts
    state.json_map = { ['{"errcode":0}'] = { errcode = 0 } }
    state.request_impl = function(opts, cb)
        got_opts = opts
        cb({ code = 200, body = '{"errcode":0}' })
        return { cancel = function() end }
    end
    local data, err
    auth.webPostAsync("https://weread.qq.com/web/sync", "{}", nil, function(d, e)
        data, err = d, e
    end)
    Assert.is_nil(err)
    Assert.not_nil(data)
    Assert.eq(got_opts.method, "POST")
    Assert.eq(got_opts.url, "https://weread.qq.com/web/sync")
    Assert.eq(got_opts.headers["Content-Type"], "application/json")
end

------------------------------------------------------------------------
-- 会话失效自动续期（Eink refreshToken）+ 重试一次，重试用新 Cookie
------------------------------------------------------------------------

do
    local refreshed = 0
    local auth = freshAuth(loggedIn({ wr_skey = "old" }), {
        hasSession = function() return true end,
        credentials = function() return { vid = state.cfg.wr_vid, access_token = state.cfg.wr_skey } end,
        refreshAsync = function(cb)
            refreshed = refreshed + 1
            state.cfg.wr_skey = "newkey"
            cb(true)
        end,
    })
    local cookies = {}
    state.json_map = {
        ['{"errcode":-2012,"errmsg":"登录态失效"}'] = { errcode = -2012, errmsg = "登录态失效" },
        ['{"errcode":0,"ok":1}'] = { errcode = 0, ok = 1 },
    }
    state.request_impl = function(opts, cb)
        cookies[#cookies + 1] = opts.headers["Cookie"]
        if #cookies == 1 then
            cb({ code = 200, body = '{"errcode":-2012,"errmsg":"登录态失效"}' })
        else
            cb({ code = 200, body = '{"errcode":0,"ok":1}' })
        end
        return { cancel = function() end }
    end
    local data, err, resp
    auth.webGetAsync("https://weread.qq.com/web/retry", nil, function(d, e, r)
        data, err, resp = d, e, r
    end)
    Assert.is_nil(err)
    Assert.eq(data, '{"errcode":0,"ok":1}')
    Assert.eq(resp.json.ok, 1, "判失效时解过的 JSON 经 res.json 交给调用方，不必再解")
    Assert.eq(refreshed, 1)
    Assert.eq(#cookies, 2)
    Assert.is_true(cookies[1]:find("wr_skey=old", 1, true) ~= nil)
    Assert.is_true(cookies[2]:find("wr_skey=newkey", 1, true) ~= nil)
end

-- 续期冷却：冷却内再遇失效回包（如 WAF 403）不再打 /login，只用现有令牌重试一次。
do
    local refreshed = 0
    local auth = freshAuth(loggedIn(), {
        hasSession = function() return true end,
        credentials = function() return { vid = state.cfg.wr_vid, access_token = state.cfg.wr_skey } end,
        refreshAsync = function(cb)
            refreshed = refreshed + 1
            cb(true)
        end,
    })
    local requests = 0
    state.json_map = {}
    state.request_impl = function(_opts, cb)
        requests = requests + 1
        cb({ code = 403, body = "<html>blocked</html>" })
        return { cancel = function() end }
    end
    local errs = {}
    for _i = 1, 3 do
        auth.webGetAsync("https://weread.qq.com/web/x", nil, function(_raw, e) errs[#errs + 1] = e end)
    end
    Assert.eq(refreshed, 1, "冷却内只续期一次")
    Assert.eq(requests, 6, "每个请求仍各重试一次")
    Assert.eq(errs[3], "HTTP 403")
end

-- 错误信息只含「超时」不是会话失效，不续期。
do
    local refreshed = 0
    local auth = freshAuth(loggedIn(), {
        hasSession = function() return true end,
        credentials = function() return { vid = state.cfg.wr_vid, access_token = state.cfg.wr_skey } end,
        refreshAsync = function(cb)
            refreshed = refreshed + 1
            cb(true)
        end,
    })
    state.json_map = { ['{"errcode":-1,"errmsg":"请求超时"}'] = { errcode = -1, errmsg = "请求超时" } }
    state.request_impl = function(_opts, cb)
        cb({ code = 200, body = '{"errcode":-1,"errmsg":"请求超时"}' })
        return { cancel = function() end }
    end
    auth.webGetAsync("https://weread.qq.com/web/t", nil, function() end)
    Assert.eq(refreshed, 0)
end

-- 续期等待中取消：不再发重试请求，也不回调；取消落到当前这次请求上。
do
    local finish_refresh
    local auth = freshAuth(loggedIn({ wr_skey = "old" }), {
        hasSession = function() return true end,
        credentials = function() return { vid = state.cfg.wr_vid, access_token = state.cfg.wr_skey } end,
        refreshAsync = function(cb) finish_refresh = cb end,
    })
    state.json_map = {
        ['{"errcode":-2012,"errmsg":"登录态失效"}'] = { errcode = -2012, errmsg = "登录态失效" },
    }
    local requests = 0
    state.request_impl = function(_opts, cb)
        requests = requests + 1
        cb({ code = 200, body = '{"errcode":-2012,"errmsg":"登录态失效"}' })
        return { cancel = function() end }
    end
    local called = false
    local job = auth.webGetAsync("https://weread.qq.com/web/cancel", nil, function() called = true end)
    job.cancel()
    finish_refresh(true)
    Assert.eq(requests, 1)
    Assert.is_false(called)
end

-- 续期失败：不重试，Eink 的续期错误原样回给调用方。
do
    local auth = freshAuth(loggedIn(), {
        hasSession = function() return true end,
        credentials = function() return { vid = state.cfg.wr_vid, access_token = state.cfg.wr_skey } end,
        refreshAsync = function(cb) cb(false, "登录失败 -2013") end,
    })
    state.json_map = {
        ['{"errcode":-2012,"errmsg":"登录态失效"}'] = { errcode = -2012, errmsg = "登录态失效" },
    }
    local requests = 0
    state.request_impl = function(_opts, cb)
        requests = requests + 1
        cb({ code = 200, body = '{"errcode":-2012,"errmsg":"登录态失效"}' })
        return { cancel = function() end }
    end
    local data, err
    auth.webGetAsync("https://weread.qq.com/web/fail", nil, function(d, e) data, err = d, e end)
    Assert.eq(requests, 1)
    Assert.is_nil(data)
    Assert.eq(err, "登录失败 -2013")
end

-- 只有真失效才判登录失效：记下 expire 调用（替身，用完还原）
local real_source_auth = package.loaded["source.auth"]
local expired = {}
package.loaded["source.auth"] = {
    expire = function(id, msg) expired[#expired + 1] = id; return msg end,
    ok = function() end,
}
local AUTH_FAIL = '{"errcode":-2012,"errmsg":"登录态失效"}'

-- 续期失败的归因：服务器明确拒绝才判登录失效；超时 / 断网只回错误。
for _idx, case in ipairs({ { rejected = true, expect = 1 }, { rejected = nil, expect = 0 } }) do
    expired = {}
    local auth = freshAuth(loggedIn({ wr_skey = "old" }), {
        hasSession = function() return true end,
        credentials = function() return { vid = state.cfg.wr_vid, access_token = state.cfg.wr_skey } end,
        refreshAsync = function(cb) cb(false, "boom", case.rejected) end,
    })
    state.json_map = { [AUTH_FAIL] = { errcode = -2012, errmsg = "登录态失效" } }
    state.request_impl = function(_opts, cb)
        cb({ code = 200, body = AUTH_FAIL })
        return { cancel = function() end }
    end
    local err
    auth.webGetAsync("https://weread.qq.com/web/x", nil, function(_d, e) err = e end)
    Assert.eq(err, "boom")
    Assert.len(expired, case.expect)
end

-- 并发竞态（日志 22:14:17）：A 回失效触发续期，续期在飞时 B 也回失效。
-- B 必须等续期结果再用新令牌重试；以前冷却直接让 B 拿旧令牌重试 → 再失效 → 误判登录失效。
do
    local finish, refreshed = nil, 0
    local auth = freshAuth(loggedIn({ wr_skey = "old" }), {
        hasSession = function() return true end,
        credentials = function() return { vid = state.cfg.wr_vid, access_token = state.cfg.wr_skey } end,
        refreshAsync = function(cb) refreshed = refreshed + 1; finish = cb end,
    })
    state.json_map = { [AUTH_FAIL] = { errcode = -2012, errmsg = "登录态失效" } }
    local cookies = {}
    state.request_impl = function(opts, cb)
        cookies[#cookies + 1] = opts.headers["Cookie"]
        cb({ code = 200, body = opts.headers["Cookie"]:find("wr_skey=old", 1, true) and AUTH_FAIL or "ok" })
        return { cancel = function() end }
    end
    local got = {}
    auth.webGetAsync("https://weread.qq.com/web/shelf/sync", nil, function(d, e) got[#got + 1] = d or e end)
    auth.webGetAsync("https://weread.qq.com/web/mp/articles", nil, function(d, e) got[#got + 1] = d or e end)
    Assert.eq(refreshed, 1, "只续期一次")
    Assert.len(got, 0, "B 在等续期，没有拿旧令牌重试")
    state.cfg.wr_skey = "newkey"
    finish(true)
    Assert.eq(table.concat(got, ","), "ok,ok")
    Assert.len(cookies, 4)
    Assert.len(expired, 0, "没有误判登录失效")
end

-- 请求在飞时令牌已被别的请求续期换掉：回失效就直接用新令牌重试，不再打 /login
do
    local refreshed = 0
    local auth = freshAuth(loggedIn({ wr_skey = "old" }), {
        hasSession = function() return true end,
        credentials = function() return { vid = state.cfg.wr_vid, access_token = state.cfg.wr_skey } end,
        refreshAsync = function(cb) refreshed = refreshed + 1; cb(true) end,
    })
    state.json_map = { [AUTH_FAIL] = { errcode = -2012, errmsg = "登录态失效" } }
    local pending = {}
    state.request_impl = function(opts, cb)
        pending[#pending + 1] = { cookie = opts.headers["Cookie"], cb = cb }
        return { cancel = function() end }
    end
    local data
    auth.webGetAsync("https://weread.qq.com/web/x2", nil, function(d) data = d end)
    state.cfg.wr_skey = "rotated"
    pending[1].cb({ code = 200, body = AUTH_FAIL })
    Assert.eq(refreshed, 0)
    Assert.is_true(pending[2].cookie:find("wr_skey=rotated", 1, true) ~= nil)
    pending[2].cb({ code = 200, body = "fine" })
    Assert.eq(data, "fine")
end

-- no_expire（公众号接口）：续期重试后仍回失效 errcode → 只回错误，不判整个微信读书登录失效
do
    local auth = freshAuth(loggedIn(), {
        hasSession = function() return true end,
        credentials = function() return { vid = state.cfg.wr_vid, access_token = state.cfg.wr_skey } end,
        refreshAsync = function(cb) cb(true) end,
    })
    state.json_map = { [AUTH_FAIL] = { errcode = -2012, errmsg = "登录态失效" } }
    state.request_impl = function(_opts, cb)
        cb({ code = 200, body = AUTH_FAIL })
        return { cancel = function() end }
    end
    local err
    auth.webGetAsync("https://weread.qq.com/web/mp/articles", { no_expire = true }, function(_d, e) err = e end)
    Assert.eq(err, "微信读书拒绝了请求，请稍后再试")
    Assert.len(expired, 0)
    -- 普通接口照旧判失效
    auth.webGetAsync("https://weread.qq.com/web/shelf/sync", nil, function(_d, e) err = e end)
    Assert.eq(err, "微信读书登录已失效")
    Assert.eq(table.concat(expired, ","), "wechat")
end
package.loaded["source.auth"] = real_source_auth

------------------------------------------------------------------------
-- 清理：恢复本文件改动的 preload / loaded，避免污染同进程后续用例
------------------------------------------------------------------------

for _, name in ipairs({ "utils.settings", "http.request", "json", "source.wechat.auth", "source.wechat.eink" }) do
    package.preload[name] = nil
    package.loaded[name] = nil
end
package.preload["json"] = original_json_preload
