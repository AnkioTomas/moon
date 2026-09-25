--[[--
zlib 镜像故障转移：重定向环与 5xx 一样换下一个镜像。

@module tests.zlib.client_spec
--]]

local Assert = require("support.assert")

package.loaded["json"] = nil
package.preload["json"] = function()
    return { decode = require("support.json_stub").decode }
end

local urls = {}
package.loaded["http.request"] = nil
package.preload["http.request"] = function()
    return {
        ok = function(code) return code >= 200 and code < 300 end,
        header = function(res, name) return res.headers and res.headers[name:lower()] end,
        request = function(opts, cb)
            urls[#urls + 1] = opts.url
            if opts.url:find("^https://bad%.example") then
                -- 自指 302：重定向环
                cb({ code = 302, headers = { location = opts.url } })
            else
                cb({ code = 200, body = '{"success":1}' })
            end
            return { cancel = function() end }
        end,
    }
end
package.loaded["http.cache"] = nil
package.preload["http.cache"] = function()
    return { key = function() return "k" end, set = function() end, getAsync = function() end }
end

package.loaded["zlib.client"] = nil
local Client = require("zlib.client")
local client = Client.new({ base_url = "https://bad.example" })

local data, err
client:_jsonAsync("GET", "/eapi/info/ok", nil, function(d, e) data, err = d, e end)

Assert.is_nil(err)
Assert.eq(data.success, 1)
Assert.eq(urls[1], "https://bad.example/eapi/info/ok")
Assert.is_true(#urls >= 2)
Assert.is_nil(urls[#urls]:find("bad.example", 1, true), "重定向环后应换镜像")

return true
