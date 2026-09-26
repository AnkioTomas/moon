--[[--
source.wechat.auth 离线用例：会话字段 / Cookie 拼装 / 登录门禁 / 自动续期重试。

cookieFrom、sessionMap、absUrl 为模块内 local 函数，经 debug.getupvalue 从引用它们的
导出函数上取出，不改插件源码。续期计时是包级状态：每个用例用 freshAuth() 重 require 隔离。
登录态 = Eink 会话（wr_skey + eink.refresh_token），扫码与续期细节见 eink_spec。

@module tests.wechat_auth_spec
--]]

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

--- 按名字取函数的 upvalue（模块内 local 函数 / 表）。
---@param fn function
---@param name string
---@return any
local function upvalue(fn, name)
    local i = 1
    while true do
        local n, v = debug.getupvalue(fn, i)
        if n == nil then
            return nil
        end
        if n == name then
            return v
        end
        i = i + 1
    end
end

------------------------------------------------------------------------
-- cookieFrom
------------------------------------------------------------------------

do
    local auth = freshAuth()
    local cookieFrom = upvalue(auth.cookieHeader, "cookieFrom")
    Assert.not_nil(cookieFrom)

    Assert.is_nil(cookieFrom(nil, { "wr_gid" }))

    -- keys 顺序输出；缺失/空串跳过；数字转字符串
    local s = cookieFrom(
        { wr_gid = "g", wr_skey = "s", wr_vid = 123, wr_fp = "" },
        { "wr_gid", "wr_fp", "wr_vid", "wr_skey" }
    )
    Assert.eq(s, "wr_gid=g; wr_vid=123; wr_skey=s")

    -- 全空 → nil
    Assert.is_nil(cookieFrom({}, { "wr_gid" }))
    Assert.is_nil(cookieFrom({ wr_gid = "" }, { "wr_gid" }))
end

------------------------------------------------------------------------
-- sessionMap
------------------------------------------------------------------------

do
    local auth = freshAuth()
    local sessionMap = upvalue(auth.cookieHeader, "sessionMap")
    Assert.not_nil(sessionMap)

    -- 字段直通
    local m = sessionMap({
        wr_gid = "g", wr_fp = "f", wr_vid = "7", wr_skey = "s",
        wr_ql = "1", wr_rt = "r",
    })
    Assert.eq(m.wr_gid, "g")
    Assert.eq(m.wr_fp, "f")
    Assert.eq(m.wr_vid, "7")
    Assert.eq(m.wr_skey, "s")
    Assert.eq(m.wr_ql, "1")
    Assert.eq(m.wr_rt, "r")

    -- wr_vid 回退 user_id
    Assert.eq(sessionMap({ user_id = 42 }).wr_vid, 42)

    -- 有 skey 且 ql 空 → ql 默认 "0"
    Assert.eq(sessionMap({ wr_skey = "s" }).wr_ql, "0")
    Assert.eq(sessionMap({ wr_skey = "s", wr_ql = "" }).wr_ql, "0")

    -- 无 skey 时 ql 不补默认
    Assert.is_nil(sessionMap({}).wr_ql)
end

------------------------------------------------------------------------
-- Auth.cookieHeader（settings 驱动）
------------------------------------------------------------------------

do
    local auth = freshAuth({
        wr_gid = "g", wr_fp = "f", wr_vid = "1", wr_skey = "s",
        wr_ql = "0", wr_rt = "r",
    })
    Assert.eq(auth.cookieHeader(), "wr_gid=g; wr_fp=f; wr_vid=1; wr_skey=s; wr_ql=0; wr_rt=r")

    -- 字段全空 → nil；整段 cookie 串不再是配置项，不读
    Assert.is_nil(freshAuth({ wr_skey = "", cookie = "wr_skey=x" }).cookieHeader())
    Assert.is_nil(freshAuth({}).cookieHeader())
end

------------------------------------------------------------------------
-- Auth.sessionHeaders（真实 Header.merge：extra 覆盖默认）
------------------------------------------------------------------------

