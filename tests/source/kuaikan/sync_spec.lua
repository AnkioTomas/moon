--[[--
快看上行：账号归属、收藏读回确认、进度字段及取消。

@module tests.source.kuaikan.sync_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch, inject-field

local Assert = require("support.assert")
local Stubs = require("support.stubs")
local JSON = require("support.json_stub")
package.loaded["json"] = JSON
local cfg = { cookie = "session=current; kk_s_t=old", user_id = "7" }
package.loaded["utils.settings"] = {
    getSource = function() return cfg end, get = function() return {} end, saveSource = function() end,
}
package.loaded["ui/network/manager"] = { isConnected = function() return true end }
package.loaded["source.auth"] = { ok = function() end }
local requests = {}
local function request(method, url, body, opts, cb)
    local r = { method = method, url = url, body = body, opts = opts, cb = cb }
    requests[#requests + 1] = r
    return { cancel = function() r.cancelled = true end }
end
package.loaded["http.request"] = {
    get = function(url, opts, cb) return request("GET", url, nil, opts, cb) end,
    post = function(url, body, opts, cb) return request("POST", url, body, opts, cb) end,
    request = function(opts, cb) return request(opts.method, opts.url, opts.body, opts, cb) end,
    header = function(res, key) return res and res.headers and res.headers[key] end,
    headerAll = function(res) return res and res.headers and res.headers.cookies or {} end,
}
local Client = require("source.kuaikan.client")
local Text = require("utils.text")
local account = { code = 200, data = { user_info = { authenticate = 1, user_id = 7 } } }
local function reply(data, err)
    local r = requests[#requests]
    local body = type(data) == "string" and data or JSON.encode(data)
    local res = { code = 200, body = body, headers = { cookies = { "kk_s_t=fresh; Path=/" } } }
    if r.method == "DELETE" then r.cb(res, err) else r.cb(body, err, res) end
end
local ok, reason
local function done(value, err) ok, reason = value, err end
local remote = Client.newSync(true)
remote:checkAsync(function(value, err)
    if not value then done(nil, err); return end
    remote:addToShelfAsync("835", done)
end)
reply(account)
Assert.is_nil(requests[#requests].opts.headers.Cookie)
reply("callback_1({})")
local write = requests[#requests]
Assert.eq(write.method, "POST")
Assert.matches(write.url, "/web/topic/835/fav%?answer=")
Assert.matches(write.opts.headers.Cookie, "session=current")
Assert.matches(write.opts.headers.Cookie, "kk_s_t=fresh")
Assert.is_nil(write.opts.headers.Cookie:find("kk_s_t=old", 1, true))
reply({ code = 200 })
reply({ code = 200, data = { total = 0, topics = {} } })
Assert.is_nil(ok)
Assert.eq(reason, "快看收藏变更尚未确认")
Assert.eq(remote.push_error, reason)

remote = Client.newSync(true)
remote:removeFromShelfAsync("835", done)
reply("callback_1({})")
Assert.eq(requests[#requests].method, "DELETE")
reply({ code = 200 })
reply({ code = 200, data = { total = 0, topics = {} } })
Assert.is_true(ok)

remote = Client.newSync(true)
remote:addToShelfAsync("835", done)
reply("callback_1({})")
local count = #requests
reply(nil, "network failed")
Assert.eq(reason, "network failed")
Assert.eq(#requests, count)

remote = Client.newSync(true)
remote:addToShelfAsync("835", done)
local late = requests[#requests]
remote:cancel()
Assert.is_true(late.cancelled)
count = #requests
late.cb("challenge", nil, { headers = { cookies = { "kk_s_t=late; Path=/" } } })
Assert.eq(#requests, count)

remote = Client.newSync(true)
remote:addToShelfAsync("835", done)
cfg = { cookie = "session=new", user_id = "8" }
reply("callback_1({})")
Assert.eq(reason, "登录状态已变化，请重试")
cfg = { cookie = "session=current" }
local module = require("source.kuaikan")
local readonly = module.new()
Assert.is_nil(readonly.putProgressAsync)
Assert.is_false(readonly:capabilities().shelf_push)
cfg.user_id = "7"
local source = module.new()
Assert.is_true(type(source.putProgressAsync) == "function")
Assert.is_true(source:capabilities().shelf_push)
local toc = { { idx = 1, uid = "10", title = "甲" }, { idx = 2, uid = "20", title = "乙" } }
source.loadTocAsync = function(_self, _identity, cb)
    cb(toc)
    return { cancel = function() error("已完成目录不得覆盖当前请求") end }
end
local identity = { source_id = "kuaikan", stable_id = "9" }
local handle = source:putProgressAsync(identity,
    { fraction = 0.6875, chapter_idx = 2, chapter_fraction = 0.375, page = 3, total_pages = 8 }, done)
reply(account)
write = requests[#requests]
Assert.eq(write.method, "POST")
Assert.matches(write.url, "/v2/pweb/read/history/report$")
local payload = JSON.decode(Text.urlDecode(write.body:match("view_rate=([^&]+)")))
Assert.eq(#payload, 1)
Assert.eq(payload[1].topic_id, 9)
Assert.eq(payload[1].comic_id, 20)
Assert.eq(payload[1].read_count, 3)
Assert.eq(payload[1].max_read_count, 3)
Assert.eq(payload[1].total_count, 8)
Assert.eq(payload[1].read_time % 1000, 0)
Assert.eq(payload[1].max_read_count_time, payload[1].read_time)
reply({ code = 200 })
reply({ code = 200, data = { total = 1, topics = { { topic_id = 9, comic_id = 10, read_count = 99 } } } })
Assert.is_nil(ok)
Assert.eq(reason, "快看进度变更尚未确认")

handle = source:putProgressAsync(identity, { fraction = 1, chapter_idx = 2, page = 8, total_pages = 8 }, done)
reply(account)
write = requests[#requests]
handle:cancel()
Assert.is_true(write.cancelled)

source:getProgressAsync(identity, done)
reply(account)
reply({ code = 200, data = { total = 1, topics = { { topic_id = 9, comic_id = 20, read_count = 99 } } } })
Assert.eq(ok.chapter_idx, 2)
Assert.eq(ok.fraction, 0.5)
Assert.is_nil(ok.chapter_fraction)
Assert.is_nil(ok.page)

source:getProgressAsync(identity, function(value, err, meta)
    ok, reason = value, err
    Assert.is_true(meta.empty)
end)
reply(account)
reply({ code = 200, data = { total = 0, topics = {} } })
Assert.is_nil(ok)
Assert.is_nil(reason)
Stubs.flush()

local deleted, removed, added = true, 0, false
package.loaded["book.books_db"] = {
    pendingDeleteIds = function() return deleted and { "30" } or {} end,
    pendingShelfAddIds = function() return not added and { "9" } or {} end,
    remove = function(_id, stable_id)
        Assert.eq(stable_id, "30")
        deleted, removed = false, removed + 1
        return true
    end,
    markSynced = function(_id, stable_id) Assert.eq(stable_id, "9"); added = true; return true end,
}
source:syncBooksAsync({ dirty_only = true }, done)
reply(account)
reply("challenge")
reply({ code = 200 })
reply({ code = 200, data = { total = 1, topics = { { id = 30, title = "旧书" } } } })
reply("challenge")
reply({ code = 200 })
reply({ code = 200, data = { total = 2, topics = { { id = 30, title = "旧书" }, { id = 9, title = "新书" } } } })
Assert.eq(ok.pushed, 1)
Assert.eq(ok.push_error, "快看收藏变更尚未确认")
Assert.is_true(deleted)
Assert.eq(removed, 0)
Assert.is_true(added)

source:syncBooksAsync({ dirty_only = true }, done)
reply(account)
reply("challenge")
reply({ code = 200 })
reply({ code = 200, data = { total = 0, topics = {} } })
Stubs.flush()
Assert.is_false(deleted)
Assert.eq(removed, 1)
Assert.eq(ok.pushed, 1)
Assert.is_nil(ok.push_error)

local row = { stable_id = "9", chapter_idx = 2, fraction = 0.75, page = 4, total_pages = 8,
    sync_status = 0, updated_at = 1 }
local confirmed = 0
package.loaded["book.progress_db"] = {
    get = function() return row end,
    unsynced = function() return { row } end,
    markSynced = function(_id, stable_id, revision)
        Assert.eq(stable_id, "9")
        Assert.eq(revision, 1)
        confirmed, row.sync_status = confirmed + 1, 1
        return true
    end,
}
source:syncProgressAsync({ dirty_only = true }, done)
Stubs.flush()
reply(account)
reply(nil, "network failed")
Assert.eq(row.sync_status, 0)
Assert.eq(confirmed, 0)
Assert.eq(ok.push_error, "network failed")

source:syncProgressAsync({ dirty_only = true }, done)
Stubs.flush()
reply(account)
reply({ code = 200 })
reply({ code = 200, data = { total = 1, topics = { { topic_id = 9, comic_id = 20 } } } })
Assert.eq(confirmed, 1)
Assert.eq(ok.pushed, 1)

Client.imagesAsync = function(uid, cb)
    Assert.eq(uid, "20")
    cb({ "https://images/1.jpg", "https://images/2.jpg" })
    return { cancel = function() error("已完成的页图不得覆盖当前请求") end }
end
handle = source:putProgressAsync(identity, { fraction = 1 }, done)
reply(account)
write = requests[#requests]
payload = JSON.decode(Text.urlDecode(write.body:match("view_rate=([^&]+)")))
Assert.eq(payload[1].comic_id, 20)
Assert.eq(payload[1].read_count, 2)
Assert.eq(payload[1].total_count, 2)
handle:cancel()
Assert.is_true(write.cancelled)

local loads = 0
source.loadTocAsync = function(_self, _identity, cb, force)
    loads = loads + 1
    cb(force and toc or { toc[1] })
    return { cancel = function() end }
end
source:getProgressAsync(identity, done)
reply(account)
reply({ code = 200, data = { total = 1, topics = { { topic_id = 9, comic_id = 20 } } } })
Assert.eq(loads, 2)
Assert.eq(ok.chapter_idx, 2)
