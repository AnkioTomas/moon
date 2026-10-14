--[[--
utils.mobi.encrypted 与本地扫盘的 DRM 跳过：record0 偏移 12 的 encryption 非 0 即加密。

@module tests.utils.mobi_spec
--]]

local Assert = require("support.assert")
local Config = require("support.config")

local function be(n, width)
    local out = {}
    for i = width, 1, -1 do
        out[i] = string.char(n % 256)
        n = math.floor(n / 256)
    end
    return table.concat(out)
end

--- 最小 BOOKMOBI：PalmDB 头 + 一节 record0（PalmDOC 头 16 字节 + "MOBI" + 填充）。
local function mobi(path, encryption)
    local pdb = string.rep("\0", 60) .. "BOOKMOBI" .. string.rep("\0", 8) .. be(1, 2)
    local record0 = be(2, 2) .. be(0, 2) .. be(0, 4) .. be(0, 2) .. be(0, 2) .. be(encryption, 2) .. be(0, 2)
        .. "MOBI" .. be(232, 4) .. be(2, 4) .. be(65001, 4) .. be(0, 4) .. be(6, 4) .. string.rep("\0", 200)
    local f = assert(io.open(path, "wb"))
    f:write(pdb, be(78 + 8, 4), be(0, 4), record0)
    f:close()
end

local dir = Config.dir()
local plain, locked, junk = dir .. "/drm_spec_a.azw3", dir .. "/drm_spec_b.mobi", dir .. "/drm_spec_c.azw"
mobi(plain, 0)
mobi(locked, 2)
local f = assert(io.open(junk, "wb")); f:write("not a mobi"); f:close()

local Mobi = require("utils.mobi")
Assert.is_false(Mobi.encrypted(plain))
Assert.is_true(Mobi.encrypted(locked))
Assert.is_false(Mobi.encrypted(junk)) -- 读坏了当未加密
Assert.is_false(Mobi.encrypted(dir .. "/drm_spec_missing.mobi"))

local Common = require("source.local.common")
Assert.is_true(Common.isDrmMobi("b.mobi", locked))
Assert.is_false(Common.isDrmMobi("a.azw3", plain))
Assert.is_false(Common.isDrmMobi("b.epub", locked)) -- 只看 mobi 族扩展名

for _idx, p in ipairs({ plain, locked, junk }) do os.remove(p) end
