--[[--
基准 JPEG 条带抽取：按 MCU 行无损切出更矮的 JPEG。

@module tests.source.cbz_jpeg_band_spec
--]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")
Stubs.install()

local Band = require("source.cbz_jpeg_band")

local function read(path)
    local file = assert(io.open(path, "rb"))
    local data = file:read("*a")
    file:close()
    return data
end

local function sofHeight(data)
    local i = 3
    while i < #data - 8 do
        if data:byte(i) ~= 0xFF then return nil end
        local marker = data:byte(i + 1)
        if marker == 0xC0 then
            return data:byte(i + 5) * 256 + data:byte(i + 6)
        end
        if marker == 0xDA or marker == 0xD9 then return nil end
        if marker >= 0xD0 and marker <= 0xD8 then
            i = i + 2
        else
            local len = data:byte(i + 2) * 256 + data:byte(i + 3)
            i = i + 2 + len
        end
    end
    return nil
end

local root = "tests/fixtures/cbz_fit"

do -- 能读出尺寸和 MCU 高度
    local info = Band.info(read(root .. "/color420.jpg"))
    Assert.not_nil(info)
    Assert.eq(info.width, 48)
    Assert.eq(info.height, 160)
    Assert.eq(info.mcu_w, 16)
    Assert.eq(info.mcu_h, 16)
end

do -- 灰度图 MCU 高为 8
    local info = Band.info(read(root .. "/gray.jpg"))
    Assert.not_nil(info)
    Assert.eq(info.width, 48)
    Assert.eq(info.height, 160)
    Assert.eq(info.mcu_h, 8)
end

do -- 抽出的条带覆盖请求区间，并按 MCU 对齐
    local data = read(root .. "/color420.jpg")
    local jpeg, y, h = Band.extract(data, 20, 30)
    Assert.not_nil(jpeg)
    Assert.eq(y, 16)
    -- 20..50 对齐到 MCU 行 16..64
    Assert.eq(h, 48)
    Assert.eq(sofHeight(jpeg), 48)
    local info = Band.info(jpeg)
    Assert.not_nil(info)
    Assert.eq(info.width, 48)
    Assert.eq(info.height, 48)
end

do -- 整图抽取保持原高度
    local data = read(root .. "/odd.jpg")
    local info = Band.info(data)
    Assert.eq(info.width, 50)
    Assert.eq(info.height, 100)
    local jpeg, y, h = Band.extract(data, 0, 100)
    Assert.eq(y, 0)
    Assert.eq(h, 100)
    Assert.eq(sofHeight(jpeg), 100)
end

do -- 末尾不足一个 MCU 时 SOF 高度不写出填充行
    local data = read(root .. "/odd.jpg")
    local jpeg, y, h = Band.extract(data, 96, 4)
    Assert.eq(y, 96)
    Assert.eq(h, 4)
    Assert.eq(sofHeight(jpeg), 4)
end

do -- 渐进 JPEG 和不完整数据返回 nil
    Assert.is_nil(Band.extract(read(root .. "/progressive.jpg"), 0, 16))
    Assert.is_nil(Band.info("not-a-jpeg"))
    Assert.is_nil(Band.extract("\255\216\255", 0, 8))
    Assert.is_nil(Band.extract(read(root .. "/color420.jpg"), -1, 16))
    Assert.is_nil(Band.extract(read(root .. "/color420.jpg"), 160, 16))
end

return true
