--[[--
爱看书多页章节完整交付、中途失败和取消，兼容旧缓存与目录落盘失败。

@module tests.source.18ta.reading_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch

local Assert = require("support.assert")
local Stubs = require("support.stubs")
local Config = require("support.config")
local path = "/aks/1/9/100.html"
local requests, delayed, failed, malformed = {}, false, false, false
package.loaded["http.request"] = {
    headerAll = function() return {} end,
    get = function(url, _opts, cb)
        local request = { url = url, cb = cb }
        requests[#requests + 1] = request
        local handle = { cancel = function() request.cancelled = true end }
        local page = tonumber(url:match("_(%d+)%.html$")) or 1
        if delayed and page == 2 then return handle end
        if failed and page == 2 then cb(nil, "timeout"); return handle end
        if malformed then cb('<article id="article"><p>片段</p></article>'); return handle end
        cb('<article id="article"><p>第' .. page .. '页</p></article><a id="next_url" href="'
            .. (page == 1 and "/aks/1/9/100_2.html" or "/aks/1/9/101.html") .. '">下一页</a>')
        return handle
    end,
}
local Client = require("source.18ta.client")
local client = Client.new()
local result, reason, calls = nil, nil, 0
local function done(html, err) result, reason, calls = html, err, calls + 1 end
client:contentAsync("https://www.18ta.com" .. path, done)
Assert.eq(result, "<p>第1页</p>\n<p>第2页</p>")
Assert.eq(calls, 1)
Assert.len(requests, 2, "不能取下一章")
failed = true
client:contentAsync(path, done)
Assert.is_nil(result, "第二页失败不能交付第一页")
Assert.eq(reason, "timeout")
failed, malformed = false, true
client:contentAsync(path, done)
Assert.is_nil(result)
Assert.eq(reason, "响应无效")
malformed, delayed = false, true
local before = calls
local handle = client:contentAsync(path, done)
handle.cancel()
Assert.is_true(requests[#requests].cancelled)
requests[#requests].cb('<article id="article"><p>迟到</p></article>')
Assert.eq(calls, before)

local online = true
package.loaded["ui/network/manager"] = { isConnected = function() return online end }
local ops
local toc = { { idx = 1, uid = path } }
package.loaded["source.toc"] = { read = function() return toc end, put = function() return false end }
package.loaded["source.chapter"] = {
    openAsync = function(_source, _identity, _book, _options, options) ops = options end,
}
local source = require("source.18ta").new()
source:openBookAsync({ source_id = "18ta", stable_id = "9" }, { chapter_idx = 1 }, function() end)
local cache = Config.dir() .. "/18ta-legacy.html"
local file = assert(io.open(cache, "wb"))
file:write("<html><p>旧单页</p></html>")
file:close()
Assert.is_false(ops.reuse(cache), "在线升级旧单页缓存")
online = false
Assert.is_true(ops.reuse(cache), "离线不丢弃旧缓存")
online = true
file = assert(io.open(cache, "wb"))
file:write("<!--moon:18ta:complete--><html><p>完整章节</p></html>")
file:close()
Assert.is_true(ops.reuse(cache))
os.remove(cache)
delayed = false
local payload
ops.fetchContent({}, { origin = "https://www.18ta.com" .. path, title = "章节" }, function(data) payload = data end)
Assert.eq(payload.mark, "moon:18ta:complete")
Assert.is_true(payload.html:find("第2页", 1, true) ~= nil)

source:loadTocAsync({ stable_id = "9" }, function(data) result = data end)
Stubs.flush()
Assert.eq(result, toc, "旧目录离线继续可用")
source.client.bookAsync = function(_self, _id, cb)
    cb('<ul id="ul_all_chapters"><li><a href="' .. path .. '" title="章">章节</a></li></ul>')
end
source:refreshTocAsync({ stable_id = "9" }, done)
Assert.is_nil(result)
Assert.eq(reason, "章节目录保存失败")
