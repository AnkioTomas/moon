--[[--
界面壁纸：把一张图铺在月读自己的各个界面之下。

图源只留用户自己的图（自定义 / 文件夹壁纸），独立于锁屏配置；一个总开关加上
两个作用面开关：
  desktop  月读桌面与各页（首页 / 图书馆 / 书城 / 统计 / 设置）
  dialog   弹窗、设置叠层、详情等主题窗口（画在遮罩之下）

阅读页不铺：crengine 把正文整屏铺满不透明，垫在下面看不见，叠加又会压低文字
对比度，实测（epub / html）都不理想，索性不做。

位图按「路径 + 尺寸 + 铺法」只缓存一张：两个作用面尺寸不同会来回换，但界面
一次只画一处，换一次解一次可接受；改设置经 invalidate 丢弃。

界面上「铺满整片的底色」不止一层：页根一层、Sections 正文框又一层（所以只摘
页根的话只有上面一条透得出来）。hollow 整棵树走一遍，把这些层一起摘掉；卡片、
对话框因为 style 是共享令牌（带圆角 / 阴影）不会被摘。

@module koplugin.book.features.wallpaper
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local lfs = require("libs/libkoreader-lfs")
local Image = require("utils.image")
local MoonSettings = require("utils.settings")
local Paths = require("utils.paths")
local logger = require("utils.log")
local _ = require("gettext")
local Screen = Device.screen

local M = {}

--- 两个作用面；键是配置后缀。
local SCOPE_KEYS = { desktop = "wallpaper_desktop", dialog = "wallpaper_dialog" }
M.SCOPES = { "desktop", "dialog" }

---@return table
local function conf()
    return MoonSettings.get("features.wallpaper")
end

-- ── 图源 ──────────────────────────────

--- 用户选的自定义图；没选过用 .moon/screensaver/wallpaper.png。
---@return string
function M.customImage()
    return conf().wallpaper_custom_image or Paths.screensaverDir() .. "/wallpaper.png"
end

--- 用户选的壁纸文件夹；没选过用 .moon/screensaver/wallpapers（与锁屏同一个）。
---@return string
function M.folder()
    return conf().wallpaper_folder or Paths.screensaverDir() .. "/wallpapers"
end

local folder_cache = {}

--- 目录及其修改时间未变时复用已排序的图片路径。
---@param dir string
---@return string[]
local function folderFiles(dir)
    local modification = lfs.attributes(dir, "modification")
    if not modification then return {} end
    if folder_cache.dir == dir and folder_cache.modification == modification then
        return folder_cache.files
    end
    local files = {}
    for name in lfs.dir(dir) do
        local path = dir .. "/" .. name
        if Image.suffix(name) and lfs.attributes(path, "mode") == "file" then files[#files + 1] = path end
    end
    table.sort(files)
    folder_cache = { dir = dir, modification = modification, files = files }
    return files
end

--- 按日期依次轮换文件夹里的图：同一天固定一张，不落盘任何状态。
---@return string|nil
local function folderPick()
    local files = folderFiles(M.folder())
    if #files == 0 then return nil end
    local t = os.date("*t")
    ---@cast t osdate
    local day = math.floor(os.time{ year = t.year, month = t.month, day = t.day, hour = 12 } / 86400)
    return files[day % #files + 1]
end

--- 页面壁纸只用用户自己的图：在线日报 / 封面都是拿来当封面的，铺到页面上太花。
local SOURCES = {
    none = { id = "none", label = _("无") },
    custom = { id = "custom", label = _("自定义"), path = function() return M.customImage() end },
    folder = { id = "folder", label = _("文件夹壁纸"), path = folderPick },
}
local SOURCE_IDS = { "none", "custom", "folder" }

--- 当前图源 id。
---@return string
function M.mode()
    local mode = conf().wallpaper_source
    return SOURCES[mode] and mode or "none"
end

--- 切换图源；非法值忽略。改完丢掉缓存，下一次绘制重新解图。
---@param mode string
function M.setMode(mode)
    if not SOURCES[mode] then return end
    local c = conf()
    if c.wallpaper_source == mode then return end
    c.wallpaper_source = mode
    MoonSettings.save("features.wallpaper", c)
    M.invalidate()
end

--- 图源的显示名。
---@param mode string|nil
---@return string
function M.label(mode)
    return (mode and SOURCES[mode] or SOURCES.none).label
end

--- 图源的设置页选项。
---@return {text: string, value: string}[]
function M.options()
    local out = {}
    for _idx, id in ipairs(SOURCE_IDS) do out[#out + 1] = { text = SOURCES[id].label, value = id } end
    return out
end

--- 是否整图缩进（两侧留底色）；缺省铺满裁切。
---@return boolean
function M.contain()
    if conf().wallpaper_contain == true then return true end
    return SOURCES[M.mode()].contain == true
end

--- 切铺法。
---@param on boolean
function M.setContain(on)
    local c = conf()
    c.wallpaper_contain = on == true
    MoonSettings.save("features.wallpaper", c)
    M.invalidate()
end

-- ── 总开关与顶栏 / 底栏 ──────────────────

--- 总开关。关上就整个不画，两个作用面的开关原样留着（再开就回来）。
---@return boolean
function M.isOn()
    return conf().wallpaper_enabled ~= false
end

---@param on boolean
function M.setOn(on)
    local c = conf()
    c.wallpaper_enabled = on == true
    MoonSettings.save("features.wallpaper", c)
    M.invalidate()
end

--- 顶栏 / 底栏要不要跟着透出壁纸；关的那条补回页面底色。
---@return {top: boolean, bottom: boolean}
function M.bars()
    local c = conf()
    return { top = c.wallpaper_topbar ~= false, bottom = c.wallpaper_tabbar ~= false }
end

---@param which string top / bottom
---@param on boolean
function M.setBar(which, on)
    local key = which == "bottom" and "wallpaper_tabbar" or "wallpaper_topbar"
    local c = conf()
    c[key] = on == true
    MoonSettings.save("features.wallpaper", c)
    M.invalidate()
end

-- ── 作用面开关 ──────────────────────────

--- 某个作用面是否铺壁纸。
---@param scope string|nil
---@return boolean
function M.enabled(scope)
    local key = SCOPE_KEYS[scope]
    if not key or M.mode() == "none" then return false end
    return M.isOn() and conf()[key] == true
end

--- 任一作用面开着（总开关关了就不算）。
---@return boolean
function M.anyEnabled()
    if not M.isOn() then return false end
    for _idx, scope in ipairs(M.SCOPES) do
        if M.enabled(scope) then return true end
    end
    return false
end

--- 开关某个作用面。
---@param scope string
---@param on boolean
function M.setScope(scope, on)
    local key = SCOPE_KEYS[scope]
    if not key then return end
    local c = conf()
    c[key] = on == true
    MoonSettings.save("features.wallpaper", c)
    M.invalidate()
end

--- 设置自定义图路径。
---@param path string
function M.setCustomImage(path)
    local c = conf()
    c.wallpaper_custom_image = path
    MoonSettings.save("features.wallpaper", c)
    M.invalidate()
end

--- 设置壁纸文件夹路径。
---@param path string
function M.setFolder(path)
    local c = conf()
    c.wallpaper_folder = path
    MoonSettings.save("features.wallpaper", c)
    folder_cache = {}
    M.invalidate()
end

-- ── 解析与缓存 ──────────────────────────

local revision = 0
local resolved = { revision = -1, day = "", path = false }
local cache = { key = nil, bb = nil }

--- 丢掉已解析的路径与位图；改了任何设置之后调用。
function M.invalidate()
    revision = revision + 1
    if cache.bb and cache.bb.free then cache.bb:free() end
    cache.key, cache.bb = nil, nil
end

--- 当前壁纸文件。图不存在时返回 nil。
--- 结果按 revision 与日期记忆：绘制是热路径，不能每次都开文件读头。
---@return string|nil
function M.path()
    local day = os.date("%Y-%m-%d")
    if resolved.revision == revision and resolved.day == day then
        return resolved.path or nil
    end
    local asset = SOURCES[M.mode()]
    local path = asset.path and asset.path()
    if path and not Image.ok(path) then path = nil end
    resolved = { revision = revision, day = day, path = path or false }
    return path
end

--- 按目标尺寸取铺好的位图；解图失败返回 nil（表层保留底色）。
--- bpp 用目标画布的类型：C 版 addblitFrom 两张图类型不同会直接退出进程。
---@param w number
---@param h number
---@param bpp integer|nil 缺省按屏幕是否彩色选 BB8 / RGB32
---@return table|nil
local function surface(w, h, bpp)
    local path = M.path()
    if not path then return nil end
    local contain = M.contain()
    local key = table.concat({ path, w, h, contain and "contain" or "cover", bpp or "auto" }, "|")
    if cache.key == key then return cache.bb end
    local bb
    local ok, err = pcall(function()
        local source = require("ui/renderimage"):renderImageFile(path, false)
        if not source then error("cannot decode wallpaper: " .. tostring(path)) end
        local iw, ih = source:getWidth(), source:getHeight()
        if not iw or not ih or iw <= 0 or ih <= 0 then
            error("cannot decode wallpaper: " .. tostring(path))
        end
        local image = require("ui/widget/imagewidget"):new{
            image = source,
            image_disposable = true,
            width = w,
            height = h,
            scale_factor = (contain and math.min or math.max)(w / iw, h / ih),
            alpha = true,
        }
        bb = Blitbuffer.new(w, h, bpp or ((Screen.isColorEnabled and Screen:isColorEnabled())
            and Blitbuffer.TYPE_BBRGB32 or Blitbuffer.TYPE_BB8))
        bb:fill(Blitbuffer.COLOR_WHITE)
        image:paintTo(bb, 0, 0)
        image:free()
    end)
    if not ok then
        if bb and bb.free then bb:free() end
        logger.warn("book wallpaper decode failed", path, err)
        return nil
    end
    if cache.bb and cache.bb.free then cache.bb:free() end
    cache.key, cache.bb = key, bb
    return bb
end

--- 把壁纸铺进目标画布。没开、没图、解图失败都不画，返回 false 让调用方保留底色。
---@param bb BlitBuffer
---@param x number
---@param y number
---@param w number
---@param h number
---@param scope string desktop / dialog
---@return boolean
function M.paintTo(bb, x, y, w, h, scope)
    if not M.enabled(scope) then return false end
    w, h = math.floor(w), math.floor(h)
    if w <= 0 or h <= 0 then return false end
    local img = surface(w, h, bb.getType and bb:getType() or nil)
    if not img then return false end
    bb:blitFrom(img, x, y, 0, 0, w, h)
    return true
end

--- 把这层方块的底色摘掉（只摘「只有 bg」的那层），记在 out 里好还原。
---@param widget table
---@param out table[]
---@param depth number
local function hollowTree(widget, out, depth)
    if type(widget) ~= "table" or depth > 24 then return end
    if widget.box_w ~= nil then
        local style = widget.style
        if type(style) == "table" and style.bg ~= nil and not widget._hollow_style then
            local only_bg = true
            for key in pairs(style) do
                if key ~= "bg" then only_bg = false break end
            end
            if only_bg then
                widget._hollow_style, widget.style = style, {}
                out[#out + 1] = widget
            end
        end
    end
    for i = 1, #widget do hollowTree(widget[i], out, depth + 1) end
end

--- 页自己铺的整片底色不止一层：页根一层，Sections 正文框又一层——只摘页根的话
--- 只有上面一条透得出来。整棵树走一遍一起摘掉，壁纸从下面透上来。
--- 卡片、对话框的 style 是共享令牌（带圆角 / 阴影），键不止 bg，一律跳过。
---@param widget table|nil 页根或面板
---@param scope string
---@return boolean
function M.hollow(widget, scope)
    if type(widget) ~= "table" then return false end
    if not M.enabled(scope) then
        M.restore(widget)
        return false
    end
    -- 弹窗每帧都调这里，不能每帧走一遍整棵树：配置没变（revision 未变）且子件数
    -- 没变就复用上次结果。换页 / 改设置会得到新的控件或新的 revision，自然会重走。
    if widget._hollow_rev == revision and widget._hollow_n == #widget then
        return widget._hollowed ~= nil and #widget._hollowed > 0
    end
    if not widget._hollowed then widget._hollowed = {} end
    hollowTree(widget, widget._hollowed, 0)
    widget._hollow_rev, widget._hollow_n = revision, #widget
    return #widget._hollowed > 0
end

--- 顶栏 / 底栏用：开关打开才透空，关上就把底色还回去。
---@param widget table|nil
---@param scope string
---@param on boolean
---@return boolean
function M.hollowBars(widget, scope, on)
    if not on then
        M.restore(widget)
        return false
    end
    return M.hollow(widget, scope)
end

--- 把 hollow 摘掉的底色全部还回去。
---@param widget table|nil
function M.restore(widget)
    if type(widget) ~= "table" or not widget._hollowed then return end
    for _idx, box in ipairs(widget._hollowed) do
        if box._hollow_style then
            box.style, box._hollow_style = box._hollow_style, nil
        end
    end
    widget._hollowed, widget._hollow_rev, widget._hollow_n = nil, nil, nil
end

--- 顶栏 / 底栏关掉的那条补回页面底色。壁纸已经铺满整屏，这里再盖一层。
---@param bb BlitBuffer
---@param x number
---@param y number
---@param w number
---@param h number
function M.paintBars(bb, x, y, w, h)
    if not M.isOn() then return end
    local bars = M.bars()
    if bars.top and bars.bottom then return end
    local color = Blitbuffer.Color8(require("ui.themes").current().color.page)
    if not bars.top then
        bb:paintRect(x, y, w, require("desktop.topbar").height(), color)
    end
    if not bars.bottom then
        local height = require("ui.themes.widgets.tabbar").height()
        bb:paintRect(x, y + h - height, w, height, color)
    end
end

--- 弹窗用：按整屏尺寸出图，只贴窗口盖住的那一块。窗口比屏小（锚定小窗）时
--- 不会出现「同一张图缩到窗口大小」的接缝，和桌面壁纸连成一片。
---@param bb BlitBuffer
---@param x number
---@param y number
---@param w number
---@param h number
---@param scope string
---@return boolean
function M.paintWindow(bb, x, y, w, h, scope)
    if not M.enabled(scope) then return false end
    w, h = math.floor(w), math.floor(h)
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local sx, sy = math.max(0, math.floor(x)), math.max(0, math.floor(y))
    w, h = math.min(w, sw - sx), math.min(h, sh - sy)
    if w <= 0 or h <= 0 then return false end
    local img = surface(sw, sh, bb.getType and bb:getType() or nil)
    if not img then return false end
    bb:blitFrom(img, sx, sy, sx, sy, w, h)
    return true
end

--- 包一层控件：先铺壁纸，再画子件（桌面外壳用）。
---@param scope string
---@param w number
---@param h number
---@param child table
---@return table
function M.wrap(scope, w, h, child)
    return require("features.wallpaper.widget"):new{
        scope = scope, width = w, height = h, [1] = child,
    }
end

local Ext = require("utils.extension")

Ext.add("desktop.backdrop", {
    content = function(widget) M.hollow(widget, "desktop") end,
    tabbar = function(bar) M.hollowBars(bar, "desktop", M.bars().bottom) end,
    wrap = function(w, h, child) return M.wrap("desktop", w, h, child) end,
})

Ext.add("modal.backdrop", function(modal, bb, x, y)
    local painted = M.paintWindow(bb, x, y, modal.dimen.w, modal.dimen.h, "dialog")
    if painted then M.hollow(modal[1], "dialog") else M.restore(modal[1]) end
end)

return M
