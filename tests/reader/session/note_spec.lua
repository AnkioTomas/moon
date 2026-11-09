--[[-- reader.session.note：注解快照在事件时 JSON 编码后同步落库。 --]]

local Assert = require("support.assert")

local writes = {}
local encoded
local fail_encode = false
local derived_file

package.preload["json"] = function()
    return {
        encode = function(value)
            encoded = value
            if fail_encode then error("invalid annotation") end
            return "[snapshot]"
        end,
        decode = function() return { origin = "/books/origin.epub", file = derived_file } end,
    }
end
package.preload["book.note_db"] = function()
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
package.loaded["reader.session.note"] = nil

local SessionNote = require("reader.session.note")
local annotations = { { datetime = "2026-08-20", text = "高亮", page = 3 } }
local ui = {
    document = { file = "/books/note-spec.epub", getPageCount = function() return 100 end },
    annotation = { annotations = annotations },
    doc_settings = {
        flush = function() end,
        readSetting = function(_, key)
            return key == "annotations"
                and { { datetime = "2026-08-19", text = "旧快照", page = 2 } }
                or nil
        end,
    },
}
local identity = { source_id = "moon", stable_id = "b'1", chapter_idx = 2 }
SessionNote.save(ui, identity)
Assert.eq(encoded[1].text, "高亮", "必须编码 ReaderAnnotation 当前内存快照")
Assert.eq(encoded[1].total_pages, 100)
annotations[1].text = "已修改"
Assert.len(writes, 1)
Assert.eq(writes[1][1], "moon")
Assert.eq(writes[1][2], "b'1")
Assert.eq(writes[1][3], 2)
Assert.eq(writes[1][4], "[snapshot]")

fail_encode = true
SessionNote.save(ui, { source_id = "moon", stable_id = "b2" })
Assert.len(writes, 1, "编码失败不能写入不完整快照")
fail_encode = false

-- 换号后首次打开，sidecar 的旧账号同步标识不能带回待迁移快照。
do
    local db = require("book.note_db")
    local json = require("json")
    local derived = require("reader.session.derived_note")
    local previous_get, previous_decode, previous_collect = db.get, json.decode, derived.collect
    local source = setmetatable({ id = "moon" }, { __index = require("source.base") })
    source.resetAccountAnnotations = function(_self, items)
        for _idx, item in ipairs(items) do item.remote_id = nil end
        return items
    end
    local ref = { source_id = "moon", stable_id = "copy", source = source }
    local old = { datetime = "2026-08-20", page = "p1", pos0 = "p1", pos1 = "p2", text = "保留", remote_id = "old" }
    local current, applied = { old }, nil
    db.get = function() return { payload = "[copied]", account_pending = 1 } end
    json.decode = function() return {
        { datetime = old.datetime, page = old.page, pos0 = old.pos0, pos1 = old.pos1, text = old.text },
    } end
    require("book.store").identityFor = function() return ref end
    derived.collect = function() end
    Assert.eq(SessionNote.applyLocal({
        document = { file = "/books/copy.epub" },
        doc_settings = {
            readSetting = function(_self, key) if key == "annotations" then return current end end,
            saveSetting = function(_self, _key, value) applied = value end,
            flush = function() end,
        },
    }, ref), 1)
    Assert.is_nil(applied[1].remote_id)
    Assert.eq(applied[1].text, old.text)
    db.get, json.decode, derived.collect = previous_get, previous_decode, previous_collect
end

-- 衍生版（同目录 meta.json 指向自己）的坐标原书不认，不进 notes 表
local dir = os.tmpname()
os.remove(dir)
assert(os.execute("mkdir -p '" .. dir .. "'"))
local meta = assert(io.open(dir .. "/meta.json", "wb"))
meta:write("[meta]")
meta:close()
derived_file = dir .. "/book.epub"
ui.document.file = derived_file
local saved
SessionNote.save(ui, identity, nil, function(ok) saved = ok end)
Assert.is_true(saved)
Assert.len(writes, 1, "衍生版不写库")
os.remove(dir .. "/meta.json")
os.remove(dir)

for _, name in ipairs({ "json", "book.note_db", "logger", "book.store", "book.note", "reader.session.note" }) do
    package.preload[name] = nil
    package.loaded[name] = nil
end
