--[[--
网易网页登录后重新检查匿名目录里的付费章，购买提示不进入后台缓存。

@module tests.source.netease.auth_content_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch

local Assert = require("support.assert")
local logged_in, downloads = true, 0
local html, content_error = "<p>已购正文</p>", nil
package.loaded["source.netease.client"] = {
    loggedIn = function() return logged_in end,
    contentAsync = function(book_id, chapter_id, cb)
        Assert.eq(book_id, "fixture")
        Assert.eq(chapter_id.uid, "c1")
        downloads = downloads + 1
        cb(html, content_error)
        return { cancel = function() end }
    end,
}
local open_fetch, cache_fetch, paid
package.loaded["source.chapter"] = {
    openAsync = function(_source, _identity, _book, _opts, ops) open_fetch = ops.fetchContent end,
    cacheAllAsync = function(_source, _identity, fetch) cache_fetch = fetch end,
}
package.loaded["source.toc"] = {
    markPaid = function(id, stable_id, uid, value)
        Assert.eq(id, "netease")
        Assert.eq(stable_id, "fixture")
        Assert.eq(uid, "c1")
        paid = value
    end,
}
local source = require("source.netease").new()
local identity = { source_id = "netease", stable_id = "fixture" }
local chapter = { idx = 1, uid = "c1", title = "第一章", vip = true }
source:openBookAsync(identity, { chapter_idx = 1 }, function() end)
local result, failure
open_fetch(identity, chapter, function(value, err) result, failure = value, err end)
Assert.eq(result.html, "<p>已购正文</p>")
Assert.is_nil(result.temporary)
Assert.is_true(paid)
Assert.is_nil(failure)

html, content_error = nil, "本章未购买"
open_fetch(identity, chapter, function(value) result = value end)
Assert.is_true(result.temporary)
source:cacheAllChaptersAsync(identity, nil, function() end)
cache_fetch(identity, chapter, function(value, err) result, failure = value, err end)
Assert.is_nil(result)
Assert.eq(failure, "本章未购买")
content_error = "network down"
open_fetch(identity, chapter, function(value, err) result, failure = value, err end)
Assert.is_nil(result)
Assert.eq(failure, "network down")
local before = downloads
logged_in = false
open_fetch(identity, chapter, function(value) result = value end)
Assert.is_true(result.temporary)
Assert.eq(downloads, before)
