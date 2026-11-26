--[[--
storage.dumps：只识别 Kindle 用户存储根顶层的 Indexer 诊断与 cvm 崩溃转储，
并可在测试夹具里选择删除。不扫子目录、不跟随符号链接、不误伤普通文档。
@module tests.features.storage.dumps_spec
--]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")
local Config = require("support.config")

if not Config.available() then
    Assert.skip("沙箱数据目录未就绪，请用 ./tests/run.sh 运行")
end

Stubs.install()

package.loaded["workers.job"] = {
    run = function(worker, opts)
        opts.on_done(worker())
        return { cancel = function() end }
    end,
}

local lfs = require("libs/libkoreader-lfs")
local Dumps = require("features.storage.dumps")

Assert.is_true(Dumps.isDumpName("Indexer_Dump_1794543178241.txt"))
Assert.is_true(Dumps.isDumpName("cvm_10145_038-juno_120202_bourbon_wario-379151.core"))
Assert.is_true(Dumps.isDumpName("cvm_1438_038-juno_120202_bourbon_wario-379151.core"))
Assert.is_false(Dumps.isDumpName("notes.txt"))
Assert.is_false(Dumps.isDumpName("something.core"))
Assert.is_false(Dumps.isDumpName("book.log"))
Assert.is_false(Dumps.isDumpName("Indexer_Dump_foo.txt"))
Assert.is_false(Dumps.isDumpName("Indexer_Dump_1794543178241.md"))
Assert.is_false(Dumps.isDumpName("cvm_10145.core"))
Assert.is_false(Dumps.isDumpName("../Indexer_Dump_1.txt"))
Assert.is_false(Dumps.isDumpName("Indexer_Dump_1.txt/evil"))

-- 非 Kindle 默认不扫任何路径。
package.loaded["device"] = { isKindle = function() return false end, home_dir = "/mnt/us" }
Dumps._roots = nil
Assert.eq(#Dumps.defaultRoots(), 0)

local root = os.tmpname()
os.remove(root)
Assert.is_true(lfs.mkdir(root) == true)
local nested = root .. "/documents"
Assert.is_true(lfs.mkdir(nested) == true)
local outside = os.tmpname()
os.remove(outside)
Assert.is_true(lfs.mkdir(outside) == true)

local function writefile(path, body)
    local file = assert(io.open(path, "wb"))
    file:write(body)
    file:close()
end

writefile(root .. "/Indexer_Dump_1794543178241.txt", "indexer dump\n")
writefile(root .. "/cvm_10145_038-juno_120202_bourbon_wario-379151.core", "core-a")
writefile(root .. "/cvm_1438_038-juno_120202_bourbon_wario-379151.core", "core-b-longer")
writefile(root .. "/notes.txt", "ordinary document")
writefile(root .. "/something.core", "not a kindle cvm dump")
writefile(root .. "/book.log", "current log")
writefile(root .. "/Indexer_Dump_foo.txt", "bad indexer name")
writefile(nested .. "/Indexer_Dump_111.txt", "should not recurse")
writefile(outside .. "/Indexer_Dump_222.txt", "outside root")
-- 同名目录不可列入、也不可删。
Assert.is_true(lfs.mkdir(root .. "/cvm_999_dir-name_should-not-match.core") == true
    or lfs.attributes(root .. "/cvm_999_dir-name_should-not-match.core", "mode") == "directory")
-- 这个目录名其实匹配 cvm 规则，必须因是目录而被跳过。
Assert.is_true(Dumps.isDumpName("cvm_999_dir-name_should-not-match.core"))

-- 符号链接：指向根外同名文件，以及指向根内诊断文件，都不列入。
local link_out = root .. "/Indexer_Dump_333.txt"
local link_in = root .. "/cvm_777_038-juno_link-wario-1.core"
os.execute(string.format("ln -s %q %q", outside .. "/Indexer_Dump_222.txt", link_out))
os.execute(string.format("ln -s %q %q", root .. "/cvm_10145_038-juno_120202_bourbon_wario-379151.core", link_in))
Assert.eq(lfs.symlinkattributes(link_out, "mode"), "link")

Dumps._roots = { root }
local got
Dumps.scanAsync(function(result) got = result end)
Assert.not_nil(got)
Assert.eq(got.count, 3)
Assert.eq(#got.items, 3)
Assert.is_true(got.total > 0)
local names = {}
for _idx, item in ipairs(got.items) do
    names[item.name] = item
    Assert.is_true(Dumps.isInsideRoot(item.path, root))
    Assert.is_nil(Dumps.verify(item))
    Assert.is_true(item.subtitle == nil)
end
Assert.not_nil(names["Indexer_Dump_1794543178241.txt"])
Assert.not_nil(names["cvm_10145_038-juno_120202_bourbon_wario-379151.core"])
Assert.not_nil(names["cvm_1438_038-juno_120202_bourbon_wario-379151.core"])
Assert.is_nil(names["notes.txt"])
Assert.is_nil(names["something.core"])
Assert.is_nil(names["book.log"])
Assert.is_nil(names["Indexer_Dump_foo.txt"])
Assert.is_nil(names["Indexer_Dump_111.txt"])
Assert.is_nil(names["Indexer_Dump_222.txt"])
Assert.is_nil(names["Indexer_Dump_333.txt"])
Assert.is_nil(names["cvm_777_038-juno_link-wario-1.core"])
Assert.is_nil(names["cvm_999_dir-name_should-not-match.core"])

-- 越界路径不能删。
local escaped = {
    path = root .. "/../" .. outside:match("([^/]+)$") .. "/Indexer_Dump_222.txt",
    root = root,
    name = "Indexer_Dump_222.txt",
    size = 4, mtime = 1,
}
Assert.eq(Dumps.verify(escaped), "out_of_scope")
Assert.is_false(Dumps.remove(escaped))
Assert.eq(lfs.attributes(outside .. "/Indexer_Dump_222.txt", "mode"), "file")

-- 指向目录的条目不能删。
local dir_item = {
    path = root .. "/cvm_999_dir-name_should-not-match.core",
    root = root,
    name = "cvm_999_dir-name_should-not-match.core",
    size = 0, mtime = 0,
}
Assert.eq(Dumps.verify(dir_item), "not_file")
Assert.is_false((Dumps.remove(dir_item)))
Assert.eq(lfs.attributes(dir_item.path, "mode"), "directory")

-- 部分失败：一个被替换、一个消失、一个正常删除（仅测试夹具）。
local keep = names["cvm_10145_038-juno_120202_bourbon_wario-379151.core"]
local gone = names["Indexer_Dump_1794543178241.txt"]
local victim = names["cvm_1438_038-juno_120202_bourbon_wario-379151.core"]
writefile(keep.path, "replaced-content-is-longer-than-before")
os.remove(gone.path)
local result = Dumps.removeMany({ keep, gone, victim })
Assert.eq(#result.removed, 1)
Assert.eq(result.removed[1].name, victim.name)
Assert.eq(#result.errors, 2)
local err_by = {}
for _idx, one in ipairs(result.errors) do err_by[one.item.name] = one.err end
Assert.eq(err_by[keep.name], "replaced")
Assert.eq(err_by[gone.name], "missing")
Assert.eq(lfs.attributes(victim.path, "mode"), nil)
Assert.eq(lfs.attributes(keep.path, "mode"), "file")

-- os.remove 失败且事后 attributes 为空时不得谎报成功。
do
    local victim2_path = root .. "/Indexer_Dump_8888888888.txt"
    writefile(victim2_path, "x")
    local item = {
        path = victim2_path,
        root = root,
        name = "Indexer_Dump_8888888888.txt",
        size = 1,
        mtime = lfs.attributes(victim2_path, "modification"),
        ino = lfs.attributes(victim2_path, "ino"),
        dev = lfs.attributes(victim2_path, "dev"),
    }
    local real_remove, real_attrs = os.remove, lfs.symlinkattributes
    local attr_calls = 0
    os.remove = function() return nil, "eperm" end
    -- verify 用第一次真实 attributes；remove 后再查时假装文件已「看不见」
    lfs.symlinkattributes = function(path)
        attr_calls = attr_calls + 1
        if attr_calls == 1 then return real_attrs(path) end
        return nil
    end
    local ok, err = Dumps.remove(item)
    os.remove = real_remove
    lfs.symlinkattributes = real_attrs
    Assert.is_false(ok)
    Assert.eq(err, "failed")
    Assert.eq(lfs.attributes(victim2_path, "mode"), "file")
    os.remove(victim2_path)
end
Assert.eq(lfs.attributes(root .. "/notes.txt", "mode"), "file")
Assert.eq(lfs.attributes(nested .. "/Indexer_Dump_111.txt", "mode"), "file")

-- 删剩的仍能再扫出来。
Assert.is_true(Dumps.scan({ root }).count >= 1)

-- 清理夹具目录（不是用户设备）。
local function rm_tree(dir)
    for name in lfs.dir(dir) do
        if name ~= "." and name ~= ".." then
            local path = dir .. "/" .. name
            local mode = lfs.symlinkattributes(path, "mode")
            if mode == "directory" then rm_tree(path) else os.remove(path) end
        end
    end
    lfs.rmdir(dir)
end
rm_tree(root)
rm_tree(outside)
Dumps._roots = nil

return true
