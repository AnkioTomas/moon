--[[-- Kavita On Deck：服务端最近阅读，书籍与漫画都保留。 --]]

local Assert = require("support.assert")

package.preload["gettext"] = function()
    return function(text) return text end
end

local JsonStub = require("support.json_stub")
package.preload["json"] = function()
    return { encode = JsonStub.encode, decode = JsonStub.decode }
end

package.preload["ui/uimanager"] = function()
    return {
        nextTick = function(_, fn) fn() end,
        scheduleIn = function() end,
        unschedule = function() end,
    }
end

local cfg = { base_url = "https://host:port/kavita", api_key = "test-key" }
package.preload["utils.settings"] = function()
    return { getSource = function() return cfg end }
end

local requests = {}
package.preload["http.request"] = function()
    return {
        request = function(opts, cb)
            requests[#requests + 1] = opts
            if (opts.url or ""):match("/api/Series/on%-deck") then
                cb({ code = 200, body = table.concat({
                    '[{"id":1,"name":"Book A","format":3,"pages":100,"pagesRead":25},',
                    '{"id":2,"name":"Book B","format":4,"pages":0,"pagesRead":0},',
                    '{"id":3,"name":"Comic C","format":1,"pages":500,"pagesRead":10}]',
                }) })
            else
                cb({ code = 404, body = "" })
            end
            return { cancel = function() end }
        end,
    }
end

local Kavita = require("source.kavita")
local source = Kavita.new()

local result, result_err
source:onDeckAsync(function(books, err)
    result, result_err = books, err
end)

Assert.is_nil(result_err)
Assert.not_nil(result)
Assert.len(result, 3)
Assert.eq(requests[1].method, "POST")
Assert.is_true(requests[1].url:find("/api/Series/on-deck", 1, true) ~= nil)
Assert.eq(result[1].source_id, "kavita")
Assert.eq(result[1].stable_id, "1")
Assert.eq(result[1].title, "Book A")
Assert.eq(result[1].format, "epub")
Assert.eq(result[1].percent, 25)
Assert.eq(result[2].stable_id, "2")
Assert.eq(result[2].format, "pdf")
Assert.eq(result[2].percent, 0)
-- 漫画（cbz）也保留：由 kamare 在线读，进度同样来自 series 级 pagesRead/pages。
Assert.eq(result[3].stable_id, "3")
Assert.eq(result[3].title, "Comic C")
Assert.eq(result[3].format, "cbz")
Assert.eq(result[3].percent, 2)

-- 未配置：异步回错误，不发请求。
cfg = { base_url = "", api_key = "" }
source = Kavita.new()
local empty, empty_err
source:onDeckAsync(function(books, err)
    empty, empty_err = books, err
end)
Assert.is_nil(empty)
Assert.not_nil(empty_err)
Assert.eq(#requests, 1)

return true
