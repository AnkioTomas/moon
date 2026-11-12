--[[--
Headless bootstrap for tests/features/share/export_previews.lua.
在仓库根执行：luajit tests/features/share/run_export.lua [输出目录]

不走 tests/run.lua，避免 support.stubs 把 blitbuffer / Font / ImageWidget 换成桩。
--]]

local function dirname(path)
    return path:match("^(.*)/[^/]+$") or "."
end

local here = arg[0]
if here:sub(1, 1) ~= "/" then
    local pwd = os.getenv("PWD") or "."
    here = pwd .. "/" .. here
end
local ROOT = dirname(dirname(dirname(dirname(here))))
if ROOT == "" then ROOT = "." end

local KO = ROOT .. "/koreader"
_G.BOOK_TEST_ROOT = ROOT

local function exists(path)
    local f = io.open(path, "r")
    if not f then return false end
    f:close()
    return true
end

local function newestEmu()
    local p = io.popen('ls -d "' .. KO .. '"/koreader-emulator-*/koreader 2>/dev/null | sort -r')
    if not p then return nil end
    local first = p:read("*l")
    p:close()
    return first
end

local EMU = newestEmu()
if not EMU then
    error("未找到 KOReader 模拟器构建目录")
end

local HOME = os.getenv("KO_HOME")
if not HOME or HOME == "" then
    HOME = ROOT .. "/test"
end
os.execute('mkdir -p "' .. HOME .. '/cache/fontlist" "' .. HOME .. '/settings"')

package.path = table.concat({
    KO .. "/frontend/?.lua",
    KO .. "/frontend/?/init.lua",
    KO .. "/base/?.lua",
    KO .. "/base/?/init.lua",
    ROOT .. "/book.koplugin/?.lua",
    ROOT .. "/book.koplugin/?/init.lua",
    ROOT .. "/tests/?.lua",
    ROOT .. "/tests/?/init.lua",
    package.path,
}, ";")

