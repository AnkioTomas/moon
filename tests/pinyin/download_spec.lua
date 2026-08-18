--[[--
pinyin.download：manifest → 原始分片下载 → 拼接 → 校验落位

不碰真网络：stub http.request（download 写假分片 / get 给 manifest），
stub utils.task 让 assemble 在主进程同步跑。

@module tests.pinyin.download_spec
--]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")
local Config = require("support.config")

if not Config.available() then
    io.write("  (skip: config/ 软链不可用)\n")
    return
end

Assert.is_true(Config.setupNativePath())

-- 数据目录指到隔离的临时根，别碰真实 .moon
-- 先清后建：上一轮若在 download_spec 崩掉（进程被杀，cleanup 没跑），
-- 残留的 dest 会让本轮 ensure 走幂等路径（0 下载）造成假失败
local TMP = Config.dir() .. "/.moon/cache/test_pinyin_download"
os.execute("rm -rf " .. TMP)
os.execute("mkdir -p " .. TMP)
package.preload["datastorage"] = function()
    return { getDataDir = function() return TMP .. "/data" end }
end

-- settings 不碰真实配置文件：内存表 mock（download 只读写 pinyin_dict_source）
local fake_settings = {}
package.preload["utils.settings"] = function()
    return {
        get = function()
            return fake_settings
        end,
        save = function() end,
    }
end

local part1 = "hello "
local part2 = "pinyin dict"
local raw = "hello pinyin dict"
local sha = require("ffi/sha2")
local raw_sha = sha.sha256(raw)

local manifest = {
    tag = "test-tag",
    entries = 2,
    raw_sha256 = raw_sha,
    parts = {
        { file = "dictionary.sqlite3.part.001", size = #part1, sha256 = sha.sha256(part1) },
        { file = "dictionary.sqlite3.part.002", size = #part2, sha256 = sha.sha256(part2) },
    },
}

-- json：download 用 JSON.decode 解 manifest；测试侧用 KOReader 自带的 dkjson 真实现
package.preload["json"] = function()
    return dofile("config/common/dkjson.lua")
end

-- stub http.request：get 给 manifest，download 写对应分片（并回报一次写字节进度）
local downloads = {}
local progress_events = {}
package.preload["http.request"] = function()
    return {
        get = function(url, opts, cb)
            local JSON = require("json")
            local body = JSON.encode(manifest)
            require("ui/uimanager"):nextTick(function()
                cb(body, nil, {})
            end)
            return { cancel = function() end }
        end,
        download = function(opts, dest, cb)
            downloads[#downloads + 1] = opts.url
            local data = dest:match("part%.001$") and part1 or part2
            local f = assert(io.open(dest, "wb"))
            f:write(data)
            f:close()
            if opts.on_progress then
                opts.on_progress(#data)
            end
            require("ui/uimanager"):nextTick(function()
                cb(true)
            end)
            return { cancel = function() end }
        end,
    }
end

-- Task 同步跑 worker（不真 fork），on_done/on_failed 直接调
package.preload["utils.task"] = function()
    return {
        run = function(worker, opts)
            local ok, err = pcall(worker)
            require("ui/uimanager"):nextTick(function()
                if ok then
                    opts.on_done()
                else
                    opts.on_failed(err)
                end
            end)
            return { abort = function() end }
        end,
    }
end

local Paths = require("utils.paths")
local Download = require("pinyin.download")
local MoonSettings = require("utils.settings")

local dest = Paths.pinyinDictPath()

local function cleanup()
    os.remove(dest)
    os.remove(dest .. ".part")
    os.execute("rm -rf " .. TMP)
    fake_settings.pinyin_dict_source = nil
end

local ok_run, err_run = pcall(function()
    local done, ok_cb
    Download.ensure(function(ok, err)
        done = true
        ok_cb = ok
        if not ok then
            print("ensure err:", err)
        end
    end, nil, function(...)
        progress_events[#progress_events + 1] = { ... }
    end)
    Stubs.flush()
    Assert.is_true(done)
    Assert.is_true(ok_cb)

    -- 两片都下了，URL 走 jsdelivr
    Assert.len(downloads, 2)
    Assert.is_true(downloads[1]:find("cdn%.jsdelivr%.net") ~= nil)
    Assert.is_true(downloads[1]:find("part%.001") ~= nil)

    -- manifest 在拿到大小后再次回报，进度框可无缝接到分片下载。
    local total = #part1 + #part2
    Assert.eq(progress_events[1][1], "manifest")
    Assert.eq(progress_events[2][1], "manifest")
    Assert.eq(progress_events[2][2], 0)
    Assert.eq(progress_events[2][3], total)
    Assert.eq(progress_events[2][5], 2)
    Assert.eq(progress_events[3][1], "part")
    Assert.eq(progress_events[3][2], #part1, "第一片完成后累计字节")
    Assert.eq(progress_events[3][3], total)
    Assert.eq(progress_events[3][4], 1)
    Assert.eq(progress_events[4][1], "part")
    Assert.eq(progress_events[4][2], total, "第二片完成后累计=总量")
    Assert.eq(progress_events[4][4], 2)
    Assert.eq(progress_events[5][1], "assemble")

    -- 落位文件 = 解压拼接结果
    local f = assert(io.open(dest, "rb"))
    Assert.eq(f:read("*a"), raw)
    f:close()

    -- 来源 tag 写入设置
    Assert.eq(MoonSettings.get().pinyin_dict_source, "test-tag")

    -- 幂等：文件已在，再 ensure 不下载
    downloads = {}
    local again
    Download.ensure(function(ok)
        again = ok
    end)
    Stubs.flush()
    Assert.is_true(again)
    Assert.len(downloads, 0)

    -- 临时目录已清理
    Assert.is_nil(require("libs/libkoreader-lfs").attributes(Paths.root() .. "/pinyin_dict.dl"))
end)

cleanup()
if not ok_run then
    error(err_run)
end
