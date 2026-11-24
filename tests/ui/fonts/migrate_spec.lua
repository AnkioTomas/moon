--[[--
ui.fonts 迁移、用户字体删除与缺失字体兜底：
1. 首次启动按 fonts_migrated_ver 版本号把旧 .moon/fonts 迁入 $DATA/fonts 用户字体目录；
2. 同步迁移 ui_font / western_font_id / book_reader_default_font_id，已迁版本不重复执行；
3. 缺失或损坏的旧字体自动清空配置并回退安全内置字体，避免闪退；
4. 删除正在使用的用户字体立即回退默认，Font:getFace 遇到失效 fontmap 槽位安全兜底。

@module tests.ui.fonts.migrate_spec
--]]

local Assert = require("support.assert")
local Config = require("support.config")
if not Config.available() then
    Assert.skip("沙箱数据目录未就绪，请用 ./tests/run.sh 运行")
end

local lfs = require("libs/libkoreader-lfs")
local test_root = Config.dir() .. "/font_migrate_spec"
local legacy_dir = test_root .. "/legacy_fonts"
local user_dir = test_root .. "/fonts"
os.execute("rm -rf '" .. test_root .. "'")
os.execute("mkdir -p '" .. legacy_dir .. "' '" .. user_dir .. "'")

local function writeFile(path, data)
    local f = assert(io.open(path, "wb"))
    assert(f:write(data))
    f:close()
end

-- 准备旧版字体：正常 TTF + 旧版 WOFF + 损坏文件
writeFile(legacy_dir .. "/syst.ttf", "\0\1\0\0good-ttf")
writeFile(legacy_dir .. "/old.woff", "woff-data")
writeFile(legacy_dir .. "/broken.ttf", "corrupt")

