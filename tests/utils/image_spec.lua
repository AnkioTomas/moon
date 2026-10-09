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

return true
