--[[--
漫画 CBZ 开书默认：不裁边、整页按宽度连续滚动、页间距为 0，避免切片错层和灰缝。

@module tests.reader.comic_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

local Assert = require("support.assert")

-- injectComic 不读这些，但 prefs.lua 模块加载时会 require。
_G.G_reader_settings = {
    data = {},
    readSetting = function() end,
    has = function() return false end,
    saveSetting = function() end,
    delSetting = function() end,
    flush = function() end,
}
package.preload["book.books_db"] = function()
    return { getReaderPrefs = function() end, setReaderPrefs = function() end, mergeReaderPrefs = function() end }
end
package.preload["ui.fonts"] = function()
    return { faceNameForId = function() end, faceForId = function() end }
end
package.preload["ui.fonts.reader"] = function()
    return { supports = function() return false end }
end
package.preload["book.store"] = function()
    return { ensureIdentity = function() end, identityFor = function() end }
end
package.preload["utils.log"] = function()
    return { warn = function() end }
end

local ReaderPrefs = require("reader.prefs")

local function sidecar(data)
    data = data or {}
    return {
        data = data,
        readSetting = function(self, key) return self.data[key] end,
        saveSetting = function(self, key, value) self.data[key] = value end,
        delSetting = function(self, key) self.data[key] = nil end,
    }
end

-- PDF 和其他格式不改。
local pdf = sidecar()
Assert.is_false(ReaderPrefs.injectComic(pdf, { file = "/books/scan.pdf" }))
Assert.is_nil(next(pdf.data))
Assert.is_false(ReaderPrefs.injectComic(sidecar(), { file = "/books/ch.html" }))
Assert.is_false(ReaderPrefs.injectComic(sidecar(), { file = "/books/ch.epub" }))
Assert.is_false(ReaderPrefs.injectComic(sidecar(), {}))
Assert.is_false(ReaderPrefs.injectComic(sidecar(), nil))

-- 新开的 CBZ/CBT 写入整页宽度缩放、不裁边、连续滚动、页间距 0。
local cbz = sidecar()
Assert.is_true(ReaderPrefs.injectComic(cbz, { file = "/cache/kuaikan/4783.CBZ" }))
Assert.eq(cbz.data.kopt_trim_page, 3)
Assert.eq(cbz.data.kopt_zoom_mode_genus, 4)
Assert.eq(cbz.data.kopt_zoom_mode_type, 1)
Assert.eq(cbz.data.kopt_page_scroll, 1)
Assert.eq(cbz.data.kopt_page_gap_height, 0)
Assert.eq(cbz.data.zoom_mode, "pagewidth")
Assert.is_true(cbz.data.book_comic_cbz_fit)
Assert.is_true(cbz.data.book_comic_cbz_nogap)

local cbt = sidecar()
Assert.is_true(ReaderPrefs.injectComic(cbt, { file = "/x/vol.cbt" }))
Assert.eq(cbt.data.kopt_trim_page, 3)
Assert.eq(cbt.data.kopt_page_gap_height, 0)

-- 已经种过对齐和去缝标记的 sidecar 尊重用户后来改的 kopt，不再覆盖。
cbz.data.kopt_trim_page = 1
cbz.data.zoom_mode = "contentwidth"
cbz.data.kopt_page_gap_height = 16
Assert.is_false(ReaderPrefs.injectComic(cbz, { file = "/cache/kuaikan/4783.CBZ" }))
Assert.eq(cbz.data.kopt_trim_page, 1)
Assert.eq(cbz.data.zoom_mode, "contentwidth")
Assert.eq(cbz.data.kopt_page_gap_height, 16)

-- 旧 sidecar 带着 KOReader 的 auto-crop / contentwidth 默认值时，仍要改过来一次。
local legacy = sidecar({
    kopt_trim_page = 1,
    kopt_zoom_mode_genus = 3,
    kopt_zoom_mode_type = 1,
    zoom_mode = "contentwidth",
})
Assert.is_true(ReaderPrefs.injectComic(legacy, { file = "/cache/kuaikan/4783.cbz" }))
Assert.eq(legacy.data.kopt_trim_page, 3)
Assert.eq(legacy.data.kopt_zoom_mode_genus, 4)
Assert.eq(legacy.data.zoom_mode, "pagewidth")
Assert.eq(legacy.data.kopt_page_gap_height, 0)
Assert.is_true(legacy.data.book_comic_cbz_fit)
Assert.is_true(legacy.data.book_comic_cbz_nogap)

-- 上一版只种了对齐标记的 sidecar：只补页间距，不改用户后来的缩放/裁边。
local fitted = sidecar({
    book_comic_cbz_fit = true,
    kopt_trim_page = 1,
    kopt_zoom_mode_genus = 3,
    zoom_mode = "contentwidth",
    kopt_page_scroll = 0,
    kopt_page_gap_height = 8,
})
Assert.is_true(ReaderPrefs.injectComic(fitted, { file = "/cache/kuaikan/4783.cbz" }))
Assert.eq(fitted.data.kopt_page_gap_height, 0)
Assert.is_true(fitted.data.book_comic_cbz_nogap)
Assert.eq(fitted.data.kopt_trim_page, 1)
Assert.eq(fitted.data.kopt_zoom_mode_genus, 3)
Assert.eq(fitted.data.zoom_mode, "contentwidth")
Assert.eq(fitted.data.kopt_page_scroll, 0)
Assert.is_false(ReaderPrefs.injectComic(fitted, { file = "/cache/kuaikan/4783.cbz" }))
Assert.eq(fitted.data.kopt_page_gap_height, 0)
