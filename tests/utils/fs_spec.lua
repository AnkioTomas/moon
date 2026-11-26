--[[-- utils.fs：原子写 / 递归删除 / 分区用量 --]]

local Assert = require("support.assert")
local Config = require("support.config")

local Fs = require("utils.fs")
local lfs = require("libs/libkoreader-lfs")

local base = Config.dir() .. "/fs_spec"
Fs.removeTree(base)
lfs.mkdir(base)

-- write：覆盖旧内容，不留 .part
do
    local path = base .. "/a.txt"
    Assert.is_true(Fs.write(path, "one"))
    Assert.is_true(Fs.write(path, "two"))
    Assert.eq(Fs.read(path), "two")
    Assert.is_nil(Fs.read(path .. ".part"))
    Assert.is_true(Fs.write(path, ""))
    Assert.eq(Fs.read(path), "", "空内容也是合法文件")
end

-- write：父目录不存在时失败，旧文件不动
do
    local ok, err = Fs.write(base .. "/missing/x.txt", "data")
    Assert.is_nil(ok)
    Assert.is_true(err ~= nil)
    Assert.is_nil(Fs.read(base .. "/missing/x.txt.part"))
end

-- write：rename 失败时清掉 .part，目标保持原样
do
    local path = base .. "/keep.txt"
    Assert.is_true(Fs.write(path, "old"))
    local real_rename = os.rename
    os.rename = function() return nil, "rename denied" end
    local ok, err = Fs.write(path, "new")
    os.rename = real_rename
    Assert.is_nil(ok)
    Assert.eq(err, "rename denied")
    Assert.eq(Fs.read(path), "old")
    Assert.is_nil(Fs.read(path .. ".part"))
end

-- removeTree：嵌套目录整棵删掉；不存在算成功；单文件直接删
do
    lfs.mkdir(base .. "/tree")
    lfs.mkdir(base .. "/tree/sub")
    Assert.is_true(Fs.write(base .. "/tree/f", "1"))
    Assert.is_true(Fs.write(base .. "/tree/sub/g", "2"))
    Assert.is_true(Fs.removeTree(base .. "/tree"))
    Assert.is_nil(lfs.attributes(base .. "/tree"))
    Assert.is_true(Fs.removeTree(base .. "/tree"), "不存在算成功")
    Assert.is_true(Fs.write(base .. "/single", "x"))
    Assert.is_true(Fs.removeTree(base .. "/single"))
    Assert.is_nil(Fs.read(base .. "/single"))
end

-- disk：used = total - free；旧版 df 没有 available 时用 free；取不到返回 nil
do
    local real = package.loaded["ffi/util"]
    local result
    package.loaded["ffi/util"] = { df = function() return unpack(result) end }
    result = { 100, 30, 20 }
    local d = Fs.disk("/")
    Assert.eq(d.total, 100)
    Assert.eq(d.used, 70)
    Assert.eq(d.available, 20)
    result = { 100, 30 }
    Assert.eq(Fs.disk("/").available, 30, "缺 available 退回 free")
    result = {}
    Assert.is_nil(Fs.disk("/"))
    package.loaded["ffi/util"] = real
end

Fs.removeTree(base)
