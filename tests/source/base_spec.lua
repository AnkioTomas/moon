---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

--[[-- source.base：业务事件默认空操作，不起任何同步；源没有插件生命周期钩子。 --]]

local Assert = require("support.assert")

package.preload["gettext"] = function()
    return function(text) return text end
end

local SourceBase = require("source.base")
local calls = 0
local source = setmetatable({
    id = "test",
    configured = function() return true end,
    syncBooksAsync = function() calls = calls + 1 end,
    syncStatsAsync = function() calls = calls + 1 end,
}, { __index = SourceBase })

for _idx, hook in ipairs({ "onCreate", "onSuspend", "onResume", "onNetworkConnected", "onExit" }) do
    Assert.is_nil(source[hook], hook)
end
for _idx, event in ipairs({ "page_changed", "chapter_changed", "book_meta_changed", "desktop_open" }) do
    Assert.is_nil(source:onEvent(event, { identity = { stable_id = "a" } }))
end
Assert.eq(calls, 0)

-- 删书三段式归基类：标删 → 已登录且联网顺手推脏；未登录没有远端可同步，书库就是唯一真相，当场撕墓碑。
do
    local Stubs = require("support.stubs")
    local rec = {}
    package.loaded["book.store"] = { markDeleted = function(source_id, stable_id)
        rec.marked = { source_id, stable_id }
        return rec.mark_ok ~= false
    end }
    package.loaded["book.books_db"] = { remove = function(source_id, stable_id)
        rec.removed = { source_id, stable_id }
        return rec.remove_ok ~= false
    end }
    package.loaded["ui/network/manager"] = { isConnected = function() return rec.online ~= false end }
    local configured, pushed = true, 0
    local src = setmetatable({
        id = "t",
        configured = function() return configured end,
        pushDirty = function() pushed = pushed + 1 end,
    }, { __index = SourceBase })
    local identity = { source_id = "t", stable_id = "b1" }
    local function run()
        local ok, err
        src:deleteBookAsync(identity, function(v, e) ok, err = v, e end)
        Stubs.flush()
        return ok, err
    end

    Assert.is_true(run(), "已登录联网：标删 + 入队推脏")
    Assert.eq(rec.marked[2], "b1")
    Assert.is_nil(rec.removed, "远端没确认不撕墓碑")
    Assert.eq(pushed, 1)

    rec, pushed = { online = false }, 0
    Assert.is_true(run(), "离线：只落墓碑")
    Assert.is_nil(rec.removed)
    Assert.eq(pushed, 0)

    rec, pushed, configured = {}, 0, false
    Assert.is_true(run(), "未登录：撕墓碑，不推脏")
    Assert.eq(rec.removed[2], "b1")
    Assert.eq(pushed, 0)

    rec = { remove_ok = false }
    Assert.is_true(run(), "撕不掉只是库里残留，书已从书架消失，不报失败")

    rec = { mark_ok = false }
    local ok, err = run()
    Assert.is_false(ok)
    Assert.eq(err, "删除本书失败")
    Assert.is_nil(rec.removed)
    package.loaded["book.store"], package.loaded["book.books_db"], package.loaded["ui/network/manager"] = nil, nil, nil
end

return true