local settings_store = {
    ui = { ui_font = "syst", ui_font_name = "思源宋体", fonts_migrated_ver = 0 },
    reader = { western_font_id = "missing_west", western_font_name = "缺西文" },
}
local saved_owners = {}
package.preload["utils.settings"] = function()
    return {
        get = function(owner)
            settings_store[owner] = settings_store[owner] or {}
            return settings_store[owner]
        end,
        save = function(owner) saved_owners[#saved_owners + 1] = owner end,
    }
end
package.preload["datastorage"] = function()
    return { getDataDir = function() return test_root end }
end
package.preload["utils.paths"] = function()
    return {
        fontsDir = function() return legacy_dir end,
        ensureDir = function(dir) os.execute("mkdir -p '" .. dir .. "'") end,
    }
end
package.preload["util"] = function()
    return {
        findFiles = function(dir, fn)
            if lfs.attributes(dir, "mode") ~= "directory" then return end
            for name in lfs.dir(dir) do
                if name ~= "." and name ~= ".." then
                    local p = dir .. "/" .. name
                    if lfs.attributes(p, "mode") == "file" then fn(p, name) end
                end
            end
        end,
    }
end
local fontlist_tbl = { "/sys/NotoSans-Regular.ttf", "/sys/NotoSans-Bold.ttf" }
package.preload["fontlist"] = function()
    return {
        fontdir = "/sys",
        fontlist = fontlist_tbl,
        fontinfo = {},
        getFontList = function(self) return self.fontlist end,
        _readList = function() end,
    }
end
package.preload["device"] = function()
    return { screen = { scaleBySize = function(_, s) return s end } }
end
local fake_font = {
    fontmap = { cfont = "NotoSans-Regular.ttf", ffont = "NotoSans-Regular.ttf", tfont = "NotoSans-Bold.ttf" },
    sizemap = { cfont = 16, ffont = 16, tfont = 16 },
    faces = {},
    fallbacks = {},
    isRealBoldFont = function() return false end,
    getAdjustedFace = function(_, face) return face end,
    getFace = function(_, font, size)
        if font == "NotoSans-Regular.ttf" or font == "NotoSans-Bold.ttf" then
            return { realname = font, size = size or 16, fallback_safe = true }
        end
        return nil
    end,
}
package.preload["ui/font"] = function() return fake_font end
package.preload["ffi/freetype"] = function()
    return {
        newFaceSize = function(path, size)
            if path:find("broken", 1, true) then error("corrupt font") end
            local f = io.open(path, "rb")
            if not f then error("missing") end
            f:close()
            return { path = path, size = size, done = function() end }
        end,
    }
end
package.preload["ui.fonts.woff"] = function()
    return {
        toSfnt = function(_src, dest)
            writeFile(dest, "\0\1\0\0converted-woff")
            return true
        end,
    }
end
local grs = { book_reader_default_font_id = "syst" }
_G.G_reader_settings = {
    readSetting = function(_, k) return grs[k] end,
    saveSetting = function(_, k, v) grs[k] = v end,
    has = function(_, k) return grs[k] ~= nil end,
    delSetting = function(_, k) grs[k] = nil end,
}

package.loaded["ui.fonts"] = nil
local Fonts = require("ui.fonts")

-- 1. 首次迁移：按版本号把旧 .moon/fonts 迁到 $DATA/fonts
Assert.is_true(Fonts.migrateLegacy(), "版本号 0 应执行一次性迁移")
Assert.eq(settings_store.ui.fonts_migrated_ver, Fonts.MIGRATION_VER)
Assert.is_true(Fonts.isFile(user_dir .. "/syst.ttf"), "TTF 迁入用户字体目录")
Assert.is_true(Fonts.isFile(user_dir .. "/old.ttf"), "旧 WOFF 转换并迁入用户字体目录")
Assert.is_false(Fonts.isFile(legacy_dir .. "/syst.ttf"), "旧目录源文件已移除")
Assert.is_false(Fonts.isFile(legacy_dir .. "/old.woff"), "旧目录 WOFF 已移除")

-- 配置 id 自动更新，缺失西文字体自动清掉兜底
Assert.eq(settings_store.ui.ui_font, "syst.ttf")
Assert.eq(grs.book_reader_default_font_id, "syst.ttf")
Assert.eq(settings_store.reader.western_font_id, "", "缺失西文字体应清掉兜底")

-- 2. 二次调用：版本号已最新，直接跳过不再迁移
Assert.is_false(Fonts.migrateLegacy(), "已迁移版本号不应重复迁移")

-- 3. 旧书 sidecar 里残留无扩展名 id（如 "syst"）仍可解析到用户目录的 syst.ttf
local resolved = select(1, Fonts.pathForId("syst"))
Assert.eq(resolved, user_dir .. "/syst.ttf")

-- 4. 删除正在使用的用户字体：文件删掉、ui_font 自动清空并回退默认
Fonts.applyCurrent()
Assert.eq(fake_font.fontmap.cfont, "syst.ttf")
Assert.is_true(Fonts.deleteUserFont("syst.ttf"))
Assert.is_false(Fonts.isFile(user_dir .. "/syst.ttf"))
Assert.eq(settings_store.ui.ui_font, "", "删除当前界面字体后应自动清空配置")
Assert.eq(fake_font.fontmap.cfont, "NotoSans-Regular.ttf", "fontmap 应立即回退安全默认")

-- 5. 外部把字体删了导致 fontmap 指向失效文件：patchGetFace 兜底返回 SAFE_UI，不返回 nil 防止闪退
fake_font.fontmap.cfont = "Vanished.ttf"
local fallback_face = fake_font:getFace("cfont", 16)
Assert.not_nil(fallback_face, "缺失界面字体必须兜底，不能返回 nil 导致闪退")
Assert.eq(fallback_face.realname, "NotoSans-Regular.ttf")
Assert.eq(fake_font.fontmap.cfont, "NotoSans-Regular.ttf")

-- 6. 迁移遇到损坏 ui_font 也自动兜底清空
settings_store.ui.fonts_migrated_ver = 0
settings_store.ui.ui_font = "broken.ttf"
settings_store.ui.ui_font_name = "坏字体"
Assert.is_true(Fonts.migrateLegacy())
Assert.eq(settings_store.ui.ui_font, "", "损坏的界面字体迁移时自动清空兜底")
Assert.eq(settings_store.ui.ui_font_name, "")

os.execute("rm -rf '" .. test_root .. "'")
return true
