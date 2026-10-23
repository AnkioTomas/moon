--[[--
reader.prefs 离线用例：捕获、落库与应用。

@module tests.reader.prefs_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

local Assert = require("support.assert")

-- 全局设置桩：saveDefaults 写这里，inject 从这里读默认插件字体。
local global_data, flushed = {}, 0
_G.G_reader_settings = {
    readSetting = function(_self, key) return global_data[key] end,
    has = function(_self, key) return global_data[key] ~= nil end,
    saveSetting = function(_self, key, value) global_data[key] = value end,
    delSetting = function(_self, key) global_data[key] = nil end,
    flush = function() flushed = flushed + 1 end,
}

local saved_payload
local fail_write
local warnings = {}
local resolved_font_ids = {}
package.preload["book.books_db"] = function()
    return {
        getReaderPrefs = function(source_id, stable_id)
            Assert.eq(source_id, "moon")
            Assert.eq(stable_id, "book-1")
            return saved_payload
        end,
        setReaderPrefs = function(source_id, stable_id, payload)
            Assert.eq(source_id, "moon")
            Assert.eq(stable_id, "book-1")
            if fail_write then return false end
            saved_payload = payload
            return true
        end,
    }
end

-- 同步落库

package.preload["utils.log"] = function()
    return { warn = function(...) warnings[#warnings + 1] = { ... } end }
end

package.preload["book.store"] = function()
    return {
        ensureIdentity = function()
            return { source_id = "moon", stable_id = "book-1", chapter_idx = 1 }
        end,
        identityFor = function(path)
            if path == "/chapter.html" then
                return { source_id = "moon", stable_id = "book-1", chapter_idx = 1 }
            end
            return { source_id = "moon", stable_id = "book-1" }
        end,
    }
end

package.preload["json"] = function()
    return {
        encode = function(value)
            return require("ffi/util").serialize(value)
        end,
        decode = function(raw)
            if type(raw) ~= "string" or raw == "" then return nil end
            local fn = loadstring("return " .. raw)
            if not fn then return nil end
            local ok, value = pcall(fn)
            return ok and value or nil
        end,
    }
end

package.preload["ui.fonts.reader"] = function()
    return {
        supports = function(ui)
            return ui and ui.font ~= nil and ui.document and ui.document.setFontFace
        end,
    }
end
package.preload["ui.fonts"] = function()
    return {
        faceForId = function(id)
            resolved_font_ids[#resolved_font_ids + 1] = id
            if id == "demo.ttf" then return "Demo Face" end
        end,
        faceNameForId = function(id)
            if id == "demo.ttf" then return "Demo Face" end
        end,
    }
end

package.preload["ui/uimanager"] = function()
    return { setDirty = function() end }
end
package.preload["ui/event"] = function()
    return { new = function(_, name) return { name = name } end }
end
package.preload["ffi/util"] = function()
    return {
        serialize = function(value)
            local seen = {}
            local function dump(v, depth)
                depth = depth or 0
                local t = type(v)
                if t == "number" then return tostring(v) end
                if t == "string" then return string.format("%q", v) end
                if t ~= "table" then return "nil" end
                if seen[v] then return "nil" end
                seen[v] = true
                local parts, n = {}, 0
                for i = 1, #v do
                    n = n + 1
                    parts[n] = dump(v[i], depth + 1)
                end
                for k, val in pairs(v) do
                    if type(k) == "string" then
                        n = n + 1
                        parts[n] = k .. "=" .. dump(val, depth + 1)
                    end
                end
                return "{" .. table.concat(parts, ",") .. "}"
            end
            return dump(value)
        end,
    }
end

package.loaded["reader.prefs"] = nil
package.loaded["json"] = nil
package.loaded["ffi/util"] = nil
package.loaded["ui.fonts"] = nil
package.loaded["ui.fonts.reader"] = nil
package.loaded["book.books_db"] = nil
package.loaded["book.store"] = nil
local ReaderPrefs = require("reader.prefs")

local ui = {
    font = {
        font_face = "Demo Face",
        onSetFont = function(self, face) self.font_face = face end,
        onSaveSettings = function(self)
            self.saved_face = self.font_face
        end,
    },
    document = {
        setFontFace = function() end,
        configurable = {
            h_page_margins = { 5, 5 },
            t_page_margin = 10,
            b_page_margin = 12,
            sync_t_b_page_margins = 0,
            font_size = 22,
            line_spacing = 100,
            font_base_weight = 0.5,
            book_font_face = 3,
            saveSettings = function() end,
        },
    },
    doc_settings = {
        data = {},
        saveSetting = function(self, key, value) self.data[key] = value end,
        readSetting = function(self, key) return self.data[key] end,
        delSetting = function(self, key) self.data[key] = nil end,
        flush = function() end,
    },
    typeset = {
        onSetPageHorizMargins = function() end,
        onSetPageTopAndBottomMargin = function() end,
    },
    handleEvent = function() end,
    dialog = {},
}

ui.font.onSetFontSize = function() end
ui.font.onSetLineSpace = function() end

local identity = { source_id = "moon", stable_id = "book-1", chapter_idx = 1 }

ui.doc_settings.data.book_reader_font_id = "demo.ttf"
ui.doc_settings.data.style_tweaks = { lines_line_height_large = 1 }
ui.doc_settings.data.book_style_tweak = "p { line-height: 2; }"
Assert.is_true(ReaderPrefs.captureAndSave(ui, identity))
Assert.is_true(type(saved_payload) == "string" and #saved_payload > 0)

-- 未落库时不得往 sidecar 写任何东西
saved_payload = nil
local blank = { data = {}, saveSetting = ui.doc_settings.saveSetting, readSetting = ui.doc_settings.readSetting }
Assert.is_false(ReaderPrefs.inject(blank, { file = "/x.epub", setFontFace = function() end }))
Assert.eq(blank.data.copt_embedded_fonts, 0)
blank.data.copt_embedded_fonts = nil
Assert.is_nil(next(blank.data))

ui.document.configurable.h_page_margins = { 40, 40 }
Assert.is_true(ReaderPrefs.captureAndSave(ui, identity))
local loaded = ReaderPrefs.load(identity)
Assert.eq(loaded.font_id, "demo.ttf")
Assert.eq(loaded.copt.h_page_margins[1], 40)
-- 白名单外的键（字重）必须一起持久化，且不带 native_font 的临时键
Assert.eq(loaded.copt.font_base_weight, 0.5)
Assert.is_nil(loaded.copt.book_font_face)

-- inject 把整套 copt 写进新章 sidecar，由原生 ReadSettings 加载
local fresh = {
    data = { style_tweaks_enabled = false },
    saveSetting = ui.doc_settings.saveSetting,
    readSetting = ui.doc_settings.readSetting,
    delSetting = ui.doc_settings.delSetting,
}
Assert.is_true(ReaderPrefs.inject(fresh, { file = "/chapter.html", setFontFace = function() end }))
-- 样式微调（行距 / 段距）与自定义 CSS 跟着全书走；全书没设的键要清掉这章自己的旧值
Assert.eq(fresh.data.style_tweaks.lines_line_height_large, 1)
Assert.eq(fresh.data.book_style_tweak, "p { line-height: 2; }")
Assert.is_nil(fresh.data.style_tweaks_enabled)
Assert.eq(fresh.data.copt_font_base_weight, 0.5)
Assert.eq(fresh.data.copt_h_page_margins[1], 40)
Assert.eq(fresh.data.font_face, "Demo Face")
Assert.eq(fresh.data.book_reader_font_id, "demo.ttf")

-- 整本书的单一 sidecar 就是偏好真相，不读写跨文件偏好。
local whole_book = { source_id = "moon", stable_id = "book-1" }
Assert.is_false(ReaderPrefs.captureAndSave(ui, whole_book))
local whole_book_settings = { data = {}, saveSetting = ui.doc_settings.saveSetting, readSetting = ui.doc_settings.readSetting }
Assert.is_false(ReaderPrefs.inject(whole_book_settings, { file = "/x.epub", setFontFace = function() end }))
-- 内嵌字体默认关（防大 EPUB OOM）；本书已显式开启或全局「设为默认」过则保留
Assert.eq(whole_book_settings.data.copt_embedded_fonts, 0)
whole_book_settings.data.copt_embedded_fonts = nil
Assert.is_nil(next(whole_book_settings.data))
local on_book = { data = { copt_embedded_fonts = 1 }, saveSetting = ui.doc_settings.saveSetting, readSetting = ui.doc_settings.readSetting }
ReaderPrefs.inject(on_book, { file = "/x.epub", setFontFace = function() end })
Assert.eq(on_book.data.copt_embedded_fonts, 1)
local saved_g = _G.G_reader_settings
_G.G_reader_settings = { has = function(_, k) return k == "copt_embedded_fonts" end, readSetting = function() end }
local g_default = { data = {}, saveSetting = ui.doc_settings.saveSetting, readSetting = ui.doc_settings.readSetting }
ReaderPrefs.inject(g_default, { file = "/x.epub", setFontFace = function() end })
Assert.is_nil(g_default.data.copt_embedded_fonts)
-- 大文件：全局默认开着也强制关内嵌字体 / 样式；本书自己设过的不动
local lfs = require("libs/libkoreader-lfs")
local real_attributes = lfs.attributes
lfs.attributes = function(path, what)
    if path == "/big.epub" and what == "size" then return 40 * 1024 * 1024 end
    return real_attributes(path, what)
end
local big_book = { data = {}, saveSetting = ui.doc_settings.saveSetting, readSetting = ui.doc_settings.readSetting }
ReaderPrefs.inject(big_book, { file = "/big.epub", setFontFace = function() end })
Assert.eq(big_book.data.copt_embedded_fonts, 0)
Assert.eq(big_book.data.copt_embedded_css, 0)
local big_on = { data = { copt_embedded_fonts = 1, copt_embedded_css = 1 }, saveSetting = ui.doc_settings.saveSetting, readSetting = ui.doc_settings.readSetting }
ReaderPrefs.inject(big_on, { file = "/big.epub", setFontFace = function() end })
Assert.eq(big_on.data.copt_embedded_fonts, 1)
Assert.eq(big_on.data.copt_embedded_css, 1)
local small = { data = {}, saveSetting = ui.doc_settings.saveSetting, readSetting = ui.doc_settings.readSetting }
ReaderPrefs.inject(small, { file = "/x.epub", setFontFace = function() end })
Assert.is_nil(small.data.copt_embedded_css)
lfs.attributes = real_attributes
_G.G_reader_settings = saved_g

-- 整本书无需注入跨章节偏好，但冷启动时必须按 sidecar 的 id 重新注册插件字体。
local cold_book_settings = {
    data = { book_reader_font_id = "demo.ttf", font_face = "Demo Face" },
    saveSetting = ui.doc_settings.saveSetting,
    readSetting = ui.doc_settings.readSetting,
}
Assert.is_false(ReaderPrefs.inject(cold_book_settings, { file = "/x.epub", setFontFace = function() end }))
Assert.eq(resolved_font_ids[#resolved_font_ids], "demo.ttf")

-- 非 CRE 文档不落 copt_
local kopt = { data = {}, saveSetting = ui.doc_settings.saveSetting, readSetting = ui.doc_settings.readSetting }
Assert.is_false(ReaderPrefs.inject(kopt, { file = "/x.pdf" }))
Assert.is_nil(next(kopt.data))

ui.doc_settings.data.book_reader_font_id = nil
Assert.is_true(ReaderPrefs.captureAndSave(ui, identity))
loaded = ReaderPrefs.load(identity)
Assert.eq(loaded.font_id, "demo.ttf")

-- 原生菜单改成其他字体后，旧插件 id 只是过期的加载提示，不能覆盖当前 font_face。
ui.font.font_face = "Native Face"
ui.doc_settings.data.font_face = "Old Sidecar Face"
ui.doc_settings.data.book_reader_font_id = "demo.ttf"
Assert.is_true(ReaderPrefs.captureAndSave(ui, identity))
loaded = ReaderPrefs.load(identity)
Assert.is_nil(loaded.font_id)
Assert.eq(loaded.font_face, "Native Face")
local reopened = { data = {}, saveSetting = ui.doc_settings.saveSetting, readSetting = ui.doc_settings.readSetting, delSetting = ui.doc_settings.delSetting }
Assert.is_true(ReaderPrefs.inject(reopened, { file = "/chapter.html", setFontFace = function() end }))
Assert.eq(reopened.data.font_face, "Native Face")
Assert.eq(reopened.data.book_reader_font_id, "")

-- 同步写库失败直接返回 false，并留下日志。
fail_write = true
Assert.is_false(ReaderPrefs.captureAndSave(ui, identity))
Assert.eq(#warnings, 1)
Assert.matches(warnings[1][1], "reader_prefs save failed")

-- 保存为默认配置：同 ConfigDialog 写 <prefix>_<name>，字体写 cre_font；临时键不落。
ui.config = { options = { prefix = "copt" } }
ui.document.configurable.book_font_face = "tmp"
ui.font.font_face = "Demo Face"
ui.doc_settings.data.book_reader_font_id = "demo.ttf"
Assert.is_true(ReaderPrefs.saveDefaults(ui))
Assert.eq(global_data.cre_font, "Demo Face")
Assert.eq(global_data.book_reader_default_font_id, "demo.ttf")
Assert.is_nil(global_data.copt_book_font_face)
for key, value in pairs(ui.document.configurable) do
    local vt = type(value)
    if key ~= "book_font_face" and (vt == "number" or vt == "string") then Assert.eq(global_data["copt_" .. key], value) end
end
Assert.eq(flushed, 1)
-- 新书 sidecar 没有字体 id 时，按默认插件字体注册。
resolved_font_ids = {}
ReaderPrefs.inject({ data = {}, readSetting = function() end, saveSetting = function() end }, { file = "/x.epub", setFontFace = function() end })
Assert.eq(resolved_font_ids[1], "demo.ttf")
Assert.is_false(ReaderPrefs.saveDefaults({ document = {} }))

return true
