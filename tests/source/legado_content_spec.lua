--[[--
reader3 本地 EPUB：正文资源与图片的成功、失败、取消及同步回调接力。

@module tests.source.legado_content_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch, assign-type-mismatch

local Assert = require("support.assert")
local JSONStub = require("support.json_stub")
local Paths = require("utils.paths")
local cfg = { server_address = "http://reader.example/reader3" }
local requests, sync_replies, writes = {}, {}, {}
local payload, reason, calls
local write_failed = false

package.preload["utils.settings"] = function()
    return { getSource = function() return cfg end }
end
package.preload["json"] = function()
    return { encode = JSONStub.encode, decode = JSONStub.decode }
end
package.preload["http.request"] = function()
    local function request(url, cb)
        local entry = { url = url, cb = cb, cancelled = false }
        requests[#requests + 1] = entry
        local reply = table.remove(sync_replies, 1)
        if reply then cb(reply.body, reply.err) end
        return { cancel = function() entry.cancelled = true end }
    end
    return {
        get = function(url, _opts, cb) return request(url, cb) end,
        post = function(url, _body, _opts, cb) return request(url, cb) end,
    }
end
package.preload["source.chapter"] = function()
    return {
        prefetchAsync = function(identity, _book, toc, _from, _count, ops, cb)
            return ops.fetchContent(identity, toc[1], cb)
        end,
    }
end
for _idx, name in ipairs({ "utils.settings", "json", "http.request", "source.chapter",
    "source.assets", "source.legado", "source.legado.client" }) do
    package.loaded[name] = nil
end
local Assets = require("source.assets")
Assets.materializeImage = function(dir, data)
    writes[#writes + 1] = { dir = dir, data = data }
    if write_failed then return nil end
    return "images/fixture.png"
end
local source = require("source.legado").new()
local identity = { source_id = "legado", stable_id = "legado-content-fixture", book = {} }
local toc = { { idx = 1, uid = "0", title = "章" } }
local resource = "/book-assets/book/Text/chapter%20one.xhtml"
local image_body = '<body><img src = "../Images/cover%20one.png"/></body>'
local function wire(text) return JSONStub.encode({ isSuccess = true, data = text }) end
local function start(replies)
    requests, writes, sync_replies = {}, {}, replies or {}
    payload, reason, calls, write_failed = nil, nil, 0, false
    return source:prefetchChaptersAsync(identity, toc, 1, 1, function(value, err)
        payload, reason, calls = value, err, calls + 1
    end)
end

-- 普通正文不能因为以 .html 结尾而被当作资源，包括 App 和轻阅读。
for _idx, address in ipairs({ "http://reader.example/reader3", "http://reader.example", "http://reader.example/api/5" }) do
    cfg.server_address = address
    start()
    requests[1].cb(wire("Documentation is at index.html"))
    Assert.eq(payload.html, "<h1>章</h1>\n<p>Documentation is at index.html</p>")
    Assert.len(requests, 1)
end
cfg.server_address = "http://reader.example/reader3"

-- 资源路径保留已有编码；合法的 src = 属性在图片落地后不再留下远程引用。
do
    start()
    requests[1].cb(wire(resource))
    Assert.eq(requests[2].url, "http://reader.example" .. resource)
    requests[2].cb(image_body)
    Assert.eq(requests[3].url, "http://reader.example/book-assets/book/Images/cover%20one.png")
    requests[3].cb("image data")
    Assert.eq(payload.html, '<h1>章</h1>\n<img src="images/fixture.png"/>')
    Assert.eq(writes[1].dir, Paths.bookWorkDir(identity.stable_id, identity.source_id) .. "/images")
    Assert.eq(calls, 1)
end

-- 资源 GET 的错误直接上报；标题和空白实体不能让空正文成功。
do
    start()
    requests[1].cb(wire(resource))
    requests[2].cb(nil, "HTTP 404")
    Assert.is_nil(payload)
    Assert.eq(reason, "HTTP 404")
    start()
    requests[1].cb(wire(resource))
    requests[2].cb("<body><div>&nbsp; &#160;</div></body>")
    Assert.is_nil(payload)
    Assert.eq(reason, "阅读章节内容为空")
    start()
    requests[1].cb(wire(resource))
    requests[2].cb("<body><div>&amp;</div></body>")
    Assert.eq(payload.html, "<h1>章</h1>\n<div>&amp;</div>")
end

-- 下载失败、不识别的图片或图片写盘失败，均不得返回成功章节。
for _idx, failure in ipairs({ "network", "invalid", "write" }) do
    start()
    requests[1].cb(wire(resource))
    requests[2].cb(image_body)
    if failure == "network" then
        requests[3].cb(nil, "HTTP 404")
    else
        if failure == "invalid" then
            local materialize = Assets.materializeImage
            Assets.materializeImage = function() return nil end
            requests[3].cb("<html>not an image</html>")
            Assets.materializeImage = materialize
        else
            write_failed = true
            requests[3].cb("image data")
        end
    end
    Assert.is_nil(payload)
    Assert.eq(reason, failure == "network" and "HTTP 404" or "阅读插图下载失败，请重试")
    Assert.eq(calls, 1)
end

-- 三个阶段分别取消；即使底层桩强行投递迟到响应也不能继续或落地图片。
for phase = 1, 3 do
    local job = start()
    if phase > 1 then requests[1].cb(wire(resource)) end
    if phase > 2 then requests[2].cb(image_body) end
    job.cancel()
    Assert.is_true(requests[phase].cancelled)
    requests[phase].cb(phase == 1 and wire(resource) or phase == 2 and image_body or "image data")
    Assert.len(requests, phase)
    Assert.len(writes, 0)
    Assert.eq(calls, 0)
end

-- 同步 API / XHTML 回调不能把旧句柄写回，取消必须命中仍在飞的下一阶段。
for phase = 2, 3 do
    local replies = { { body = wire(resource) } }
    if phase == 3 then replies[2] = { body = image_body } end
    local job = start(replies)
    job.cancel()
    Assert.is_true(requests[phase].cancelled)
    Assert.is_false(requests[1].cancelled)
    Assert.eq(calls, 0)
end

-- 已登录时 XHTML 和同服务器图片都带令牌，CDN 图片不带服务器令牌。
do
    cfg.username, cfg.password = "fixture-user", "fixture-password"
    start()
    requests[1].cb(wire({ accessToken = "fixture-token" }))
    requests[2].cb(wire(resource))
    Assert.eq(requests[3].url, "http://reader.example" .. resource .. "?accessToken=fixture-token")
    requests[3].cb('<body><img src="../Images/cover.png"/><img src="//cdn.example/cover.png"/></body>')
    Assert.eq(requests[4].url, "http://reader.example/book-assets/book/Images/cover.png?accessToken=fixture-token")
    requests[4].cb("image data")
    Assert.eq(requests[5].url, "http://cdn.example/cover.png")
    requests[5].cb("cdn image data")
    Assert.is_nil(reason)
    Assert.eq(calls, 1)
end
