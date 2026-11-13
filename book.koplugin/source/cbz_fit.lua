--[[--
漫画页打包时按设备屏宽缩小、过高的图切成约一两屏高的切片。
切片各自作为 CBZ 里的一页，阅读器不会再拼回一张大图。所有漫画源共用。

缩放只缩小不放大。切分按行对齐，并把剩余高度均分，避免最后一片过短。
解码按一张源图进行，优先用 TurboJPEG 裁切条带，避免整条长图进内存。
没有裁切符号时改为无损抽出 JPEG 条带再解压，仍然按条带占用内存。

@module koplugin.book.source.cbz_fit
--]]

local Image = require("utils.image")
local lfs = require("libs/libkoreader-lfs")
local _ = require("gettext")

local Fit = {}

--- 切片最大高度：两个屏幕高。Voyage 全宽 8bit 位图加翻页预渲染仍远低于整机内存。
Fit.MAX_SCREENS = 2
--- 单次解码（整图或一条带）允许占用的像素字节上限。
Fit.DECODE_BUDGET = 16 * 1024 * 1024
--- 写出切片用的 JPEG 质量。
Fit.JPEG_QUALITY = 85

--- 测试可替换的解码 / 编码后端；生产路径走 defaultBackend。
---@type table|nil
Fit.backend = nil

-- libjpeg-turbo 官方缩放比，按从大到小排列，选用仍不小于目标宽度的最小一档。
local JPEG_SCALES = {
    { 2, 1 }, { 15, 8 }, { 7, 4 }, { 13, 8 }, { 3, 2 }, { 11, 8 }, { 5, 4 }, { 9, 8 },
    { 1, 1 }, { 7, 8 }, { 3, 4 }, { 5, 8 }, { 1, 2 }, { 3, 8 }, { 1, 4 }, { 1, 8 },
}

---@return integer|nil w
---@return integer|nil h
function Fit.screen()
    local ok, Device = pcall(require, "device")
    if not ok or type(Device) ~= "table" or type(Device.screen) ~= "table" then return nil end
    local w = tonumber(Device.screen.getWidth and Device.screen:getWidth())
    local h = tonumber(Device.screen.getHeight and Device.screen:getHeight())
    if not w or not h or w < 1 or h < 1 then return nil end
    return math.floor(w), math.floor(h)
end

---@return boolean
local function colorScreen()
    local ok, Device = pcall(require, "device")
    return ok and type(Device) == "table" and Device.hasColorScreen and Device:hasColorScreen() or false
end

--- 分页文件名，四位序号，保证连续滚动时按文件名从上到下排。
---@param index integer
---@param ext string|nil
---@return string
function Fit.pageName(index, ext)
    ext = ext or ".jpg"
    if ext:sub(1, 1) ~= "." then ext = "." .. ext end
    if ext == ".jpeg" then ext = ".jpg" end
    return string.format("%04d%s", index, ext)
end

--- 按屏宽缩小（不放大），再把高于约两屏的图均分成若干片。
---@param src_w integer
---@param src_h integer
---@param screen_w integer|nil
---@param screen_h integer|nil
---@return { width: integer, height: integer, slices: { y: integer, h: integer }[] }|nil plan
---@return string|nil err
function Fit.plan(src_w, src_h, screen_w, screen_h)
    src_w = math.floor(tonumber(src_w) or 0)
    src_h = math.floor(tonumber(src_h) or 0)
    screen_w = math.floor(tonumber(screen_w) or 0)
    screen_h = math.floor(tonumber(screen_h) or 0)
    if src_w < 1 or src_h < 1 then return nil, _("无法读取漫画图片") end
    local out_w, out_h = src_w, src_h
    if screen_w > 0 and src_w > screen_w then
        out_w = screen_w
        out_h = math.max(1, math.floor(src_h * screen_w / src_w + 0.5))
    end
    local max_h = screen_h > 0 and (screen_h * Fit.MAX_SCREENS) or out_h
    if max_h < 1 then max_h = out_h end
    ---@type { y: integer, h: integer }[]
    local slices = {}
    if out_h <= max_h then
        slices[1] = { y = 0, h = out_h }
    else
        local n = math.ceil(out_h / max_h)
        local y = 0
        for i = 1, n do
            local remain = n - i + 1
            local h = math.floor((out_h - y) / remain)
            slices[i] = { y = y, h = h }
            y = y + h
        end
    end
    return { width = out_w, height = out_h, slices = slices }
