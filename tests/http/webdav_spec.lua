--[[--
http.webdav 离线用例：join 拼接 / listAsync（驱动 local parseList）/ statusErr 文案

parseList 是 local，经 package.preload 打桩 http.request 喂罐头 207 XML 驱动。

@module tests.http.webdav_spec
--]]

local Assert = require("support.assert")

-- 离线 harness 的 LuaJIT 无 LUAJIT_ENABLE_LUA52COMPAT（无 table.pack），
-- ffi/util.template 依赖它；KOReader 真机的 LuaJIT 带 52compat 无此问题。
local saved_pack = table.pack
if not table.pack then
    table.pack = function(...)
        return { n = select("#", ...), ... }
    end
end

-- util stub 缺 htmlEntitiesToUtf8（parseList 需要），换成带该函数的浅拷贝
local saved_util = package.loaded["util"] or require("util")
local util_copy = {}
for k, v in pairs(saved_util) do
    util_copy[k] = v
end
util_copy.htmlEntitiesToUtf8 = function(s)
    return s
end
package.loaded["util"] = util_copy

-- 打桩 http.request：记录请求、喂罐头响应（同步回调）
local captured = {}
local canned_res
local canned_err
package.preload["http.request"] = function()
    return {
        ok = function(code)
            local n = tonumber(code)
            return n ~= nil and n >= 200 and n < 300
        end,
        request = function(opts, cb)
            captured[#captured + 1] = opts
            cb(canned_res, canned_err)
            return { cancel = function() end }
        end,
    }
end
package.loaded["http.request"] = nil
package.loaded["http.webdav"] = nil

local Webdav = require("http.webdav")

-- ── 构造：URL 去尾斜杠、user 回退 ─────────────────────────
do
    local dav = Webdav.new({ url = "http://example.com/dav//", user = "u2" })
    Assert.eq(dav.url, "http://example.com/dav")
    Assert.eq(dav.username, "u2")
    Assert.eq(dav.password, "")
end

-- ── join：斜杠归一 / 段编码 / 目录尾斜杠 ──────────────────
do
    local dav = Webdav.new({ url = "http://example.com/dav/", username = "u", password = "p" })
    Assert.eq(dav:join(), "http://example.com/dav")
    Assert.eq(dav:join(""), "http://example.com/dav")
    Assert.eq(dav:join("a/b"), "http://example.com/dav/a/b")
    -- 首尾斜杠归一
    Assert.eq(dav:join("/a/b/"), "http://example.com/dav/a/b")
    Assert.eq(dav:join("///"), "http://example.com/dav")
    -- 段 urlEncode，'/' 保留
    Assert.eq(dav:join("a b/c#d"), "http://example.com/dav/a%20b/c%23d")
    Assert.eq(dav:join("目录/书"), "http://example.com/dav/%E7%9B%AE%E5%BD%95/%E4%B9%A6")
    -- as_dir 强制尾斜杠，且不重复追加
    Assert.eq(dav:join("a", true), "http://example.com/dav/a/")
    Assert.eq(dav:join("/a/", true), "http://example.com/dav/a/")
    Assert.eq(dav:join(nil, true), "http://example.com/dav/")
end

-- ── 罐头 207 XML ─────────────────────────────────────────
-- 根目录：自身条目 + 1 子目录 + 2 文件（两种空 resourcetype 写法）
local XML_ROOT = [[<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/dav/</d:href>
    <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat>
  </d:response>
  <d:response>
    <d:href>/dav/subdir/</d:href>
    <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat>
  </d:response>
  <d:response>
    <d:href>/dav/b%20file.txt</d:href>
    <d:propstat><d:prop><d:resourcetype/><d:getcontentlength>123</d:getcontentlength><d:getlastmodified>Tue, 02 Jan 2024 03:04:05 GMT</d:getlastmodified></d:prop></d:propstat>
  </d:response>
  <d:response>
    <d:href>/dav/a.txt</d:href>
    <d:propstat><d:prop><d:resourcetype></d:resourcetype><d:getcontentlength>45</d:getcontentlength></d:prop></d:propstat>
  </d:response>
</d:multistatus>]]

-- 子目录 books：验证 path 前缀拼接
local XML_BOOKS = [[<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/dav/books/</d:href>
    <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat>
  </d:response>
  <d:response>
    <d:href>/dav/books/inner/</d:href>
    <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat>
  </d:response>
  <d:response>
    <d:href>/dav/books/x.txt</d:href>
    <d:propstat><d:prop><d:resourcetype/><d:getcontentlength>7</d:getcontentlength></d:prop></d:propstat>
  </d:response>
</d:multistatus>]]

-- ── listAsync：目录/文件判定、剔除自身、排序 ──────────────
do
    local dav = Webdav.new({ url = "http://example.com/dav/", username = "u", password = "p" })
    canned_res = { code = 207, body = XML_ROOT }
    canned_err = nil

    local entries, err
    dav:listAsync(nil, function(e, er)
        entries, err = e, er
    end)
    Assert.is_nil(err)
    Assert.len(entries, 3) -- 自身 /dav/ 条目被剔除

    -- 排序：目录在前，其后按 name 升序
    Assert.eq(entries[1].name, "subdir")
    Assert.is_true(entries[1].is_dir)
    Assert.eq(entries[1].path, "subdir")
    Assert.eq(entries[1].href, "/dav/subdir/")
    Assert.eq(entries[1].size, 0)
    Assert.is_nil(entries[1].mtime)

    Assert.eq(entries[2].name, "a.txt")
    Assert.is_false(entries[2].is_dir)
    Assert.eq(entries[2].path, "a.txt")
    Assert.eq(entries[2].size, 45)
    Assert.is_nil(entries[2].mtime)

    -- href 百分号解码
    Assert.eq(entries[3].name, "b file.txt")
    Assert.eq(entries[3].href, "/dav/b file.txt")
    Assert.eq(entries[3].size, 123)
    Assert.eq(entries[3].mtime, "Tue, 02 Jan 2024 03:04:05 GMT")

    -- 请求本身：PROPFIND + Depth:1 + Basic 凭据 + 目录尾斜杠 URL
    Assert.eq(captured[1].method, "PROPFIND")
    Assert.eq(captured[1].url, "http://example.com/dav/")
    Assert.eq(captured[1].headers["Depth"], "1")
    Assert.eq(captured[1].auth_username, "u")
    Assert.eq(captured[1].auth_password, "p")
    Assert.matches(captured[1].body, "propfind")
end

-- ── listAsync 子目录：child_path 带前缀 ───────────────────
do
    local dav = Webdav.new({ url = "http://example.com/dav/" })
    canned_res = { code = 207, body = XML_BOOKS }
    canned_err = nil

    local entries
    dav:listAsync("/books/", function(e)
        entries = e
    end)
    Assert.len(entries, 2)
    Assert.eq(entries[1].name, "inner")
    Assert.eq(entries[1].path, "books/inner")
    Assert.eq(entries[2].name, "x.txt")
    Assert.eq(entries[2].path, "books/x.txt")
    Assert.eq(captured[2].url, "http://example.com/dav/books/")
end

-- ── listAsync：空 body → 空表 ────────────────────────────
do
    local dav = Webdav.new({ url = "http://example.com/dav/" })
    canned_res = { code = 207, body = "" }
    canned_err = nil

    local entries, err
    dav:listAsync(nil, function(e, er)
        entries, err = e, er
    end)
    Assert.is_nil(err)
    Assert.len(entries, 0)
end

-- ── listAsync：网络错误透传 ──────────────────────────────
do
    local dav = Webdav.new({ url = "http://example.com/dav/" })
    canned_res = nil
    canned_err = "boom"

    local entries, err
    dav:listAsync(nil, function(e, er)
        entries, err = e, er
    end)
    Assert.is_nil(entries)
    Assert.eq(err, "boom")
    canned_err = nil
end

-- ── statusErr 文案（经 listAsync 驱动）────────────────────
do
    local dav = Webdav.new({ url = "http://example.com/dav/" })
    local function listErr(code)
        canned_res = { code = code }
        canned_err = nil
        local err
        dav:listAsync(nil, function(_, er)
            err = er
        end)
        return err
    end

    Assert.eq(listErr(401), "认证失败，请检查用户名或密码")
    Assert.eq(listErr(403), "认证失败，请检查用户名或密码")
    Assert.eq(listErr(500), "HTTP 500")
    Assert.eq(listErr("404"), "HTTP 404")
    -- 非数字状态码
    Assert.eq(listErr("nope"), "请求失败: nope")
end

-- ── 还原现场（不影响后续 spec 文件）────────────────────────
package.preload["http.request"] = nil
package.loaded["http.request"] = nil
package.loaded["http.webdav"] = nil
package.loaded["util"] = saved_util
table.pack = saved_pack