local lib_dirs = {
    HOME .. "/libs",
    EMU .. "/libs",
    EMU,
    ROOT .. "/test/libs",
}
local cpath = {}
for _, dir in ipairs(lib_dirs) do
    cpath[#cpath + 1] = dir .. "/?.so"
    cpath[#cpath + 1] = dir .. "/?.dylib"
    cpath[#cpath + 1] = dir .. "/lib?.so"
    cpath[#cpath + 1] = dir .. "/lib?.dylib"
end
package.cpath = table.concat(cpath, ";") .. ";" .. package.cpath

local ffi = require("ffi")
if not ffi.loadlib then
    ffi.loadlib = function(name, version)
        local names = {}
        if version then
            if ffi.os == "OSX" then
                names[#names + 1] = "lib" .. name .. "." .. version .. ".dylib"
            else
                names[#names + 1] = "lib" .. name .. ".so." .. version
            end
        end
        names[#names + 1] = "lib" .. name .. ".dylib"
        names[#names + 1] = "lib" .. name .. ".so"
        names[#names + 1] = name
        for _, dir in ipairs(lib_dirs) do
            for _, file in ipairs(names) do
                local path = dir .. "/" .. file
                if exists(path) then
                    local ok, lib = pcall(ffi.load, path)
                    if ok then return lib end
                end
            end
        end
        -- 退回按短名让 dyld/cpath 解析
        for _, file in ipairs(names) do
            local ok, lib = pcall(ffi.load, file)
            if ok then return lib end
        end
        error("ffi.loadlib failed: " .. tostring(name) .. " " .. tostring(version))
    end
end

package.preload["gettext"] = function()
    local function identity(s)
        return s
    end
    return setmetatable({
        pgettext = function(_, s) return s end,
        ngettext = function(one, _many, n) return n == 1 and one or (_many or one) end,
        gettext = identity,
        translation = {},
        current_lang = "zh_CN",
    }, { __call = function(_, s) return s end })
end

package.preload["datastorage"] = function()
    return {
        getDataDir = function() return HOME end,
        getSettingsDir = function() return HOME .. "/settings" end,
        getDocSettingsDir = function() return HOME .. "/docsettings" end,
        getDocSettingsHashDir = function() return HOME .. "/docsettings" end,
        getHistoryDir = function() return HOME .. "/history" end,
        getDataFile = function(_, name) return HOME .. "/" .. (name or "") end,
    }
end

-- ImageWidget 会 require documentregistry；导出预览不打开文档，给空实现即可。
package.preload["document/documentregistry"] = function()
    return {
        getProvider = function() return nil end,
        openDocument = function() return nil end,
        isImageFile = function() return true end,
    }
end

local Screen = {
    getWidth = function() return 1240 end,
    getHeight = function() return 1650 end,
    getDPI = function() return 300 end,
    scaleBySize = function(_, n) return n end,
    scaleByDPI = function(_, n) return n end,
    getSize = function() return { w = 1240, h = 1650 } end,
    isColorEnabled = function() return true end,
    isColorScreen = function() return true end,
    getWidthMM = function() return 100 end,
    getHeightMM = function() return 130 end,
    fb_bpp = 32,
}
package.preload["device"] = function()
    local Device = {
        screen = Screen,
        input = { disableRotationGestures = function() end },
        isTouchDevice = function() return true end,
        hasKeys = function() return false end,
        hasDPad = function() return false end,
        hasKeyboard = function() return false end,
        hasClipboard = function() return false end,
        hasBGRFrameBuffer = function() return false end,
        isKindle = function() return false end,
        isAndroid = function() return false end,
        isDesktop = function() return true end,
        isPocketBook = function() return false end,
        hasSystemFonts = function() return true end,
        hasEinkScreen = function() return false end,
        hasColorScreen = function() return true end,
        canHWDither = function() return false end,
        enableCPUCores = function() end,
        isSDL = function() return false end,
        isEmulator = function() return true end,
        canRestart = function() return false end,
        hasMultitouch = function() return false end,
        night_mode = false,
        home_dir = os.getenv("HOME"),
        canOpenLink = function() return false end,
        openLink = function() end,
    }
    -- 未声明的 isX / hasX / canX 一律当 false，避免 FontSettings 这类探测崩溃。
    setmetatable(Device, {
        __index = function(tbl, key)
            if type(key) == "string" and (key:match("^is") or key:match("^has") or key:match("^can")) then
                local fn = function() return false end
                rawset(tbl, key, fn)
                return fn
            end
        end,
    })
    return Device
end

-- UIManager / Cache 在 paint 路径里可能被碰到，给空操作。
package.preload["ui/uimanager"] = function()
    return {
        schedule = function() end,
        scheduleIn = function() end,
        unschedule = function() end,
        nextTick = function() end,
        show = function() end,
        close = function() end,
        setDirty = function() end,
        preventStandby = function() end,
        allowStandby = function() end,
        getTime = function() return 0 end,
        _window_stack = {},
    }
end

_G.G_reader_settings = setmetatable({
    readSetting = function() return nil end,
    saveSetting = function() end,
    delSetting = function() end,
    flush = function() end,
    has = function() return false end,
    isTrue = function() return false end,
    isFalse = function() return true end,
    nilOrTrue = function() return true end,
    nilOrFalse = function() return false end,
}, { __index = function() return function() end end })

_G.G_defaults = _G.G_reader_settings

-- FontList 默认扫 ./fonts；切到模拟器根目录以便找到 Noto。
assert(exists(EMU .. "/fonts/noto/NotoSans-Regular.ttf") or exists(EMU .. "/fonts/NotoSans-Regular.ttf") or true)
local lfs = require("libs/libkoreader-lfs")
assert(lfs.chdir(EMU))

local CanvasContext = require("document/canvascontext")
CanvasContext:init(require("device"))

-- 把仓库里的 Noto CJK 也挂到 fonts 搜索路径：通过软链到临时目录太重，
-- 导出脚本依赖 Card.fontDirs 扫系统 Songti 以及下面这个环境变量式补位。
-- 保持 EMU 为 cwd 即可。

-- 转交导出脚本（它会再 require Card / Render）
arg[0] = ROOT .. "/tests/features/share/export_previews.lua"
dofile(arg[0])