end

--- 源图是否需要缩小或切片。
---@param src_w integer
---@param src_h integer
---@param screen_w integer|nil
---@param screen_h integer|nil
---@return boolean
---@return { width: integer, height: integer, slices: { y: integer, h: integer }[] }|nil plan
function Fit.needed(src_w, src_h, screen_w, screen_h)
    local plan = Fit.plan(src_w, src_h, screen_w, screen_h)
    if not plan then return false, nil end
    return plan.width ~= src_w or #plan.slices > 1, plan
end

---@param path string
---@param data string|nil
---@return integer|nil w
---@return integer|nil h
function Fit.dimensions(path, data)
    if type(data) == "string" then
        local w, h = Image.size(data)
        if w then return w, h end
    end
    return Image.dimensions(path)
end

---@param dir string
---@return boolean
---@return string|nil
local function ensureDir(dir)
    local attr = lfs.attributes(dir)
    if attr and attr.mode == "directory" then return true end
    if attr then return false, _("无法保存漫画文件") end
    local parent = dir:match("(.+)/[^/]+$")
    if parent and parent ~= dir then
        local ok, err = ensureDir(parent)
        if not ok then return false, err end
    end
    local ok, err = lfs.mkdir(dir)
    if not ok then return false, err or _("无法保存漫画文件") end
    return true
end

local function freeBB(bb)
    if bb and bb.free then pcall(function() bb:free() end) end
end

---@param bb table
---@param path string
---@return boolean
---@return string|nil
local function encodeSlice(bb, path)
    local ok, err = pcall(function()
        local BB = require("ffi/blitbuffer")
        local typ = bb.getType and bb:getType()
        local out = bb
        if typ == BB.TYPE_BB8 or typ == BB.TYPE_BB8A then
            out = BB.new(bb:getWidth(), bb:getHeight(), BB.TYPE_BBRGB24)
            out:blitFrom(bb)
        end
        local wrote = out:writeToFile(path, "jpg", Fit.JPEG_QUALITY)
        if out ~= bb then freeBB(out) end
        if wrote == false then error("jpeg encode failed") end
    end)
    if ok then
        local size = tonumber(lfs.attributes(path, "size")) or 0
        if size > 0 then return true end
        os.remove(path)
        err = _("无法写入漫画文件")
    end
    ok, err = pcall(function()
        local png = path:gsub("%.jpe?g$", ".png")
        bb:writePNG(png)
        if png ~= path then
            os.remove(path)
            os.rename(png, path)
        end
    end)
    if ok and (tonumber(lfs.attributes(path, "size")) or 0) > 0 then return true end
    os.remove(path)
    return false, type(err) == "string" and err or _("无法写入漫画文件")
end

---@param src table
---@param x integer
---@param y integer
---@param w integer
---@param h integer
---@return table|nil
local function cropBB(src, x, y, w, h)
    local BB = require("ffi/blitbuffer")
    local slice = BB.new(w, h, src:getType())
    slice:blitFrom(src, 0, 0, x, y, w, h)
    return slice
end

---@param bb table
---@param w integer
---@param h integer
---@return table
local function scaleBB(bb, w, h)
    if bb:getWidth() == w and bb:getHeight() == h then return bb end
    local ok, scaled = pcall(function()
        return require("ffi/mupdf").scaleBlitBuffer(bb, w, h)
    end)
    if ok and scaled then
        if scaled ~= bb then freeBB(bb) end
        return scaled
    end
    local RenderImage = require("ui/renderimage")
    scaled = RenderImage:scaleBlitBuffer(bb, w, h, true)
    return scaled or bb
end

-- TurboJPEG 裁切 / 缩放是 3.1+ 才有的符号，KOReader 的 FFI 头文件也没声明。
-- Android / Kindle 的 monolibtic 只导出 turbojpeg_decl.c 里的符号，
-- 直接取 tj3SetCroppingRegion 会在 __index 抛 undefined symbol。
local turbo_ready = false
local turbo_ok = false
local turbo_crop = false
local turbo_scale = false
local tj = nil

--- 测试可替换：自行加载 TurboJPEG 库。生产路径不要设置。
---@type (fun(): any)|nil
Fit.turboLoader = nil
--- 测试可替换：覆盖能力探测结果。生产路径不要设置。
---@type { ok: boolean, crop: boolean, scale: boolean, lib: any }|nil
Fit.turboOverride = nil

