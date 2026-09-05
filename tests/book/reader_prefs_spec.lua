--[[--
book.reader_prefs 离线用例：捕获、落库与应用。

@module tests.book.reader_prefs_spec
--]]

local Assert = require("support.assert")

local saved_payload
local fail_write
local warnings = {}
package.preload["db.book"] = function()
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

package.preload["utils.font"] = function()
    return {
        supportsReader = function(ui)
            return ui and ui.font ~= nil and ui.document and ui.document.setFontFace
        end,
        faceForId = function(id)
            if id == "demo.ttf" then return "Demo Face" end
        end,
        applyFaceToReader = function() return true end,
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

package.loaded["book.reader_prefs"] = nil
package.loaded["json"] = nil
package.loaded["ffi/util"] = nil
package.loaded["utils.font"] = nil
package.loaded["db.book"] = nil
package.loaded["book.store"] = nil
local ReaderPrefs = require("book.reader_prefs")

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
Assert.is_true(ReaderPrefs.captureAndSave(ui, identity))
Assert.is_true(type(saved_payload) == "string" and #saved_payload > 0)

-- 未落库时不得往 sidecar 写任何东西
saved_payload = nil
local blank = { data = {}, saveSetting = ui.doc_settings.saveSetting, readSetting = ui.doc_settings.readSetting }
Assert.is_false(ReaderPrefs.inject(blank, { file = "/x.epub", setFontFace = function() end }))
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
local fresh = { data = {}, saveSetting = ui.doc_settings.saveSetting, readSetting = ui.doc_settings.readSetting }
Assert.is_true(ReaderPrefs.inject(fresh, { file = "/chapter.html", setFontFace = function() end }))
Assert.eq(fresh.data.copt_font_base_weight, 0.5)
Assert.eq(fresh.data.copt_h_page_margins[1], 40)
Assert.eq(fresh.data.font_face, "Demo Face")
Assert.eq(fresh.data.book_reader_font_id, "demo.ttf")

-- 整本书的单一 sidecar 就是偏好真相，不读写跨文件偏好。
local whole_book = { source_id = "moon", stable_id = "book-1" }
Assert.is_false(ReaderPrefs.captureAndSave(ui, whole_book))
local whole_book_settings = { data = {}, saveSetting = ui.doc_settings.saveSetting, readSetting = ui.doc_settings.readSetting }
Assert.is_false(ReaderPrefs.inject(whole_book_settings, { file = "/x.epub", setFontFace = function() end }))
Assert.is_nil(next(whole_book_settings.data))

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
local reopened = { data = {}, saveSetting = ui.doc_settings.saveSetting, readSetting = ui.doc_settings.readSetting }
Assert.is_true(ReaderPrefs.inject(reopened, { file = "/chapter.html", setFontFace = function() end }))
Assert.eq(reopened.data.font_face, "Native Face")
Assert.eq(reopened.data.book_reader_font_id, "")

-- 同步写库失败直接返回 false，并留下日志。
fail_write = true
Assert.is_false(ReaderPrefs.captureAndSave(ui, identity))
Assert.eq(#warnings, 1)
Assert.matches(warnings[1][1], "reader_prefs save failed")

return true
