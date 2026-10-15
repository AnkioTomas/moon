--[[--
source.local.setting.subdirs：不可读目录（Android 的 /storage）返回 nil, err，不抛错。

@module tests.source.local.dir_perm_spec
--]]

local Assert = require("support.assert")
local Setting = require("source.local.setting")

local root = os.tmpname()
os.remove(root)
os.execute("mkdir -p '" .. root .. "/b' '" .. root .. "/a' '" .. root .. "/x.sdr' '" .. root .. "/locked'")
os.execute("touch '" .. root .. "/f.txt' && chmod 000 '" .. root .. "/locked'")

local names = Setting.subdirs(root)
Assert.eq(2 + 1, #names)
Assert.eq("a", names[1])
Assert.eq("b", names[2])
Assert.eq("locked", names[3])

-- 测试桩的 lfs.dir 不抛错；按真机 lfs 的行为模拟「cannot open ...: Permission denied」
local lfs = require("libs/libkoreader-lfs")
local realDir = lfs.dir
lfs.dir = function(path)
    if path:find("/locked$") then error("cannot open " .. path .. ": Permission denied") end
    return realDir(path)
end
local locked, err = Setting.subdirs(root .. "/locked")
lfs.dir = realDir
Assert.is_nil(locked)
Assert.is_true(err:find("Permission denied", 1, true) ~= nil)

os.execute("chmod 755 '" .. root .. "/locked' && rm -rf '" .. root .. "'")
