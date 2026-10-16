--[[--
界面主题：纸本 paper / 高对比 bold / 柔和 soft 三套令牌，组件在 ui/themes/widgets。

令牌是纯数据，不依赖 KOReader：
  颜色  8 位灰度（0x00 黑 … 0xFF 白），组件里经 Blitbuffer.Color8 变成颜色
  尺寸  逻辑像素，组件里经 Theme.px（DPI × ui_scale）
  字号  逻辑字号，组件里经 Theme.face（Font:getFace 自带 DPI，这里只乘 ui_scale）

三套主题的键集合完全一致（tests/ui/themes 校验），组件只读键、不判断主题 id。
当前主题读 ui.ui_theme，未设或写错回落 paper。

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

--- 当前主题令牌表。
---@return table
function Theme.current()
    return Theme.get(Theme.id())
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
