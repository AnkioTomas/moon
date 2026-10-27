--[[-- ui.fonts 字体解析、UI 字体与阅读字体应用离线用例。
@module tests.ui.fonts.init_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

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
local directory_scans = 0
local repair_calls = {}
package.preload["ui.fonts.sfnt"] = function()
    return { ensureSpace = function(path)
        repair_calls[#repair_calls + 1] = path
        error("font repair must not run on UI thread")
    end }
end

package.preload["ui.fonts.woff"] = function()
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
    return { fontmap = { cfont = "NotoSans-Regular.ttf" }, faces = {} }
end
package.preload["json"] = function() return { decode = function() end } end
package.preload["ffi/util"] = function() return { md5 = function() return "" end } end
package.preload["logger"] = function() return { info = function() end, warn = function() end } end
package.preload["util"] = function()
    return {
        findFiles = function(_dir, fn)
            directory_scans = directory_scans + 1
            if files["/tmp/reader-font.ttf"] then
                fn("/tmp/reader-font.ttf", "reader-font.ttf", { mode = "file" })
            end
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
            if (path == "/tmp/fonts" or path == "/tmp/ko/fonts") and (not key or key == "mode") then
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
                    if engine_registered[path] or path:match("aik")
                        or path:match("unfixable") then
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
package.preload["reader.prefs"] = function()
    return { captureAndSave = function() end }
end

for _, name in ipairs({ "ui.fonts", "ui.fonts.reader" }) do
    package.loaded[name] = nil
end
local Fonts = require("ui.fonts")
local FontReader = require("ui.fonts.reader")

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

Assert.is_true(FontReader.supports(ui))
Assert.is_false(FontReader.supports({ document = {} }))

local face_name, face_name_err = Fonts.faceNameForId("reader-font.ttf")
Assert.eq(face_name, "Reader Demo")
Assert.is_nil(face_name_err)
Assert.eq(register_calls, 0, "偏好比较不应注册 CRE 字体")
local initial_scans = directory_scans
Assert.eq(initial_scans, 1)

local face, err = Fonts.faceForId("reader-font.ttf")
Assert.is_nil(err)
Assert.eq(face, "Reader Demo")
Assert.is_true(registered["/tmp/reader-font.ttf"])
Assert.eq(register_calls, 1)
Assert.eq(Fonts.faceForId("reader-font.ttf"), "Reader Demo")
Assert.eq(register_calls, 1, "同一路径只注册一次")
Assert.eq(directory_scans, initial_scans, "同一字体后续解析复用路径，不重新扫描目录")
Assert.is_nil(Fonts.downloadedPath("wr"), "未下载的微信读书字体")

-- engineInit 已注册的系统字体：重复注册被拒不算失败
Assert.eq(Fonts.faceForId("sys.ttf"), "System Demo")
-- 注册失败且 crengine 不认识该字体名：仍报应用失败
local broken_face, broken_err = Fonts.faceForId("broken.ttf")
Assert.is_nil(broken_face)
Assert.eq(broken_err, "应用字体失败")
Assert.len(repair_calls, 0, "不修改用户/系统字库")
files["/tmp/fonts/aik.ttf"] = true
fontinfo["/tmp/fonts/aik.ttf"] = { { name = "AI Kai" } }
local aik, aik_err = Fonts.faceForId("aik")
Assert.is_nil(aik)
Assert.eq(aik_err, "应用字体失败")
Assert.len(repair_calls, 0, "加载/开书只注册，不在 UI 线程同步修复")
files["/tmp/fonts/unfixable.ttf"] = true
fontinfo["/tmp/fonts/unfixable.ttf"] = { { name = "Unfixable" } }
local unavailable, unavailable_err = Fonts.faceForId("unfixable")
Assert.is_nil(unavailable)
Assert.eq(unavailable_err, "应用字体失败", "不是缺空格的字体仍然报错")
-- 含空格/中文的文件名按原样匹配，不能被 sanitize 成下划线
Assert.eq(Fonts.faceForId("霞鹜 文楷.ttf"), "LXGW WenKai")
Assert.is_true(FontReader.apply(ui, "霞鹜 文楷.ttf", "霞鹜文楷"))
Assert.eq(ui.doc_settings.data.book_reader_font_id, "霞鹜 文楷.ttf")
Assert.eq(FontReader.currentId(ui), "霞鹜 文楷.ttf")

-- 先作桌面字体（路径插进 FontList），首次开书 engineInit 按 FontList 注册，
-- 再在阅读页选同一字体：重复注册被拒不能报失败
fontinfo["/tmp/fonts/desk.ttf"] = { { name = "Desk Demo" } }
files["/tmp/fonts/desk.ttf"] = true
Fonts.set("desk", "Desk")
Fonts.applyCurrent()
Assert.eq(require("ui/font").fontmap.cfont, "desk.ttf", "UI 字体写进 fontmap")
-- fontmap 进程级共享：已应用过，后续插件实例（开书 / 回书架）的 onCreate 不再重写
require("ui/font").fontmap.cfont = "sentinel.ttf"
Fonts.onCreate()
Assert.eq(require("ui/font").fontmap.cfont, "sentinel.ttf", "onCreate 每进程只应用一次")
Fonts.applyCurrent()
local FontList = require("fontlist")
Assert.eq(FontList.fontlist[1], "/tmp/fonts/desk.ttf")
for _, path in ipairs(FontList.fontlist) do engine_registered[path] = true end
engine_faces[#engine_faces + 1] = "Desk Demo"
Assert.is_true(FontReader.apply(ui, "desk", "Desk"))
Assert.eq(ui.font.font_face, "Desk Demo")

-- 旧版微信读书 .woff：列表只判存在不转换；解析时转成 .ttf 并注册 sfnt 路径
files["/tmp/fonts/wr.woff"] = true
Assert.eq(Fonts.downloadedPath("wr"), "/tmp/fonts/wr.woff")
Assert.len(woff_calls, 0, "downloadedPath 不应触发转换")
Assert.eq(Fonts.faceForId("wr"), "WeRead Demo")
Assert.eq(woff_calls[1][1], "/tmp/fonts/wr.woff")
Assert.eq(woff_calls[1][2], "/tmp/fonts/wr.ttf")
Assert.is_true(registered["/tmp/fonts/wr.ttf"])
Assert.is_nil(registered["/tmp/fonts/wr.woff"])
Assert.eq(Fonts.faceForId("wr"), "WeRead Demo")
Assert.len(woff_calls, 1, "已转换的字体不再重复转换")

-- 删除已下载字体：.ttf 与旧 .woff 都清掉，之后视为未下载
local real_remove = os.remove
os.remove = function(path) files[path] = nil return true end
files["/tmp/fonts/wr.woff"] = true
Assert.is_true(Fonts.removeDownloaded("wr"))
Assert.is_nil(Fonts.downloadedPath("wr"))
Assert.is_nil(files["/tmp/fonts/wr.ttf"])
Assert.is_nil(files["/tmp/fonts/wr.woff"])
Assert.is_nil(Fonts.pathForId("wr"), "删除字体后路径缓存失效")
Assert.eq(Fonts.removeDownloaded("wr"), false, "没有文件可删")
os.remove = real_remove
files["/tmp/fonts/wr.woff"] = true
files["/tmp/fonts/wr.ttf"] = true
Assert.eq(Fonts.pathForId("wr"), "/tmp/fonts/wr.ttf", "重新下载后可再次解析字体")

-- 转换失败且改名也失败：退回原 WOFF，字体仍可用
files["/tmp/fonts/bad.woff"] = true
Assert.eq(Fonts.faceForId("bad"), "Bad Woff")
Assert.is_true(registered["/tmp/fonts/bad.woff"])

local ok, apply_err = FontReader.apply(ui, "reader-font.ttf", "Demo")
Assert.is_true(ok)
Assert.is_nil(apply_err)
Assert.eq(ui.font.font_face, "Reader Demo")
Assert.eq(ui.document.face, "Reader Demo")
Assert.eq(ui.font.saved_face, "Reader Demo")
Assert.eq(ui.doc_settings.data.book_reader_font_id, "reader-font.ttf")
Assert.eq(FontReader.currentId(ui), "reader-font.ttf")

-- FontList 里没有该字体名：onSetFont 静默不动，必须报失败而不是假装成功
fontinfo["/tmp/fonts/ghost.ttf"] = { { name = "Ghost" } }
files["/tmp/fonts/ghost.ttf"] = true
engine_faces[#engine_faces + 1] = "Ghost"
local real_set = ui.font.onSetFont
ui.font.onSetFont = function() end
local ghost_ok, ghost_err = FontReader.apply(ui, "ghost", "Ghost")
ui.font.onSetFont = real_set
Assert.is_nil(ghost_ok)
Assert.eq(ghost_err, "应用字体失败")
Assert.eq(ui.doc_settings.data.book_reader_font_id, "reader-font.ttf", "失败不写 sidecar")

-- 字体文件不存在
local miss_ok, miss_err = FontReader.apply(ui, "missing.ttf", "Missing")
Assert.is_nil(miss_ok)
Assert.eq(miss_err, "字体文件不存在")

-- 配置字体已被删除：UI 退回首次备份的默认 fontmap
Fonts.set("gone", "Gone")
Fonts.applyCurrent()
Assert.eq(require("ui/font").fontmap.cfont, "NotoSans-Regular.ttf", "缺字体时恢复默认 fontmap")

-- 字体信息缺失时 _readList 会把整个目录追加进 fontlist：只能留下已登记的那一条
FontList._readList = function(self, dir)
    for _, p in ipairs({ dir .. "/late.ttf", dir .. "/wr.ttf", dir .. "/desk.ttf" }) do
        table.insert(self.fontlist, p)
    end
    self.fontinfo[dir .. "/late.ttf"] = { { name = "Late Demo" } }
end
files["/tmp/fonts/late.ttf"] = true
local before = #FontList.fontlist
Assert.eq(Fonts.faceNameForId("late"), "Late Demo")
Assert.eq(#FontList.fontlist, before + 1, "只多出 late.ttf 一条")
Assert.eq(FontList.fontlist[1], "/tmp/fonts/late.ttf")
Assert.eq(FontReader.currentId({ doc_settings = { readSetting = function() end } }), "")

-- 能取到 fontlist 的 collectFaceInfo 时只读选中的这一个文件，不扫整个目录
local collected, walked = {}, false
local function collectFaceInfo(path)
    collected[#collected + 1] = path
    return { { name = "Solo Demo" } }
end
FontList._readList = function()
    walked = true
    return collectFaceInfo
end
files["/tmp/fonts/solo.ttf"] = true
Assert.eq(Fonts.faceNameForId("solo"), "Solo Demo")
Assert.eq(table.concat(collected, ","), "/tmp/fonts/solo.ttf", "只读这一个文件的字体信息")
Assert.is_false(walked, "不走整目录 _readList")

-- 已缓存的本地文件被删除时，不得重新命中 FontList 中残留的旧路径。
files["/tmp/reader-font.ttf"] = nil
Assert.is_nil(Fonts.pathForId("reader-font.ttf"))
files["/tmp/reader-font.ttf"] = true
Assert.eq(Fonts.pathForId("reader-font.ttf"), "/tmp/reader-font.ttf")

-- 西文选择重载当前书，保留中文字体；选择失败不重载。
local western_reloads, western_error = 0
moon_settings.western_font_id = ""
package.preload["ui.fonts.mixed"] = function() return { setWestern = function(id, name)
    if id == moon_settings.western_font_id then return true, nil, false end
    if id == "bad.ttf" then return nil, "不支持的西文字体" end
    moon_settings.western_font_id, moon_settings.western_font_name = id, name
    return true, nil, true
end } end
package.preload["ui.themes.widgets.toast"] = function() return { new = function(_, opts)
    return { show = function() western_error = opts.text end }
end } end
ui.reloadDocument = function(_, callback, seamless)
    Assert.is_nil(callback)
    Assert.is_true(seamless)
    western_reloads = western_reloads + 1
end
local chinese_face = ui.font.font_face
local western = FontReader.westernPickerOpts(ui)
Assert.eq(western.title, "西文字体")
Assert.eq(western.current_id(), "")
western.on_select(nil, "west.ttf", "自选西文")
Assert.eq(western.current_id(), "west.ttf")
Assert.eq(western_reloads, 1)
western.on_select(nil, "west.ttf", "自选西文")
Assert.eq(western_reloads, 1, "重复选择当前西文字体不重载当前书籍")
Assert.eq(ui.font.font_face, chinese_face, "西文选择不覆盖中文字体状态")
western.on_select(nil, "bad.ttf", "无效字体")
Assert.eq(western_reloads, 1)
Assert.eq(western_error, "不支持的西文字体")
western.on_select(nil, "", "")
Assert.eq(moon_settings.western_font_id, "", "空选择恢复默认西文字体")
Assert.eq(western_reloads, 2)
western.on_select(nil, "", "")
Assert.eq(western_reloads, 2, "重复使用自动选择不重载")
