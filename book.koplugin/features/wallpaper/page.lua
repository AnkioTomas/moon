--[[-- 界面壁纸设置项。
@module koplugin.book.features.wallpaper.page
--]]

local lfs = require("libs/libkoreader-lfs")
local UIManager = require("ui/uimanager")
local List = require("ui.themes.widgets.list")
local Row = require("ui.themes.widgets.row")
local Image = require("utils.image")
local Theme = require("ui.themes")
local Core = require("features.wallpaper")
local _ = require("gettext")

---@class BookSettingsWallpaper
local Page = {}

---@class BookWallpaperScope
---@field id string
---@field icon string
---@field title string
---@field subtitle string

--- 两个作用面。
local SCOPES = {
    { id = "desktop", icon = "web_asset", title = _("月读页面"),
        subtitle = _("桌面、书架、书城、统计、设置") },
    { id = "dialog", icon = "chat_bubble", title = _("弹窗与详情"),
        subtitle = _("弹窗、设置叠层、书籍详情") },
}

--- 改完设置重画所有用到壁纸的界面（updateView 末尾会顺带重建设置叠层）。
---@param desktop table
local function repaint(desktop)
    desktop:updateView()
    UIManager:setDirty(desktop, "full")
end

--- 导航行；opts 即 Row.widget 参数（宽度在绘制时补上）。
---@param opts table
---@return fun(iw: number): table
local function navRow(opts)
    return function(iw)
        opts.width, opts.kind = iw, "nav"
        return Row.widget(opts)
    end
end

--- 单选行：点开列表，选中新值写配置并重画。apply 返回 false 表示还没定，不重画。
---@param desktop table
---@param opts { icon: string, title: string, status: string, items: table[], current: string, apply: fun(value: string): boolean|nil }
---@return fun(iw: number): table
local function choiceRow(desktop, opts)
    return navRow{
        icon = opts.icon, title = opts.title, status = opts.status,
        callback = function()
            List:new{
                title = opts.title, items = opts.items, current = opts.current, centered = true,
                on_select = function(value)
                    if not value or value == opts.current then return end
                    if opts.apply(value) == false then return end
                    repaint(desktop)
                end,
            }:show()
        end,
    }
end

--- 弹路径选择器选图片（is_file）或文件夹。
---@param desktop table
---@param current string 当前路径
---@param is_file boolean
---@param apply fun(path: string)
local function choosePath(desktop, current, is_file, apply)
    local dir = is_file and current:match("^(.*)/") or current
    local start = lfs.attributes(dir, "mode") == "directory" and current
        or require("apps/filemanager/filemanagerutil").getHomeFolder()
    require("ui.themes.widgets.path_picker"):new{
        path = start,
        select_file = is_file,
        filter = is_file and function(name) return Image.suffix(name) ~= nil end or nil,
        on_select = function(path)
            apply(path)
            repaint(desktop)
        end,
    }:show()
end

--- 开关行：kind=toggle，点一下写配置并重画。
---@param desktop table
---@param opts { icon: string, title: string, subtitle: string|nil, on: boolean, apply: fun(on: boolean) }
---@return fun(iw: number): table
local function toggleRow(desktop, opts)
    return function(iw)
        return Row.widget({
            width = iw, chevron = false,
            kind = "toggle", icon = opts.icon, title = opts.title,
            subtitle = opts.subtitle,
            status = opts.on and _("开") or _("关"), status_on = opts.on,
            callback = function()
                opts.apply(not opts.on)
                repaint(desktop)
            end,
        })
    end
end

---@param desktop table
---@return table
function Page:rows(desktop)
    local mode = Core.mode()
    local rows = {
        toggleRow(desktop, {
            icon = "wallpaper", title = _("启用界面壁纸"),
            subtitle = _("关上就整个不画，下面的开关原样留着"),
            on = Core.isOn(),
            apply = function(on) Core.setOn(on) end,
        }),
    }
    if not Core.isOn() then
        return rows
    end

    rows[#rows + 1] = choiceRow(desktop, {
        icon = "image", title = _("壁纸图源"), status = Core.label(mode),
        items = Core.options(), current = mode,
        apply = function(value) Core.setMode(value) end,
    })
    if mode == "none" then
        return rows
    end

    if mode == "custom" then
        local path = Core.customImage()
        rows[#rows + 1] = navRow{
            icon = "image", title = _("选择图片"), subtitle = path,
            callback = function() choosePath(desktop, path, true, Core.setCustomImage) end,
        }
    elseif mode == "folder" then
        local path = Core.folder()
        rows[#rows + 1] = navRow{
            icon = "folder", title = _("选择文件夹"), subtitle = path,
            callback = function() choosePath(desktop, path, false, Core.setFolder) end,
        }
    end

    if mode ~= "none" then
        local contain = Core.contain()
        rows[#rows + 1] = choiceRow(desktop, {
            icon = "crop", title = _("铺法"), status = contain and _("整图") or _("铺满"),
            items = { { text = _("铺满裁切"), value = "cover" }, { text = _("整图缩进"), value = "contain" } },
            current = contain and "contain" or "cover",
            apply = function(value) Core.setContain(value == "contain") end,
        })
    end

    local bars = Core.bars()
    rows[#rows + 1] = toggleRow(desktop, {
        icon = "space_bar", title = _("顶栏显示壁纸"),
        subtitle = _("关上顶栏用页面底色"),
        on = bars.top,
        apply = function(on) Core.setBar("top", on) end,
    })
    rows[#rows + 1] = toggleRow(desktop, {
        icon = "space_bar", title = _("底栏显示壁纸"),
        subtitle = _("关上底栏用页面底色"),
        on = bars.bottom,
        apply = function(on) Core.setBar("bottom", on) end,
    })

    for _idx, scope in ipairs(SCOPES) do
        local on = Core.enabled(scope.id)
        rows[#rows + 1] = toggleRow(desktop, {
            icon = scope.icon, title = scope.title,
            subtitle = scope.subtitle,
            on = on,
            apply = function(value) Core.setScope(scope.id, value) end,
        })
    end

    return rows
end

--- 已选壁纸缩略；没开 / 没图走占位。
---@param width number
---@return table
function Page.preview(width)
    local Overlay = require("desktop.pages.setting.overlay")
    local preview_h = Theme.px(144)
    if not Core.anyEnabled() then
        return Overlay.previewPlaceholder(width, preview_h, _("关"))
    end
    local path = Core.path()
    if not path then
        return Overlay.previewPlaceholder(width, preview_h, _("无可用图片"))
    end
    local Geom = require("ui/geometry")
    local CenterContainer = require("ui/widget/container/centercontainer")
    local ImageWidget = require("ui/widget/imagewidget")
    local inner_w = math.max(1, width - 2)
    local inner_h = math.max(1, preview_h - 2)
    return Overlay.previewBox(width, CenterContainer:new{
        dimen = Geom:new{ w = inner_w, h = inner_h },
        ImageWidget:new{
            file = path,
            width = inner_w,
            height = inner_h,
            -- 同一路径可能被换掉（自定义图被覆盖），按路径命中会一直显示旧图。
            file_do_cache = false,
        },
    }, preview_h)
end

return Page
