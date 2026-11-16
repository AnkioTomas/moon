--[[--
desktop.detail.scrape.platform.changpei 离线用例：打桩 http.request，驱动 searchAsync 的解析

@module tests.desktop.detail.scrape.platform.changpei_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch

local Assert = require("support.assert")
local Config = require("support.config")

local function readFixture(name)
    local f = assert(io.open(Config.root() .. "/tests/desktop/detail/scrape/platform/fixtures/" .. name, "r"))
    local data = f:read("*a")
    f:close()
    return data
end

local fake = { body = nil, err = nil, url = nil, opts = nil }

package.preload["http.request"] = function()
    return {
        get = function(url, opts, cb)
            fake.url, fake.opts = url, opts
            cb(fake.body, fake.err, nil)
            return { cancel = function() end }
        end,
    }
end

package.preload["json"] = function()
    return { decode = require("support.json_stub").decode }
end

for _, name in ipairs({ "http.request", "json", "utils.json", "desktop.detail.scrape.platform.changpei" }) do
    package.loaded[name] = nil
end
local Platform = require("desktop.detail.scrape.platform.changpei")

local function search(body, err)
    fake.body, fake.err = body, err
    local rows, e
    Platform.searchAsync("关键词", function(r, er) rows, e = r, er end)
    return rows, e
end

do
    local rows, err = search(readFixture("changpei.json"))
    Assert.is_nil(err)
    Assert.eq(2, #rows)
    Assert.eq("changpei", rows[1].source)
    Assert.eq("空间", rows[1].title)
    Assert.eq("木喵白", rows[1].author)
    Assert.eq("HE", rows[1].tags[1])
    Assert.eq("也许我们一见如“故”呢？", rows[1].intro)
    Assert.eq("https://resourcecp-cdn.gongzicp.com/uploads/20210801/0c810b068bb0d8b311cbbe8cf2422cd105.jpg", rows[1].cover_url)
    Assert.eq("", rows[2].cover_url)
    Assert.is_true(fake.url:find("gongzicp.com/webapi/search/novels", 1, true) ~= nil)
    Assert.is_true(fake.url:find("%E5%85%B3%E9%94%AE%E8%AF%8D", 1, true) ~= nil)
end

do
    local rows, err = search('{"code":200,"data":{"list":[]}}')
    Assert.is_nil(err)
    Assert.eq(0, #rows)
end

do
    local rows, err = search("<html>blocked</html>")
    Assert.is_nil(rows)
    Assert.eq("响应无效", err)
    rows, err = search(nil, "timeout")
    Assert.is_nil(rows)
    Assert.eq("timeout", err)
end

package.preload["http.request"] = nil
package.preload["json"] = nil
for _, name in ipairs({ "http.request", "json", "utils.json", "desktop.detail.scrape.platform.changpei" }) do
    package.loaded[name] = nil
end
