--[[--
站点映射保持单一 API 协议；书架写入必须回读确认，取消不能漏到下一阶段。

@module tests.source.copymanga.api_spec
--]]

local Assert = require("support.assert")
local JSON = require("support.json_stub")
package.loaded["json"] = JSON
local Client = require("source.copymanga.client")
local settings = require("utils.settings")
local calls, replies, cancelled = {}, {}, {}
package.loaded["http.request"] = {
    get = function(url, opts, cb)
        calls[#calls + 1] = { url = url, headers = opts.headers, redirects = opts.allow_redirects }
        local reply = table.remove(replies, 1)
        local id = #calls
        if reply.hold then reply.callback = cb else cb(reply.raw, reply.err) end
        return { cancel = function() cancelled[id] = true end }
    end,
    post = function(url, body, opts, cb)
        calls[#calls + 1] = { url = url, headers = opts.headers, body = body, redirects = opts.allow_redirects }
        local reply = table.remove(replies, 1)
        local id = #calls
        if reply.hold then reply.callback = cb else cb(reply.raw, reply.err) end
        return { cancel = function() cancelled[id] = true end }
    end,
}
local detail = '{"code":200,"results":{"comic":{"uuid":"comic-id","path_word":"test","name":"Test"}}}'
local empty = '{"code":200,"results":{"list":[],"total":0}}'
local collected = '{"code":200,"results":{"list":[{"comic":{"uuid":"comic-id","path_word":"test"}}],"total":1}}'

for _idx, site in ipairs(Client.SITES) do
    local api = site:gsub("https://www%.", "https://api.")
    Assert.eq(Client.normalizeBaseUrl(site .. "/"), api)
    Assert.eq(Client.normalizeBaseUrl(api), api)
    local cfg = settings.getSource("copymanga")
    cfg.base_url, cfg.token, cfg.user_id = site, "private-token", "1"
    settings.saveSource("copymanga", cfg)
    local client = Client:new(cfg)
    local result, err
    replies = { { raw = empty } }
    client:searchAsync("one", function(wire, e) result, err = wire, e end)
    Assert.is_nil(err)
    Assert.is_true(result ~= nil)
    Assert.is_true(calls[#calls].url:find(api .. "/api/v3/search/comic?", 1, true) == 1)
    Assert.eq(calls[#calls].headers["User-Agent"], "COPY/3.0.0")
    Assert.is_nil(calls[#calls].headers.Authorization)

    replies = { { raw = '{"code":200,"results":{"chapter":{"contents":[{"url":"https://images.example/page.jpg"}]}}}' } }
    client:chapterAsync("test", "chapter-id", function(wire, e) result, err = wire, e end)
    Assert.is_nil(err)
    Assert.is_true(result ~= nil)
    local endpoint = api == Client.CURRENT_BASE_URL and "chapter" or "chapter2"
    Assert.eq(calls[#calls].url, api .. "/api/v3/comic/test/" .. endpoint .. "/chapter-id?platform=1")

    replies = { { raw = detail }, { raw = '{"code":200}' }, { raw = collected } }
    client:addToShelfAsync("test", function(wire, e) result, err = wire, e end)
    Assert.is_nil(err)
    Assert.is_true(result ~= nil)
    Assert.eq(calls[#calls - 1].url, api .. "/api/v3/member/collect/comic")
    Assert.is_true(calls[#calls - 1].body:find("is_collect=1", 1, true) ~= nil)
    Assert.eq(calls[#calls].headers.Authorization, "Token private-token")
    Assert.is_false(calls[#calls].redirects)
    Assert.is_false(calls[#calls - 1].redirects)

    replies = { { raw = detail }, { raw = '{"code":200}' }, { raw = collected } }
    client:removeFromShelfAsync("test", function(wire, e) result, err = wire, e end)
    Assert.is_nil(result)
    Assert.eq(err, "书架同步未确认")

    replies = { { raw = detail }, { raw = '{"code":200}' }, { raw = empty } }
    client:removeFromShelfAsync("test", function(wire, e) result, err = wire, e end)
    Assert.is_nil(err)
    Assert.is_true(result ~= nil)

    local held = { hold = true }
    replies = { { raw = detail }, { raw = '{"code":200}' }, held }
    local completed = false
    local job = client:addToShelfAsync("test", function() completed = true end)
    job.cancel()
    Assert.is_true(cancelled[#calls], "取消回读阶段，不得被同步返回的旧句柄覆盖")
    held.callback(collected)
    Assert.is_false(completed)

    local source = require("source.copymanga").new()
    if api == Client.CURRENT_BASE_URL then
        Assert.is_nil(source.getProgressAsync)
        Assert.is_nil(source.putProgressAsync)
    else
        Assert.eq(type(source.getProgressAsync), "function")
        Assert.eq(type(source.putProgressAsync), "function")
    end
end

do
    local client = Client:new(settings.getSource("copymanga"))
    local result, err
    replies = { { raw = '{"code":200,"results":{}}' } }
    client:shelfSyncAsync(function(rows, e) result, err = rows, e end)
    Assert.is_nil(result)
    Assert.eq(err, "响应无效")
    replies = { { raw = '{"code":200,"results":{"list":[{}],"total":1}}' } }
    client:shelfSyncAsync(function(rows, e) result, err = rows, e end)
    Assert.is_nil(result)
    Assert.eq(err, "响应无效")
    replies = { { raw = '{"code":200,"results":{"list":[],"total":2}}' } }
    client:shelfSyncAsync(function(rows, e) result, err = rows, e end)
    Assert.is_nil(result)
    Assert.eq(err, "响应无效")

    replies = {
        { raw = '{"code":200,"results":{"list":[{"comic":{"path_word":"one"}}],"total":2}}' },
        { raw = '{"code":200,"results":{"list":[{"comic":{"path_word":"two"}}],"total":2}}' },
    }
    client:shelfSyncAsync(function(rows, e) result, err = rows, e end)
    Assert.is_nil(err)
    Assert.len(result, 2)
    Assert.is_true(calls[#calls].url:find("offset=1", 1, true) ~= nil)
    require("source.copymanga.auth").clearSession()
    Assert.eq(client:_latestToken(), "")
    local cfg = settings.getSource("copymanga")
    cfg.base_url, cfg.token = Client.SITES[1], "new-site-token"
    settings.saveSource("copymanga", cfg)
    Assert.eq(client:_latestToken(), "")
end
require("source.copymanga.auth").clearSession()
