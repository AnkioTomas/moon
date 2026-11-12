--[[--
utils.image：后缀与文件头。
@module tests.utils.image_spec
--]]

local Assert = require("support.assert")
local Image = require("utils.image")

local PNG = "\137PNG\r\n\26\nxxxx"
local JPEG = "\255\216\255xxxx"
local GIF = "GIF89axxxx"
local WEBP = "RIFF....WEBPxxxx"
local BMP = "BMxxxx"
local SVG = "<svg xmlns='http://www.w3.org/2000/svg'></svg>"

do -- 文件头
    Assert.eq(Image.ext(JPEG), ".jpg")
    Assert.eq(select(2, Image.ext(JPEG)), "image/jpeg")
    Assert.eq(Image.ext(PNG), ".png")
    Assert.eq(Image.ext(GIF), ".gif")
    Assert.eq(Image.ext(WEBP), ".webp")
    Assert.eq(Image.ext(BMP), ".bmp")
    Assert.eq(Image.ext(SVG), ".svg")
    Assert.is_nil(Image.ext("RIFF....WAVE"))
    Assert.is_nil(Image.ext("<html>error</html>"))
    Assert.is_nil(Image.ext(""))
    Assert.is_nil(Image.ext(nil))
end

do -- 路径 / URL 后缀
    Assert.eq(Image.suffix("a.PNG"), ".png")
    Assert.eq(Image.suffix("https://x.test/a.JPEG?w=1"), ".jpg")
    Assert.eq(Image.suffix("a.webp#hash"), ".webp")
    Assert.is_nil(Image.suffix("a.txt"))
    Assert.is_nil(Image.suffix("noext"))
    Assert.is_nil(Image.suffix(nil))
end

do -- 打开文件读头
    local dir = (os.getenv("TMPDIR") or "/tmp") .. "/moon-image-spec"
    os.execute("mkdir -p '" .. dir .. "'")
    local path = dir .. "/x.bin"
    local file = assert(io.open(path, "wb"))
    file:write(PNG)
    file:close()
    Assert.is_true(Image.ok(path))
    Assert.eq(Image.file(path), ".png")
    file = assert(io.open(path, "wb"))
    file:write("<html>")
    file:close()
    Assert.is_false(Image.ok(path))
    Assert.is_false(Image.ok(dir .. "/missing.png"))
    os.execute("rm -rf '" .. dir .. "'")
end


do -- 文件头宽高
    local function be16(n) return string.char(math.floor(n / 256), n % 256) end
    local function be32(n)
        return be16(math.floor(n / 65536)) .. be16(n % 65536)
    end
    local function le16(n) return string.char(n % 256, math.floor(n / 256)) end
    local function le24(n)
        return string.char(n % 256, math.floor(n / 256) % 256, math.floor(n / 65536) % 256)
    end
    local function le32(n)
        n = n % 4294967296
        return le16(n % 65536) .. le16(math.floor(n / 65536))
    end

    local png = "\137PNG\r\n\26\n" .. be32(13) .. "IHDR" .. be32(70) .. be32(80) .. "\8\2\0\0\0\0\0\0\0"
    Assert.eq(Image.size(png), 70)
    Assert.eq(select(2, Image.size(png)), 80)
    Assert.is_nil(Image.size(PNG)) -- 现有短文件头不够解析宽高

    local jpeg = "\255\216\255\192" .. be16(11) .. "\8" .. be16(80) .. be16(70) .. "\1\1\17\0"
    Assert.eq(Image.size(jpeg), 70)
    Assert.eq(select(2, Image.size(jpeg)), 80)
    local app0 = "\255\216\255\224" .. be16(16) .. string.rep("x", 14) .. "\255\192" .. be16(11) .. "\8" .. be16(40) .. be16(30)
    Assert.eq(Image.size(app0), 30)
    Assert.eq(select(2, Image.size(app0)), 40)

    local gif = "GIF89a" .. le16(70) .. le16(80)
    Assert.eq(Image.size(gif), 70)
    Assert.eq(select(2, Image.size(gif)), 80)

    local bmp = "BM" .. string.rep("\0", 16) .. le32(70) .. le32(80)
    Assert.eq(Image.size(bmp), 70)
    Assert.eq(select(2, Image.size(bmp)), 80)
    local bmp_neg = "BM" .. string.rep("\0", 16) .. le32(70) .. le32(4294967216) -- -80
    Assert.eq(select(2, Image.size(bmp_neg)), 80)

    local webp = "RIFF....WEBPVP8X" .. le32(10) .. "\0\0\0\0" .. le24(69) .. le24(79)
    Assert.eq(Image.size(webp), 70)
    Assert.eq(select(2, Image.size(webp)), 80)

    local bits = 69 + 79 * 16384
    local vp8l = "RIFF....WEBPVP8L" .. le32(5) .. "\47" .. le32(bits)
    Assert.eq(Image.size(vp8l), 70)
    Assert.eq(select(2, Image.size(vp8l)), 80)

    Assert.is_nil(Image.size(""))
    Assert.is_nil(Image.size(nil))
    Assert.is_nil(Image.dimensions(nil))
    Assert.is_nil(Image.dimensions("/no/such/file"))
end

do -- 从文件读宽高
    local dir = (os.getenv("TMPDIR") or "/tmp") .. "/moon-image-size-spec"
    os.execute("mkdir -p '" .. dir .. "'")
    local path = dir .. "/a.png"
    local function be16(n) return string.char(math.floor(n / 256), n % 256) end
    local function be32(n)
        return be16(math.floor(n / 65536)) .. be16(n % 65536)
    end
    local png = "\137PNG\r\n\26\n" .. be32(13) .. "IHDR" .. be32(12) .. be32(34) .. "\8\2\0\0\0\0\0\0\0"
    local file = assert(io.open(path, "wb"))
    file:write(png)
    file:close()
    Assert.eq(Image.dimensions(path), 12)
    Assert.eq(select(2, Image.dimensions(path)), 34)
    os.execute("rm -rf '" .. dir .. "'")
end

return true
