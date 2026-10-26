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

--- 各界面；顺序即设置页顺序。
local SCOPES = {
    { id = "home", icon = "home", title = _("桌面"), subtitle = _("首页") },
    { id = "library", icon = "local_library", title = _("书架"), subtitle = _("图书馆") },
    { id = "store", icon = "storefront", title = _("书城"), subtitle = _("书城") },
    { id = "insight", icon = "bar_chart", title = _("统计"), subtitle = _("阅读统计") },
    { id = "settings", icon = "settings", title = _("设置"), subtitle = _("设置页字看不清时调低透明度或关掉") },
    { id = "dialog", icon = "chat_bubble", title = _("弹窗与详情"), subtitle = _("弹窗、书籍详情") },
    { id = "reader", icon = "menu_book", title = _("阅读页"),
        subtitle = _("下次打开书生效，仅 EPUB / TXT 等排版文档；建议调低透明度") },
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

local FOLLOW = "follow"

--- 透明度选项；with_follow 时多一项「跟随全局」。
---@param with_follow boolean
---@return table[]
local function opacityItems(with_follow)
    local items = with_follow and { { text = _("跟随全局"), value = FOLLOW } } or {}
    for pct = 100, 10, -10 do items[#items + 1] = { text = pct .. "%", value = tostring(pct) } end
    return items
end

---@param with_follow boolean
---@return table[]
local function layoutItems(with_follow)
    local items = with_follow and { { text = _("跟随全局"), value = FOLLOW } } or {}
    items[#items + 1] = { text = _("铺满裁切"), value = "cover" }
    items[#items + 1] = { text = _("整图缩进"), value = "contain" }
    return items
end

---@param contain boolean
---@return string
local function layoutLabel(contain)
    return contain and _("整图") or _("铺满")
end

--- 图片行：没选过 / 选了文件名；点开选一张图或一个文件夹（文件夹里随机换图）。
---@param desktop table
---@param opts { title: string, path: string|nil, empty: string, apply: fun(path: string), clear: (fun())|nil }
---@return fun(iw: number): table
local function imageRow(desktop, opts)
    local is_dir = opts.path and lfs.attributes(opts.path, "mode") == "directory"
    local items = {
        { text = _("选一张图片"), value = "file" },
        { text = _("选文件夹（随机换图）"), value = "folder" },
    }
    if opts.clear then items[#items + 1] = { text = _("跟随全局"), value = "clear" } end
    return navRow{
        icon = is_dir and "folder" or "image", title = opts.title,
        status = opts.path and opts.path:match("[^/]*$") or opts.empty,
        subtitle = opts.path and is_dir and opts.path .. "\n" .. _("每次启动 / 唤醒随机换一张") or opts.path,
        callback = function()
            List:new{
                title = opts.title, centered = true, items = items,
                on_select = function(action)
                    local start = opts.path or require("apps/filemanager/filemanagerutil").getHomeFolder() --[[@as string]]
                    if action == "clear" then
                        opts.clear()
                        repaint(desktop)
                    elseif action then
                        choosePath(desktop, start, action == "file", opts.apply)
                    end
                end,
            }:show()
        end,
    }
end

---@param desktop table
---@param scope BookWallpaperScope
---@return table[]
local function scopeRows(desktop, scope)
    local id = scope.id
    local contain, opacity = Core.override(id, "contain"), Core.override(id, "opacity")
    local own_image = Core.override(id, "image")
    local rows = {
        toggleRow(desktop, {
            icon = scope.icon, title = _("显示壁纸"), subtitle = scope.subtitle,
            on = Core.scopeOn(id),
            apply = function(on) Core.setScope(id, on) end,
        }),
        imageRow(desktop, {
            title = _("壁纸图片"), path = own_image, empty = _("跟随全局"),
            apply = function(path) Core.setOverride(id, "image", path) end,
            clear = function() Core.setOverride(id, "image", nil) end,
        }),
        choiceRow(desktop, {
            icon = "crop", title = _("铺法"),
            status = contain == nil and _("跟随全局") or layoutLabel(contain),
            items = layoutItems(true),
            current = contain == nil and FOLLOW or (contain and "contain" or "cover"),
            apply = function(value)
                Core.setOverride(id, "contain", value ~= FOLLOW and value == "contain" or nil)
            end,
        }),
        choiceRow(desktop, {
            icon = "opacity", title = _("壁纸透明度"),
            status = opacity and opacity .. "%" or _("跟随全局"),
            items = opacityItems(true), current = opacity and tostring(opacity) or FOLLOW,
            apply = function(value) Core.setOverride(id, "opacity", tonumber(value)) end,
        }),
    }
    return rows
end

---@param desktop table
---@return table 主页面叠层规格
function Page.spec(desktop)
    return {
        title = _("界面壁纸"),
        preview = function(width) return Page.preview(width) end,
        sections = function() return Page.sections(desktop) end,
    }
end

--- 某个界面的子页；返回时回到主页。
---@param desktop table
---@param scope BookWallpaperScope
local function openScope(desktop, scope)
    require("desktop.pages.setting.overlay").open(desktop, {
        title = scope.title,
        on_close = function()
            if not desktop.closed then require("desktop.pages.setting.overlay").open(desktop, Page.spec(desktop)) end
        end,
        sections = function() return { { title = scope.title, rows = scopeRows(desktop, scope) } } end,
    })
end

---@param desktop table
---@return table[]
function Page.sections(desktop)
    local rows = {
        toggleRow(desktop, {
            icon = "wallpaper", title = _("启用界面壁纸"),
            subtitle = _("关上就整个不画，各界面的设置原样留着"),
            on = Core.isOn(),
            apply = function(on) Core.setOn(on) end,
        }),
    }
    if not Core.isOn() then return { { title = _("全局"), rows = rows } } end

    rows[#rows + 1] = imageRow(desktop, {
        title = _("壁纸图片"), path = Core.image(), empty = _("未选择"), apply = Core.setImage,
    })
    local contain = Core.contain()
    rows[#rows + 1] = choiceRow(desktop, {
        icon = "crop", title = _("铺法"), status = layoutLabel(contain),
        items = layoutItems(false), current = contain and "contain" or "cover",
        apply = function(value) Core.setContain(value == "contain") end,
    })
    local opacity = Core.opacity()
    rows[#rows + 1] = choiceRow(desktop, {
        icon = "opacity", title = _("壁纸透明度"), status = opacity .. "%",
        items = opacityItems(false), current = tostring(opacity),
        apply = function(value) Core.setOpacity(tonumber(value)) end,
    })
    local bars = Core.bars()
    rows[#rows + 1] = toggleRow(desktop, {
        icon = "space_bar", title = _("顶栏显示壁纸"), subtitle = _("关上顶栏用页面底色"),
        on = bars.top, apply = function(on) Core.setBar("top", on) end,
    })
    rows[#rows + 1] = toggleRow(desktop, {
        icon = "space_bar", title = _("底栏显示壁纸"), subtitle = _("关上底栏用页面底色"),
        on = bars.bottom, apply = function(on) Core.setBar("bottom", on) end,
    })
    if bars.bottom then
        rows[#rows + 1] = toggleRow(desktop, {
            icon = "space_bar", title = _("底栏文字不变灰"), subtitle = _("未选中的图标文字与正文同色"),
            on = Core.plainTabbar(), apply = function(on) Core.setPlainTabbar(on) end,
        })
    end

    local scope_rows = {}
    for _idx, scope in ipairs(SCOPES) do
        local on = Core.enabled(scope.id)
        local custom = Core.override(scope.id, "image") ~= nil or Core.override(scope.id, "contain") ~= nil
            or Core.override(scope.id, "opacity") ~= nil
        scope_rows[#scope_rows + 1] = navRow{
            icon = scope.icon, title = scope.title,
            subtitle = custom and _("已单独调整") or _("跟随全局"),
            status = on and _("开") or _("关"), status_on = on,
            callback = function() openScope(desktop, scope) end,
        }
    end
    return { { title = _("全局"), rows = rows }, { title = _("各界面"), rows = scope_rows } }
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
