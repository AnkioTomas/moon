--[[--
正文归属、扫码 Cookie 大小写与取消后的迟到响应。

@module tests.source.xiaoxiang.content_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch

local A = require("support.assert")
local JSON = require("support.json_stub")
package.loaded["json"] = JSON
local cfg, mode, post_cb, decrypt_cb, stopped = { cookie = "ywguid=42" }, "sync", nil, nil, false
package.loaded["utils.settings"] = { getSource = function() return cfg end }
local chapter = { ccid = "123", chapterPrice = 20, auth = true, encrypt = true, font = false,
    chapterContent = "encrypted", fkp = require("utils.text").base64Encode('window.onkeyfocus("pool", 3)') }
package.loaded["http.request"] = {
    post = function(_url, _body, _opts, cb)
        post_cb = cb
        if mode == "sync" then cb(JSON.encode({ code = 0, data = { chapterContents = { chapter } } })) end
        return { cancel = function() end }
    end,
}
package.loaded["source.xiaoxiang.fock"] = {
    chapterAsync = function(_chapter, _font, _id, _pool, _version, uid, cb)
        A.eq(uid, "42", "官网同时接受 ywGuid 与扫码生成的小写 ywguid")
        decrypt_cb = cb
        local handle = {}
        function handle:cancel() A.eq(self, handle); stopped = true end
        return handle
    end,
}
package.loaded["source.xiaoxiang.client"] = nil
local C = require("source.xiaoxiang.client")
local result, err
local handle = C.contentAsync("book", "123", function(text, reason) result, err = text, reason end)
handle.cancel()
A.is_true(stopped, "同步正文请求不能覆盖解密句柄")
decrypt_cb("迟到正文")
A.is_nil(result)
mode, result = "wait", nil
handle = C.contentAsync("book", "123", function(text) result = text end)
handle.cancel()
post_cb(JSON.encode({ code = 0, data = { chapterContents = { chapter } } }))
A.is_nil(result)
C.contentAsync("book", "123", function(text, reason) result, err = text, reason end)
cfg.cookie = "ywguid=43"
post_cb(JSON.encode({ code = 0, data = { chapterContents = { chapter } } }))
A.is_nil(result)
A.eq(err, "账号已变化，请重新登录")
mode, cfg.cookie = "sync", "ywguid=42"
chapter.ccid = "456"
C.contentAsync("book", "123", function(text, reason) result, err = text, reason end)
A.is_nil(result)
A.eq(err, "响应无效", "错误章节不能落入请求章节缓存")
chapter.ccid, chapter.auth = "123", false
C.contentAsync("book", "123", function(text, reason, kind) result, err = text, kind or reason end)
A.is_nil(result)
A.eq(err, "unpaid")
