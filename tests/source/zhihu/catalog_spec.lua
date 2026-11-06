--[[--
知乎长篇目录：有序分页、失败原子性、取消与章节权限。

@module tests.source.zhihu.catalog_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch

local Assert = require("support.assert")
local JSON = require("support.json_stub")
package.loaded["json"] = JSON
local Mapper = require("source.zhihu.mapper")
local function chapter(id, title, extra)
    local row = { id = id, title = title, section_cell = { type = "article" } }
    for key, value in pairs(extra or {}) do row[key] = value end
    return row
end
local first = {
    data = { chapter("2", "第一章", { is_free = true }), chapter("3", "第二章") },
    extra = { title = "长篇", tab_artwork = "https://img/cover.jpg" },
    paging = { offset = 0, limit = 2, has_next = true, is_end = false },
}
local last = {
    data = { chapter("4", "第三章", { right = { has_ownership = true } }) },
    paging = { offset = 2, limit = 2, has_next = false, is_end = true },
}
local pending, sync_first, cancelled = {}, false, false
package.loaded["http.request"] = {
    get = function(url, opts, cb)
        if sync_first and url:find("offset=0", 1, true) then
            cb(JSON.encode(first), nil, { code = 200 })
            return { cancel = function() error("取消不能指向已经完成的第一页") end }
        end
        pending[#pending + 1] = { url = url, opts = opts, cb = cb }
        return { cancel = function() cancelled = true end }
    end,
}
local Client = require("source.zhihu.client")
local result, err, calls = nil, nil, 0
local function done(value, reason) result, err, calls = value, reason, calls + 1 end
Client.catalogAsync("1", done)
Assert.matches(pending[1].url, "/remix/well/1/catalog%?")
Assert.matches(pending[1].url, "order_by=global_idx")
pending[1].cb(JSON.encode(first))
Assert.eq(calls, 0, "目录没拉完之前不暴露部分结果")
Assert.matches(pending[2].url, "offset=2$")
pending[2].cb(JSON.encode(last))
Assert.eq(calls, 1)
Assert.is_nil(err)
local toc = Mapper.chapters(result, "1")
Assert.len(toc, 3)
Assert.eq(toc[1].uid, "2")
Assert.eq(toc[3].uid, "4")
Assert.eq(toc[3].idx, 3)
Assert.is_false(toc[1].vip)
Assert.is_true(toc[2].vip)
Assert.is_false(toc[3].vip)
Assert.is_nil(Mapper.chapters({ data = { chapter("", "坏章节") } }, "1"))

Client.catalogAsync("1", done)
pending[#pending].cb(JSON.encode(first))
pending[#pending].cb(nil, "network failed")
Assert.is_nil(result)
Assert.eq(err, "network failed", "后一页失败不能返回前面的半本目录")
Client.catalogAsync("1", done)
local broken = { data = first.data, paging = { has_next = true, offset = 0, limit = 0 } }
pending[#pending].cb(JSON.encode(broken))
Assert.is_nil(result)
Assert.not_nil(err, "分页不前进时必须失败，不能无限请求")

sync_first = true
local handle = Client.catalogAsync("1", done)
local before = calls
handle.cancel()
Assert.is_true(cancelled, "同步完成第一页后，取消仍指向在途的下一页")
pending[#pending].cb(JSON.encode(last))
Assert.eq(calls, before)
