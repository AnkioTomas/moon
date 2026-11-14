--[[--
进程内 Cookie 罐回归用例：Domain / Path / Secure / 过期 / 陈旧回包。

@module tests.http.cookie_jar_spec
--]]

local Assert = require("support.assert")
local Jar = require("http.cookie_jar")

local jar = Jar.new():seed("a=1; b=2")
Assert.eq(jar:header("https://x.test/any"), "a=1; b=2", "seed 对任何 host 生效")

jar:absorb("https://www.x.test/api/v1", { "a=9; Path=/", "b=; Max-Age=0; Path=/" })
Assert.eq(jar:header("https://www.x.test/"), "a=9", "同名覆盖，Max-Age=0 删除")

jar:absorb("https://www.x.test/api/v1", { "h=host; Path=/" })
Assert.is_nil((jar:header("https://sub.www.x.test/") or ""):match("h="), "无 Domain 是 host-only，不给子域")
jar:absorb("https://www.x.test/", { "d=dom; Domain=.x.test; Path=/" })
Assert.matches(jar:header("https://other.x.test/"), "d=dom", "Domain 覆盖兄弟子域")
jar:absorb("https://www.x.test/", { "evil=1; Domain=.y.test" })
Assert.is_nil((jar:header("https://www.y.test/") or ""):match("evil"), "与请求 host 无关的 Domain 拒收")

jar:absorb("https://www.x.test/api/v1", { "p=1" })
Assert.matches(jar:header("https://www.x.test/api/v2"), "p=1", "缺省 Path 取请求目录")
Assert.is_nil((jar:header("https://www.x.test/apix") or ""):match("p=1"), "路径按段边界匹配")

jar:absorb("https://www.x.test/", { "s=1; Secure; Path=/" })
Assert.is_nil((jar:header("http://www.x.test/") or ""):match("s=1"), "Secure 不走明文")
Assert.matches(jar:header("https://www.x.test/"), "s=1")

jar:absorb("https://www.x.test/", { "old=1; Expires=Wed, 21 Oct 2015 07:28:00 GMT; Path=/" })
Assert.is_nil((jar:header("https://www.x.test/") or ""):match("old="), "过期立即丢弃")
jar:absorb("https://www.x.test/", { "new=1; Expires=Wed, 21 Oct 2999 07:28:00 GMT; Path=/" })
Assert.matches(jar:header("https://www.x.test/"), "new=1")

-- 请求发出后同一条被别的响应改过，迟到的旧回包不能回滚
local fresh = Jar.new()
local since = fresh.seq
fresh:absorb("https://x.test/", { "sid=new; Path=/" })
fresh:absorb("https://x.test/", { "sid=stale; Path=/", "other=ok; Path=/" }, since)
Assert.eq(fresh:get("sid"), "new")
Assert.eq(fresh:get("other"), "ok", "没被改过的 Cookie 照收")

-- 会话罐：同一份 Cookie 复用（服务端轮换的会话保留），换 Cookie 重建
local first = Jar.session("t", "sid=a")
first:absorb("https://x.test/", { "sid=rotated; Path=/" })
Assert.eq(Jar.session("t", "sid=a"), first)
Assert.eq(Jar.session("t", "sid=a"):header("https://x.test/"), "sid=rotated")
Assert.eq(Jar.session("t", "sid=b"):header("https://x.test/"), "sid=b", "换 Cookie 不继承旧会话")
Assert.is_nil(Jar.session("t", ""))
