--[[--
界面主题：纸本 paper / 高对比 bold / 柔和 soft 三套令牌，组件在 ui/themes/widgets。

令牌是纯数据，不依赖 KOReader：
  颜色  8 位灰度（0x00 黑 … 0xFF 白）或 0xRRGGBB，组件经 Theme.color 变成颜色
  尺寸  逻辑像素，组件里经 Theme.px（DPI × ui_scale）
  字号  逻辑字号，组件里经 Theme.face（Font:getFace 自带 DPI，这里只乘 ui_scale）

三套主题的键集合完全一致（tests/ui/themes 校验），组件只读键、不判断主题 id。
当前主题读 ui.ui_theme，未设或写错回落 paper。
彩色渲染开启时，导航、图标、标题、书名和统计共用一个主题色（色板见
ui/themes/palettes.lua）；正文保持黑白。没选过色板时用旧 theme_color。
彩色令牌按主题缓存，不改原始灰度令牌。彩屏（Kindle Color / Kaleido）会把颜色
冲淡，主题色在收口处经 Theme.vivid 补饱和后再派生，存量配置不迁移。

ui/themes 自成一体：除 KOReader 自带模块与 utils.settings / l10n 外不依赖插件其他 UI 组件。
缩放沿用设置 ui.ui_scale（百分比，100–180，缺省 130），与旧桌面同一个键。

组件在 widgets/：基础件 box / text / icon / button / tap / progress / image / mask；布局件 row / titlebar / tabbar / pager / sections；
弹窗都继承 modal（confirm / toast / sheet / list / input / spin / icon_picker / path_picker / progress_dialog / qr / text_viewer），:show() / :close()。
组件内部取 Theme.current()，调用方不传主题；opts 的 width / height 是物理像素（文件头注明逻辑像素的除外）。
Modal 定位 anchor = center / top / 某个矩形（下拉）；弹窗一律带遮罩，只有全屏页（covers_fullscreen）不画，全局开关 ui.mesh_mask；dismissable、close_on_tap 控制点外关窗。
progress_dialog 点按不关窗，转后台只是关窗；后台任务的前台进度走 workers/ui/task_dialog.follow。
新增组件：放 widgets/，值一律从令牌取、不写死像素，不引用 ui/widgets；新增令牌三套主题同时加（init_spec 校验）。
新增主题：<id>.lua 键集合一致，再加进 Theme.ids。演示页在 book.koplugin/demo/（打包剔除）。

@module koplugin.book.ui.themes
--]]

local Device = require("device")
---@type BlitBufferModule
local Blitbuffer = require("ffi/blitbuffer")
local Font = require("ui/font")
local MoonSettings = require("utils.settings")
local Screen = Device.screen

---@class BookTheme
local Theme = {}

--- 主题 id，顺序即展示顺序。
Theme.ids = { "paper", "bold", "soft" }

local DEFAULT = "paper"
Theme.SCALE_MIN, Theme.SCALE_MAX, Theme.SCALE_STEP = 100, 180, 10
local known = {}
local colored = {}
for _idx, id in ipairs(Theme.ids) do known[id] = true end

--- 取指定主题的令牌表。
---@param id string
---@return table
function Theme.get(id)
    assert(known[id], "unknown ui theme: " .. tostring(id))
    return (require("ui.themes." .. id))
end

--- 当前主题 id。未设或写错回落 paper。
---@return string
function Theme.id()
    local id = MoonSettings.get("ui").ui_theme
    return known[id] and id or DEFAULT
end

--- 写入主题 id。未知 id 不落盘，返回当前 id。
---@param id string|nil
---@return string
function Theme.set(id)
    if not known[id] then return Theme.id() end
    local display = MoonSettings.get("ui")
    display.ui_theme = id
    MoonSettings.save("ui", display)
    return id
end

--- 补饱和：绕三通道均值拉开色差。彩色墨水屏的滤光层会把 RGB 往灰里冲，
--- 存量主题色和拿 accent 往灰里掺的派生色都靠它补回来；灰度与等通道色原样返回。
---@param value number 0xRRGGBB 或灰度
---@return number
function Theme.vivid(value)
    if value <= 0xFF then return value end
    local r = math.floor(value / 0x10000)
    local g = math.floor(value / 0x100) % 0x100
    local b = value % 0x100
    local mean = (r + g + b) / 3
    local function boost(channel)
        return math.max(0, math.min(0xFF, math.floor(mean + (channel - mean) * 1.7 + 0.5)))
    end
    return boost(r) * 0x10000 + boost(g) * 0x100 + boost(b)
end

--- 主按钮底色上的文字色：按相对亮度选黑或白（移植自 mooncolor 的 foreground）。
---@param rgb number 0xRRGGBB
---@return number 灰度 0x00 或 0xFF
local function onColor(rgb)
    local function lin(n)
        n = n / 255
        return n <= 0.04045 and n / 12.92 or ((n + 0.055) / 1.055) ^ 2.4
    end
    local lum = 0.2126 * lin(math.floor(rgb / 0x10000))
        + 0.7152 * lin(math.floor(rgb / 0x100) % 0x100) + 0.0722 * lin(rgb % 0x100)
    return (lum + 0.05) / 0.05 >= 1.05 / (lum + 0.05) and 0x00 or 0xFF
