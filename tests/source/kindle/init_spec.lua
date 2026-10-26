--[[--
source.kindle：只读伪造的 cc.db 列书；可见性、封面、缓存路径、开书都依赖 kindle.koplugin 的 open_file_ext。

@module tests.source.kindle.init_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, inject-field

local Assert = require("support.assert")
local Config = require("support.config")

local dir = Config.dir()
local function file(name, size)
    local p = dir .. "/kindle_spec_" .. name
    local f = assert(io.open(p, "wb")); f:write(string.rep("x", size or 1)); f:close()
    return p
end
local cc_path = file("cc.db")
local kfx = file("a.kfx")
local azw3 = file("b.azw3")
local epub = file("a.epub")
local thumb = file("a.jpg", 5000)
local placeholder = file("b.jpg", 1015)

-- 离线环境没有 ljsqlite3：伪造连接，按 SQL 是否带 uuid 条件返回行（列序同 COLUMNS）。
local ENTRIES = {
    { "u1", kfx, "甲", '[{"display":"作者一"},{"display":"作者二"}]', "application/x-kfx-ebook", thumb, 12, 1700000000 },
    { "u2", azw3, "乙", nil, "application/x-mobi8-ebook", placeholder, nil, nil },
}
local last_sql, opened_mode
package.loaded["lua-ljsqlite3/init"] = {
    open = function(_path, mode)
        opened_mode = mode
        return {
            close = function() end,
            prepare = function(_self, sql)
                last_sql = sql
                local uuid
                return {
                    bind = function(_s, v) uuid = v end,
                    close = function() end,
                    rows = function()
                        local i = 0
                        return function()
                            repeat i = i + 1 until not ENTRIES[i] or not uuid or ENTRIES[i][1] == uuid
                            return ENTRIES[i]
                        end
                    end,
                }
            end,
        }
    end,
}

local reconciled
package.loaded["book.books_db"] = {
    reconcile = function(source_id, books, opts)
        reconciled = { source_id = source_id, books = books, opts = opts }
        return true, 0
    end,
    get = function() return { cover = thumb } end,
}
local touched
package.loaded["book.store"] = { touch = function(path) touched = path; return true end }
local toasts = 0
package.loaded["ui.themes.widgets.toast"] = { new = function() return { show = function() toasts = toasts + 1 end } end }
package.loaded["ui/uimanager"] = { nextTick = function(_self, fn) fn() end }
package.loaded["ui.guard"] = { call = function(_name, fn, ...) return fn(...) end }
package.loaded["lua/open_file_ext"] = nil
package.loaded["source.kindle"] = nil
local Kindle = require("source.kindle")
Kindle.CC_DB = cc_path

-- 没装 kindle.koplugin：不可用
Assert.is_false(Kindle.available())

local prepared, epub_exists = {}, false
local ofe = {
    cache_manager = { getCachePaths = function(_self, book)
        return book.id == "cc:u1" and epub_exists and epub or (dir .. "/none.epub")
    end },
    prepareKnownKindlePath = function(_self, path)
        prepared[#prepared + 1] = path
        if path == azw3 then return nil, "DRM 不支持" end
        return epub
    end,
}
package.loaded["lua/open_file_ext"] = ofe
Assert.is_true(Kindle.available())

local rows = Kindle.query()
Assert.eq(#rows, 2)
Assert.eq(opened_mode, "ro")
Assert.is_true(last_sql:find("application/x-mobi8-ebook", 1, true) ~= nil)
-- 只要 KFX 和带 DRM 的 mobi 族：无 DRM 的归本地源
Assert.is_true(last_sql:find("p_mimeType = 'application/x-kfx-ebook'", 1, true) ~= nil)
Assert.is_true(last_sql:find("AND p_isDRMProtected = 1)", 1, true) ~= nil)
Assert.is_true(last_sql:find("p_thumbnail", 1, true) ~= nil)
Assert.eq(rows[1].authors, "作者一, 作者二")
Assert.eq(rows[1].cover, thumb)
Assert.is_nil(rows[2].cover) -- 占位图丢掉

local source = Kindle.new()
local result
source:syncBooksAsync({ force = true }, function(r) result = r end)
Assert.eq(result.pulled, 2)
Assert.eq(reconciled.source_id, "kindle")
Assert.eq(reconciled.books[1].path, kfx) -- 未转换用原文件
Assert.eq(reconciled.books[1].inserted_at, 1700000000)

epub_exists = true
source:syncBooksAsync({ force = true }, function(r) result = r end)
Assert.eq(reconciled.books[1].path, epub) -- 已转换用缓存 EPUB

local req = source:coverRequest({ stable_id = "u1" })
Assert.eq(req.url, thumb)

-- 开未转换的 KFX：先提示，交给解析器，拿到 EPUB 后登记
epub_exists = false
local path, err
source:openBookAsync({ source_id = "kindle", stable_id = "u1" }, nil, function(p, e) path, err = p, e end)
Assert.eq(toasts, 1) -- 未转换先提示
Assert.eq(prepared[1], kfx)
Assert.eq(path, epub)
Assert.eq(touched, epub)

-- 解析器失败：原样显示它的文案
source:openBookAsync({ source_id = "kindle", stable_id = "u2" }, nil, function(p, e) path, err = p, e end)
Assert.eq(toasts, 1) -- 不是 KFX 不提示
Assert.is_nil(path)
Assert.eq(err, "DRM 不支持")

-- 解析器抛错也不崩
ofe.prepareKnownKindlePath = function() error("boom") end
source:openBookAsync({ source_id = "kindle", stable_id = "u2" }, nil, function(p, e) path, err = p, e end)
Assert.is_nil(path)
Assert.not_nil(err)

-- 后台转换：接口齐全时 KFX 走任务，转换完用户还在等才开书
local enqueued, followed
package.loaded["workers.tasks"] = { enqueue = function(spec) enqueued = spec; return { cancel = function() end } end }
package.loaded["workers.ui.task_dialog"] = { follow = function(_task, on_bg) followed = on_bg end }
ofe.virtual_library = { getBook = function(_self, id) return { id = id } end }
ofe.cache_manager.isFresh = function() return false end
ofe.cache_manager.ensureCachedEpub = function() return epub end
ofe.prepareKnownKindlePath = function() return epub end
path, err, touched = nil, nil, nil
source:openBookAsync({ source_id = "kindle", stable_id = "u1" }, nil, function(p, e) path, err = p, e end)
Assert.eq(enqueued.kind, "cache")
Assert.is_nil(path) -- 转换没完不开
enqueued.on_done({ ok = true })
Assert.eq(path, epub)
-- 转了后台：不开，只提示
path = nil
source:openBookAsync({ source_id = "kindle", stable_id = "u1" }, nil, function(p) path = p end)
followed()
enqueued.on_done({ ok = true })
Assert.is_nil(path)
-- 转换失败：报给调用方
source:openBookAsync({ source_id = "kindle", stable_id = "u1" }, nil, function(p, e) path, err = p, e end)
enqueued.on_done({ ok = false, err = "坏书" })
Assert.eq(err, "坏书")

-- 超大 KFX 待转换：先确认（点明 kindle.koplugin），确认后才入队；取消带 cancelled。
do
    local confirms = {}
    package.loaded["ui.themes.widgets.confirm"] = {
        new = function(_self, opts)
            return { show = function() confirms[#confirms + 1] = opts end }
        end,
    }
    local lfs = require("libs/libkoreader-lfs")
    local real_attributes = lfs.attributes
    lfs.attributes = function(path, what)
        if path == kfx and what == "size" then return 40 * 1024 * 1024 end
        return real_attributes(path, what)
    end
    enqueued = nil
    source:openBookAsync({ source_id = "kindle", stable_id = "u1" }, nil, function(p, e) path, err = p, e end)
    Assert.is_nil(enqueued)
    Assert.eq(#confirms, 1)
    Assert.matches(confirms[1].text, "kindle.koplugin")
    Assert.matches(confirms[1].text, "约 40 MB")
    confirms[1].ok_callback()
    Assert.eq(enqueued.kind, "cache")

    local meta
    enqueued = nil
    source:openBookAsync({ source_id = "kindle", stable_id = "u1" }, nil, function(p, e, m)
        path, err, meta = p, e, m
    end)
    confirms[#confirms].cancel_callback()
    Assert.is_nil(enqueued)
    Assert.is_nil(path)
    Assert.eq(meta.cancelled, true)
    lfs.attributes = real_attributes
end
package.loaded["workers.tasks"], package.loaded["workers.ui.task_dialog"] = nil, nil

package.loaded["lua/open_file_ext"] = nil
for _idx, p in ipairs({ cc_path, kfx, azw3, epub, thumb, placeholder }) do os.remove(p) end
