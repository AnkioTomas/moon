--[[--
extensions/moonsource-kavita.koplugin/moonsource_kavita/client.lua：请求超时可配置，
统计分页的 URL 形态与 `Pagination` 头解析。

慢设备 / 慢服务器上全量书架（all-v2）一次要几十秒，固定的 30s 上限会让整轮同步中断、
书架永远加载不出来；这里锁住「默认足够宽 + 可在设置里调大 + 透传到 HTTP 层」。

@module tests.extensions.kavita.client_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, inject-field

local Assert = require("support.assert")
local Config = require("support.config")
local JsonStub = require("support.json_stub")

package.loaded["json"] = { encode = JsonStub.encode, decode = JsonStub.decode }

local captured
package.loaded["http.request"] = {
    ok = function(code) return tonumber(code) == 200 end,
    request = function(opts, cb)
        captured = opts
        cb({ code = 200, body = "{}" })
        return { cancel = function() end }
    end,
}
local PLUGIN = Config.root() .. "/extensions/moonsource-kavita.koplugin"
package.preload["moonsource_kavita.client"] = function()
    return dofile(PLUGIN .. "/moonsource_kavita/client.lua")
end
local Client = require("moonsource_kavita.client")

local function make(timeout)
    return Client.new({ base_url = "http://kav/", api_key = "k", timeout = timeout })
end

Assert.eq(Client.DEFAULT_TIMEOUT, 60, "默认不再是 30s")
Assert.eq(Client.new({ base_url = "http://kav/", api_key = "k" }).timeout, 60, "未配置用默认超时")
Assert.eq(make("120").timeout, 120, "设置里的字符串数值也认")
Assert.eq(make(1).timeout, 5, "过小收敛到下限")
Assert.eq(make(0).timeout, 5, "0 收敛到下限")
Assert.eq(make(100000).timeout, 600, "过大收敛到上限")

local client = make(180)
Assert.eq(client:configured(), true)
client:request("GET", "/api/Series/all-v2", { pageNumber = 1 }, nil, function() end)
Assert.eq(captured.timeout, 180, "超时透传到 HTTP 请求，长拉书架不再被 30s 掐断")
Assert.matches(captured.url, "^http://kav/api/Series/all%-v2%?")
Assert.eq(captured.headers["x-api-key"], "k")

-- 统计拉取：`Libraries` 是重复键（逗号串会被服务端当成一个库，恒返回 0 条），
-- 其余参数按名排序，PageSize 用服务端接受的上限 200。
Assert.eq(
    client:url("/api/Stats/reading-history", {
        TimeZoneId = "Asia/Shanghai", Libraries = { 2, 1 }, PageNumber = 1, PageSize = 200,
    }),
    "http://kav/api/Stats/reading-history?Libraries=2&Libraries=1&PageNumber=1&PageSize=200&TimeZoneId=Asia%2FShanghai"
)
Assert.eq(client:url("/api/Image/series-cover", { seriesId = "10" }),
    "http://kav/api/Image/series-cover?seriesId=10", "单值参数与 formEncode 同形")

-- 分页头（挂在响应上，不在 body 里）：只认 totalPages。
Assert.eq(Client.totalPages('{"currentPage":1,"itemsPerPage":200,"totalItems":316,"totalPages":2}'), 2)
Assert.eq(Client.totalPages('{"totalPages":0}'), 0, "0 页 = 没有数据，读成 nil 会让调用方按「本页拉满」再拉一页")
Assert.is_nil(Client.totalPages('{"currentPage":1}'), "没有 totalPages 就当不可信，调用方走兜底")
Assert.is_nil(Client.totalPages('{"totalPages":-1}'), "负数不可信")
Assert.is_nil(Client.totalPages(nil))
Assert.is_nil(Client.totalPages(""))
Assert.is_nil(Client.totalPages("<html>oops</html>"), "反代错误页不能当分页头")
