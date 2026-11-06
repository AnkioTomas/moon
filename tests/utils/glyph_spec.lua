--[[--
直角引号跨字体版本的外框偏移不能导致正文识别失败；不放宽圆点与横线的位置判定。

@module tests.utils.glyph_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch

local Assert = require("support.assert")
local Config = require("support.config")
local Text = require("utils.text")
local ffi = require("ffi")
local pixels = ffi.new("uint8_t[256]")
for y = 0, 15 do
    for x = 0, 15 do
        if (x >= 12 and y <= 13) or (y >= 12 and x >= 2) then pixels[y * 16 + x] = 255 end
    end
end
local shape = {
    bb = {
        data = pixels, stride = 16,
        getWidth = function() return 16 end,
        getHeight = function() return 16 end,
    },
}
local reference_code, encoded_code = 0x300D, 0x8FD8
local source_top = 30
package.preload["ffi/freetype"] = function()
    return { newFaceSize = function(path)
        local ref = path == "reference"
        return {
            hasGlyph = function(_self, cp) return cp == (ref and reference_code or encoded_code) end,
            renderGlyph = function(_self, cp)
                if cp ~= (ref and reference_code or encoded_code) then error("missing glyph") end
                return { bb = shape.bb, l = 2, t = ref and 40 or source_top }
            end,
        }
    end }
end

local cache = Config.dir() .. "/glyph-reference-test.bin"
local count = #Text.chars(require("utils.glyph_chars"))
local file = assert(io.open(cache, "wb"))
file:write(string.rep("\0", count * (16 * 16 + 8 * 8)))
file:close()
local Glyph = require("utils.glyph")
local function recognize()
    return Glyph.recognize("reference", cache, {
        { font_path = "encoded", codes = { encoded_code }, limit = count },
    })[1][encoded_code]
end
Assert.eq(recognize(), "」", "外框偏移但形状相同，仍能认回直角引号")
source_top = 40
Assert.eq(recognize(), "」", "已有外框匹配路径保持不变")
os.remove(cache)
