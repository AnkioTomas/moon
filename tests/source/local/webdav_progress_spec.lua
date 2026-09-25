--[[-- source.local.client：WebDAV 进度与 Moon+ Reader `.Moon+/Cache/*.po` 互通 --]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")

local progress_rows, remote_upserts = {}, {}
package.preload["db.progress"] = function()
    return {
        get = function(_, stable_id) return progress_rows[stable_id] end,
        unsynced = function()
            local out = {}
            for _, row in pairs(progress_rows) do
                if row.sync_status == 0 then out[#out + 1] = row end
            end
            return out
        end,
        upsertRemote = function(_, stable_id, pos)
            remote_upserts[stable_id] = pos
            return true
        end,
        markSynced = function(_, stable_id)
            progress_rows[stable_id].sync_status = 1
            return true
        end,
    }
end
package.preload["db.book"] = function()
    return {
        get = function() return nil end,
        upsertRemote = function() return true end,
        stableIdsBySource = function() return {} end,
        setLibraryMembership = function() return true end,
    }
end
package.loaded["db.progress"] = nil
package.loaded["db.book"] = nil
package.loaded["source.local.client"] = nil

local Client = require("source.local.client")

local function readFile(path)
    local file = assert(io.open(path, "rb"))
    local raw = file:read("*a")
    file:close()
    return raw
end

local LISTING = {
    ["Apps/Books"] = {
        { name = "real.epub" }, { name = "legacy.epub" }, { name = "short.epub" },
        { name = ".Moon+", is_dir = true, path = "Apps/Books/.Moon+" },
    },
    ["Apps/Books/.Moon+"] = { { name = "Cache", is_dir = true, path = "Apps/Books/.Moon+/Cache" } },
    ["Apps/Books/.Moon+/Cache"] = {
        { name = "real.epub.po" }, { name = "legacy.epub.po" }, { name = "short.epub.po" },
    },
}
local REMOTE = {
    -- Moon+ Reader 实际写出的格式：毫秒时间戳、一位小数百分比
    ["Apps/Books/.Moon+/Cache/real.epub.po"] = "1703297605115*21@0#4826:11.1%",
    -- 旧版插件写出的花括号秒级格式
    ["Apps/Books/.Moon+/Cache/legacy.epub.po"] = "{1700000000}*3@7#0:42%",
    ["Apps/Books/.Moon+/Cache/short.epub.po"] = "1590486119266*9:3.8%",
}

local function fakeDav(uploads)
    return {
        listAsync = function(_, path, cb) cb(LISTING[path] or {}) end,
        getAsync = function(_, path, temp, _, cb)
            local file = assert(io.open(temp, "wb"))
            file:write(REMOTE[path] or "")
            file:close()
            cb(REMOTE[path] ~= nil)
        end,
        ensurePathAsync = function(_, _, cb) cb(true) end,
        putFileAsync = function(_, path, temp, cb)
            uploads[path] = readFile(temp)
            cb(true)
        end,
    }
end

-- 拉取：Moon+ Reader 真实文件、旧版花括号文件、短格式都要能解析，时间戳统一为秒。
do
    local client = Client.new({ webdav_url = "https://dav.example" })
    client.dav = fakeDav({})
    local ok
    client:scanWebdavAsync(function(value) ok = value end)
    Stubs.flush()
    Assert.is_true(ok)
    local real = remote_upserts["webdav://real.epub"]
    Assert.eq(real.updated_at, 1703297605)
    Assert.eq(real.chapter_idx, 21)
    Assert.eq(real.fraction, 0.111)
    local legacy = remote_upserts["webdav://legacy.epub"]
    Assert.eq(legacy.updated_at, 1700000000)
    Assert.eq(legacy.chapter_idx, 3)
    Assert.eq(legacy.fraction, 0.42)
    local short = remote_upserts["webdav://short.epub"]
    Assert.eq(short.updated_at, 1590486119)
    Assert.eq(short.fraction, 0.038)
end

-- 推送：写 Moon+ Reader 能读的格式，不带花括号，时间戳是毫秒。
do
    progress_rows["webdav://real.epub"] = {
        stable_id = "webdav://real.epub", sync_status = 0,
        updated_at = 1700000123, chapter_idx = 4, page = 57, fraction = 0.4567,
    }
    local uploads = {}
    local client = Client.new({ webdav_url = "https://dav.example" })
    client.dav = fakeDav(uploads)
    local ok
    client:syncWebdavProgressAsync({ stable_id = "webdav://real.epub" }, function(value) ok = value end)
    Stubs.flush()
    Assert.is_true(ok)
    Assert.eq(uploads["Apps/Books/.Moon+/Cache/real.epub.po"], "1700000123000*4@0#0:45.7%")
    Assert.eq(progress_rows["webdav://real.epub"].sync_status, 1)
end
