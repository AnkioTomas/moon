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
    io.write("  (skip: 沙箱数据目录未就绪，请用 ./tests/run.sh 运行)\n")
    return
end

Assert.is_true(Config.setupNativePath())

-- 数据目录指到隔离的临时根，别碰真实 .moon
-- 先清后建：避免上一轮崩掉（进程被杀，cleanup 没跑）留下的残留影响断言
local TMP = Config.dir() .. "/.moon/cache/test_pinyin_download"
os.execute("rm -rf " .. TMP)
os.execute("mkdir -p " .. TMP)
package.preload["datastorage"] = function()
    return { getDataDir = function() return TMP .. "/data" end }
end

-- settings 不碰真实配置文件：内存表 mock（download 读写 manifest built_at）
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
    built_at = "2026-08-19 13:17:06",
    entries = 2,
    raw_sha256 = raw_sha,
    raw_size = #raw,
    parts = {
        { file = "dictionary.sqlite3.part.001", size = #part1, sha256 = sha.sha256(part1) },
        { file = "dictionary.sqlite3.part.002", size = #part2, sha256 = sha.sha256(part2) },
    },
}

-- json：download 用 JSON.decode 解 manifest；测试侧用 KOReader 自带的 dkjson 真实现
-- （只读模拟器构建产物，和 native 库同一性质）
local DKJSON = Config.root() .. "/config/common/dkjson.lua"
do
    local probe = io.open(DKJSON, "r")
    if not probe then
        io.write("  (skip: 缺 config/common/dkjson.lua，需要本机 koreader 构建产物)\n")
        return
    end
    probe:close()
end
package.preload["json"] = function()
    return dofile(DKJSON)
end

-- stub http.request：get 给 manifest，download 写对应分片（并回报一次写字节进度）
local downloads = {}
local progress_events = {}
local fail_part_once = false
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
            if fail_part_once and dest:match("part%.002$") then
                fail_part_once = false
                f:write(data:sub(1, 3))
                f:close()
                require("ui/uimanager"):nextTick(function()
                    cb(false, "network failed")
                end)
                return { cancel = function() end }
            end
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
    fake_settings.pinyin_dict_built_at = nil
end

local ok_run, err_run = pcall(function()
    -- 第一轮第二片失败：第一片必须保留，重试只拉失败的那片。
    fail_part_once = true
    local failed, failed_err
    Download.ensure(function(ok, err)
        failed = not ok
        failed_err = err
    end)
    Stubs.flush()
    Assert.is_true(failed)
    Assert.matches(failed_err, "network failed")
    Assert.eq(#downloads, 2)
    Assert.is_true(require("libs/libkoreader-lfs").attributes(Paths.root() .. "/pinyin_dict.dl/" .. manifest.parts[1].file) ~= nil)
    Assert.is_nil(require("libs/libkoreader-lfs").attributes(Paths.root() .. "/pinyin_dict.dl/" .. manifest.parts[2].file))

    downloads = {}
    progress_events = {}
    local done, ok_cb
    Download.ensure(function(ok, err)
        done = true
        ok_cb = ok
        if not ok then
            print("ensure err:", err)
        end
    end, function(...)
        progress_events[#progress_events + 1] = { ... }
    end)
    Stubs.flush()
    Assert.is_true(done)
    Assert.is_true(ok_cb)

    -- 续传只下载失败的第二片，URL 走 jsdelivr
    Assert.len(downloads, 1)
    Assert.is_true(downloads[1]:find("cdn%.jsdelivr%.net") ~= nil)
    Assert.is_true(downloads[1]:find("part%.002") ~= nil)

    -- manifest 在拿到大小后再次回报，进度框可无缝接到分片下载。
    local total = #part1 + #part2
    Assert.eq(progress_events[1][1], "manifest")
    Assert.eq(progress_events[2][1], "manifest")
    Assert.eq(progress_events[2][2], 0)
    Assert.eq(progress_events[2][3], total)
    Assert.eq(progress_events[2][5], 2)
    Assert.eq(progress_events[3][1], "part")
    Assert.eq(progress_events[3][2], #part1, "续传跳过第一片后累计字节")
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

    -- manifest built_at 是本地词库版本，供下次更新比较。
    Assert.eq(MoonSettings.get().pinyin_dict_built_at, manifest.built_at)
    Assert.eq(MoonSettings.get().pinyin_dict_sha256, raw_sha)

    -- 临时目录已清理
    Assert.is_nil(require("libs/libkoreader-lfs").attributes(Paths.root() .. "/pinyin_dict.dl"))

    -- built_at 未变时只检查 manifest，不重复下载或拼接词库；
    -- SHA 只是下载完整性记录，不能作为用户可见版本。
    local downloads_before = #downloads
    fake_settings.pinyin_dict_sha256 = "stale-sha"
    local done_again, ok_again
    Download.ensure(function(ok)
        done_again = true
        ok_again = ok
    end)
    Stubs.flush()
    Assert.is_true(done_again)
    Assert.is_true(ok_again)
    Assert.eq(#downloads, downloads_before)
end)

cleanup()
if not ok_run then
    error(err_run)
end
