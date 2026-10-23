---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

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
package.preload["book.note_db"] = function()
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
        all = function(source_id)
            local out = {}
            for _, row in pairs(rows) do
                if not source_id or row.source_id == source_id then out[#out + 1] = row end
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
        -- 与真身同语义：只写 payload，sync_status / updated_at 不动
        updatePayload = function(source_id, stable_id, chapter_idx, payload)
            local row = rows[source_id .. ":" .. stable_id .. ":" .. (chapter_idx or 0)]
            if row then row.payload = payload end
            return true
        end,
    }
end
package.preload["source.registry"] = function()
    return { resolve = function() return source end }
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
package.loaded["book.note_db"] = nil
package.loaded["json"] = nil
package.loaded["source.registry"] = nil
package.loaded["book.note"] = nil
package.loaded["reader.session.note"] = nil
local open_files = {
    ["/a.epub"] = { source_id = "moon", stable_id = "小说.epub" },
    ["/b2.epub"] = { source_id = "unlocated", stable_id = "book2.epub" },
    ["/b3.epub"] = { source_id = "authoritative", stable_id = "book.epub", chapter_idx = 2 },
    ["/b4.epub"] = { source_id = "dropped", stable_id = "book8.epub" },
    ["/b6.epub"] = { source_id = "dedupe", stable_id = "book9.epub" },
}
package.preload["book.store"] = function()
    return { identityFor = function(file) return open_files[file] end }
end
package.loaded["book.store"] = nil

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
        file = "/a.epub",
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
local SessionNote = require("reader.session.note")
source.syncNotesAsync = function(self, opts, cb)
    return Note.syncAsync(self, opts, cb)
end