function Fit.resetTurbo()
    turbo_ready = false
    turbo_ok = false
    turbo_crop = false
    turbo_scale = false
    tj = nil
end

---@param lib any
---@param name string
---@return boolean
local function hasCSymbol(lib, name)
    if lib == nil or type(name) ~= "string" then return false end
    local ok, value = pcall(function()
        return lib[name]
    end)
    return ok and value ~= nil
end

---@return boolean
local function bindTurbo()
    if turbo_ready then return turbo_ok end
    turbo_ready = true
    pcall(function() require("ffi/turbojpeg_h") end)
    if Fit.turboOverride then
        turbo_ok = not not Fit.turboOverride.ok
        turbo_crop = not not Fit.turboOverride.crop
        turbo_scale = not not Fit.turboOverride.scale
        if Fit.turboOverride.lib ~= nil then
            tj = Fit.turboOverride.lib
        end
        return turbo_ok
    end
    local ok, ffi = pcall(require, "ffi")
    if not ok then return false end
    pcall(function()
        ffi.cdef[[
            typedef struct { int x; int y; int w; int h; } tjregion;
            typedef struct { int num; int denom; } tjscalingfactor;
            int tj3SetScalingFactor(void *handle, tjscalingfactor scalingFactor);
            int tj3SetCroppingRegion(void *handle, tjregion croppingRegion);
        ]]
    end)
    local lib
    if Fit.turboLoader then
        local loaded, result = pcall(Fit.turboLoader)
        if not loaded or not result then return false end
        lib = result
    else
        local loaded
        loaded, lib = pcall(function()
            return ffi.loadlib("turbojpeg", "0.5.0", "turbojpeg", "0.4.0", "turbojpeg", "0.3.0", "turbojpeg")
        end)
        if not loaded or not lib then
            loaded, lib = pcall(function() return ffi.load("turbojpeg") end)
        end
        if not loaded or not lib then return false end
    end
    if not hasCSymbol(lib, "tj3Decompress8")
        or not hasCSymbol(lib, "tj3DecompressHeader")
        or not hasCSymbol(lib, "tj3Destroy")
        or not (hasCSymbol(lib, "tj3Init") or hasCSymbol(lib, "tj3InitVersion")) then
        return false
    end
    tj = lib
    turbo_crop = hasCSymbol(lib, "tj3SetCroppingRegion")
    turbo_scale = hasCSymbol(lib, "tj3SetScalingFactor")
    turbo_ok = true
    return true
end

--- 探测当前环境的 TurboJPEG 能力。缺符号时不会抛错。
---@return { ok: boolean, crop: boolean, scale: boolean }
function Fit.turboCaps()
    bindTurbo()
    return { ok = turbo_ok, crop = turbo_crop, scale = turbo_scale }
end

---@param src_w integer
---@param out_w integer
---@param band_src_h integer
---@param bpp integer
---@return integer num
---@return integer denom
local function jpegScale(src_w, out_w, band_src_h, bpp)
    local chosen_num, chosen_denom = 1, 1
    for i = 1, #JPEG_SCALES do
        local num, denom = JPEG_SCALES[i][1], JPEG_SCALES[i][2]
        local scaled_w = math.floor(src_w * num / denom)
        if scaled_w >= out_w then
            chosen_num, chosen_denom = num, denom
        end
    end
    -- 在仍不小于目标宽的档里，挑带宽内存最小的（也就是最小的那档，上面循环已落到最小）。
    local scaled_w = math.max(1, math.floor(src_w * chosen_num / chosen_denom))
    local scaled_h = math.max(1, math.floor(band_src_h * chosen_num / chosen_denom))
    if scaled_w * scaled_h * bpp > Fit.DECODE_BUDGET then
        -- 即使超预算也用这档：再小就要放大了。
    end
    return chosen_num, chosen_denom
end

---@return any|nil
local function tjInit()
    if hasCSymbol(tj, "tj3Init") then
        return tj.tj3Init(tj.TJINIT_DECOMPRESS)
    end
    if hasCSymbol(tj, "tj3InitVersion") then
        return tj.tj3InitVersion(tj.TJINIT_DECOMPRESS, tj.TURBOJPEG_VERSION_NUMBER)
    end
    return nil
end

