--[[--
进度编排保护同步取消句柄与目录返回前的账号变更。

@module tests.source.xiaoxiang.progress_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch

local A = require("support.assert")
local cookie, delayed, toc_cb, write_cb, stopped, writes = "old", false, nil, nil, false, 0
local toc = { { uid = "77", title = "第一章" }, { uid = "78", title = "第二章" } }
package.loaded["source.xiaoxiang.client"] = {
    cookie = function() return cookie end,
    shelfAsync = function(cb)
        cb({ { bookid = "123", ccid = "78" } })
        return { cancel = function() end }
    end,
    progressAsync = function(_book, _chapter, cb)
        writes = writes + 1
        write_cb = cb
        return { cancel = function() stopped = true end }
    end,
}
package.loaded["source.toc"] = { index = function() return 2 end }
package.loaded["source.xiaoxiang"] = nil
local source = require("source.xiaoxiang").new()
function source:loadTocAsync(_identity, cb)
    toc_cb = cb
    if not delayed then cb(toc) end
    return { cancel = function() stopped = true end }
end
local identity = { source_id = "xiaoxiang", stable_id = "123" }
local result, err
source:getProgressAsync(identity, function(data) result = data end)
A.eq(result.chapter_idx, 2)
A.eq(result.fraction, 0.5)
delayed, stopped, result = true, false, nil
local handle = source:getProgressAsync(identity, function(data) result = data end)
handle.cancel()
A.is_true(stopped)
toc_cb(toc)
A.is_nil(result)
source:getProgressAsync(identity, function(data, reason) result, err = data, reason end)
cookie = "new"
toc_cb(toc)
A.is_nil(result)
A.eq(err, "账号已变化，请重新登录")
cookie, delayed, stopped = "old", false, false
handle = source:putProgressAsync(identity, { chapter_idx = 2 }, function(data) result = data end)
handle.cancel()
A.is_true(stopped)
write_cb({})
A.is_nil(result)
delayed = true
source:putProgressAsync(identity, { chapter_idx = 2 }, function(data, reason) result, err = data, reason end)
cookie = "new"
toc_cb(toc)
A.eq(writes, 1, "不能把旧书进度推到新账号")
A.eq(err, "账号已变化，请重新登录")