do
    local auth = freshAuth({ wr_vid = "88", wr_skey = "sk", wr_gid = "g" })
    local h = auth.sessionHeaders({ ["X-Custom"] = "c" })
    Assert.eq(h["X-Vid"], "88")
    Assert.eq(h["X-Skey"], "sk")
    Assert.eq(h["X-Custom"], "c")
    Assert.is_true(h["Cookie"]:find("wr_skey=sk", 1, true) ~= nil)
    -- 浏览器默认头
    Assert.eq(h["Referer"], "https://weread.qq.com/")
    Assert.not_nil(h["User-Agent"])

    -- extra 覆盖默认 Referer
    local h2 = auth.sessionHeaders({ ["Referer"] = "https://example.com/" })
    Assert.eq(h2["Referer"], "https://example.com/")

    -- 无会话：Cookie / X-Vid / X-Skey 均不出现
    local h3 = freshAuth({}).sessionHeaders()
    Assert.is_nil(h3["Cookie"])
    Assert.is_nil(h3["X-Vid"])
    Assert.is_nil(h3["X-Skey"])

    -- vid 为数字 → tostring
    local h4 = freshAuth({ user_id = 7, wr_skey = "s" }).sessionHeaders()
    Assert.eq(h4["X-Vid"], "7")

    -- wr_vid 空串不遮蔽有效的 user_id（空串在 Lua 里为真值）
    local h5 = freshAuth({ wr_vid = "", user_id = "v2", wr_skey = "s" }).sessionHeaders()
    Assert.eq(h5["X-Vid"], "v2")
    Assert.is_nil(freshAuth({ wr_vid = "", wr_skey = "s" }).sessionHeaders()["X-Vid"])
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
        api_key = "k", skill_version = "sv", other = "keep",
    }
    local auth = freshAuth(cfg)
    auth.clearSession()
    for _, k in ipairs({
        "wr_vid", "wr_skey", "wr_rt",
        "wr_gid", "wr_fp", "wr_ql", "user_id", "user_name",
        "api_key", "skill_version",
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

------------------------------------------------------------------------
-- renewCookieAsync：走 Eink refreshToken 续期
------------------------------------------------------------------------

do
    local refresh_ok, refreshed = true, 0
    local auth = freshAuth(loggedIn(), {
        hasSession = function() return true end,
        refreshAsync = function(cb)
            refreshed = refreshed + 1
            cb(refresh_ok, not refresh_ok and "bad" or nil)
        end,
    })
    local ok, err
    auth.renewCookieAsync(function(o, e) ok, err = o, e end)
    Assert.eq(refreshed, 1)
    Assert.is_true(ok)
    Assert.is_nil(err)

    refresh_ok = false
    auth.renewCookieAsync(function(o, e) ok, err = o, e end)
    Assert.is_nil(ok)
    Assert.eq(err, "bad")
end

------------------------------------------------------------------------
-- absUrl
------------------------------------------------------------------------

do
    local auth = freshAuth()
    local absUrl = upvalue(auth.webApiPostAsync, "absUrl")
    Assert.not_nil(absUrl)

    Assert.eq(absUrl("https://i.weread.qq.com", "/a/b?x=1"), "https://i.weread.qq.com/a/b?x=1")
    Assert.eq(absUrl("https://base", "https://other.com/x"), "https://other.com/x")
    Assert.eq(absUrl("https://base", "http://other.com/x"), "http://other.com/x")
end

------------------------------------------------------------------------
-- webApiGetAsync：会话门禁 / URL 拼接 / decodeJson / HTTP 错误
--
-- errcode 非 0 不在此层判定（由 client 的 acceptWebWire 负责），
-- 这里只确认 wire 原样透传。
------------------------------------------------------------------------

do
    -- 未登录：直接回调错误，不发请求
    local auth = freshAuth({})
    state.request_impl = function()
        error("request must not be called")
    end
    local data, err
    auth.webApiGetAsync("/web/test", function(d, e)
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
    auth.webApiGetAsync("/web/test?x=1", function(d, e)
        data, err = d, e
    end)
    Assert.is_nil(err)
    Assert.eq(got_url, "https://weread.qq.com/web/test?x=1")
    Assert.eq(data.ok, 1)

    -- 非法 JSON → 返回非 JSON
    state.json_map = {}
    state.request_impl = function(_opts, cb)
        cb({ code = 200, body = "<html>not json</html>" })
        return { cancel = function() end }
    end
    data, err = nil, nil
    auth.webApiGetAsync("/web/t", function(d, e)
        data, err = d, e
    end)
    Assert.is_nil(data)
    Assert.eq(err, "返回非 JSON")

    -- HTTP 非 2xx
    state.request_impl = function(_opts, cb)
        cb({ code = 500, body = "x" })
        return { cancel = function() end }
    end
    data, err = nil, nil
    auth.webApiGetAsync("/web/t", function(d, e)
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
    auth.webApiGetAsync("/web/t", function(d, e)
        data, err = d, e
    end)
    Assert.is_nil(data)
    Assert.eq(err, "timeout")
end

------------------------------------------------------------------------
-- webApiPostAsync：Content-Type 默认与 URL 拼接
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
    auth.webApiPostAsync("/web/sync", { a = 1 }, function(d, e)
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
    local data, err
    auth.webApiGetAsync("/web/retry", function(d, e)
        data, err = d, e
    end)
    Assert.is_nil(err)
    Assert.eq(data.ok, 1)
    Assert.eq(refreshed, 1)
    Assert.eq(#cookies, 2)
    Assert.is_true(cookies[1]:find("wr_skey=old", 1, true) ~= nil)
    Assert.is_true(cookies[2]:find("wr_skey=newkey", 1, true) ~= nil)
end

------------------------------------------------------------------------
-- 清理：恢复本文件改动的 preload / loaded，避免污染同进程后续用例
------------------------------------------------------------------------

for _, name in ipairs({ "utils.settings", "http.request", "json", "source.wechat.auth", "source.wechat.eink" }) do
    package.preload[name] = nil
    package.loaded[name] = nil
end
package.preload["json"] = original_json_preload
