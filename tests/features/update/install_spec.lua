---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

--[[-- utils.plugin_install：完整目录换位、校验与旧目录备份。 --]]

local Assert = require("support.assert")
local Config = require("support.config")

if not Config.available() then
    Assert.skip("沙箱数据目录未就绪，请用 ./tests/run.sh 运行")
end

local lfs = require("libs/libkoreader-lfs")
local sha256 = require("ffi/sha2").sha256

local tmp = Config.dir() .. "/update-install"
local current = tmp .. "/book.koplugin"
local archive = tmp .. "/update.zip"

os.execute("rm -rf " .. tmp)
assert(lfs.mkdir(tmp))
assert(lfs.mkdir(current))

local function write(path, body)
    local file = assert(io.open(path, "wb"))
    assert(file:write(body))
    assert(file:close())
end

write(current .. "/main.lua", "return 'old'\n")
write(current .. "/stale.lua", "return true\n")
write(archive, "fake update archive")

local entries = {
    { path = "book.koplugin", mode = "directory", size = 0 },
    { path = "book.koplugin/main.lua", mode = "file", body = "return 'new'\n" },
    { path = "book.koplugin/bookversion.lua", mode = "file", body = 'return "1.2.3"\n' },
    { path = "book.koplugin/nested", mode = "directory", size = 0 },
    { path = "book.koplugin/nested/value.lua", mode = "file", body = "return 42\n" },
}
package.preload["ffi/archiver"] = function()
    local Reader = {}
    function Reader:new() return setmetatable({}, { __index = self }) end
    function Reader:open() return true end
    function Reader:close() end
    function Reader:iterate()
        local index = 0
        return function()
            index = index + 1
            local entry = entries[index]
            if entry then entry.size = entry.size or #entry.body end
            return entry
        end
    end
    function Reader:extractToPath(path, dest)
        local entry
        for _, candidate in ipairs(entries) do
            if candidate.path == path then entry = candidate break end
        end
        if entry.mode == "directory" then return lfs.mkdir(dest) end
        write(dest, entry.body)
        return true
    end
    return { Reader = Reader }
end

local Install = require("utils.plugin_install")

local zip_file = assert(io.open(archive, "rb"))
local digest = sha256(assert(zip_file:read("*a")))
zip_file:close()

local ok, err = Install.run(archive, tmp, digest, { name = "book.koplugin" })
Assert.is_true(ok, err)
Assert.is_nil(lfs.attributes(current .. "/stale.lua"), "旧版本残留文件必须消失")
Assert.eq(assert(loadfile(current .. "/nested/value.lua"))(), 42)
Assert.eq(assert(loadfile(tmp .. "/.book.koplugin-backup/main.lua"))(), "old")

-- 校验失败发生在换位前，当前目录不得被碰。
local bad_ok, bad_err = Install.run(archive, tmp, string.rep("0", 64), { name = "book.koplugin" })
Assert.is_nil(bad_ok)
Assert.matches(bad_err, "checksum mismatch")
Assert.eq(assert(loadfile(current .. "/main.lua"))(), "new")

-- 包里没有 book.koplugin/：换位失败回滚，当前目录原样恢复，暂存目录清掉。
entries = { { path = "other", mode = "directory", size = 0 } }
local wrong_ok, wrong_err = Install.run(archive, tmp, digest, { name = "book.koplugin" })
Assert.is_nil(wrong_ok)
Assert.not_nil(wrong_err)
Assert.eq(assert(loadfile(current .. "/main.lua"))(), "new")
Assert.is_nil(lfs.attributes(tmp .. "/.book.koplugin-update"))

-- 调用方的 verify 在换位前拒绝：当前目录不动，暂存目录清掉。
entries = {
    { path = "book.koplugin", mode = "directory", size = 0 },
    { path = "book.koplugin/main.lua", mode = "file", body = "return 'evil'\n" },
}
local verified
local foreign_ok, foreign_err = Install.run(archive, tmp, nil, {
    verify = function(name, staging)
        verified = lfs.attributes(staging .. "/" .. name .. "/main.lua", "mode")
        return "not a moon plugin archive"
    end,
})
Assert.eq(verified, "file", "verify 看到的是解压后的暂存目录")
Assert.is_nil(foreign_ok)
Assert.eq(foreign_err, "not a moon plugin archive")
Assert.eq(assert(loadfile(current .. "/main.lua"))(), "new")
Assert.is_nil(lfs.attributes(tmp .. "/.book.koplugin-update"))

-- 远程上传的包没有校验值：不做 SHA 校验，照常换位。
entries = {
    { path = "book.koplugin", mode = "directory", size = 0 },
    { path = "book.koplugin/main.lua", mode = "file", body = "return 'uploaded'\n" },
    { path = "book.koplugin/bookversion.lua", mode = "file", body = 'return "1.2.4"\n' },
}
local local_ok, local_name = Install.run(archive, tmp)
Assert.is_true(local_ok, local_name)
Assert.eq(local_name, "book.koplugin")
Assert.eq(assert(loadfile(current .. "/main.lua"))(), "uploaded")
Assert.eq(assert(loadfile(tmp .. "/.book.koplugin-backup/main.lua"))(), "new")

