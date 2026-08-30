--[[-- book.note：KOReader 本地 Lua 注解按已登记路径导入并按身份去重。 --]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")

local rows = {}
local writes = {}
local opened = {}
local snapshots = {
    ["/books/whole.epub"] = {
        annotations = { { datetime = "2026-08-20", page = "/body/p[1]", text = "整本" } },
        doc_pages = 120,
    },
    ["/books/chapter-1.html"] = {
        annotations = { { datetime = "2026-08-21", pageref = "/body/p[2]", text = "章节" } },
        doc_pages = 20,
    },
    ["/books/invalid.epub"] = {
        annotations = { { datetime = "2026-08-22", text = "没有页码" } },
        doc_pages = 1,
    },
}

package.preload["json"] = function()
    return {
        encode = function(items)
            local item = items[1]
            return string.format("[%s:%s:%s]", item.text, item.page, item.total_pages)
        end,
    }
end
package.preload["db.book"] = function()
    return {
        pathsAll = function()
            return {
                { path = "/books/whole.epub", source_id = "moon", stable_id = "book-1" },
                { path = "/books/invalid.epub", source_id = "local", stable_id = "/books/invalid.epub" },
                { path = "/books/whole.epub", source_id = "moon", stable_id = "wrong-duplicate" },
            }
        end,
    }
end
package.preload["db.chapter"] = function()
    return {
        all = function()
            return {
                { path = "/books/chapter-1.html", source_id = "moon", stable_id = "book-1", chapter_idx = 1 },
            }
        end,
    }
end
package.preload["docsettings"] = function()
    return {
        open = function(_, path)
            opened[#opened + 1] = path
            local snapshot = snapshots[path]
            return {
                readSetting = function(_, key)
                    return snapshot and snapshot[key]
                end,
            }
        end,
    }
end
package.preload["db.note"] = function()
    local NoteDB = {}
    local function key(source_id, stable_id, chapter_idx)
        return source_id .. ":" .. stable_id .. ":" .. tostring(chapter_idx or 0)
    end
    function NoteDB.get(source_id, stable_id, chapter_idx)
        return rows[key(source_id, stable_id, chapter_idx)]
    end
    function NoteDB.upsert(source_id, stable_id, chapter_idx, payload)
        local row = {
            source_id = source_id,
            stable_id = stable_id,
            chapter_idx = chapter_idx or 0,
            payload = payload,
        }
        rows[key(source_id, stable_id, chapter_idx)] = row
        writes[#writes + 1] = row
        return true
    end
    return NoteDB
end
package.preload["book.store"] = function()
    return {}
end
package.preload["logger"] = function()
    return { warn = function() end }
end

package.loaded["book.note"] = nil
package.loaded["db.note"] = nil
package.loaded["json"] = nil
local Note = require("book.note")

local first
Note.importLocalAsync(function(result) first = result end)
Assert.is_nil(first, "导入必须逐项异步调度")
Stubs.flush()
Assert.eq(first.imported, 2)
Assert.eq(first.skipped, 1, "无效注解不能写入空快照")
Assert.eq(first.failed, 0)
Assert.len(writes, 2)
Assert.eq(writes[1].stable_id, "book-1")
Assert.eq(writes[1].chapter_idx, 0)
Assert.eq(writes[1].payload, "[整本:/body/p[1]:120]")
Assert.eq(writes[2].stable_id, "book-1")
Assert.eq(writes[2].chapter_idx, 1)
Assert.eq(writes[2].payload, "[章节:/body/p[2]:20]")
Assert.len(opened, 3, "同一路径只能读取一次")

local second
Note.importLocalAsync(function(result) second = result end)
Stubs.flush()
Assert.eq(second.imported, 0)
Assert.eq(second.skipped, 3, "已有身份必须跳过，不覆盖或再次排队上传")
Assert.eq(second.failed, 0)
Assert.len(writes, 2)
