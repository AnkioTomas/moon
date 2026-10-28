--[[-- source.local.gdrive：按路径建文件夹、列目录、上传分两段。 --]]

local Assert = require("support.assert")
local JSON = require("support.json_stub")
package.preload["json"] = function() return JSON end
package.loaded["json"] = nil

if not table.pack then
    table.pack = function(...)
        return { n = select("#", ...), ... }
    end
end

local captured = {}
local script = {}
package.preload["http.request"] = function()
    return {
        ok = function(code)
            local n = tonumber(code)
            return n ~= nil and n >= 200 and n < 300
        end,
        header = function(res, name)
            local headers = res and res.headers
            if not headers then return nil end
            return headers[name] or headers[name:lower()]
        end,
        request = function(opts, cb)
            captured[#captured + 1] = opts
            local res = table.remove(script, 1)
            cb(res, res and res.err)
            return { cancel = function() end }
        end,
        download = function(opts, dest, cb)
            captured[#captured + 1] = opts
            local res = table.remove(script, 1)
            local file = io.open(dest, "wb")
            if file then
                file:write("book")
                file:close()
            end
            local ok = res and res.code and res.code >= 200 and res.code < 300
            cb(ok, res and res.err, res)
            return { cancel = function() end }
        end,
    }
end
package.loaded["http.request"] = nil
package.loaded["source.local.gdrive"] = nil

local Drive = require("source.local.gdrive")
local CFG = { gdrive_token = "refresh", gdrive_client = "id:secret" }

local CLIENT_ID = "934338025336-tfahubvrlj60l0r483ho80j4det35o30.apps.googleusercontent.com"

-- 授权地址带完整 drive 范围和离线刷新。空码不发请求。整段地址能取出 code。
do
    local url = Drive.authorizeUrl()
    Assert.is_true(url:find("client_id=" .. CLIENT_ID, 1, true) ~= nil)
    Assert.is_true(url:find("access_type=offline", 1, true) ~= nil)
    Assert.is_true(url:find("prompt=consent", 1, true) ~= nil)
    Assert.is_true(url:find("auth%2Fdrive", 1, true) ~= nil or url:find("auth/drive", 1, true) ~= nil)
    Assert.is_true(url:find("127.0.0.1", 1, true) ~= nil)
    Assert.eq(Drive.clientApp(), CLIENT_ID .. ":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")

    local refresh, err
    Drive.exchangeCode("", function(token, e) refresh, err = token, e end)
    Assert.is_nil(refresh)
    Assert.eq(err, "请填写授权码")
    Assert.eq(#captured, 0)

    script = { { code = 200, body = [[{"refresh_token":"user-refresh","access_token":"a"}]] } }
    Drive.exchangeCode("http://127.0.0.1/?code=4%2F0Acode&scope=drive", function(token, e)
        refresh, err = token, e
    end)
    Assert.eq(refresh, "user-refresh")
    Assert.eq(err, nil)
    Assert.is_true(captured[1].body:find("grant_type=authorization_code", 1, true) ~= nil)
    Assert.is_true(captured[1].body:find("code=4%2F0Acode", 1, true) ~= nil)
    Assert.is_true(captured[1].body:find("redirect_uri=", 1, true) ~= nil)
    Assert.is_true(captured[1].url:find("oauth2.googleapis.com/token", 1, true) ~= nil)

    script = { { code = 200, body = [[{"access_token":"a"}]] } }
    Drive.exchangeCode("plain", function(token, e) refresh, err = token, e end)
    Assert.is_nil(refresh)
    Assert.eq(err, "Google Drive 没有返回刷新令牌")
end

local function reset(responses)
    captured = {}
    script = responses
end

local TOKEN = { code = 200, body = [[{"access_token":"access","expires_in":3600}]] }

-- 缺的 Apps/Books 会逐级创建。
do
    reset({
        TOKEN,
        { code = 200, body = [[{"files":[]}]] },
        { code = 200, body = [[{"id":"id-apps"}]] },
        { code = 200, body = [[{"files":[]}]] },
        { code = 200, body = [[{"id":"id-books"}]] },
    })
    local drive = Drive.new(CFG)
    local ok, err
    drive:ensurePathAsync("Apps/Books", function(v, e) ok, err = v, e end)
    Assert.is_true(ok, err)
    Assert.is_true(captured[2].url:find("Apps", 1, true) ~= nil)
    Assert.is_true(captured[3].body:find("id-apps", 1, true) == nil)
    Assert.is_true(captured[3].body:find("Apps", 1, true) ~= nil)
    Assert.is_true(captured[5].body:find("id-apps", 1, true) ~= nil)
end

-- 列一层：文件夹在前，mtime 有值。第二次用缓存的文件夹 id，不再查路径。
do
    reset({
        TOKEN,
        { code = 200, body = [[{"files":[{"id":"id-apps","name":"Apps","mimeType":"application/vnd.google-apps.folder"}]}]] },
        { code = 200, body = [[{"files":[{"id":"id-books","name":"Books","mimeType":"application/vnd.google-apps.folder"}]}]] },
        { code = 200, body = [[{"files":[
            {"id":"f1","name":"b.epub","mimeType":"application/epub+zip","size":"4","modifiedTime":"2020-01-02T03:04:05.000Z"},
            {"id":"d1","name":"z","mimeType":"application/vnd.google-apps.folder"}
        ]}]] },
        { code = 200, body = [[{"files":[]}]] },
    })
    local drive = Drive.new(CFG)
    local entries, err
    drive:listAsync("Apps/Books", function(got, e) entries, err = got, e end)
    Assert.is_nil(err)
    Assert.eq(entries[1].name, "z")
    Assert.is_true(entries[1].is_dir)
    Assert.eq(entries[2].path, "Apps/Books/b.epub")
    Assert.is_true(entries[2].mtime ~= nil)
    local before = #captured
    drive:listAsync("Apps/Books", function(got, e) entries, err = got, e end)
    Assert.is_nil(err)
    Assert.eq(#captured, before + 1)
end

-- 上传：先开断点会话，再 PUT 文件。没有的文件不走更新。
do
    reset({
        { code = 200, body = [[{"files":[]}]] },
        { code = 200, headers = { Location = "https://upload.example/session" }, body = "" },
        { code = 200, body = "{}" },
    })
    local drive = Drive.new(CFG)
    drive.access = "access"
    drive.access_until = os.time() + 3600
    drive.ids.Apps = "id-apps"
    drive.ids["Apps/Books"] = "id-books"
    local path = os.tmpname()
    local file = assert(io.open(path, "wb"))
    file:write("hi")
    file:close()
    local ok, err
    drive:putFileAsync("Apps/Books/a.epub", path, function(v, e) ok, err = v, e end)
    os.remove(path)
    Assert.is_true(ok, err)
    Assert.is_true(captured[2].url:find("uploadType=resumable", 1, true) ~= nil)
    Assert.eq(captured[3].url, "https://upload.example/session")
    Assert.eq(captured[3].method, "PUT")
end

-- 令牌缓存命中时 tokenAsync 同步回调，call 返回的句柄必须指向真正在飞的请求：取消要能停掉它。
do
    local cancelled = false
    local drive = Drive.new(CFG)
    drive.access = "access"
    drive.access_until = os.time() + 3600
    local finished = false
    local handle = drive:call(function(_token, _done)
        return { cancel = function() cancelled = true end }
    end, function() finished = true end)
    handle:cancel()
    Assert.is_true(cancelled, "取消没有传到在飞请求")
    Assert.is_true(not finished)
end

-- 没有这本书：下载回 404。
do
    reset({
        { code = 200, body = [[{"files":[]}]] },
    })
    local drive = Drive.new(CFG)
    drive.access = "access"
    drive.access_until = os.time() + 3600
    local ok, err, code
    drive:getAsync("Apps/Books/no.epub", os.tmpname(), nil, function(v, e, c) ok, err, code = v, e, c end)
    Assert.is_nil(ok)
    Assert.eq(code, 404, err)
end

return true
