--[[--
盐选正文权限、错误与 HTTP → 字体任务的取消所有权。

@module tests.source.zhihu.content_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch

local Assert = require("support.assert")
local Json = require("support.json_stub")
package.preload["json"] = function() return Json end

local response, response_err, http_pending, font_pending
local http_cb, font_cb, requested_path, signed_cookie, request_options
local calls, http_cancelled, font_cancelled = 0, 0, 0
package.preload["source.zhihu.sign"] = function()
    return { headers = function(path, cookie)
        requested_path, signed_cookie = path, cookie
        return { ["x-zse-96"] = "fixture" }
    end }
end
package.preload["http.request"] = function()
    return { get = function(url, options, cb)
        request_options = options
        Assert.eq(url, "https://api.zhihu.com" .. requested_path)
        http_cb = cb
        if not http_pending then cb(response, response_err) end
        return { cancel = function() http_cancelled = http_cancelled + 1 end }
    end }
end
package.preload["source.zhihu.font"] = function()
    return { restoreAsync = function(wire, cb)
        calls = calls + 1
        Assert.eq(wire.use_font, true)
        font_cb = cb
        if not font_pending then cb("<p>还原正文</p>") end
        local job = {}
        function job:cancel()
            Assert.eq(self, job, "字体 Job 使用冒号取消")
            font_cancelled = font_cancelled + 1
        end
        return job
    end }
end

local Settings = require("utils.settings")
Settings.getSource("zhihu").cookie = 'z_c0=saved; d_c0="fixture|1"'
local Client = require("source.zhihu.client")
local value, error_message, completed
local function fetch()
    value, error_message, completed = nil, nil, 0
    return Client.contentAsync("1/2", function(html, err)
        value, error_message = html, err
        completed = completed + 1
    end)
end
response = Json.encode({ is_fold = false, authentication_result = true, manuscript = "<p>正文</p>" })
fetch()
Assert.eq(value, "<p>正文</p>")
Assert.eq(requested_path, "/remix-web/paid_columns/1/sections/2/manuscript?v=1&manuscript_version=0")
Assert.eq(signed_cookie, Settings.getSource("zhihu").cookie)
Assert.eq(request_options.headers.Cookie, signed_cookie)
Assert.eq(request_options.headers["x-zse-96"], "fixture")
Assert.eq(calls, 0, "没有乱序字体的章节不创建字体任务")

for _idx, denied in ipairs({
    { is_fold = true, manuscript = "<p>付费预览</p>", use_font = true },
    { is_fold = false, authentication_result = false, manuscript = "<p>付费预览</p>" },
}) do
    response = Json.encode(denied)
    fetch()
    Assert.is_nil(value)
    Assert.eq(error_message, "本章未购买")
end
Assert.eq(calls, 0, "拒绝权限后不能还原或缓存预览")

for _idx, invalid in ipairs({ "{}", "<html>风控</html>",
    '{"is_fold":false,"manuscript":""}', '{"error":{"code":10003}}' }) do
    response = invalid
    fetch()
    Assert.is_nil(value)
    Assert.eq(error_message, "请求失败")
end
response, response_err = nil, "HTTP 403"
fetch()
Assert.is_nil(value)
Assert.eq(error_message, "HTTP 403")
response_err = nil

response = Json.encode({ is_fold = false, manuscript = "<p>乱序</p>", use_font = true })
font_pending = true
local handle = fetch()
Assert.eq(completed, 0)
handle.cancel()
Assert.eq(http_cancelled, 0, "同步 HTTP 回调不能用已结束请求覆盖正在还原的 Job")
Assert.eq(font_cancelled, 1)
font_cb("<p>迟到正文</p>")
Assert.eq(completed, 0)

handle = fetch()
font_cb(nil, "字体失败")
Assert.eq(error_message, "字体失败")
Assert.eq(completed, 1)
handle.cancel()
Assert.eq(font_cancelled, 1, "字体完成后不再持有任务")

font_pending = false
handle = fetch()
Assert.eq(value, "<p>还原正文</p>")
handle.cancel()
Assert.eq(font_cancelled, 1, "同步字体回调也不能留下完成句柄")

http_pending = true
handle = fetch()
handle.cancel()
Assert.eq(http_cancelled, 1)
http_cb(response)
Assert.eq(completed, 0, "取消 HTTP 后忽略迟到响应")
Settings.getSource("zhihu").cookie = nil
