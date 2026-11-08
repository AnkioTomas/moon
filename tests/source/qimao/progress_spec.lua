--[[--
七猫的多阶段进度请求必须保留当前阶段的取消句柄。

@module tests.source.qimao.progress_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch

local Assert = require("support.assert")

local client = { token = function() return "token" end }
package.preload["source.qimao.client"] = function() return client end
package.preload["source.qimao.mapper"] = function()
    return {
        readChapter = function(row)
            return row and { uid = row.latest_read_chapter_id, title = row.latest_read_chapter_name }
        end,
        progressItem = function(row, chapter) return { row = row, chapter = chapter } end,
    }
end
package.preload["source.base"] = function()
    return { loadMeta = function() return { id = "qimao", name = "七猫", type = "chapter" } end }
end
package.preload["source.browse"] = function() return {} end
package.preload["source.shelf"] = function() return {} end
package.preload["source.toc"] = function() return { index = function() return 3 end } end
package.loaded["source.qimao"] = nil

local Source = require("source.qimao")
local identity = { stable_id = "book" }
local source = Source.new()
local toc_cancelled, shelf_cancelled = false, false
local shelf_job = { cancel = function() shelf_cancelled = true end }
local toc_job = { cancel = function() toc_cancelled = true end }
local toc_callback

client.shelfSyncAsync = function(cb)
    cb({ { book_id = "book", latest_read_chapter_id = "chapter", latest_read_chapter_name = "第3章" } })
    return shelf_job
end
source.loadTocAsync = function(_self, _identity, cb)
    toc_callback = cb
    return toc_job
end
local result_called = false
local get_job = source:getProgressAsync(identity, function() result_called = true end)
get_job.cancel()
Assert.is_true(toc_cancelled, "cancel targets the in-flight TOC request")
Assert.is_false(shelf_cancelled, "cancel does not retain the completed shelf request")
toc_callback({ { uid = "chapter", title = "第3章" } })
Assert.is_false(result_called, "a cancelled request ignores a late callback")

local push_cancelled = false
local push_job = { cancel = function() push_cancelled = true end }
toc_cancelled, shelf_cancelled = false, false
source.loadTocAsync = function(_self, _identity, cb)
    cb({ { uid = "chapter", title = "第3章" } })
    return toc_job
end
client.shelfPushAsync = function(_items, _cb) return push_job end
local put_job = source:putProgressAsync(identity, { chapter_idx = 1 }, function() end)
put_job.cancel()
Assert.is_true(push_cancelled, "cancel targets the in-flight progress upload")
Assert.is_false(toc_cancelled)
Assert.is_false(shelf_cancelled)
