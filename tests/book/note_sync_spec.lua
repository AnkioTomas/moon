--[[-- book.note 从本地未同步快照上传，并在打开时拉取远端快照。 --]]

local Assert = require("support.assert")

local previous_settings = _G.G_reader_settings
local source
_G.G_reader_settings = {
    readSetting = function()
        return "device-1"
    end,
    saveSetting = function() end,
}

local rows = {}
package.preload["utils.db.note"] = function()
    return {
        upsert = function(source_id, stable_id, chapter_idx, payload, updated_at, synced)
            rows[source_id .. ":" .. stable_id .. ":" .. (chapter_idx or 0)] = {
                source_id = source_id,
                stable_id = stable_id,
                chapter_idx = chapter_idx or 0,
                payload = payload,
                updated_at = updated_at,
                sync_status = synced and 1 or 0,
            }
            return true
        end,
        get = function(source_id, stable_id, chapter_idx)
            return rows[source_id .. ":" .. stable_id .. ":" .. (chapter_idx or 0)]
        end,
        unsynced = function()
            local out = {}
            for _, row in pairs(rows) do
                if row.sync_status == 0 then out[#out + 1] = row end
            end
            return out
        end,
        markSynced = function(source_id, stable_id, chapter_idx, updated_at)
            local row = rows[source_id .. ":" .. stable_id .. ":" .. chapter_idx]
            if row and row.updated_at == updated_at then row.sync_status = 1 end
            return true
        end,
    }
end
package.preload["source.registry"] = function()
    return { resolve = function() return source end }
end
package.preload["book.store"] = function()
    return { isCurrentDocument = function() return true end }
end
package.preload["json"] = function()
    local payloads = {}
    local revision = 0
    return {
        encode = function(value)
            revision = revision + 1
            local payload = "[snapshot-" .. revision .. "]"
            payloads[payload] = value
            return payload
        end,
        decode = function(payload) return payloads[payload] end,
    }
end
package.preload["utils.db.queue"] = function()
    return {
        run = function(worker, opts)
            local ok, err = pcall(worker)
            if ok then
                if opts.on_done then opts.on_done() end
            elseif opts.on_failed then
                opts.on_failed(err)
            end
        end,
    }
end
package.loaded["utils.db.note"] = nil
package.loaded["utils.db.queue"] = nil
package.loaded["json"] = nil
package.loaded["source.registry"] = nil
package.loaded["book.store"] = nil
package.loaded["book.note"] = nil

local sent = {}
source = {
    id = "moon",
    syncAnnotationsAsync = function(_, pushed_identity, pushed_annotations, cb)
        sent[#sent + 1] = { identity = pushed_identity, annotations = pushed_annotations }
        cb({ code = 200 })
    end,
    getAnnotationsAsync = function(_, _identity, cb)
        cb({ { datetime = "2026-08-20", page = "/remote" } })
    end,
}
local annotations = {
    {
        datetime = "2026-08-15 21:11:53",
        datetime_updated = "2026-08-15 21:35:51",
        drawer = "lighten",
        color = "cyan",
        text = "高亮文字",
        note = "笔记",
        chapter = "第一章",
        pageno = 12,
        page = "/body/p[1].0",
        pos0 = "/body/p[1].0",
        pos1 = "/body/p[1].4",
        ignored = "不能上报",
    },
}
local ui = {
    document = {
        getPageCount = function()
            return 100
        end,
    },
    doc_settings = {
        flush = function() end,
        readSetting = function(_, key)
            if key == "annotations" then
                return annotations
            end
        end,
        saveSetting = function(_, key, value)
            if key == "annotations" then annotations = value end
        end,
    },
}
local identity = {
    source_id = "moon",
    stable_id = "小说.epub",
    source = source,
}
local Note = require("book.note")

Note.save(ui, identity, function(ok) if ok then Note.push() end end)
Assert.eq(#sent, 1)
Assert.eq(sent[1].identity.source_id, "moon")
Assert.eq(sent[1].identity.stable_id, "小说.epub")
Assert.is_nil(sent[1].identity.chapter_idx)
Assert.eq(sent[1].annotations[1].total_pages, 100)
Assert.eq(sent[1].annotations[1].text, "高亮文字")
Assert.eq(sent[1].annotations[1].ignored, nil)

annotations = {}
Note.save(ui, identity, function(ok) if ok then Note.push() end end)
Assert.eq(#sent, 2)
Assert.eq(#sent[2].annotations, 0, "空快照必须上报以传播删除")

Note.pull(ui, identity)
Assert.eq(annotations[1].page, "/remote", "pull 必须在保存当前快照后应用远端快照")
Assert.eq(rows["moon:小说.epub:0"].sync_status, 1, "拉取结果必须先作为已同步快照写入 SQLite")

_G.G_reader_settings = previous_settings
