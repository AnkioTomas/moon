--[[--
desktop.pages.home.random.randomBook：先抽没读过的，再抽读到一半的，已读完的不抽；只取一行；库里不止一本时避开上一次。

@module tests.desktop.home.random_pick_spec
--]]

local Assert = require("support.assert")

local Kit = require("support.widget_stubs")
Kit.install("paper")
Kit.sections.source = {}
package.loaded["book.catalog"] = nil
local Catalog = require("book.catalog")
local settings = {}
package.preload["utils.settings"] = function() return { get = function() return settings end } end
local Random = require("desktop.pages.home.random")

local books = {
    { stable_id = "a", read_state = 1 },
    { stable_id = "b", read_state = 0 },
    { stable_id = "c", read_state = 0 },
    { stable_id = "d", read_state = 0, started = true },
}
local calls = {}
Catalog.listBooks = function(scope, opts)
    calls[#calls + 1] = opts
    Assert.eq(scope, "local")
    Assert.eq(opts.limit, 1, "只取一行")
    local hit = {}
    for _idx, b in ipairs(books) do
        local ok = b.read_state ~= 1 and (opts.read_status ~= "new" or not b.started)
        if ok then hit[#hit + 1] = b end
    end
    local row = hit[(opts.offset or 0) + 1]
    return { row }, #hit
end

for _i = 1, 20 do
    local book = Random.randomBook("local", "b")
    Assert.eq(book.stable_id, "c", "优先未读并避开上一次")
    Assert.eq(book.source_id, "local")
end

books[2].read_state, books[3].read_state = 1, 1
calls = {}
Assert.is_nil(Random.randomBook("local"), "默认范围不含阅读中")
settings.random_scope = "reading"
Assert.eq(Random.randomBook("local").stable_id, "d", "含阅读中时抽读到一半的")
Assert.eq(calls[#calls].read_status, "unread")
books[4].read_state = 1
Assert.is_nil(Random.randomBook("local"), "全读完了不抽已读")
books[4].read_state = 0
settings.random_scope = "new"

books = { { stable_id = "only", read_state = 0 } }
Assert.eq(Random.randomBook("local", "only").stable_id, "only", "只有一本时仍给这本")

books = {}
Assert.is_nil(Random.randomBook("local"))
Assert.is_nil(Random.randomBook(nil), "无效范围")
