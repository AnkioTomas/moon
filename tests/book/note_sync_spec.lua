--[[-- book.note 从本地未同步快照上传，并在打开时拉取远端快照。 --]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")

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
        -- 返回副本：真身每次都从 sqlite 新建表。共享引用会让调用方手里的 row
        -- 跟着库里的行一起变，把「期间被改过」的判定悄悄变成永远相等。
        get = function(source_id, stable_id, chapter_idx)
            local row = rows[source_id .. ":" .. stable_id .. ":" .. (chapter_idx or 0)]
            if not row then return nil end
            local copy = {}
            for k, v in pairs(row) do copy[k] = v end
            return copy
        end,
        upsertRemote = function(source_id, stable_id, chapter_idx, payload, updated_at)
            local key = source_id .. ":" .. stable_id .. ":" .. (chapter_idx or 0)
            local old = rows[key]
            if not old or old.sync_status == 1 then
                rows[key] = { source_id = source_id, stable_id = stable_id,
                    chapter_idx = chapter_idx or 0, payload = payload,
                    updated_at = updated_at, sync_status = 1 }
            end
            return true
        end,
        unsynced = function()
            local out = {}
            for _, row in pairs(rows) do
                if row.sync_status == 0 then out[#out + 1] = row end
            end
            return out
        end,
        -- 与真身同语义：payload 与 sync_status 同一条语句写入，受 updated_at 乐观锁保护
        markSynced = function(source_id, stable_id, chapter_idx, updated_at, payload)
            local row = rows[source_id .. ":" .. stable_id .. ":" .. chapter_idx]
            if row and row.updated_at == updated_at then
                row.sync_status = 1
                if payload ~= nil then row.payload = payload end
            end
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
local pull_count = 0
source = {
    id = "moon",
    pushNotesAsync = function(_, pushed_identity, pushed_annotations, cb)
        sent[#sent + 1] = { identity = pushed_identity, annotations = pushed_annotations }
        cb({ code = 200 })
    end,
    pullNotesAsync = function(_, _identity, cb)
        pull_count = pull_count + 1
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
source.syncNotesAsync = function(self, opts, cb)
    return Note.syncAsync(self, opts, cb)
end

Note.save(ui, identity, function(ok)
    if ok then Note.syncAsync(source, { identity = identity }, function() end) end
end)
Stubs.flush()
Assert.eq(#sent, 1)
Assert.eq(sent[1].identity.source_id, "moon")
Assert.eq(sent[1].identity.stable_id, "小说.epub")
Assert.is_nil(sent[1].identity.chapter_idx)
Assert.eq(sent[1].annotations[1].total_pages, 100)
Assert.eq(sent[1].annotations[1].text, "高亮文字")
Assert.eq(sent[1].annotations[1].ignored, nil)

annotations = {}
Note.save(ui, identity, function(ok)
    if ok then Note.syncAsync(source, { identity = identity }, function() end) end
end)
Stubs.flush()
Assert.eq(#sent, 2)
Assert.eq(#sent[2].annotations, 0, "空快照必须上报以传播删除")

-- 网络恢复只重试本地脏快照，不顺手拉远端。
annotations = { { datetime = "2026-08-21", page = "/local-new" } }
Note.save(ui, identity, function(ok)
    if ok then Note.syncAsync(source, { identity = identity, dirty_only = true }, function() end) end
end)
Stubs.flush()
Assert.eq(#sent, 3)
Assert.eq(pull_count, 2)

Note.pull(ui, identity)
Stubs.flush()
Assert.eq(annotations[1].page, "/remote", "pull 必须在保存当前快照后应用远端快照")
Assert.eq(rows["moon:小说.epub:0"].sync_status, 1, "拉取结果必须先作为已同步快照写入 SQLite")

-- 只读源：本地脏快照不能上传，但仍应拉取远端。
pull_count = 0
local readonly = {
    id = "readonly",
    pullNotesAsync = function(_, _identity, cb)
        pull_count = pull_count + 1
        cb({ { datetime = "2026-08-22", page = "/remote-readonly", drawer = "lighten", text = "远端" } })
    end,
}
readonly.syncNotesAsync = function(self, opts, cb)
    return Note.syncAsync(self, opts, cb)
end
rows["readonly:book.epub:0"] = {
    source_id = "readonly",
    stable_id = "book.epub",
    chapter_idx = 0,
    payload = "[snapshot-dirty]",
    updated_at = 99,
    sync_status = 0,
}
local sync_err
Note.syncAsync(readonly, { identity = {
    source_id = "readonly", stable_id = "book.epub", source = readonly,
} }, function(result, err)
    sync_err = err
    Assert.eq(result.conflicts, 1)
    Assert.eq(result.pulled, 1)
end)
Stubs.flush()
Assert.is_nil(sync_err, "只读源拉取不应因无法上传而失败")
Assert.eq(pull_count, 1)

-- 未定位的远端划线不能进 doc_settings：
-- ReaderAnnotation:onReadSettings 按首条 page 的类型判定整份注解的格式，数字 page 会把
-- 本地划线一起搬去 annotations_paging 并加载空表；缺 pos0 则让 drawSavedHighlight 抛错。
do
    local unlocated = {
        id = "unlocated",
        pullNotesAsync = function(_, _identity, cb)
            cb({
                -- 定位失败：只有 wr_range，没有 page/pos0
                { datetime = "2026-08-23", drawer = "lighten", text = "远端未定位", wr_range = "0-5" },
                -- 已定位：page 是 xpointer
                {
                    datetime = "2026-08-23", drawer = "lighten", text = "远端已定位",
                    page = "/html/body/p[1]/text().0",
                    pos0 = "/html/body/p[1]/text().0",
                    pos1 = "/html/body/p[1]/text().5",
                    wr_range = "10-15", wr_bookmark_id = "bm-1",
                },
            })
        end,
    }
    unlocated.syncNotesAsync = function(self, opts, cb)
        return Note.syncAsync(self, opts, cb)
    end
    annotations = {}
    local ui2 = {
        document = { getPageCount = function() return 10 end },
        doc_settings = {
            flush = function() end,
            readSetting = function(_, key)
                if key == "annotations" then return annotations end
            end,
            saveSetting = function(_, key, value)
                if key == "annotations" then annotations = value end
            end,
        },
    }
    Note.pull(ui2, {
        source_id = "unlocated", stable_id = "book2.epub", source = unlocated,
    })
    Stubs.flush()
    Assert.eq(#annotations, 1, "只有定位成功的远端划线可进 doc_settings")
    Assert.eq(annotations[1].text, "远端已定位")
    Assert.eq(type(annotations[1].page), "string", "page 必须是 xpointer 字符串")
end

-- 远端一条注解都没报回来时，不能把已同步的本地快照覆盖成空：
-- 协议字段缺失与「云端确实为空」在 wire 上无法区分，宁可漏掉云端删除也不能清空划线。
do
    local empty = {
        id = "empty",
        pullNotesAsync = function(_, _identity, cb) cb({}) end,
    }
    rows["empty:book3.epub:0"] = {
        source_id = "empty",
        stable_id = "book3.epub",
        chapter_idx = 0,
        payload = "[snapshot-kept]",
        updated_at = 7,
        sync_status = 1,
    }
    local result_err
    Note.syncAsync(empty, { identity = {
        source_id = "empty", stable_id = "book3.epub", source = empty,
    } }, function(_, err) result_err = err end)
    Stubs.flush()
    Assert.is_nil(result_err)
    Assert.eq(rows["empty:book3.epub:0"].payload, "[snapshot-kept]",
        "远端空回包不能覆盖已同步的本地划线")
end

-- 上传窗口内用户又划了线：不能用上传时那份快照 + 旧修订号覆盖回去。
-- 曾经的写法是「先 upsert 旧 payload + 旧 updated_at，再 markSynced」，
-- 第一步把新划的线抹掉，第二步的乐观锁于是恰好匹配、脏标记也被清掉。
do
    local racing = { id = "racing" }
    -- payload 必须经 json stub 的 encode 生成，decode 才认得（否则 sync 在解码处就退出）
    local JSON = require("json")
    local uploaded_payload = JSON.encode({
        { datetime = "2026-08-24", page = "/body/p[1].0" },
    })
    local newer_payload = JSON.encode({
        { datetime = "2026-08-24", page = "/body/p[1].0" },
        { datetime = "2026-08-24", page = "/body/p[2].0" },
    })
    rows["racing:book4.epub:0"] = {
        source_id = "racing",
        stable_id = "book4.epub",
        chapter_idx = 0,
        payload = uploaded_payload,
        updated_at = 100,
        sync_status = 0,
    }
    racing.pushNotesAsync = function(_, _identity, _annotations, cb)
        -- 模拟上传耗时期间用户新划一条线：payload 与修订号都变了
        rows["racing:book4.epub:0"].payload = newer_payload
        rows["racing:book4.epub:0"].updated_at = 101
        rows["racing:book4.epub:0"].sync_status = 0
        cb({ code = 200 })
    end
    racing.pullNotesAsync = function(_, _identity, cb) cb({}) end

    local pushed_result
    Note.syncAsync(racing, { identity = {
        source_id = "racing", stable_id = "book4.epub", source = racing,
    }, dirty_only = true }, function(result) pushed_result = result end)
    Stubs.flush()

    local row = rows["racing:book4.epub:0"]
    Assert.eq(row.payload, newer_payload, "上传期间新划的线不能被旧快照覆盖")
    Assert.eq(row.updated_at, 101, "修订号不能被回退")
    Assert.eq(row.sync_status, 0, "本地仍有未上传内容，脏标记必须保留")
    Assert.eq(pushed_result.pushed, 1, "这次上传本身是成功的")
end

_G.G_reader_settings = previous_settings
