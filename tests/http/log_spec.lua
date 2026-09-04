--[[-- HTTP 调试日志必须可追踪请求，且不能泄露 URL 凭据与查询参数。 --]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")

local lines = {}
package.preload["utils.log"] = function()
    return {
        dbg = function(...)
            local parts = {}
            for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
            lines[#lines + 1] = table.concat(parts, " ")
        end,
        warn = function() end,
    }
end
package.loaded["utils.log"] = nil
package.loaded["http.request"] = nil

local Request = require("http.request")
Request.ensureTurbo = function() return false end

local received
Request.request({
    method = "GET",
    url = "https://user:secret@example.test/books?token=hidden#section",
}, function(_, err)
    received = err
end)
Stubs.flush()

local output = table.concat(lines, "\n")
Assert.not_nil(output:find("book.http start", 1, true))
Assert.not_nil(output:find("https://example.test/books", 1, true))
Assert.not_nil(output:find("book.http done", 1, true))
Assert.is_nil(output:find("user:secret", 1, true))
Assert.is_nil(output:find("token=hidden", 1, true))
Assert.eq(received, "turbo looper unavailable")
