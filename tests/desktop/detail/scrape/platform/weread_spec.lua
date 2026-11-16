--[[--
desktop.detail.scrape.platform.weread 离线用例：打桩 http.request，驱动搜索响应解析

@module tests.desktop.detail.scrape.platform.weread_spec
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
local MODULE = "desktop.detail.scrape.platform.weread"

package.preload["http.request"] = function()
    return {
        randomUA = function() return "TestUA/1.0" end,
        get = function(url, opts, cb)
            fake.url, fake.opts = url, opts
            cb(fake.body, fake.err)
            return { cancel = function() end }
        end,
    }
end
package.preload["json"] = function()
    return { decode = require("support.json_stub").decode }
end
for _, name in ipairs({ "http.request", "json", MODULE }) do package.loaded[name] = nil end
local Platform = require(MODULE)

local function search(body, err)
    fake.body, fake.err = body, err
    local got_rows, got_err
    Platform.searchAsync("三体", function(rows, e) got_rows, got_err = rows, e end)
    return got_rows, got_err
end

-- 正常解析
do
    local rows = search(readFixture("weread_search.json"))
    Assert.len(rows, 2)
    Assert.eq(rows[1].source, "weread")
    Assert.eq(rows[1].title, "三体全集（全三册）")
    Assert.eq(rows[1].author, "刘慈欣")
    Assert.eq(rows[1].publisher, "重庆出版社")
    Assert.eq(rows[1].rating, "9.3")
    Assert.eq(rows[1].cover_url:find("^https://cdn.weread.qq.com/") ~= nil, true)
    Assert.eq(fake.url:find("weread.qq.com/web/search/global?", 1, true) ~= nil, true)
end

-- 空结果
do
    local rows, err = search('{"books":[],"totalCount":0}')
    Assert.is_nil(rows)
    Assert.eq(err, "无搜索结果")
end

-- 坏响应与传输错误
do
    local rows, err = search("<html>blocked</html>")
    Assert.is_nil(rows)
    Assert.eq(err, "响应无效")

    rows, err = search(nil, "连接超时")
    Assert.is_nil(rows)
    Assert.eq(err, "连接超时")
end

for _, name in ipairs({ "http.request", "json", MODULE }) do
    package.preload[name] = nil
    package.loaded[name] = nil
end
