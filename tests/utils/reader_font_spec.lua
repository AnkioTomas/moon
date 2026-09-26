--[[-- utils.font 阅读字体应用离线用例。
@module tests.utils.reader_font_spec
--]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")

Stubs.install()
Stubs.reset()

local fontinfo = {
    ["/tmp/reader-font.ttf"] = { { name = "Reader Demo" } },
    ["/tmp/fonts/wr.ttf"] = { { name = "WeRead Demo" } },
    ["/tmp/fonts/bad.woff"] = { { name = "Bad Woff" } },
    ["/tmp/sys.ttf"] = { { name = "System Demo" } },
    ["/tmp/broken.ttf"] = { { name = "Broken Demo" } },
    ["/tmp/霞鹜 文楷.ttf"] = { { name = "LXGW WenKai" } },
}
local files = {
    ["/tmp/reader-font.ttf"] = true,
    ["/tmp/sys.ttf"] = true,
    ["/tmp/broken.ttf"] = true,
    ["/tmp/霞鹜 文楷.ttf"] = true,
}
-- engineInit 已注册过的路径：crengine 拒绝重复注册（luaL_error）
local engine_registered = { ["/tmp/sys.ttf"] = true, ["/tmp/broken.ttf"] = true }
local engine_faces = { "System Demo" }
local registered = {}
local register_calls = 0
local woff_calls = {}

package.preload["utils.woff"] = function()
    return { toSfnt = function(src, dest)
        woff_calls[#woff_calls + 1] = { src, dest }
        if src:match("bad") then return nil, "corrupt" end
        files[src], files[dest] = nil, true
        return true
    end }
end

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
    return {
        findFiles = function(_dir, fn)
            fn("/tmp/reader-font.ttf", "reader-font.ttf", { mode = "file" })
        end,
        arrayContains = function(t, v)
            for i, x in ipairs(t) do if x == v then return i end end
            return false
        end,
    }
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
local moon_settings = {}
package.preload["utils.settings"] = function()
    return { get = function() return moon_settings end, save = function() end }
end
package.preload["utils.task"] = function()
    return { spawn = function(_, fn) fn(); return { abort = function() end } end }
end
package.preload["libs/libkoreader-lfs"] = function()
    return {
        attributes = function(path, key)
            if files[path] and (not key or key == "mode") then
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
        fontlist = { "/tmp/reader-font.ttf", "/tmp/sys.ttf", "/tmp/broken.ttf", "/tmp/霞鹜 文楷.ttf" },
        fontinfo = fontinfo,
        getFontList = function(self) return self.fontlist end,
        _readList = function() end,
    }
    return FontList
end
package.preload["document/credocument"] = function()
    return {
        engineInit = function()
            return {
                registerFont = function(path)
                    register_calls = register_calls + 1
                    if engine_registered[path] then
                        error("cannot register font <" .. path .. ">")
                    end
                    registered[path] = true
                end,
                getFontFaces = function() return engine_faces end,
            }
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
        onSetFont = function(self, face)
            self.font_face = face
            ui.document:setFontFace(face)
            ui:handleEvent({ name = "UpdatePos" })
        end,
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

local face_name, face_name_err = MoonFont.faceNameForId("reader-font.ttf")
Assert.eq(face_name, "Reader Demo")
Assert.is_nil(face_name_err)
Assert.eq(register_calls, 0, "偏好比较不应注册 CRE 字体")

local face, err = MoonFont.faceForId("reader-font.ttf")
Assert.is_nil(err)
Assert.eq(face, "Reader Demo")
Assert.is_true(registered["/tmp/reader-font.ttf"])
Assert.eq(register_calls, 1)
Assert.eq(MoonFont.faceForId("reader-font.ttf"), "Reader Demo")
Assert.eq(register_calls, 1, "同一路径只注册一次")
Assert.is_true(MoonFont.isInstalled("reader-font.ttf"), "字符串 ID 应识别设置目录字体")
Assert.is_false(MoonFont.isInstalled({
    id = "missing.ttf", kind = "local", path = "/tmp/missing.ttf",
}), "列表项路径失效后不能继续报告已安装")

-- engineInit 已注册的系统字体：重复注册被拒不算失败
Assert.eq(MoonFont.faceForId("sys.ttf"), "System Demo")
-- 注册失败且 crengine 不认识该字体名：仍报应用失败
local broken_face, broken_err = MoonFont.faceForId("broken.ttf")
Assert.is_nil(broken_face)
Assert.eq(broken_err, "应用字体失败")
-- 含空格/中文的文件名按原样匹配，不能被 sanitize 成下划线
Assert.eq(MoonFont.faceForId("霞鹜 文楷.ttf"), "LXGW WenKai")
Assert.is_true(MoonFont.applyToReader(ui, "霞鹜 文楷.ttf", "霞鹜文楷"))
Assert.eq(ui.doc_settings.data.book_reader_font_id, "霞鹜 文楷.ttf")
Assert.eq(MoonFont.readerCurrentId(ui), "霞鹜 文楷.ttf")

-- 先作桌面字体（路径插进 FontList），首次开书 engineInit 按 FontList 注册，
-- 再在阅读页选同一字体：重复注册被拒不能报失败
fontinfo["/tmp/fonts/desk.ttf"] = { { name = "Desk Demo" } }
files["/tmp/fonts/desk.ttf"] = true
MoonFont.set("desk", "Desk")
Assert.is_true(MoonFont.applyCurrent())
local FontList = require("fontlist")
Assert.eq(FontList.fontlist[1], "/tmp/fonts/desk.ttf")
for _, path in ipairs(FontList.fontlist) do engine_registered[path] = true end
engine_faces[#engine_faces + 1] = "Desk Demo"
Assert.is_true(MoonFont.applyToReader(ui, "desk", "Desk"))
Assert.eq(ui.font.font_face, "Desk Demo")

-- 旧版微信读书 .woff：列表只判存在不转换；解析时转成 .ttf 并注册 sfnt 路径
files["/tmp/fonts/wr.woff"] = true
Assert.is_true(MoonFont.isInstalled("wr"))
Assert.len(woff_calls, 0, "isInstalled 不应触发转换")
Assert.eq(MoonFont.faceForId("wr"), "WeRead Demo")
Assert.eq(woff_calls[1][1], "/tmp/fonts/wr.woff")
Assert.eq(woff_calls[1][2], "/tmp/fonts/wr.ttf")
Assert.is_true(registered["/tmp/fonts/wr.ttf"])
Assert.is_nil(registered["/tmp/fonts/wr.woff"])
Assert.eq(MoonFont.faceForId("wr"), "WeRead Demo")
Assert.len(woff_calls, 1, "已转换的字体不再重复转换")

-- 转换失败且改名也失败：退回原 WOFF，字体仍可用
files["/tmp/fonts/bad.woff"] = true
Assert.eq(MoonFont.faceForId("bad"), "Bad Woff")
Assert.is_true(registered["/tmp/fonts/bad.woff"])

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
