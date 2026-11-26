--[[-- book.note.mutate：改备注 / 删条目，同步到正打开的同一章，联网时推脏行。 --]]

local Assert = require("support.assert")
local JSON = require("support.json_stub")
package.preload["json"] = function() return JSON end
package.loaded["json"] = nil

local row
local saved
package.preload["book.note_db"] = function()
    return {
        get = function() return row end,
        upsert = function(_source_id, _stable_id, _chapter_idx, payload)
            saved = payload
            return true
        end,
    }
end
local pushes = 0
local source = {
    pushNotesAsync = function() end,
    pushDirty = function() pushes = pushes + 1 end,
}
package.preload["source.registry"] = function()
    return { resolve = function() return source end }
end
local connected = true
package.preload["ui/network/manager"] = function()
    return { isConnected = function() return connected end }
end
local session
package.preload["reader.session"] = function()
    return { current = function() return session end }
end
local flushed, refreshed = 0, 0
local live = {}
local ui = {
    annotation = {
        annotations = live,
        updateAnnotations = function() refreshed = refreshed + 1 end,
    },
    doc_settings = {
        saveSetting = function(_self, key, value) Assert.eq(key, "annotations"); Assert.eq(value, live) end,
        flush = function() flushed = flushed + 1 end,
    },
}
package.preload["apps/reader/readerui"] = function() return { instance = ui } end
package.loaded["book.note"] = nil
local Note = require("book.note")

local function item(id, note)
    return { datetime = "2026-01-0" .. id, page = id, text = "句" .. id, drawer = "lighten", note = note,
        pos0 = "a" .. id, pos1 = "b" .. id }
end
row = { payload = JSON.encode({ item(1, "旧"), item(2) }) }
live[1], live[2] = item(1, "旧"), item(2)
session = { identity = { source_id = "moon", stable_id = "b", chapter_idx = 0 } }

-- 改备注：库与打开中的文档一起改，联网推脏行
Assert.is_true(Note.mutate({ key = Note.itemKey("moon", "b", 0, item(1)), note = " 新 " }))
local stored = JSON.decode(saved)
Assert.eq(stored[1].note, "新")
Assert.eq(live[1].note, "新")
Assert.eq(flushed, 1)
Assert.eq(refreshed, 1)
Assert.eq(pushes, 1)

-- 删条目；离线不推；打开的是别的书不碰文档
row = { payload = saved }
connected = false
session = { identity = { source_id = "moon", stable_id = "other", chapter_idx = 0 } }
Assert.is_true(Note.mutate({ key = Note.itemKey("moon", "b", 0, item(2)), remove = true }))
Assert.len(JSON.decode(saved), 1)
Assert.len(live, 2)
Assert.eq(flushed, 1)
Assert.eq(pushes, 1)

-- 同一本书：从打开中的文档摘掉
row = { payload = JSON.encode({ item(1), item(2) }) }
session = { identity = { source_id = "moon", stable_id = "b", chapter_idx = 0 } }
Assert.is_true(Note.mutate({ key = Note.itemKey("moon", "b", 0, item(2)), remove = true }))
Assert.len(live, 1)
Assert.eq(live[1].text, "句1")

-- 没有在读：只改库
session = nil
row = { payload = JSON.encode({ item(1) }) }
Assert.is_true(Note.mutate({ key = Note.itemKey("moon", "b", 0, item(1)), note = "x" }))
Assert.eq(flushed, 2)

Assert.is_false((Note.mutate({ key = "bad" })))

for _idx, name in ipairs({ "json", "book.note_db", "source.registry", "ui/network/manager", "reader.session",
    "apps/reader/readerui", "book.note" }) do
    package.preload[name] = nil
    package.loaded[name] = nil
end

return true
