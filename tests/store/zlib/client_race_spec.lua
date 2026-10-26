--[[--
zlib 镜像并发竞速：同时请求前 5 个镜像，第一个成功的胜出并取消其余；不能并发的请求依次试。

@module tests.store.zlib.client_race_spec
--]]

local Assert = require("support.assert")

package.loaded["json"] = nil
package.preload["json"] = function()
    return { decode = require("support.json_stub").decode }
end

local pending, cancelled = {}, {}
package.loaded["http.request"] = nil
package.preload["http.request"] = function()
    return {
        ok = function(code) return code >= 200 and code < 300 end,
        header = function(res, name) return res.headers and res.headers[name:lower()] end,
        request = function(opts, cb)
            pending[#pending + 1] = { url = opts.url, cb = cb }
            return { cancel = function() cancelled[opts.url] = true end }
        end,
    }
end
package.loaded["http.cache"] = nil
package.preload["http.cache"] = function()
    return { key = function() return "k" end, fetch = function(_key, _ttl, load, cb) return load(cb) or { cancel = function() end } end }
end

local saved = 0
package.loaded["utils.settings"] = { saveSource = function() saved = saved + 1 end }

package.loaded["store.zlib.client"] = nil
local Client = require("store.zlib.client")
local client = Client.new({ base_url = "https://a.example" })

-- 并发：5 个同时发出，第 3 个先答成功，其余被取消，只回调一次
---@type integer, table|nil
local calls, data = 0, nil
client:_jsonAsync("GET", "/eapi/x", {}, function(d) calls = calls + 1; data = d end)
Assert.eq(#pending, 5)
pending[1].cb({ code = 503 })
Assert.eq(calls, 0)
pending[3].cb({ code = 200, body = '{"success":1}' })
Assert.eq(calls, 1)
Assert.eq(data.success, 1)
Assert.is_true(cancelled[pending[2].url] and cancelled[pending[4].url] and cancelled[pending[5].url])
pending[5].cb({ code = 200, body = '{"success":1}' })
Assert.eq(calls, 1, "胜出后迟到的回包不再回调")

-- 同场失败的镜像被落盘拉黑，胜出的不拉黑
Assert.eq(saved, 1)
Assert.is_true(client.cfg.dead_bases[pending[1].url:match("^https://[^/]+")] ~= nil)
Assert.is_nil(client.cfg.dead_bases[pending[3].url:match("^https://[^/]+")])

-- 已有胜出镜像：后续请求不再竞速，只发给它
pending = {}
client:_jsonAsync("GET", "/eapi/y", {}, function() end)
Assert.eq(#pending, 1)
Assert.eq(pending[1].url, "https://a.example/eapi/y")

-- 全部失败：只回调一次最终错误（先清掉固定镜像）
pending = {}
package.loaded["store.zlib.client"] = nil
Client = require("store.zlib.client")
client = Client.new({ base_url = "https://a.example" })
local err
calls = 0
client:_jsonAsync("GET", "/eapi/x", {}, function(_d, e) calls = calls + 1; err = e end)
for _idx = 1, #pending do pending[_idx].cb({ code = 503 }) end
Assert.eq(calls, 1)
Assert.matches(err, "503")

-- 拉黑的镜像下次竞速不再尝试
pending = {}
package.loaded["store.zlib.client"] = nil
Client = require("store.zlib.client")
local dead = { ["https://a.example"] = os.time() }
client = Client.new({ dead_bases = dead })
client:_jsonAsync("GET", "/eapi/z", {}, function() end)
for _idx = 1, #pending do
    Assert.is_true(pending[_idx].url:find("a.example", 1, true) == nil)
end

-- serial：一次只发一个，失败才换下一个，最多 3 个
pending = {}
calls = 0
client:_jsonAsync("GET", "/eapi/x", { serial = true }, function() calls = calls + 1 end)
Assert.eq(#pending, 1)
pending[1].cb({ code = 503 })
Assert.eq(#pending, 2)
pending[2].cb({ code = 503 })
pending[3].cb({ code = 503 })
Assert.eq(#pending, 3)
Assert.eq(calls, 1)

return true
