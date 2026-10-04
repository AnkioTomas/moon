--[[--
设置叠层：主题全屏页（标题栏返回 + 预览 + 分组设置项）；登记在 desktop.settings_overlay，
updateView 重算设置项，返回键 / close 关窗后清引用并让桌面重画。

@module tests.desktop.pages.setting.overlay_spec
--]]

local Assert = require("support.assert")
local Kit = require("support.widget_stubs")
Kit.install("paper")

local Row = require("ui.themes.widgets.row")
local Overlay = require("desktop.pages.setting.overlay")

--- dirty 记录里有没有刷过这个窗口（按钮点按反馈也会记一笔，不能只看最后一条）。
local function dirtied(widget)
    for _, d in ipairs(Kit.dirty) do
        if d.widget == widget then return true end
    end
    return false
end

-- 预览框：给定宽高的卡片；空预览同尺寸，框内淡字。
local box = Overlay.previewBox(560, Row.widget({ width = 100, title = "x" }), 40)
Assert.eq(box:getSize().w, 560)
Assert.eq(box:getSize().h, 40)
local empty = Overlay.previewPlaceholder(560, 40, "关")
Assert.eq(empty:getSize().h, 40)
Assert.contains(Kit.texts(empty), "关")

local status = "开"
local built = 0
local preview_w
local spec = {
    id = "demo",
    title = "阅读页顶栏",
    preview = function(width)
        preview_w = width
        return Overlay.previewPlaceholder(width, 40, "预览")
    end,
    sections = function()
        built = built + 1
        return { { title = "顶栏", rows = {
            function(width) return Row.widget({ width = width, title = "时钟", status = status }) end,
        } } }
    end,
}

local desktop = {}
Overlay.open(desktop, spec)
local overlay = desktop.settings_overlay
Assert.eq(Kit.shown[#Kit.shown], overlay)
Assert.is_false(overlay.mask, "全屏页不画遮罩")
Assert.eq(overlay[1]:getSize().h, 800)
overlay:paintTo(Kit.canvas(), 0, 0)
local texts = Kit.texts(overlay)
Assert.contains(texts, "阅读页顶栏")
Assert.contains(texts, "预览")
Assert.contains(texts, "顶栏")
Assert.contains(texts, "开")
Assert.eq(preview_w, 600 - 24, "预览两侧留 space.md")

-- 设置改了之后 updateView：重算 sections 并刷叠层自己。
status = "关"
Kit.dirty = {}
overlay:updateView()
overlay:paintTo(Kit.canvas(), 0, 0)
Assert.eq(built, 2)
Assert.contains(Kit.texts(overlay), "关")
Assert.is_true(dirtied(overlay))

-- 标题栏返回键关窗：清引用，桌面没关就重画桌面。
Kit.dirty = {}
Kit.buttons(overlay)[1]:onTapThemeButton()
Assert.eq(Kit.closed[#Kit.closed], overlay)
Assert.is_nil(desktop.settings_overlay)
Assert.is_true(dirtied(desktop))

-- 再开会先关旧叠层；桌面已关时关叠层不再重画桌面。
Overlay.open(desktop, spec)
local old = desktop.settings_overlay
Overlay.open(desktop, spec)
Assert.eq(Kit.closed[#Kit.closed], old)
Assert.is_true(desktop.settings_overlay ~= old)
desktop.closed = true
Kit.dirty = {}
desktop.settings_overlay:close()
Assert.is_nil(desktop.settings_overlay)
Assert.is_false(dirtied(desktop))
