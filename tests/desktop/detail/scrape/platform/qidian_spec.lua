--[[--
desktop.detail.scrape.platform.qidian 离线用例：打桩 http.request，驱动 searchAsync 的解析

@module tests.desktop.detail.scrape.platform.qidian_spec
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

for _, name in ipairs({ "http.request", "json", "utils.json", "desktop.detail.scrape.platform.qidian" }) do
    package.loaded[name] = nil
end
local Platform = require("desktop.detail.scrape.platform.qidian")

local function search(body, err)
    fake.body, fake.err = body, err
    local rows, e
    Platform.searchAsync("关键词", function(r, er) rows, e = r, er end)
    return rows, e
end

do
    local rows, err = search(readFixture("qidian.json"))
    Assert.is_nil(err)
    Assert.eq(2, #rows)
    Assert.eq("qidian", rows[1].source)
    Assert.eq("诡秘之主", rows[1].title)
    Assert.eq("爱潜水的乌贼", rows[1].author)
    Assert.eq("玄幻", rows[1].tags[1])
    Assert.eq("https://bookcover.yuewen.com/qdbimg/349573/1010868264/180", rows[1].cover_url)
    Assert.is_true(rows[1].intro:find("愚者", 1, true) ~= nil)
    Assert.is_true(fake.opts.headers.Cookie:find("_csrfToken=", 1, true) ~= nil)
    Assert.is_true(fake.url:find("m.qidian.com/webcommon/search/list", 1, true) ~= nil)
    Assert.is_true(fake.url:find("%E5%85%B3%E9%94%AE%E8%AF%8D", 1, true) ~= nil)
end

do
    local rows, err = search('{"code":0,"data":{"bookInfo":{"records":[]}}}')
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
for _, name in ipairs({ "http.request", "json", "utils.json", "desktop.detail.scrape.platform.qidian" }) do
    package.loaded[name] = nil
end
