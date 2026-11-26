--[[--
月读同步：设备谱系、文件方向、阅读数据能不能盖本地。

@module tests.moon_sync.plan_spec
--]]

local Assert = require("support.assert")
local Plan = require("moon_sync.plan")
local Lock = require("moon_sync.lock")

Assert.is_true(Lock.trusted(nil, nil))
Assert.is_true(Lock.trusted(Lock.encode("book-b", 200), nil), "没见过就信")
Assert.is_true(Lock.trusted("book-b", Lock.encode("book-a", 100)), "没有时间的旧内容没有谱系")
Assert.eq(Lock.owner("  book-b \n"), "book-b")
Assert.is_true(Lock.trusted(Lock.encode("book-b", 200), Lock.encode("book-a", 100)), "更新的设备")
Assert.is_true(Lock.trusted(Lock.encode("book-a", 100), Lock.encode("book-a", 100)), "同时间同设备")
Assert.is_false(Lock.trusted(Lock.encode("book-b", 100), Lock.encode("book-a", 100)), "同时间另一台设备各写一份")
Assert.is_false(Lock.trusted(Lock.encode("book-b", 50), Lock.encode("book-a", 100)), "更旧的不信")

Assert.is_true(Plan.safeRel("settings/desktop.lua"))
Assert.is_true(Plan.safeRel("secrets/marketplace.json"))
Assert.is_true(Plan.safeRel("fonts/noto/NotoSans.ttf"))
Assert.is_false(Plan.safeRel("../settings/desktop.lua"))
Assert.is_false(Plan.safeRel("settings/../../etc/passwd"))
Assert.is_false(Plan.safeRel("/tmp/x"))
Assert.is_false(Plan.safeRel("reading/kindle.json"))

local upload, download = Plan.files({
    ["settings/a.lua"] = { hash = "1", mtime = 10 },
    ["settings/b.lua"] = { hash = "2", mtime = 5 },
    ["settings/c.lua"] = { hash = "same", mtime = 1 },
}, {
    ["settings/b.lua"] = { hash = "9", mtime = 8 },
    ["settings/c.lua"] = { hash = "same", mtime = 3 },
    ["settings/d.lua"] = { hash = "4", mtime = 1 },
})
Assert.eq(table.concat(upload, ","), "settings/a.lua", "只在本地、以及本地更新的才上传")
Assert.eq(table.concat(download, ","), "settings/b.lua,settings/d.lua")

local stale_upload, stale_download = Plan.files({
    ["settings/a.lua"] = { hash = "1", mtime = 10 },
    ["settings/b.lua"] = { hash = "old", mtime = 1 },
}, {
    ["settings/b.lua"] = { hash = "new", mtime = 9 },
    ["settings/d.lua"] = { hash = "4", mtime = 1 },
}, false)
Assert.eq(table.concat(stale_upload, ","), "settings/a.lua,settings/b.lua", "不信的清单不盖本地")
Assert.eq(table.concat(stale_download, ","), "")

Assert.is_false(Plan.shouldApply({ updated_at = 10, sync_status = 0 }, { updated_at = 20 }), "本地脏行不盖")
Assert.is_false(Plan.shouldApply({ updated_at = 10, sync_status = 1 }, { updated_at = 10 }))
Assert.is_true(Plan.shouldApply({ updated_at = 10, sync_status = 1 }, { updated_at = 11 }))
Assert.is_true(Plan.shouldApply(nil, { updated_at = 1 }))
Assert.is_false(Plan.shouldApply(nil, nil))
