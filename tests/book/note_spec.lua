--[[-- book.note：注解快照在事件时 JSON 编码后同步落库。 --]]

local Assert = require("support.assert")

local writes = {}
local encoded
local fail_encode = false

package.preload["json"] = function()
    return {
        encode = function(value)
            encoded = value
            if fail_encode then error("invalid annotation") end
            return "[snapshot]"
        end,
    }
end
package.preload["db.note"] = function()
    return {
        get = function() return nil end,
        upsert = function(source_id, stable_id, chapter_idx, payload)
            writes[#writes + 1] = { source_id, stable_id, chapter_idx, payload }
            return true
        end,
    }
end
package.preload["book.store"] = function()
    return {}
end
package.preload["logger"] = function()
    return { warn = function() end }
end
package.loaded["book.note"] = nil

local Note = require("book.note")
local annotations = { { datetime = "2026-08-20", text = "高亮", page = 3 } }
local ui = {
    document = { getPageCount = function() return 100 end },
    doc_settings = {
        flush = function() end,
        readSetting = function(_, key)
            return key == "annotations" and annotations or nil
        end,
    },
}
local identity = { source_id = "moon", stable_id = "b'1", chapter_idx = 2 }
Note.save(ui, identity)
Assert.eq(encoded[1].text, "高亮", "必须在事件当下编码")
Assert.eq(encoded[1].total_pages, 100)
annotations[1].text = "已修改"
Assert.len(writes, 1)
Assert.eq(writes[1][1], "moon")
Assert.eq(writes[1][2], "b'1")
Assert.eq(writes[1][3], 2)
Assert.eq(writes[1][4], "[snapshot]")

fail_encode = true
Note.save(ui, { source_id = "moon", stable_id = "b2" })
Assert.len(writes, 1, "编码失败不能写入不完整快照")

for _, name in ipairs({ "json", "db.note", "logger", "book.store", "book.note" }) do
    package.preload[name] = nil
    package.loaded[name] = nil
end