SessionNote.save(ui, identity, nil, function(ok)
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
SessionNote.save(ui, identity, nil, function(ok)
    if ok then Note.syncAsync(source, { identity = identity }, function() end) end
end)
Stubs.flush()
Assert.eq(#sent, 2)
Assert.eq(#sent[2].annotations, 0, "空快照必须上报以传播删除")

-- 网络恢复只重试本地脏快照，不顺手拉远端。
annotations = { { datetime = "2026-08-21", page = "/local-new" } }
SessionNote.save(ui, identity, nil, function(ok)
    if ok then Note.syncAsync(source, { identity = identity, dirty_only = true }, function() end) end
end)
Stubs.flush()
Assert.eq(#sent, 3)
Assert.eq(pull_count, 2)

SessionNote.pull(ui, identity)
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

-- 重复开书拉到同一份远端快照：payload 与库里那行逐字节相同就不写，
-- 修订号（updated_at）不抖 —— 否则每次开书都像「有新内容」。
-- 本 spec 的 JSON 桩每次 encode 都返回新的 `[snapshot-N]`，payload 永远不相等，
-- 这条断言无从谈起；这一段临时换成「按内容稳定编码」的 JSON（decode 同步换），结束后恢复。
-- 另外用独立的小书（pageCount=0）验：pageCount 非 0 时保存侧会给快照补 total_pages，
-- 与 pull 落的桶本就不等，那是保存侧的差异，不该混进来干扰本条断言。
do
    local JSON = require("json")
    local real_encode, real_decode = JSON.encode, JSON.decode
    local encoded = {}
    local function stable(value)
        if type(value) ~= "table" then return tostring(value) end
        local keys = {}
        for key in pairs(value) do keys[#keys + 1] = key end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        local parts = {}
        for _idx, key in ipairs(keys) do
            parts[#parts + 1] = tostring(key) .. "=" .. stable(value[key])
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    JSON.encode = function(value)
        local payload = stable(value)
        encoded[payload] = value
        return payload
    end
    JSON.decode = function(payload) return encoded[payload] end

    -- 让 applyLocal 认得这本书，否则远端快照落不进 doc_settings，下一轮保存又把它当成本地改动。
    open_files["/idem.epub"] = { source_id = "idem", stable_id = "idem.epub" }
    local idem_annotations = {}
    local idem_ui = {
        document = { file = "/idem.epub", getPageCount = function() return 0 end },
        doc_settings = {
            flush = function() end,
            readSetting = function(_, key)
                if key == "annotations" then return idem_annotations end
            end,
            saveSetting = function(_, key, value)
                if key == "annotations" then idem_annotations = value end
            end,
        },
    }
    local idem_source = {
        id = "idem",
        pushNotesAsync = function(_, _, _, cb) cb({ code = 200 }) end,
        pullNotesAsync = function(_, _, cb) cb({ { datetime = "2026-09-01", page = "/idem" } }) end,
    }
    idem_source.syncNotesAsync = function(self, opts, cb) return Note.syncAsync(self, opts, cb) end
    local idem_identity = { source_id = "idem", stable_id = "idem.epub", source = idem_source }

    SessionNote.pull(idem_ui, idem_identity)
    Stubs.flush()
    local key = "idem:idem.epub:0"
    Assert.not_nil(rows[key], "首次拉取要落库")
    local revision = rows[key].updated_at
    SessionNote.pull(idem_ui, idem_identity)
    Stubs.flush()
    Assert.eq(rows[key].updated_at, revision, "同一份快照重复拉取不刷新修订号")
    SessionNote.pull(idem_ui, idem_identity)
    Stubs.flush()
    Assert.eq(rows[key].updated_at, revision, "再开一次也不抖")
    JSON.encode, JSON.decode = real_encode, real_decode
end

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
        document = { file = "/b2.epub", getPageCount = function() return 10 end },
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
    SessionNote.pull(ui2, {
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

-- 完整远端快照为空时必须覆盖旧分片，并携带 authoritative 标记供 applyLocal 删除旧项。
do
    local merge_authoritative
    local authoritative = {
        id = "authoritative",
        pullNotesAsync = function(_, _identity, cb)
            cb({}, nil, { authoritative = true })
        end,
        mergeAnnotations = function(_, remote, _current, _paging, is_authoritative)
            merge_authoritative = is_authoritative
            return remote
        end,
    }
    local JSON = require("json")
    rows["authoritative:book.epub:2"] = {
        source_id = "authoritative",
        stable_id = "book.epub",
        chapter_idx = 2,
        payload = JSON.encode({
            {
                datetime = "old", page = "/body/a", pos0 = "/body/a", pos1 = "/body/b",
                drawer = "lighten", wr_bookmark_id = "bm-old",
            },
        }),
        updated_at = 7,
        sync_status = 1,
    }
    Note.syncAsync(authoritative, { identity = {
        source_id = "authoritative", stable_id = "book.epub", chapter_idx = 2,
        source = authoritative,
    } }, function() end)
    Stubs.flush()
    local snapshot = JSON.decode(rows["authoritative:book.epub:2"].payload)
    Assert.is_true(snapshot.authoritative)
    Assert.eq(#snapshot.items, 0)

    annotations = {
        {
            datetime = "old", page = "/body/a", pos0 = "/body/a", pos1 = "/body/b",
            drawer = "lighten", wr_bookmark_id = "bm-old",
        },
    }
    local ui3 = {
        document = { file = "/b3.epub" },
        doc_settings = {
            readSetting = function(_, key)
                if key == "annotations" then return annotations end
            end,
            saveSetting = function(_, key, value)
                if key == "annotations" then annotations = value end
            end,
            flush = function() end,
        },
    }
    SessionNote.applyLocal(ui3, {
        source_id = "authoritative", stable_id = "book.epub", chapter_idx = 2,
        source = authoritative,
    })
    Assert.eq(#annotations, 0, "权威远端删除不能被本地防丢保护挡住")
    Assert.is_true(merge_authoritative)

    -- 回调回来时阅读器已换了章：不得把别章快照写进当前文档
    Assert.eq(SessionNote.applyLocal(ui3, {
        source_id = "authoritative", stable_id = "book.epub", chapter_idx = 3,
        source = authoritative,
    }), 0)
    Assert.eq(SessionNote.applyLocal({ doc_settings = ui3.doc_settings }, {
        source_id = "authoritative", stable_id = "book.epub", chapter_idx = 2,
        source = authoritative,
    }), 0, "没有打开文档时不应用")
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

-- 同一源并发触发两次同步时必须串行；第二次应看到第一轮已确认的干净快照。
do
    local JSON = require("json")
    local callbacks = {}
    local serial = {
        id = "serial",
        pushNotesAsync = function(_, _identity, _annotations, cb)
            callbacks[#callbacks + 1] = cb
            return { cancel = function() end }
        end,
    }
    rows["serial:book.epub:0"] = {
        source_id = "serial", stable_id = "book.epub", chapter_idx = 0,
        payload = JSON.encode({ { datetime = "2026-09-04", page = "/local" } }),
        updated_at = 200, sync_status = 0,
    }
    local completed = 0
    local opts = {
        identity = { source_id = "serial", stable_id = "book.epub", source = serial },
        dirty_only = true,
    }
    Note.syncAsync(serial, opts, function() completed = completed + 1 end)
    Note.syncAsync(serial, opts, function() completed = completed + 1 end)
    Stubs.flush()
    Assert.eq(#callbacks, 1, "第二轮不能与第一轮并发上传")
    callbacks[1]({ code = 200 })
    Stubs.flush()
    Assert.eq(#callbacks, 1, "第一轮确认后第二轮不应重复上传干净快照")
    Assert.eq(completed, 2)

    -- 已结束任务的句柄迟到 cancel，不能放行同源的下一轮并发。
    rows["serial:book.epub:0"].sync_status = 0
    rows["serial:book.epub:0"].updated_at = 300
    local done_handle = Note.syncAsync(serial, opts, function() end)
    Stubs.flush()
    callbacks[2]({ code = 200 })
    Stubs.flush()
    rows["serial:book.epub:0"].sync_status = 0
    rows["serial:book.epub:0"].updated_at = 400
    Note.syncAsync(serial, opts, function() end)
    Stubs.flush()
    Assert.eq(#callbacks, 3)
    done_handle.cancel()
    rows["serial:other.epub:0"] = {
        source_id = "serial", stable_id = "other.epub", chapter_idx = 0,
        payload = JSON.encode({ { datetime = "2026-09-05", page = "/x" } }),
        updated_at = 500, sync_status = 0,
    }
    Note.syncAsync(serial, {
        identity = { source_id = "serial", stable_id = "other.epub", source = serial },
        dirty_only = true,
    }, function() end)
    Stubs.flush()
    Assert.eq(#callbacks, 3, "第三轮仍在飞，第四轮必须排队")
end

-- 上传期间又改了笔记（stale）：回填的 kavita_id 并进 live 快照，脏标记与修订号都不动。
-- 之前整份丢弃，下一轮推送只好重新按键认领（甚至重复建）。
do
    local JSON = require("json")
    local racing_backfill = { id = "backfill" }
    local uploaded = JSON.encode({
        {
            datetime = "2026-10-01", page = "/body/p[1].0", pos0 = "/body/p[1].0", pos1 = "/body/p[1].5",
            text = "高亮", kavita_id = nil,
        },
    })
    local newer = JSON.encode({
        {
            datetime = "2026-10-01", page = "/body/p[1].0", pos0 = "/body/p[1].0", pos1 = "/body/p[1].5",
            text = "高亮",
        },
        { datetime = "2026-10-01", page = "/body/p[2].0", pos0 = "/body/p[2].0", pos1 = "/body/p[2].4", text = "新划的" },
    })
    local key = "backfill:book5.epub:0"
    rows[key] = {
        source_id = "backfill", stable_id = "book5.epub", chapter_idx = 0,
        payload = uploaded, updated_at = 10, sync_status = 0,
    }
    -- 真实源会把 kavita_* 透传进快照；这里明确这条路（核心不自己补字段）。
    racing_backfill.cleanAnnotations = function(_, items) return items end
    racing_backfill.pushNotesAsync = function(_, _identity, annotations, cb)
        annotations[1].kavita_id = 77
        annotations[1].kavita_note = "高亮"
        -- 回包还没到，用户又划了一条：payload 与修订号都变了
        rows[key].payload = newer
        rows[key].updated_at = 11
        cb(true, nil, { pushed = 1 })
    end
    racing_backfill.pullNotesAsync = function(_, _identity, cb) cb({}) end

    local result
    Note.syncAsync(racing_backfill, { identity = {
        source_id = "backfill", stable_id = "book5.epub", source = racing_backfill,
    }, dirty_only = true }, function(value) result = value end)
    Stubs.flush()

    local snapshot = JSON.decode(rows[key].payload)
    Assert.eq(#snapshot, 2, "上传期间新划的线不能被覆盖")
    Assert.eq(snapshot[1].kavita_id, 77, "回填的 id 并进 live 快照")
    Assert.eq(snapshot[1].kavita_note, "高亮")
    Assert.is_nil(snapshot[2].kavita_id, "没推的那条不编 id")
    Assert.eq(rows[key].updated_at, 11, "修订号不能被回退")
    Assert.eq(rows[key].sync_status, 0, "仍是脏行，下轮再推")
    Assert.eq(result.pushed, 1)
end

-- pushed 如实计数：源说「这轮没什么可推」时核心不能 +1，否则首页会白刷一次。
do
    local JSON = require("json")
    local quiet = { id = "quiet" }
    local key = "quiet:book6.epub:0"
    rows[key] = {
        source_id = "quiet", stable_id = "book6.epub", chapter_idx = 0,
        payload = JSON.encode({ { datetime = "2026-10-02", page = "/body/p[1].0" } }),
        updated_at = 500, sync_status = 0,
    }
    quiet.pushNotesAsync = function(_, _identity, _annotations, cb) cb(true, nil, { pushed = 0 }) end
    quiet.pullNotesAsync = function(_, _identity, cb) cb({}) end
    local result
    Note.syncAsync(quiet, { identity = {
        source_id = "quiet", stable_id = "book6.epub", source = quiet,
    }, dirty_only = true }, function(value) result = value end)
    Stubs.flush()
    Assert.eq(result.pushed, 0, "源如实回 0 就按 0 记")
    Assert.eq(rows[key].sync_status, 1, "对账完的快照仍要清脏，否则每轮重推")
end

-- 远端删除穿过条数保护：源返回 dropped = 主动判定为「远端已删」的条数，
-- 守卫要把它们算进来；老源没有第二返回值时行为不变（仍然不覆盖本地划线）。
do
    local JSON = require("json")
    local kept = {
        { datetime = "2026-10-04", page = "/body/a", pos0 = "/body/a", pos1 = "/body/b",
            drawer = "lighten", text = "远端删了" },
    }
    rows["dropped:book8.epub:0"] = {
        source_id = "dropped", stable_id = "book8.epub", chapter_idx = 0,
        payload = JSON.encode(kept), updated_at = 9, sync_status = 1,
    }
    local current_annotations = kept
    local ui8 = {
        document = { file = "/b4.epub", getPageCount = function() return 10 end },
        doc_settings = {
            flush = function() end,
            readSetting = function(_, name)
                if name == "annotations" then return current_annotations end
            end,
            saveSetting = function(_, name, value)
                if name == "annotations" then current_annotations = value end
            end,
        },
    }
    local dropping = {
        id = "dropped",
        mergeAnnotations = function(_, _remote, _current, _paging, _authoritative)
            return {}, 1
        end,
    }
    Assert.eq(SessionNote.applyLocal(ui8, {
        source_id = "dropped", stable_id = "book8.epub", source = dropping,
    }), 0)
    Assert.eq(#current_annotations, 0, "dropped 计入守卫，合法删除不被条数保护拦住")

    current_annotations = { kept[1] }
    local legacy = {
        id = "dropped",
        mergeAnnotations = function() return {} end,
    }
    Assert.eq(SessionNote.applyLocal(ui8, {
        source_id = "dropped", stable_id = "book8.epub", source = legacy,
    }), 0)
    Assert.eq(#current_annotations, 1, "没有 dropped 第二返回值时仍按条数保护跳过")
end

-- 远端同键去重穿过条数保护：第一次修正时 doc_settings 里旧有 5 条（37 / 43 都在），
-- 合并后只剩 4 条 + 1 条被抑制（deduped）。守卫必须把 deduped 算回来，否则重复条目永远修不掉；
-- 没有 dropped / deduped 解释的「少一条」仍按误删拦住。
do
    local JSON = require("json")
    local function ann(page)
        return { datetime = "2026-10-05", page = page, pos0 = page, pos1 = page .. ".5",
            drawer = "lighten", text = "线" }
    end
    local five = { ann("/body/p[1]"), ann("/body/p[2]"), ann("/body/p[3]"), ann("/body/p[4]"), ann("/body/p[5]") }
    rows["dedupe:book9.epub:0"] = {
        source_id = "dedupe", stable_id = "book9.epub", chapter_idx = 0,
        payload = JSON.encode(five), updated_at = 9, sync_status = 1,
    }
    local current_annotations = five
    local ui9 = {
        document = { file = "/b6.epub", getPageCount = function() return 10 end },
        doc_settings = {
            flush = function() end,
            readSetting = function(_, name)
                if name == "annotations" then return current_annotations end
            end,
            saveSetting = function(_, name, value)
                if name == "annotations" then current_annotations = value end
            end,
        },
    }
    local deduping = {
        id = "dedupe",
        mergeAnnotations = function(_, _remote, _current, _paging, _authoritative)
            return { five[1], five[2], five[3], five[4] }, 0, 1
        end,
    }
    Assert.eq(SessionNote.applyLocal(ui9, {
        source_id = "dedupe", stable_id = "book9.epub", source = deduping,
    }), 4, "deduped 计入守卫：4 merged + 1 deduped vs 5 current → 放行")
    Assert.eq(#current_annotations, 4)

    current_annotations = five
    local losing = {
        id = "dedupe",
        mergeAnnotations = function(_, _remote, _current, _paging, _authoritative)
            return { five[1], five[2], five[3], five[4] }
        end,
    }
    Assert.eq(SessionNote.applyLocal(ui9, {
        source_id = "dedupe", stable_id = "book9.epub", source = losing,
    }), 0, "没解释的丢条仍被拦住")
    Assert.eq(#current_annotations, 5, "旧快照原样保留")
end

-- 删除事件判据（spec §9.1）：index_modified < 0 取 changed[1] 作被删条目传给源；
-- 划线转笔记 / 只删备注时 nb_highlights_added 也是负的，但 index_modified 非负 → 不是删除。
do
    local JSON = require("json")
    local seen = {}
    local deleting = {
        id = "deleting",
        cleanAnnotations = function(_, items) return items end,
        prepareLocalAnnotations = function(_, previous, current, deleted)
            seen[#seen + 1] = { previous = previous, current = current, deleted = deleted }
            return current
        end,
    }
    local key = "deleting:book7.epub:0"
    local item = { datetime = "2026-10-03", page = "/body/p[1].0", pos0 = "/body/p[1].0",
        pos1 = "/body/p[1].5", drawer = "lighten", text = "划的线", note = "备注" }
    local current_annotations = {}
    local ui7 = {
        document = { file = "/b5.epub", getPageCount = function() return 10 end },
        doc_settings = {
            flush = function() end,
            readSetting = function(_, name)
                if name == "annotations" then return current_annotations end
            end,
            saveSetting = function(_, name, value)
                if name == "annotations" then current_annotations = value end
            end,
        },
    }
    local identity7 = { source_id = "deleting", stable_id = "book7.epub", source = deleting }
    local function seed()
        rows[key] = { source_id = "deleting", stable_id = "book7.epub", chapter_idx = 0,
            payload = JSON.encode({ item }), updated_at = 1, sync_status = 1 }
    end

    -- 删除：阅读器数组里已经没有它了（annotation.annotations 是删除后的状态）。
    seed()
    current_annotations = {}
    SessionNote.save(ui7, identity7, { item, nb_highlights_added = -1, index_modified = -7 })
    Assert.eq(seen[#seen].deleted, item, "被删条目就是 changed[1]")

    -- 划线转笔记 / 只删备注：条目还在，index_modified 非负 → 不传 deleted。
    seed()
    current_annotations = { item }
    SessionNote.save(ui7, identity7, { item, nb_highlights_added = -1, index_modified = 0 })
    Assert.is_nil(seen[#seen].deleted)
    Assert.eq(#seen, 2)

    -- 老调用方不传 changed：它是可选参数，不产生删除。
    seed()
    current_annotations = { item }
    SessionNote.save(ui7, identity7, nil)
    Assert.is_nil(seen[#seen].deleted)
    Assert.eq(#seen, 3)
end

_G.G_reader_settings = previous_settings
