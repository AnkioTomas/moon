--[[--
source.wechat.auth 离线用例：cookie 解析 / 会话字段 / 错误码映射。

parseSetCookie、cookieFrom、jarMerge、sessionMap、absUrl、checkWereadErr
均为模块内 local 函数，经 debug.getupvalue 从引用它们的导出函数上取出，
不改插件源码。login_jar 是包级状态：每个用例用 freshAuth() 重 require 隔离。
QR 登录三步与 renewCookieAsync 需要真实网络流程，不在本文件覆盖。

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

--- 重 require auth，重置包级 login_jar。
---@param cfg table|nil
---@return table
local function freshAuth(cfg)
    state.cfg = cfg or {}
    state.saved = nil
    package.loaded["source.wechat.auth"] = nil
    return require("source.wechat.auth")
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
-- parseSetCookie
------------------------------------------------------------------------

do
    local auth = freshAuth()
    local parseSetCookie = upvalue(auth.renewCookieAsync, "parseSetCookie")
    Assert.not_nil(parseSetCookie)

    -- 非 table 输入 → 空表
    Assert.eq(type(parseSetCookie(nil)), "table")
    Assert.eq(type(parseSetCookie("junk")), "table")

    -- 单字符串头 + 属性剥离
    local one = parseSetCookie({ ["set-cookie"] = "wr_gid=288279; Path=/; HttpOnly" })
    Assert.eq(one.wr_gid, "288279")

    -- 数组多 cookie；值内允许 '='；Expires 属性不影响首个键值
    local multi = parseSetCookie({
        ["set-cookie"] = {
            "wr_skey=abc==; Expires=Thu, 01-Jan-1970 00:00:00 GMT; Path=/",
            "wr_vid=123456; Domain=.weread.qq.com",
            "garbage-line-without-equals",
        },
    })
    Assert.eq(multi.wr_skey, "abc==")
    Assert.eq(multi.wr_vid, "123456")
    Assert.is_nil(multi["garbage-line-without-equals"])

    -- 大写 Set-Cookie 键
    local upper = parseSetCookie({ ["Set-Cookie"] = "wr_rt=refresh-token" })
    Assert.eq(upper.wr_rt, "refresh-token")

    -- 过期 cookie：空值保留为空串（由 cookieFrom 负责丢弃）
    local expired = parseSetCookie({ ["set-cookie"] = "wr_skey=; Expires=Thu, 01-Jan-1970 00:00:00 GMT" })
    Assert.eq(expired.wr_skey, "")

    -- set-cookie 类型非法 → 空表
    Assert.eq(next(parseSetCookie({ ["set-cookie"] = 42 })), nil)
end

------------------------------------------------------------------------
-- cookieFrom
------------------------------------------------------------------------

do
    local auth = freshAuth()
    local cookieFrom = upvalue(auth.cookieHeader, "cookieFrom")
    Assert.not_nil(cookieFrom)

    Assert.is_nil(cookieFrom(nil))

    -- keys 顺序输出；缺失/空串跳过；数字转字符串
    local s = cookieFrom(
        { wr_gid = "g", wr_skey = "s", wr_vid = 123, wr_fp = "" },
        { "wr_gid", "wr_fp", "wr_vid", "wr_skey" }
    )
    Assert.eq(s, "wr_gid=g; wr_vid=123; wr_skey=s")

    -- keys 为 nil：wr_gid/wr_fp 优先，其余随后
    local def = cookieFrom({ wr_fp = "f", wr_x = "1", wr_gid = "g" })
    Assert.is_true(def:find("^wr_gid=g; wr_fp=f; ") ~= nil)
    Assert.is_true(def:find("wr_x=1", 1, true) ~= nil)

    -- 全空 → nil
    Assert.is_nil(cookieFrom({}))
    Assert.is_nil(cookieFrom({ wr_gid = "" }))
end

------------------------------------------------------------------------
-- jarMerge 合并语义（login_jar 包级状态）
------------------------------------------------------------------------

do
    local auth = freshAuth()
    local jarMerge = upvalue(auth.waitQrLoginAsync, "jarMerge")
    Assert.not_nil(jarMerge)
    local jar = upvalue(auth.waitQrLoginAsync, "login_jar")
    Assert.eq(next(jar), nil)

    -- 新键写入
    jarMerge({ ["set-cookie"] = { "wr_a=1; Path=/", "wr_b=2" } })
    Assert.eq(jar.wr_a, "1")
    Assert.eq(jar.wr_b, "2")

    -- 已有键覆盖，其它键保留
    jarMerge({ ["set-cookie"] = "wr_a=9" })
    Assert.eq(jar.wr_a, "9")
    Assert.eq(jar.wr_b, "2")

    -- 重 require 后 jar 重置
    local auth2 = freshAuth()
    local jar2 = upvalue(auth2.waitQrLoginAsync, "login_jar")
    Assert.eq(next(jar2), nil)
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

    -- 仅旧整段 cookie → 原样回退
    local legacy = freshAuth({ cookie = "wr_skey=oldskey; wr_vid=9" })
    Assert.eq(legacy.cookieHeader(), "wr_skey=oldskey; wr_vid=9")

    -- 字段为空串不算，仍回退旧 cookie
    local empty_fields = freshAuth({ wr_skey = "", cookie = "wr_skey=x" })
    Assert.eq(empty_fields.cookieHeader(), "wr_skey=x")

    -- 什么都没有 → nil
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
end

------------------------------------------------------------------------
-- hasSession / userLabel / userVid
------------------------------------------------------------------------

do
    Assert.is_true(freshAuth({ wr_skey = "s" }).hasSession())
    -- 旧 cookie 串含非空 wr_skey= 才算有会话；空值不算
    Assert.is_true(freshAuth({ cookie = "wr_gid=1; wr_skey=abc" }).hasSession())
    Assert.is_false(freshAuth({ cookie = "wr_skey=; wr_gid=1" }).hasSession())
    Assert.is_false(freshAuth({ wr_skey = "" }).hasSession())
    Assert.is_false(freshAuth({ cookie = "wr_gid=1" }).hasSession())
    Assert.is_false(freshAuth({}).hasSession())

    Assert.eq(freshAuth({ user_name = "阿明", user_id = "9" }).userLabel(), "阿明")
    -- user_name 空 → 回退 user_id
    Assert.eq(freshAuth({ user_name = "", user_id = 9 }).userLabel(), "9")
    Assert.is_nil(freshAuth({}).userLabel())

    Assert.eq(freshAuth({ wr_vid = "v1", user_id = "v2" }).userVid(), "v1")
    Assert.eq(freshAuth({ user_id = 33 }).userVid(), "33")
    -- wr_vid 空串不遮蔽有效的 user_id
    Assert.eq(freshAuth({ wr_vid = "", user_id = "v2" }).userVid(), "v2")
    Assert.is_nil(freshAuth({ wr_vid = "" }).userVid())
    Assert.is_nil(freshAuth({}).userVid())
end

------------------------------------------------------------------------
-- clearSession
------------------------------------------------------------------------

do
    local cfg = {
        cookie = "c", wr_vid = "v", wr_skey = "s", wr_rt = "r",
        wr_gid = "g", wr_fp = "f", wr_ql = "1",
        user_id = "u", user_name = "n",
        api_key = "k", skill_version = "sv", other = "keep",
    }
    local auth = freshAuth(cfg)
    auth.clearSession()
    for _, k in ipairs({
        "cookie", "wr_vid", "wr_skey", "wr_rt",
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

------------------------------------------------------------------------
-- absUrl
------------------------------------------------------------------------

do
    local auth = freshAuth()
    local absUrl = upvalue(auth.apiPostAsync, "absUrl")
    Assert.not_nil(absUrl)

    Assert.eq(absUrl("https://i.weread.qq.com", "/a/b?x=1"), "https://i.weread.qq.com/a/b?x=1")
    Assert.eq(absUrl("https://base", "https://other.com/x"), "https://other.com/x")
    Assert.eq(absUrl("https://base", "http://other.com/x"), "http://other.com/x")
end

------------------------------------------------------------------------
-- checkWereadErr
------------------------------------------------------------------------

do
    local auth = freshAuth()
    local checkWereadErr = upvalue(auth.apiPostAsync, "checkWereadErr")
    Assert.not_nil(checkWereadErr)

    -- errcode 缺失 / 0 → 原样返回 data
    local d0 = {}
    Assert.eq(checkWereadErr(d0), d0)
    local d1 = { errcode = 0, data = 1 }
    Assert.eq(checkWereadErr(d1), d1)

    -- 非 0 + errmsg → 文案直通
    local d2, e2 = checkWereadErr({ errcode = -2012, errmsg = "登录过期" })
    Assert.is_nil(d2)
    Assert.eq(e2, "登录过期")

    -- 驼峰 errCode / errMsg
    local d3, e3 = checkWereadErr({ errCode = 100, errMsg = "bad" })
    Assert.is_nil(d3)
    Assert.eq(e3, "bad")

    -- 无文案 → 默认「微信读书错误 <code>」
    local d4, e4 = checkWereadErr({ errcode = 7 })
    Assert.is_nil(d4)
    Assert.eq(e4, "微信读书错误 7")

    -- 字符串数字 errcode 也能识别
    local d5, e5 = checkWereadErr({ errcode = "12" })
    Assert.is_nil(d5)
    Assert.eq(e5, "微信读书错误 12")
end

------------------------------------------------------------------------
-- apiGetAsync：会话门禁 / URL 拼接 / decodeJson / HTTP 错误
------------------------------------------------------------------------

do
    -- 未登录：直接回调错误，不发请求
    local auth = freshAuth({})
    state.request_impl = function()
        error("request must not be called")
    end
    local data, err
    auth.apiGetAsync("/test", function(d, e)
        data, err = d, e
    end)
    Assert.is_nil(data)
    Assert.eq(err, "请先扫码登录微信读书")

    -- 已登录：URL 拼接 + JSON 成功 + errcode 检查通过
    auth = freshAuth({ wr_skey = "s", wr_vid = "1" })
    local got_url
    state.json_map = { ['{"errcode":0,"ok":1}'] = { errcode = 0, ok = 1 } }
    state.request_impl = function(opts, cb)
        got_url = opts.url
        cb({ code = 200, body = '{"errcode":0,"ok":1}' })
        return { cancel = function() end }
    end
    data, err = nil, nil
    auth.apiGetAsync("/test?x=1", function(d, e)
        data, err = d, e
    end)
    Assert.is_nil(err)
    Assert.eq(got_url, "https://i.weread.qq.com/test?x=1")
    Assert.eq(data.ok, 1)

    -- errcode 非 0 → 业务错误
    state.json_map = { ['{"errcode":-2012,"errmsg":"登录态失效"}'] = { errcode = -2012, errmsg = "登录态失效" } }
    state.request_impl = function(_opts, cb)
        cb({ code = 200, body = '{"errcode":-2012,"errmsg":"登录态失效"}' })
        return { cancel = function() end }
    end
    data, err = nil, nil
    auth.apiGetAsync("/t", function(d, e)
        data, err = d, e
    end)
    Assert.is_nil(data)
    Assert.eq(err, "登录态失效")

    -- 非法 JSON → 返回非 JSON
    state.json_map = {}
    state.request_impl = function(_opts, cb)
        cb({ code = 200, body = "<html>not json</html>" })
        return { cancel = function() end }
    end
    data, err = nil, nil
    auth.apiGetAsync("/t", function(d, e)
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
    auth.apiGetAsync("/t", function(d, e)
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
    auth.apiGetAsync("/t", function(d, e)
        data, err = d, e
    end)
    Assert.is_nil(data)
    Assert.eq(err, "timeout")
end

------------------------------------------------------------------------
-- webPostAsync：Content-Type 默认与覆盖
------------------------------------------------------------------------

do
    local auth = freshAuth({ wr_skey = "s" })
    local got_opts
    state.json_map = { ['{"errcode":0}'] = { errcode = 0 } }
    state.request_impl = function(opts, cb)
        got_opts = opts
        cb({ code = 200, body = '{"errcode":0}' })
        return { cancel = function() end }
    end
    local data, err
    auth.apiPostAsync("/sync", { a = 1 }, function(d, e)
        data, err = d, e
    end)
    Assert.is_nil(err)
    Assert.not_nil(data)
    Assert.eq(got_opts.method, "POST")
    Assert.eq(got_opts.url, "https://i.weread.qq.com/sync")
    Assert.eq(got_opts.headers["Content-Type"], "application/json")
end

------------------------------------------------------------------------
-- 清理：恢复本文件改动的 preload / loaded，避免污染同进程后续用例
------------------------------------------------------------------------

for _, name in ipairs({ "utils.settings", "http.request", "json", "source.wechat.auth" }) do
    package.preload[name] = nil
    package.loaded[name] = nil
end
package.preload["json"] = original_json_preload