---@param jpeg string
---@param color boolean
---@return table|nil bb
local function decompressJpegData(jpeg, color)
    if type(jpeg) ~= "string" or jpeg == "" or not bindTurbo() then return nil end
    local ffi = require("ffi")
    local BB = require("ffi/blitbuffer")
    local handle = tjInit()
    if handle == nil then return nil end
    local bb
    local ok = pcall(function()
        if tj.tj3DecompressHeader(handle, ffi.cast("const unsigned char*", jpeg), #jpeg) < 0 then
            error("jpeg header")
        end
        local dec_w = tj.tj3Get(handle, tj.TJPARAM_JPEGWIDTH)
        local dec_h = tj.tj3Get(handle, tj.TJPARAM_JPEGHEIGHT)
        if not dec_w or dec_w < 1 or not dec_h or dec_h < 1 then
            error("jpeg size")
        end
        if dec_w * dec_h * (color and 3 or 1) > Fit.DECODE_BUDGET then
            error("jpeg budget")
        end
        local typ = color and BB.TYPE_BBRGB24 or BB.TYPE_BB8
        local format = color and tj.TJPF_RGB or tj.TJPF_GRAY
        bb = BB.new(dec_w, dec_h, typ)
        if tj.tj3Decompress8(handle, ffi.cast("const unsigned char*", jpeg), #jpeg,
            ffi.cast("unsigned char*", bb.data), bb.stride, format) < 0 then
            error("jpeg decompress")
        end
    end)
    tj.tj3Destroy(handle)
    if not ok or not bb then
        freeBB(bb)
        return nil
    end
    return bb
end

---@param src_h integer
---@param plan { height: integer }
---@param slice { y: integer, h: integer }
---@return integer src_y
---@return integer src_band_h
local function sliceSourceBand(src_h, plan, slice)
    local scale_y = plan.height / src_h
    local src_y = math.floor(slice.y / scale_y + 0.5)
    local src_band_h = math.max(1, math.floor(slice.h / scale_y + 0.5))
    if src_y < 0 then src_y = 0 end
    if src_y + src_band_h > src_h then src_band_h = src_h - src_y end
    return src_y, src_band_h
end

--- 有 tj3SetCroppingRegion 时按条带裁切解码，尽量在库内完成缩小。
---@param data string
---@param src_w integer
---@param src_h integer
---@param plan { width: integer, height: integer }
---@param slice { y: integer, h: integer }
---@param color boolean
---@return table|nil bb
local function decodeJpegSliceCrop(data, src_w, src_h, plan, slice, color)
    local ffi = require("ffi")
    local BB = require("ffi/blitbuffer")
    local src_y, src_band_h = sliceSourceBand(src_h, plan, slice)
    if src_band_h < 1 then return nil end
    local bpp = color and 3 or 1
    local num, denom = 1, 1
    if turbo_scale then
        num, denom = jpegScale(src_w, plan.width, src_band_h, bpp)
    end
    local dec_w = math.max(1, math.floor(src_w * num / denom))
    local dec_y = math.floor(src_y * num / denom)
    local dec_h = math.max(1, math.floor(src_band_h * num / denom))
    local scaled_h = math.max(1, math.floor(src_h * num / denom))
    if dec_y + dec_h > scaled_h then
        dec_h = math.max(1, scaled_h - dec_y)
    end
    if dec_w * dec_h * bpp > Fit.DECODE_BUDGET then return nil end
    local handle = tjInit()
    if handle == nil then return nil end
    local bb
    local ok = pcall(function()
        if tj.tj3DecompressHeader(handle, ffi.cast("const unsigned char*", data), #data) < 0 then
            error("jpeg header")
        end
        if num ~= 1 or denom ~= 1 then
            local factor = ffi.new("tjscalingfactor", { num, denom })
            if tj.tj3SetScalingFactor(handle, factor) < 0 then
                error("jpeg scale")
            end
        end
        local region = ffi.new("tjregion", { 0, dec_y, dec_w, dec_h })
        if tj.tj3SetCroppingRegion(handle, region) < 0 then
            error("jpeg crop")
        end
        local typ = color and BB.TYPE_BBRGB24 or BB.TYPE_BB8
        local format = color and tj.TJPF_RGB or tj.TJPF_GRAY
        bb = BB.new(dec_w, dec_h, typ)
        if tj.tj3Decompress8(handle, ffi.cast("const unsigned char*", data), #data,
            ffi.cast("unsigned char*", bb.data), bb.stride, format) < 0 then
            error("jpeg decompress")
        end
    end)
    tj.tj3Destroy(handle)
    if not ok or not bb then
        freeBB(bb)
        return nil
    end
    return scaleBB(bb, plan.width, slice.h)
end

--- 没有裁切符号时：无损抽出 MCU 条带，再用已导出的 tj3Decompress8 解码。
--- 过宽的条带再按内存预算切成更矮的几段，避免整张长图进内存。
---@param data string
---@param src_w integer
---@param src_h integer
---@param plan { width: integer, height: integer }
---@param slice { y: integer, h: integer }
---@param color boolean
---@return table|nil bb
local function decodeJpegSliceBand(data, src_w, src_h, plan, slice, color)
    local Band = require("source.cbz_jpeg_band")
    local info = Band.info(data)
    if not info then return nil end
    local src_y, src_band_h = sliceSourceBand(src_h, plan, slice)
    if src_band_h < 1 then return nil end
    local bpp = color and 3 or 1
    local mcu_h = math.max(1, info.mcu_h)
    local max_pixels = math.max(1, math.floor(Fit.DECODE_BUDGET / (math.max(1, src_w) * bpp)))
    ---@type { bb: table, y: integer, h: integer }[]
    local pieces = {}
    local function abandon()
        for _, piece in ipairs(pieces) do
            freeBB(piece.bb)
        end
    end
    local y = src_y
    local src_end = src_y + src_band_h
    while y < src_end do
        local remain = src_end - y
        local top = 0
        if y >= mcu_h then
            top = mcu_h
        end
        local chunk_h = math.min(remain, math.max(1, max_pixels - top))
        if chunk_h < 1 then
            abandon()
            return nil
        end
        local ext_y = y - top
        local ext_h = chunk_h + top
        if ext_y + ext_h < src_h and ext_h + mcu_h <= max_pixels then
            ext_h = ext_h + mcu_h
        end
        local jpeg, ay, ah = Band.extract(data, ext_y, ext_h)
        if not jpeg or not ay or not ah then
            abandon()
            return nil
        end
        if ah * src_w * bpp > Fit.DECODE_BUDGET then
            abandon()
            return nil
        end
        local decoded = decompressJpegData(jpeg, color)
        if not decoded then
            abandon()
            return nil
        end
        local crop_y = y - ay
        local crop_h = math.min(src_end, ay + (decoded.getHeight and decoded:getHeight() or ah)) - y
        if crop_h > remain then crop_h = remain end
        if crop_y < 0 or crop_h < 1 or crop_y + crop_h > decoded:getHeight() then
            freeBB(decoded)
            abandon()
            return nil
        end
        local cropped = cropBB(decoded, 0, crop_y, decoded:getWidth(), crop_h)
        if cropped ~= decoded then freeBB(decoded) end
        if not cropped then
            abandon()
            return nil
        end
        pieces[#pieces + 1] = { bb = cropped, y = y, h = crop_h }
        local next_y = y + crop_h
        if next_y <= y then
            abandon()
            return nil
        end
        y = next_y
    end
    if #pieces == 0 then return nil end
    if #pieces == 1 and pieces[1].y == src_y and pieces[1].h == src_band_h then
        return scaleBB(pieces[1].bb, plan.width, slice.h)
    end
    local BB = require("ffi/blitbuffer")
    local typ = pieces[1].bb.getType and pieces[1].bb:getType()
    local out = BB.new(plan.width, slice.h, typ)
    for i, piece in ipairs(pieces) do
        local out_y = math.floor((piece.y - src_y) * slice.h / src_band_h + 0.5)
        local out_end = math.floor((piece.y + piece.h - src_y) * slice.h / src_band_h + 0.5)
        if i == 1 then out_y = 0 end
        if i == #pieces then out_end = slice.h end
        local out_h = math.max(1, out_end - out_y)
        if out_y + out_h > slice.h then
            out_h = slice.h - out_y
        end
        local scaled = scaleBB(piece.bb, plan.width, out_h)
        out:blitFrom(scaled, 0, out_y, 0, 0, plan.width, out_h)
        if scaled ~= piece.bb then freeBB(scaled) end
    end
    return out
end

---@param data string
---@param src_w integer
---@param src_h integer
---@param plan { width: integer, height: integer }
---@param slice { y: integer, h: integer }
---@param color boolean
---@return table|nil bb
local function decodeJpegSlice(data, src_w, src_h, plan, slice, color)
    if not bindTurbo() then return nil end
    if turbo_crop then
        local bb = decodeJpegSliceCrop(data, src_w, src_h, plan, slice, color)
        if bb then return bb end
    end
    return decodeJpegSliceBand(data, src_w, src_h, plan, slice, color)
end

---@param path string
---@param plan { width: integer, height: integer }
---@return table|nil bb
local function decodeFull(path, plan)
    local ok, image = pcall(function()
        local RenderImage = require("ui/renderimage")
        return RenderImage:renderImageFile(path, false, plan.width, plan.height)
    end)
    if ok and image then
        if image.getWidth and (image:getWidth() ~= plan.width or image:getHeight() ~= plan.height) then
            image = scaleBB(image, plan.width, plan.height)
        end
        return image
    end
    return nil
end

---@class CbzFitPage
---@field path string
---@field name string
---@field temp boolean

--- 把一张源图整理成 CBZ 页文件。不需要处理时直接引用原文件。
---@param path string
---@param dest_dir string
---@param start_index integer
---@param screen_w integer|nil
---@param screen_h integer|nil
---@return CbzFitPage[]|nil pages
---@return string|nil err
function Fit.materialize(path, dest_dir, start_index, screen_w, screen_h)
    local backend = Fit.backend
    if backend and backend.materialize then
        return backend.materialize(path, dest_dir, start_index, screen_w, screen_h)
    end
    local src_w, src_h
    if backend and backend.dimensions then
        src_w, src_h = backend.dimensions(path)
    else
        src_w, src_h = Fit.dimensions(path)
    end
    if not src_w or not src_h then
        -- 读不出尺寸就原样打包，避免因少见格式打断整章。
        local ext = Image.suffix(path) or Image.file(path) or ".jpg"
        return { { path = path, name = Fit.pageName(start_index, ext), temp = false } }
    end
    local plan, plan_err = Fit.plan(src_w, src_h, screen_w, screen_h)
    if not plan then return nil, plan_err end
    if plan.width == src_w and #plan.slices == 1 then
        local ext = Image.suffix(path) or Image.file(path) or ".jpg"
        return { { path = path, name = Fit.pageName(start_index, ext), temp = false } }
    end
    local ok_dir, dir_err = ensureDir(dest_dir)
    if not ok_dir then return nil, dir_err end

    if backend and backend.writeSlices then
        return backend.writeSlices(path, dest_dir, start_index, plan)
    end

    ---@type CbzFitPage[]
    local pages = {}
    local color = colorScreen()
    local data
    local ext = Image.file(path) or Image.suffix(path)
    if ext == ".jpg" then
        local handle = io.open(path, "rb")
        if handle then
            data = handle:read("*a")
            handle:close()
        end
    end

    local full
    local function sliceBB(slice)
        if data then
            local bb = decodeJpegSlice(data, src_w, src_h, plan, slice, color)
            if bb then return bb end
        end
        if not full then
            -- RenderImage / MuPDF 会先按源图像素解码，源图过大时不要走这条路径。
            local bpp = color and 3 or 1
            if src_w * src_h * bpp > Fit.DECODE_BUDGET
                or plan.width * plan.height * bpp > Fit.DECODE_BUDGET then
                return nil, _("无法读取漫画图片")
            end
            full = decodeFull(path, plan)
            if not full then return nil, _("无法读取漫画图片") end
        end
        return cropBB(full, 0, slice.y, plan.width, slice.h)
    end

    for i, slice in ipairs(plan.slices) do
        local bb, err = sliceBB(slice)
        if not bb then
            freeBB(full)
            for _idx, page in ipairs(pages) do os.remove(page.path) end
            return nil, err or _("无法读取漫画图片")
        end
        local name = Fit.pageName(start_index + i - 1, ".jpg")
        local dest = dest_dir .. "/" .. name
        local encoded, encode_err = encodeSlice(bb, dest)
        freeBB(bb)
        if not encoded then
            freeBB(full)
            for _idx, page in ipairs(pages) do os.remove(page.path) end
            os.remove(dest)
            return nil, encode_err
        end
        pages[i] = { path = dest, name = name, temp = true }
    end
    freeBB(full)
    data = nil
    collectgarbage("collect")
    return pages
end

return Fit
