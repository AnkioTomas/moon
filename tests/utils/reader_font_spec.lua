--[[-- utils.font 阅读字体应用离线用例。
@module tests.utils.reader_font_spec
--]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")

Stubs.install()
Stubs.reset()

local fontinfo = {
    ["/tmp/reader-font.ttf"] = { { name = "Reader Demo" } },
}
local registered = {}

package.preload["ffi/archiver"] = function()
    return { Reader = { new = function() return { open = function() end } end } }
end
package.preload["datastorage"] = function()
    return { getDataDir = function() return "/tmp/ko" end }
end
package.preload["ui/font"] = function()
    return { fontmap = {}, faces = {} }
end
package.preload["json"] = function() return { decode = function() end } end
package.preload["ffi/util"] = function() return { md5 = function() return "" end } end
package.preload["logger"] = function() return { info = function() end, warn = function() end } end
package.preload["util"] = function()
    return { findFiles = function(_dir, fn)
        fn("/tmp/reader-font.ttf", "reader-font.ttf", { mode = "file" })
    end }
end
package.preload["http.cache"] = function()
    return { key = function() return "" end, get = function() end }
end
package.preload["http.request"] = function()
    return { download = function(_, _, cb) cb(false) end }
end
package.preload["utils.paths"] = function()
    return {
        fontsDir = function() return "/tmp/fonts" end,
        ensureFonts = function() end,
        slugFor = function(v) return v end,
    }
end
package.preload["utils.settings"] = function()
    return { get = function() return {} end, save = function() end }
end
package.preload["utils.task"] = function()
    return { spawn = function(_, fn) fn(); return { abort = function() end } end }
end
package.preload["utils.text"] = function()
    return {
        stripWhitespace = function(v) return v end,
        trim = function(v) return v end,
    }
end
package.preload["libs/libkoreader-lfs"] = function()
    return {
        attributes = function(path, key)
            if path == "/tmp/reader-font.ttf" and (not key or key == "mode") then
                return "file"
            end
            if path == "/tmp/fonts" and (not key or key == "mode") then
                return "directory"
            end
        end,
    }
end
package.preload["fontlist"] = function()
    local FontList = {
        fontlist = { "/tmp/reader-font.ttf" },
        fontinfo = fontinfo,
        getFontList = function(self) return self.fontlist end,
        _readList = function() end,
    }
    return FontList
end
package.preload["document/credocument"] = function()
    return {
        engineInit = function()
            return { registerFont = function(path) registered[path] = true end }
        end,
    }
end
package.preload["ui/uimanager"] = function()
    return { setDirty = function() end }
end
package.preload["ui/event"] = function()
    return { new = function(_, name) return { name = name } end }
end
package.preload["book.reader_prefs"] = function()
    return { captureAndSave = function() end }
end

package.loaded["utils.font"] = nil
local MoonFont = require("utils.font")

local ui
ui = {
    font = {
        font_face = "Old",
        onSetFont = function(self, face) self.font_face = face end,
        onSaveSettings = function(self)
            self.saved_face = self.font_face
        end,
    },
    document = {
        setFontFace = function(_, face) ui.document.face = face end,
    },
    doc_settings = {
        data = {},
        saveSetting = function(self, key, value) self.data[key] = value end,
        readSetting = function(self, key) return self.data[key] end,
        flush = function() end,
    },
    handleEvent = function() end,
    dialog = {},
}

Assert.is_true(MoonFont.supportsReader(ui))
Assert.is_false(MoonFont.supportsReader({ document = {} }))

local face, err = MoonFont.faceForId("reader-font.ttf")
Assert.is_nil(err)
Assert.eq(face, "Reader Demo")
Assert.is_true(registered["/tmp/reader-font.ttf"])

local ok, apply_err = MoonFont.applyToReader(ui, "reader-font.ttf", "Demo")
Assert.is_true(ok)
Assert.is_nil(apply_err)
Assert.eq(ui.font.font_face, "Reader Demo")
Assert.eq(ui.document.face, "Reader Demo")
Assert.eq(ui.font.saved_face, "Reader Demo")
Assert.eq(ui.doc_settings.data.book_reader_font_id, "reader-font.ttf")
Assert.eq(MoonFont.readerCurrentId(ui), "reader-font.ttf")

local ok_face = MoonFont.applyFaceToReader(ui, "Reader Demo", "reader-font.ttf", "Demo")
Assert.is_true(ok_face)
Assert.eq(ui.document.face, "Reader Demo")

ui.font.font_face = "Reader Demo"
ui.document.face = nil
Assert.is_true(MoonFont.applyFaceToReader(ui, "Reader Demo", "reader-font.ttf", "Demo"))
Assert.eq(ui.document.face, "Reader Demo")
