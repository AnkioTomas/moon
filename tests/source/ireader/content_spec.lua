--[[--
掌阅补充私用字码、正文插图、分阶段取消与旧章节离线升级。

@module tests.source.ireader.content_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch

local Assert = require("support.assert")
local Config = require("support.config")
local JSON = require("support.json_stub")
local Text = require("utils.text")
local Mapper = require("source.ireader.mapper")
local Fs = require("utils.fs")

local encoded = {}
for cp = 0xF0000, 0xF0009 do encoded[#encoded + 1] = Text.utf8char(cp) end
for cp = 0xF0010, 0xF0019 do encoded[#encoded + 1] = Text.utf8char(cp) end
local attributes = ' id="keep" data-book="original"'
Assert.eq(Mapper.content("<p" .. attributes .. ">" .. table.concat(encoded) .. "</p>"),
    "<p" .. attributes .. ">的一是了在有他我这们来去说就事你对也还但</p>")
Assert.eq(Mapper.content("<p>普通字、标点 &amp; 😀</p>"), "<p>普通字、标点 &amp; 😀</p>")
Assert.is_nil(Mapper.content("<p>" .. Text.utf8char(0xF001A) .. "</p>"), "新字码不能静默留下问号")

local requests, content_async, images_sync = {}, false, false
local wire, image_data, image_error
local png = "\137PNG\r\n\026\n" .. string.rep("x", 32)
local url = "https://bookbk.img.zhangyue01.com/fixture.png?v=one&amp;t=two"
local raw = '<html><body><p id="keep">人' .. Text.utf8char(0xF0009) .. Text.utf8char(0xF0004)
    .. '阅读。</p><img src="' .. url .. '"/><img src="' .. url .. '"/></body></html>'

package.loaded["json"] = JSON
package.loaded["utils.settings"] = { getSource = function() return { usr = "test", zysid = "test" } end }
package.loaded["http.request"] = {
    get = function(target, opts, cb)
        local request = { url = target, opts = opts, cb = cb }
        requests[#requests + 1] = request
        if target:find("/nsr/chapter-content", 1, true) then
            if not content_async then cb(JSON.encode(wire)) end
        elseif images_sync then
            cb(image_data, image_error)
        end
        return { cancel = function() request.cancelled = true end }
    end,
}

local captured_ops, captured_reuse
local identity = { source_id = "ireader", stable_id = "content-fixture" }
local chapter = { idx = 1, uid = "1", title = "正文" }
package.loaded["source.chapter"] = {
    openAsync = function(_source, ref, _book, _opts, ops, cb)
        captured_ops = ops
        return ops.fetchContent(ref, chapter, cb)
    end,
    prefetchAsync = function(ref, _book, _toc, _from, _count, ops, cb)
        captured_ops = ops
        return ops.fetchContent(ref, chapter, cb)
    end,
    cacheAllAsync = function(_source, ref, fetch, _progress, cb, _interval, _range, cache_reuse)
        captured_reuse = cache_reuse
        return fetch(ref, chapter, cb)
    end,
}
local source = require("source.ireader").new()
local Client = require("source.ireader.client")
local payload, reason, calls = nil, nil, 0
local function done(value, err) payload, reason, calls = value, err, calls + 1 end
local function reset()
    requests, payload, reason, calls = {}, nil, nil, 0
    content_async, images_sync = false, false
    image_data, image_error = png, nil
    wire = { code = 0, body = { bookContent = raw } }
end
local function open()
    return source:openBookAsync(identity, { chapter_idx = 1 }, done)
end

reset()
open()
Assert.eq(#requests, 2, "正文同步返回后转入插图下载")
local image = requests[2]
Assert.eq(image.url, (url:gsub("&amp;", "&")))
Assert.eq(image.opts.headers.Referer, "https://pc.ireader.com/")
Assert.is_nil(image.opts.headers.Cookie)
Assert.is_nil(image.url:find("zysid=", 1, true))
Assert.is_nil(image.url:find("usr=", 1, true), "正文凭证不发送到图片 CDN")
Assert.eq(calls, 0, "图片完成前不交出成功正文")
image.cb(png)
Assert.eq(calls, 1)
Assert.is_nil(reason)
Assert.eq(payload.title, chapter.title)
Assert.is_true(payload.html:find("人们在阅读。", 1, true) ~= nil)
Assert.is_false(Text.hasRemoteImageSrc(payload.html))
Assert.eq(#requests, 2, "同一图片只下载一次")
local href = payload.html:match('src="([^"]+)"')
Assert.matches(href, "^images/[a-f0-9]+%.png$")
Assert.eq(Fs.read(require("utils.paths").bookWorkDir(identity.stable_id, "ireader") .. "/" .. href), png)

reset()
local handle = open()
image = requests[2]
handle:cancel()
Assert.is_true(image.cancelled, "正文同步回调不能用旧请求覆盖图片取消句柄")
image.cb(png)
Assert.eq(calls, 0)

reset()
content_async = true
handle = open()
local initial = requests[1]
handle:cancel()
Assert.is_true(initial.cancelled)
initial.cb(JSON.encode(wire))
Assert.eq(#requests, 1, "取消后的正文回包不能再下载插图")
Assert.eq(calls, 0)

reset()
images_sync, image_data, image_error = true, nil, "network failed"
open()
Assert.is_nil(payload)
Assert.eq(reason, "network failed", "图片网络失败不能算全章缓存成功")

reset()
images_sync, image_data = true, "<html>not an image</html>"
open()
Assert.is_nil(payload)
Assert.eq(reason, "掌阅插图下载失败，请重试")

reset()
wire.body.bookContent = "<p>" .. Text.utf8char(0xF001A) .. "</p>"
Client.contentAsync("content-fixture", "1", done)
Assert.is_nil(payload)
Assert.eq(reason, "掌阅正文含未知字码，请更新插件后重试")

reset()
wire.body = { bookContent = raw, charging_info = { is_buy = false } }
source:prefetchChaptersAsync(identity, { chapter }, 0, 1, done)
Assert.is_nil(payload)
Assert.eq(reason, "本章未购买")
Assert.eq(#requests, 1, "未购正文不能开始下载资源")

reset()
wire.body.bookContent = '<p id="keep">' .. Text.utf8char(0xF0000) .. "正文。</p>"
open()
local cache_reuse = captured_ops.reuse
local old = '<html><head><title>书名</title></head><body><p id="keep">旧'
    .. Text.utf8char(0xF0000) .. "正文。</p></body></html>"
local fixed = old:gsub(Text.utf8char(0xF0000), "的")
local path = Config.dir() .. "/ireader_content_fixture.html"
local function writeOld()
    local file = assert(io.open(path, "wb")); assert(file:write(old)); assert(file:close())
end
writeOld()
Assert.is_true(cache_reuse(path))
Assert.eq(Fs.read(path), fixed, "不联网、不删目录、不改节点，原地修复旧缓存")
Assert.is_true(cache_reuse(path))
Assert.eq(Fs.read(path), fixed, "升级幂等")
Assert.is_nil(io.open(path .. ".part", "rb"))

writeOld()
local rename = os.rename
os.rename = function() return nil, "rename blocked" end
Assert.errors(function() cache_reuse(path) end, "rename blocked")
os.rename = rename
Assert.eq(Fs.read(path), old, "落盘失败保留旧正文")
Assert.is_nil(io.open(path .. ".part", "rb"))

source:prefetchChaptersAsync(identity, { chapter }, 0, 1, done)
Assert.is_true(captured_ops.reuse(path))
Assert.eq(Fs.read(path), fixed, "阅读预取也升级旧缓存")
writeOld()
source:cacheAllChaptersAsync(identity, nil, done)
Assert.is_true(captured_reuse(path))
Assert.eq(Fs.read(path), fixed, "全本缓存不能把旧字码当作已处理")
os.remove(path)
