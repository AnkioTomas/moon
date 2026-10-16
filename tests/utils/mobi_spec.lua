--[[--
utils.mobi.encrypted 与本地扫盘的 DRM 跳过：record0 偏移 12 的 encryption 非 0 即加密。
utils.mobi.cover / book.cover 兜底：按 EXTH 201 取封面记录（crengine 只认 JFIF，EXIF 开头的 JPEG 没封面）。

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

-- ── 封面：EXTH 201 → 第一个图片记录 + 偏移；EXIF 开头的 JPEG 也认 ──
do
    local function put(t, at, bytes) for i = 1, #bytes do t[at + i] = bytes:sub(i, i) end end
    local function book(path, opts)
        local r0 = {}
        for i = 1, 16 + 232 do r0[i] = "\0" end
        put(r0, 16, "MOBI")
        put(r0, 20, be(232, 4))
        put(r0, 0x6C, be(1, 4)) -- 第一个图片记录
        put(r0, 0x80, be(opts.exth == false and 0 or 0x50, 4))
        local exth = "EXTH" .. be(12 + 12, 4) .. be(1, 4) .. be(opts.type or 201, 4) .. be(12, 4) .. be(opts.offset or 1, 4)
        local record0 = table.concat(r0) .. exth
        local images = { "\137PNG-other", opts.image or ("\255\216\255\225EXIF-cover") }
        local recs = { record0, images[1], images[2] }
        local start = 78 + #recs * 8
        local pdb = string.rep("\0", 60) .. "BOOKMOBI" .. string.rep("\0", 8) .. be(#recs, 2)
        local off = start
        for _i, r in ipairs(recs) do pdb = pdb .. be(off, 4) .. be(0, 4); off = off + #r end
        local fh = assert(io.open(path, "wb"))
        fh:write(pdb, table.concat(recs))
        fh:close()
    end
    local p1 = dir .. "/cover_spec.mobi"
    book(p1, {})
    Assert.eq(Mobi.cover(p1), "\255\216\255\225EXIF-cover")
    book(p1, { offset = 0 })
    Assert.eq(Mobi.cover(p1), "\137PNG-other")
    book(p1, { type = 202 })
    Assert.is_nil(Mobi.cover(p1), "没有 201")
    book(p1, { exth = false })
    Assert.is_nil(Mobi.cover(p1), "EXTH 标记位没开")
    book(p1, { image = "not an image" })
    Assert.is_nil(Mobi.cover(p1), "记录不像图片")
    Assert.is_nil(Mobi.cover(junk), "不是 BOOKMOBI")
    Assert.is_nil(Mobi.cover(dir .. "/missing.mobi"))

    -- book.cover：引擎没给封面时走兜底，只对 mobi 族扩展名
    book(p1, {})
    local rendered
    package.loaded["ui/renderimage"] = { renderImageData = function(_self, data, size) rendered = { data, size }; return { tag = "bb" } end }
    local Cover = require("book.cover")
    local bb = Cover.mobiFallback({ file = p1 })
    Assert.eq(bb.tag, "bb")
    Assert.eq(rendered[1], "\255\216\255\225EXIF-cover")
    Assert.is_nil(Cover.mobiFallback({ file = dir .. "/x.epub" }))
    Assert.is_nil(Cover.mobiFallback({}))
    os.remove(p1)
end
