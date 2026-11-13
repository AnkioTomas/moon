--[[--
漫画 CBZ 开书默认：不裁边、整页按宽度连续滚动、页间距为 0，避免切片错层和灰缝。

@module tests.reader.comic_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

local Assert = require("support.assert")
local JSON = require("support.json_stub")
package.preload["json"] = function() return JSON end

local global_data, saved = {}, {}
_G.G_reader_settings = {
    data = global_data,
    readSetting = function(_self, key) return global_data[key] end,
    has = function(_self, key) return global_data[key] ~= nil end,
    saveSetting = function(_self, key, value) global_data[key] = value end,
    delSetting = function(_self, key) global_data[key] = nil end,
    flush = function() end,
}
package.preload["book.books_db"] = function()
    return {
        getReaderPrefs = function(sid, stable_id) return saved[sid .. "\0" .. stable_id] end,
        setReaderPrefs = function(sid, stable_id, raw) saved[sid .. "\0" .. stable_id] = raw; return true end,
        mergeReaderPrefs = function(update)
            for key, raw in pairs(saved) do saved[key] = update(raw) end
            return true
        end,
    }
end
package.preload["ui.fonts"] = function()
    return { faceNameForId = function() end, faceForId = function() end }
end
package.preload["ui.fonts.reader"] = function()
    return { supports = function() return false end }
end
package.preload["book.store"] = function()
    return { ensureIdentity = function() end, identityFor = function(file)
        if file:match("^/cache/comic/") then
            return { source_id = "kuaikan", stable_id = "comic", chapter_idx = 2 }
        end
    end }
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

-- 没有月读标记的旧章也不能把明确选择的分页覆盖成连续。
local paged = sidecar({ kopt_page_scroll = 0 })
ReaderPrefs.injectComic(paged, { file = "/books/paged.cbz" })
Assert.eq(paged.data.kopt_page_scroll, 0)

-- 漫画没有 CRE 字体模块，仍须在切章前保存当前阅读模式，而不是旧 sidecar 值。
local identity = { source_id = "kuaikan", stable_id = "comic", chapter_idx = 1 }
local saves = 0
local ui = {
    document = { file = "/cache/comic/1.cbz", configurable = { page_scroll = 0 } },
    config = { options = { prefix = "kopt" } },
    doc_settings = sidecar({ kopt_page_scroll = 1 }),
    handleEvent = function(self, event)
        Assert.eq(event.handler, "onSaveSettings")
        saves = saves + 1
        self.doc_settings:saveSetting("kopt_page_scroll", self.document.configurable.page_scroll)
    end,
}
Assert.is_true(ReaderPrefs.captureAndSave(ui, identity))
Assert.eq(saves, 1)
Assert.eq(ReaderPrefs.load(identity).kopt.page_scroll, 0)
local next_chapter = sidecar()
ReaderPrefs.injectComic(next_chapter, { file = "/cache/comic/2.cbz" })
Assert.eq(next_chapter.data.kopt_page_scroll, 0, "新章节必须继承当前书的分页选择")
Assert.eq(next_chapter.data.zoom_mode, "pagewidth")
Assert.eq(next_chapter.data.kopt_page_gap_height, 0)
local old_chapter = sidecar({ book_comic_cbz_fit = true, book_comic_cbz_nogap = true, kopt_page_scroll = 1 })
ReaderPrefs.injectComic(old_chapter, { file = "/cache/comic/old.cbz" })
Assert.eq(old_chapter.data.kopt_page_scroll, 0, "已缓存章节的旧模式也不能压过全书偏好")
local other = sidecar()
ReaderPrefs.injectComic(other, { file = "/cache/other/1.cbz" })
Assert.eq(other.data.kopt_page_scroll, 1, "不能把某一本的选择变成全局默认")

-- 保存为默认与普通切章不同：更新全局和已有漫画模式，但不清掉 CRE 排版。
saved["moon\0novel"] = JSON.encode({ copt = { font_size = 22 }, font_face = "Novel Font" })
ui.document.configurable.page_scroll = 1
Assert.is_true(ReaderPrefs.saveDefaults(ui))
Assert.eq(global_data.kopt_page_scroll, 1)
Assert.eq(ReaderPrefs.load(identity).kopt.page_scroll, 1)
Assert.eq(JSON.decode(saved["moon\0novel"]).copt.font_size, 22)
Assert.eq(JSON.decode(saved["moon\0novel"]).font_face, "Novel Font")
global_data.kopt_page_scroll = 0
local default_paged = sidecar()
ReaderPrefs.injectComic(default_paged, { file = "/books/default.cbz" })
Assert.eq(default_paged.data.kopt_page_scroll, 0, "明确设置的全局分页优先于漫画默认")
Assert.is_true(ReaderPrefs.captureAndSave(ui, identity))
local continued = sidecar()
ReaderPrefs.injectComic(continued, { file = "/cache/comic/3.CBT" })
Assert.eq(continued.data.kopt_page_scroll, 1, "手动切回连续同样跨章保留")
Assert.eq(global_data.kopt_page_scroll, 0, "普通切章不能修改全局分页默认")
