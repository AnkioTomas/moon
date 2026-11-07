--[[--
快看书架：先校验账号再拉完整快照，失败与取消不写库。

@module tests.source.kuaikan.shelf_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch, inject-field

package.preload["json"] = function() return require("support.json_stub") end

local Assert = require("support.assert")
local Stubs = require("support.stubs")
local Client = require("source.kuaikan.client")
local Json = require("support.json_stub")
local connected = true
local cfg = { cookie = "session=current", user_id = "7" }
package.loaded["utils.settings"] = {
    getSource = function() return cfg end,
    get = function() return {} end,
    saveSource = function() end,
}
package.loaded["ui/network/manager"] = { isConnected = function() return connected end }
local pending, cancelled, writes, expired = nil, nil, 0, false
package.loaded["source.auth"] = {
    ok = function() end,
    expire = function() expired = true end,
}
package.loaded["source.shelf"] = { syncAsync = function(id, remote, _mapper, opts, cb)
    Assert.eq(id, "kuaikan")
    Assert.is_true(opts.force)
    Assert.is_true(remote.writing)
    return remote:shelfSyncAsync(function(books, err)
        if not books then cb(nil, err); return end
        writes = writes + 1
        cb({ pulled = #books, pushed = 0, hidden = 0, conflicts = 0, skipped = false })
    end)
end }
Client.loginRequestAsync = function(_url, cookie, cb)
    Assert.eq(cookie, "session=current")
    cb(Json.encode({ code = 200, data = { user_info = { authenticate = 1, user_id = 7 } } }))
    return { cancel = function() error("已结束的校验不应覆盖书架句柄") end }
end
Client.favAsync = function(cb, cookie)
    Assert.eq(cookie, "session=current")
    pending = cb
    return { cancel = function() cancelled = true end }
end
local source = require("source.kuaikan").new()
local result, reason
local function done(value, err) result, reason = value, err end
local handle = source:syncBooksAsync({ force = true }, done)
pending({ { stable_id = "1", title = "甲" } })
Assert.eq(result.pulled, 1)
Assert.eq(writes, 1)

result = nil
handle = source:syncBooksAsync({ force = true }, done)
handle.cancel()
Assert.is_true(cancelled)
pending({ { stable_id = "2", title = "乙" } })
Assert.is_nil(result)
Assert.eq(writes, 1)

source:syncBooksAsync({ force = true }, done)
cfg = { cookie = "session=new", user_id = "8" }
pending({ { stable_id = "2", title = "乙" } })
Assert.eq(reason, "登录状态已变化，请重试")
Assert.eq(writes, 1)

cfg = { cookie = "session=current", user_id = "7" }
source:syncBooksAsync({ force = true }, done)
pending(nil, "offline")
Assert.eq(reason, "offline")
Assert.eq(writes, 1)

Client.loginRequestAsync = function(_url, _cookie, cb)
    cb(Json.encode({ code = 200, data = { user_info = { authenticate = 0 } } }))
    return { cancel = function() end }
end
source:syncBooksAsync({ force = true }, done)
Assert.is_true(expired)
Assert.eq(reason, "快看登录已失效，请重新登录")
Assert.eq(writes, 1)

connected = false
source:syncBooksAsync({ force = true }, done)
Stubs.flush()
Assert.eq(reason, "网络不可用，请先连接 Wi-Fi")
cfg = {}
source:syncBooksAsync(nil, done)
Stubs.flush()
Assert.is_true(result.skipped)
Assert.eq(result.reason, "not_logged_in")
source:syncBooksAsync({ dirty_only = true }, done)
Stubs.flush()
Assert.is_true(result.skipped)

connected = true
cfg = { cookie = "session=current" }
Client.loginRequestAsync = function(_url, _cookie, cb)
    cb(Json.encode({ code = 200, data = { user_info = { authenticate = 1, user_id = 7 } } }))
    return { cancel = function() end }
end
local legacy = require("source.kuaikan").new()
legacy:syncBooksAsync({ force = true }, done)
pending({ { stable_id = "3", title = "丙" } })
Assert.eq(cfg.user_id, "7")
Assert.is_true(cfg.logged_in)
Assert.is_true(legacy:capabilities().shelf_push)
Assert.is_true(type(legacy.putProgressAsync) == "function")
