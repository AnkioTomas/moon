--[[--
月读同步扫描本机设置：size + mtime 没变就复用上次的 hash，一轮里两次扫描只算一遍。

@module tests.moon_sync.run_hash_spec
--]]

local Assert = require("support.assert")
package.preload["json"] = function()
    local JSON = require("support.json_stub")
    return { encode = JSON.encode, decode = JSON.decode }
end
package.loaded["json"] = nil
package.loaded["moon_sync"] = { syncFonts = function() return false end }

local Fs = require("utils.fs")
local Paths = require("utils.paths")
local lfs = require("libs/libkoreader-lfs")
local Run = require("moon_sync.run")
Run.reading = function(_handle, _dav, _root, _report, cb) cb(true) end

local PROBE = "moon-sync-hash-probe"
local sha2 = require("ffi/sha2")
local md5 = sha2.md5
local hashed = 0
sha2.md5 = function(data)
    if type(data) == "string" and data:find(PROBE, 1, true) then hashed = hashed + 1 end
    return md5(data)
end

local manifest
local dav = {
    getAsync = function(_self, _path, _dest, _opts, cb) cb(nil, "missing", 404) end,
    putFileAsync = function(_self, remote, local_path, cb)
        if remote:match("manifest%.json$") then manifest = Fs.read(local_path) end
        cb(true)
    end,
    ensurePathAsync = function(_self, _path, cb) cb(true) end,
}

local path = Paths.settingsDir() .. "/zz_moon_sync_hash_probe.lua"
local function writeOld(content)
    Assert.is_true(Paths.ensureDir(Paths.settingsDir()))
    Assert.is_true(Fs.write(path, content))
    local old = os.time() - 60
    lfs.touch(path, old, old)
end
local function sync()
    local result
    Run.payload({}, dav, "/root", function() end, function(ok, err) result = { ok = ok, err = err } end)
    Assert.is_true(result.ok, result.err)
end

writeOld("return '" .. PROBE .. "-a'")
sync()
Assert.eq(hashed, 1, "规划前和上传后两次扫描只算一遍")
Assert.not_nil(manifest:find(md5("return '" .. PROBE .. "-a'"), 1, true))

sync()
Assert.eq(hashed, 1, "没改过的文件下一轮不重算")

writeOld("return '" .. PROBE .. "-bb'")
sync()
Assert.eq(hashed, 2, "改过（长度或时间变了）才重算")
Assert.not_nil(manifest:find(md5("return '" .. PROBE .. "-bb'"), 1, true))

-- 一秒内刚写的不进缓存：同秒同长度的第二次修改不能被当成没变。
Assert.is_true(Fs.write(path, "return '" .. PROBE .. "-cc'"))
sync()
Assert.eq(hashed, 4, "刚改过的文件每次扫描都现算")

sha2.md5 = md5
os.remove(path)