end

--- 当前主题令牌表。彩色时全场共用一个主题色（色板见 ui/themes/palettes.lua）：
--- 按钮、图标、标题、导航、统计全部取 accent——分角色着色实测看不出区别，不值一套管线，别再拆。
---@return table
function Theme.current()
    local base = Theme.get(Theme.id())
    if not (Screen.isColorEnabled and Screen:isColorEnabled()) then return base end
    local conf = MoonSettings.get("ui")
    local signature = tostring(conf.theme_preset) .. ":" .. tostring(conf.theme_color)
    if not colored[base.id] or colored[base.id].signature ~= signature then
        local accent = Theme.vivid(require("ui.themes.palettes").color(conf.theme_preset, conf.theme_color))
        local t = {}
        for key, value in pairs(base) do t[key] = value end
        t.color = {}
        for key, value in pairs(base.color) do t.color[key] = value end
        t.color.accent = accent
        t.button = {
            normal = { bg = base.button.normal.bg, ink = accent, border_color = accent },
            primary = { bg = accent, ink = onColor(accent), border_color = accent },
            ghost = { ink = accent },
        }
        t.selected = {
            bg = base.selected.bg == base.color.ink and accent or base.selected.bg,
            ink = base.selected.ink == base.color.ink and accent or base.selected.ink,
            mark = base.selected.mark,
        }
        for _idx, name in ipairs({ "card", "raised", "dialog" }) do
            t[name] = {}
            for key, value in pairs(base[name]) do t[name][key] = value end
            t[name].border_color = accent
        end
        t.progress = {}
        for key, value in pairs(base.progress) do t.progress[key] = value end
        t.progress.fill, t.progress.border_color = accent, accent
        colored[base.id] = { signature = signature, tokens = t }
    end
    return colored[base.id].tokens
end

--- 颜色之间插值；不能直接对打包后的 RGB 整数做算术。
---@param from number
---@param to number
---@param fraction number
---@return number
function Theme.mix(from, to, fraction)
    if fraction == 0 then return from end
    if fraction == 1 then return to end
    local function mix(a, b) return math.floor(a + (b - a) * fraction + 0.5) end
    if from <= 0xFF and to <= 0xFF then return mix(from, to) end
    local function channel(value, divisor)
        return value <= 0xFF and value or math.floor(value / divisor) % 0x100
    end
    -- 掺灰本身就掉饱和，彩色结果补回来，否则热力图低档在彩屏上与灰阶无异。
    return Theme.vivid(mix(channel(from, 0x10000), channel(to, 0x10000)) * 0x10000
        + mix(channel(from, 0x100), channel(to, 0x100)) * 0x100
        + mix(channel(from, 1), channel(to, 1)))
end

--- 灰度 / RGB 令牌转绘图颜色；灰度主题保留原来的 Color8 路径。
---@param value number
---@return BlitColor
function Theme.color(value)
    if value <= 0xFF then return Blitbuffer.Color8(value) end
    return Blitbuffer.ColorRGB32(math.floor(value / 0x10000), math.floor(value / 0x100) % 0x100, value % 0x100, 0xFF)
end

--- 当前 UI 缩放百分比（夹到 100–180）。
---@return number
function Theme.scale()
    local n = tonumber(MoonSettings.get("ui").ui_scale) or 130
    return math.max(Theme.SCALE_MIN, math.min(Theme.SCALE_MAX, n))
end

--- 写入 UI 缩放百分比，夹到 100–180 并按 10 取整。
---@param n number|nil
---@return number
function Theme.setScale(n)
    n = tonumber(n) or 130
    n = math.max(Theme.SCALE_MIN, math.min(Theme.SCALE_MAX, n))
    local step = Theme.SCALE_STEP
    n = math.floor((n + step / 2) / step) * step
    local display = MoonSettings.get("ui")
    display.ui_scale = n
    MoonSettings.save("ui", display)
    return n
end

--- 逻辑像素 → 物理像素（DPI × ui_scale）；0 保持 0，其余至少 1。
---@param n number
---@return number
function Theme.px(n)
    if n <= 0 then return 0 end
    return math.max(1, math.floor(Screen:scaleBySize(n) * Theme.scale() / 100 + 0.5))
end

--- 逻辑字号 → Font 字号（只乘 ui_scale；DPI 由 Font:getFace 自己乘，不能再过 px）。
---@param size number
---@return number
function Theme.fontSize(size)
    return math.max(10, math.floor(size * Theme.scale() / 100 + 0.5))
end

---@param name string Font.fontmap 字面名
---@param size number 逻辑字号
---@return table
function Theme.face(name, size)
    return Font:getFace(name, Theme.fontSize(size))
end

local _root

--- 插件根目录（…/book.koplugin/，带尾斜杠）：图标字体、相对路径图片按它解析。
---@return string
function Theme.root()
    if not _root then
        local src = debug.getinfo(1, "S").source
        _root = src:sub(1, 1) == "@" and src:sub(2):match("(.*/)ui/themes/[^/]+$") or ""
    end
    return _root
end

return Theme