-- 其它插件：装到 book.koplugin 同级，不碰月读，也不动月读的备份。
assert(lfs.mkdir(tmp .. "/other.koplugin"))
write(tmp .. "/other.koplugin/main.lua", "return 'old-other'\n")
entries = {
    { path = "other.koplugin", mode = "directory", size = 0 },
    { path = "other.koplugin/main.lua", mode = "file", body = "return 'new-other'\n" },
}
local other_ok, other_name = Install.run(archive, tmp)
Assert.is_true(other_ok, other_name)
Assert.eq(other_name, "other.koplugin")
Assert.eq(assert(loadfile(tmp .. "/other.koplugin/main.lua"))(), "new-other")
Assert.eq(assert(loadfile(tmp .. "/.other.koplugin-backup/main.lua"))(), "old-other")
Assert.eq(assert(loadfile(current .. "/main.lua"))(), "uploaded")
Assert.eq(assert(loadfile(tmp .. "/.book.koplugin-backup/main.lua"))(), "new")

-- 目录还不存在：直接落位，不制造空备份。
entries = {
    { path = "fresh.koplugin", mode = "directory", size = 0 },
    { path = "fresh.koplugin/main.lua", mode = "file", body = "return 'fresh'\n" },
}
local fresh_ok, fresh_name = Install.run(archive, tmp)
Assert.is_true(fresh_ok, fresh_name)
Assert.eq(fresh_name, "fresh.koplugin")
Assert.eq(assert(loadfile(tmp .. "/fresh.koplugin/main.lua"))(), "fresh")
Assert.is_nil(lfs.attributes(tmp .. "/.fresh.koplugin-backup"))
Assert.eq(assert(loadfile(current .. "/main.lua"))(), "uploaded")

-- 顶层没有 .koplugin 目录（同名文件不算）：拒绝，已装的插件不动。
entries = { { path = "readme.koplugin", mode = "file", body = "nope\n" } }
local bare_ok, bare_err = Install.run(archive, tmp)
Assert.is_nil(bare_ok)
Assert.eq(bare_err, "not a koplugin archive")
Assert.eq(assert(loadfile(tmp .. "/other.koplugin/main.lua"))(), "new-other")
Assert.is_nil(lfs.attributes(tmp .. "/.book.koplugin-update"))

-- 顶层有两个插件目录：一个都不装。
entries = {
    { path = "a.koplugin", mode = "directory", size = 0 },
    { path = "b.koplugin", mode = "directory", size = 0 },
}
local multi_ok, multi_err = Install.run(archive, tmp)
Assert.is_nil(multi_ok)
Assert.eq(multi_err, "multiple koplugin directories")
Assert.eq(assert(loadfile(current .. "/main.lua"))(), "uploaded")
Assert.eq(assert(loadfile(tmp .. "/other.koplugin/main.lua"))(), "new-other")
Assert.is_nil(lfs.attributes(tmp .. "/a.koplugin"))
Assert.is_nil(lfs.attributes(tmp .. "/.book.koplugin-update"))

-- 指定顶层目录与安装目录：kamare 在线更新用（digest + name + parent）。
local extra = tmp .. "/extra-plugins"
assert(lfs.mkdir(extra))
assert(lfs.mkdir(extra .. "/kamare.koplugin"))
write(extra .. "/kamare.koplugin/main.lua", "return 'old-kamare'\n")
entries = {
    { path = "kamare.koplugin", mode = "directory", size = 0 },
    { path = "kamare.koplugin/kamarecache.lua", mode = "file", body = "return 42\n" },
}
local kamare_ok, kamare_name = Install.run(archive, extra, digest, { name = "kamare.koplugin" })
Assert.is_true(kamare_ok, kamare_name)
Assert.eq(kamare_name, "kamare.koplugin")
Assert.eq(assert(loadfile(extra .. "/kamare.koplugin/kamarecache.lua"))(), 42)
Assert.eq(assert(loadfile(extra .. "/.kamare.koplugin-backup/main.lua"))(), "old-kamare")
Assert.is_nil(lfs.attributes(extra .. "/.kamare.koplugin-update"), "kamare 暂存目录装完即删")
Assert.is_nil(lfs.attributes(extra .. "/.book.koplugin-update"), "kamare 不占用月读的暂存目录")
Assert.eq(assert(loadfile(tmp .. "/other.koplugin/main.lua"))(), "new-other", "装到指定目录时不动月读与其它插件")

-- 指定目录名对不上：整包拒绝，旧目录不动。
entries = {
    { path = "other.koplugin", mode = "directory", size = 0 },
    { path = "other.koplugin/main.lua", mode = "file", body = "return 'wrong'\n" },
}
local named_ok, named_err = Install.run(archive, extra, digest, { name = "kamare.koplugin" })
Assert.is_nil(named_ok)
Assert.eq(named_err, "not a koplugin archive")
Assert.is_nil(lfs.attributes(extra .. "/.kamare.koplugin-update"))
Assert.eq(assert(loadfile(extra .. "/kamare.koplugin/kamarecache.lua"))(), 42)

os.execute("rm -rf " .. tmp)

return true
