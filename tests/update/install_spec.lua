--[[-- update.install：完整目录换位、校验与旧目录备份。 --]]

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

local Install = require("update.install")

local zip_file = assert(io.open(archive, "rb"))
local digest = sha256(assert(zip_file:read("*a")))
zip_file:close()

local ok, err = Install.run(archive, current, "1.2.3", digest)
Assert.is_true(ok, err)
Assert.is_nil(lfs.attributes(current .. "/stale.lua"), "旧版本残留文件必须消失")
Assert.eq(assert(loadfile(current .. "/nested/value.lua"))(), 42)
Assert.eq(assert(loadfile(tmp .. "/.book.koplugin-backup/main.lua"))(), "old")

-- 校验失败发生在换位前，当前目录不得被碰。
local bad_ok, bad_err = Install.run(archive, current, "1.2.3", string.rep("0", 64))
Assert.is_nil(bad_ok)
Assert.matches(bad_err, "checksum mismatch")
Assert.eq(assert(loadfile(current .. "/main.lua"))(), "new")

os.execute("rm -rf " .. tmp)

return true
