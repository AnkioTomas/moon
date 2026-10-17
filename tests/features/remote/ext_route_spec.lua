--[[-- features.remote.ext_route：/api/<name>/<action> 交给 web.routes 提供者；附件直出；回调只认第一次；静态文件按登记开放。 --]]

local Assert = require("support.assert")
require("support.stubs").install()
package.loaded["json"] = { encode = function() return "{}" end, decode = require("support.json_stub").decode }

local Ext = require("utils.extension")
Ext.reset()
local calls = {}
Ext.add("web.routes", {
    name = "demo",
    dir = "/plug/demo/web",
    assets = { "demo.html", "demo.js", "demo.exe" },
    page = { href = "/demo.html", title = "演示", desc = "说明", icon = "M0 0z" },
    l10n = "demo_l10n",
    handle = function(method, action, params, cb)
        calls[#calls + 1] = method .. ":" .. action .. ":" .. tostring(params.id)
        cb(200, { ok = true })
        cb(500, { error = "again" })
    end,
    download = function(action)
        if action == "file" then return { ctype = "text/plain", filename = "a.txt", body = "hi" } end
    end,
})
package.loaded["features.remote.ext_route"] = nil
local ExtRoute = require("features.remote.ext_route")

Assert.eq(ExtRoute.find("demo").name, "demo")
Assert.is_nil(ExtRoute.find("nope"))
local a = ExtRoute.asset("/demo.js")
Assert.eq(a[1], "demo.js")
Assert.eq(a[3], "/plug/demo/web/demo.js", "从提供者自己的目录读")
Assert.matches(a[2], "javascript")
Assert.is_nil(ExtRoute.asset("/demo.exe"), "未知类型不开放")
Assert.eq(ExtRoute.pages()[1].href, "/demo.html")
Assert.eq(ExtRoute.pages()[1].title, "演示")
package.preload["demo_l10n.en"] = function() return { ["演示"] = "Demo" } end
Assert.eq(ExtRoute.l10n("en")[1]["演示"], "Demo")
Assert.len(ExtRoute.l10n("fr"), 0)
Assert.is_nil(ExtRoute.asset("/other.js"), "没登记的不开放")
Assert.is_nil(ExtRoute.asset("/../demo.js"))

local queued, failed, accepted = {}, {}, nil
local server = {
    jsonResp = function(code, body) return { code = code, body = body } end,
    _queueResponse = function(_self, _conn, resp) queued[#queued + 1] = resp end,
    _fail = function(_self, _conn, code) failed[#failed + 1] = code end,
    _acceptText = function(self, conn, _headers, _limit, finish) accepted = true; return finish(self, conn, '{"id":7}') end,
}
local item = ExtRoute.find("demo")

-- GET 附件直出
ExtRoute.route(server, {}, "GET", {}, {}, item, "file")
Assert.eq(queued[1].body, "hi")
Assert.matches(queued[1].extra[1], 'filename="a.txt"')

-- GET 其余交给 handle；回调只认第一次
local conn = {}
ExtRoute.route(server, conn, "GET", {}, { id = "3" }, item, "list")
Assert.eq(calls[1], "GET:list:3")
Assert.eq(conn.resp.code, 200, "第二次回调被丢掉")

-- POST 读 JSON body
conn = {}
ExtRoute.route(server, conn, "POST", {}, {}, item, "save")
Assert.is_true(accepted)
Assert.eq(calls[2], "POST:save:7")

-- 其他方法 405
ExtRoute.route(server, {}, "DELETE", {}, {}, item, "x")
Assert.eq(failed[1], 405)
Ext.reset()
