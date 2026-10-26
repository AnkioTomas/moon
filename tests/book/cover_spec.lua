--[[-- book.cover：从已打开的文档提取封面落盘。 --]]

local Assert = require("support.assert")
local Paths = require("utils.paths")
local Cover = require("book.cover")

local dir = require("support.config").dir() .. "/cover-spec"
Paths.ensureDir(dir)
local target = dir .. "/c.png"
os.remove(target)

local function read(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

local asked, freed = 0, 0
local function doc(bb)
    return { getCoverPageImage = function() asked = asked + 1; return bb end }
end
local image = {
    getWidth = function() return 400 end,
    getHeight = function() return 600 end,
    writePNG = function(_, path)
        local f = assert(io.open(path, "wb"))
        f:write("png")
        f:close()
    end,
    free = function() freed = freed + 1 end,
}

-- 文档没有封面（txt 等）：不落文件。
Cover.save(doc(nil), target)
Assert.is_nil(read(target))

-- 取图抛错（引擎异常）：按无封面处理。
Cover.save({ getCoverPageImage = function() error("boom") end }, target)
Assert.is_nil(read(target))

-- 正常：写 PNG、释放位图、不留 .part。
Cover.save(doc(image), target)
Assert.eq(read(target), "png")
Assert.eq(freed, 1)
Assert.is_nil(read(target .. ".part"))

-- 已有封面（云端下载 / 刮削 / 用户设置）：不再打开取图，不覆盖。
asked = 0
local f = assert(io.open(target, "wb"))
f:write("remote")
f:close()
Cover.save(doc(image), target)
Assert.eq(asked, 0)
Assert.eq(read(target), "remote")

-- 写盘失败：清掉半成品，不留目标文件。
os.remove(target)
Cover.save(doc({ writePNG = function(_, path)
    local out = assert(io.open(path, "wb"))
    out:write("half")
    out:close()
    error("disk full")
end, free = function() end, getWidth = function() return 1 end, getHeight = function() return 1 end }), target)
Assert.is_nil(read(target))
Assert.is_nil(read(target .. ".part"))
os.remove(target)

-- 大封面：写盘前把最长边缩到 600，原图释放，只写缩小后的那张。
local scaled_to
local small = { writePNG = image.writePNG, free = function() freed = freed + 1 end,
    getWidth = function() return 400 end, getHeight = function() return 600 end }
package.loaded["ffi/mupdf"] = { scaleBlitBuffer = function(_bb, w, h) scaled_to = w .. "x" .. h; return small end }
freed = 0
Cover.save(doc({ getWidth = function() return 1600 end, getHeight = function() return 2400 end,
    writePNG = function() error("原图不该落盘") end, free = function() freed = freed + 1 end }), target)
Assert.eq(scaled_to, "400x600")
Assert.eq(read(target), "png")
Assert.eq(freed, 2, "原图与缩图都释放")
os.remove(target)

-- 清理缓存删掉了封面目录：补封面时自动重建目录。
local gone = dir .. "/cleared/image"
local gone_target = gone .. "/c.png"
os.remove(gone_target); os.remove(gone); os.remove(dir .. "/cleared")
Cover.save(doc(image), gone_target)
Assert.eq(read(gone_target), "png")
os.remove(gone_target); os.remove(gone); os.remove(dir .. "/cleared")
