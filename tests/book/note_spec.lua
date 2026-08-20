--[[-- book.note：注解快照在事件时 JSON 编码后排队落库。 --]]

local Assert = require("support.assert")

local queued = {}
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
package.preload["utils.db.note"] = function()
    return {
        upsert = function(source_id, stable_id, chapter_idx, payload)
            writes[#writes + 1] = { source_id, stable_id, chapter_idx, payload }
            return true
        end,
    }
end
package.preload["utils.db.queue"] = function()
    return {
        run = function(worker, opts)
            queued[#queued + 1] = { worker = worker, opts = opts }
        end,
    }
end
package.preload["logger"] = function()
    return { warn = function() end }
end
package.loaded["book.note"] = nil

local Note = require("book.note")
local annotations = { { text = "高亮", page = 3 } }
Note.save({ source_id = "moon", stable_id = "b'1", chapter_idx = 2 }, annotations)
Assert.eq(encoded, annotations, "必须在事件当下编码，不能把可变表交给异步队列")
Assert.len(queued, 1)
annotations[1].text = "已修改"
queued[1].worker()
Assert.len(writes, 1)
Assert.eq(writes[1][1], "moon")
Assert.eq(writes[1][2], "b'1")
Assert.eq(writes[1][3], 2)
Assert.eq(writes[1][4], "[snapshot]")

fail_encode = true
Note.save({ source_id = "moon", stable_id = "b2" }, {})
Assert.len(queued, 1, "编码失败不能写入不完整快照")

for _, name in ipairs({ "json", "utils.db.note", "utils.db.queue", "logger", "book.note" }) do
    package.preload[name] = nil
    package.loaded[name] = nil
end
