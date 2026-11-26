--[[--
Fonts.getFace / patchGetFace：系统字体名含 %1 时，宿主 path:find 会抛
invalid capture index；插件按 basename 精确定位并用绝对路径打开。
@module tests.ui.fonts.getface_spec
--]]

local Assert = require("support.assert")

local files = {
    ["/tmp/ko/fonts/NotoSans-Regular.ttf"] = true,
    ["/tmp/ko/fonts/NotoSans-Bold.ttf"] = true,
    ["/system/fonts/Source%201Han.ttf"] = true,
    ["/system/fonts/Good.ttf"] = true,
    ["/system/fonts/broken%2Font.ttf"] = true,
}
local opened = {}
package.preload["gettext"] = function() return function(s) return s end end
package.preload["utils.log"] = function() return { info = function() end, warn = function() end, dbg = function() end } end
package.preload["utils.paths"] = function()
    return { fontsDir = function() return "/tmp/fonts" end, slugFor = function(v) return v end }
end
package.preload["utils.settings"] = function()
    return { get = function() return { ui_font = "", ui_font_name = "" } end, save = function() end }
end
package.preload["datastorage"] = function()
    return { getDataDir = function() return "/tmp/ko" end }
end
package.preload["libs/libkoreader-lfs"] = function()
    return {
        attributes = function(path, key)
            if files[path] and (not key or key == "mode") then return "file" end
        end,
    }
end
package.preload["fontlist"] = function()
    return {
        fontdir = "/tmp/ko/fonts",
        fontlist = {
            "/tmp/ko/fonts/NotoSans-Regular.ttf",
            "/system/fonts/Source%201Han.ttf",
            "/system/fonts/Good.ttf",
            "/system/fonts/broken%2Font.ttf",
        },
        fontinfo = {},
        getFontList = function(self) return self.fontlist end,
        _readList = function() end,
    }
end
package.preload["device"] = function()
    return { screen = { scaleBySize = function(_, size) return size * 2 end } }
end
package.preload["ui/font"] = function()
    return {
        fontmap = { cfont = "NotoSans-Regular.ttf" },
        sizemap = { cfont = 16 },
        faces = {},
        fallbacks = { "NotoSans-Regular.ttf" },
        isRealBoldFont = function() return false end,
        getFace = function(self, font, size, faceindex)
            -- 与 koreader/frontend/ui/font.lua:getFace 回落搜索等价：只转义 `-`。
            local realname = (self.fontmap and self.fontmap[font]) or font
            local orig_size = size or 16
            local scaled = require("device").screen:scaleBySize(orig_size)
            local hash = realname .. scaled
            if faceindex then hash = hash .. "/" .. faceindex end
            if self.faces[hash] then return self.faces[hash] end
            local escaped = realname:gsub("[-]", "%%-")
            local FontList = require("fontlist")
            for _k, _v in ipairs(FontList:getFontList()) do
                if _v:find(escaped) then
                    local face = { orig_font = font, realname = realname, size = scaled, orig_size = size or 16, hash = hash, path = _v }
                    self.faces[hash] = face
                    return face
                end
            end
            return nil
        end,
    }
end
package.preload["ffi/freetype"] = function()
    return {
        newFaceSize = function(path, size, faceindex)
            opened[#opened + 1] = { path = path, size = size, faceindex = faceindex }
            if path:find("broken", 1, true) then error("freetype error code: 8") end
            if not files[path] then error("font not found: " .. tostring(path)) end
            return { path = path, size = size, faceindex = faceindex, done = function() end }
        end,
    }
end
package.preload["ui.fonts.woff"] = function() return { toSfnt = function() return nil, "no" end } end
package.preload["document/credocument"] = function()
    return { engineInit = function() return { registerFont = function() end, getFontFaces = function() return {} end } end }
end

package.loaded["ui.fonts"] = nil
package.loaded["ui/font"] = nil
package.loaded["fontlist"] = nil
local Fonts = require("ui.fonts")
local Font = require("ui/font")

-- 宿主等价 pattern：只转义 `-`，%1 会炸；完整字面转义则不会。
local weird = "Source%201Han.ttf"
local path = "/system/fonts/" .. weird
local host_pat = weird:gsub("[-]", "%%-")
local ok_host, err_host = pcall(function() return path:find(host_pat) end)
Assert.is_false(ok_host)
Assert.is_true(tostring(err_host):find("invalid capture", 1, true) ~= nil)

-- 未打补丁的宿主 getFace 会炸
Assert.is_false(pcall(function() Font:getFace(weird, 18) end))

-- 插件按绝对路径打开；缓存键 = realname .. scaledSize（18*2）
opened = {}
local face = Fonts.getFace(weird, 18)
Assert.is_true(type(face) == "table")
Assert.eq(face.realname, weird)
Assert.eq(face.orig_font, weird)
Assert.eq(face.orig_size, 18)
Assert.eq(face.size, 36)
Assert.eq(face.hash, weird .. "36")
Assert.eq(opened[1].path, path)
Assert.eq(opened[1].size, 36)
Assert.is_true(Font.faces[face.hash] == face)

local face0 = Fonts.getFace(weird, 18, 0)
Assert.eq(face0.hash, weird .. "36/0")
Assert.eq(opened[2].faceindex, 0)

local n = #opened
Assert.is_true(Fonts.getFace(weird, 18) == face)
Assert.eq(#opened, n)

Assert.is_nil(Fonts.getFace("broken%2Font.ttf", 18))
Assert.is_nil(Fonts.getFace("missing.ttf", 18))

-- patch 后：怪名字不再抛错，直接返回插件打开的 face
Fonts.patchGetFace()
local patched = Font:getFace(weird, 18)
Assert.is_true(type(patched) == "table")
Assert.eq(patched.hash, weird .. "36")
Assert.is_true(patched == face)

-- 内置目录字体仍走原实现（本桩不打开文件）
local builtin = Font:getFace("cfont", 16)
Assert.is_true(type(builtin) == "table")

-- fallback 走 Font.fallbacks → 内置 Noto，不复制宿主粗体变体逻辑
local fb = face.getFallbackFont(1)
Assert.is_true(type(fb) == "table")
Assert.eq(fb.realname, "NotoSans-Regular.ttf")

return true
