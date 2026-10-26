--[[--
界面壁纸：把一张图铺在月读自己的各个界面之下。

全局设一张图、铺法、透明度，独立于锁屏配置；总开关之外每个界面可单独开关，并可单独换图 /
换铺法 / 换透明度（没覆盖的项跟随全局；墨水屏上某张图在首页清楚、在设置页看不清字时单独调）：
  home / library / store / insight  桌面各页签
  settings  设置叠层
  dialog    其余弹窗、详情等主题窗口（画在遮罩之下）

阅读页（reader，默认关）：crengine 把正文整屏铺满不透明，垫在下面看不见，所以改用它自带的
平铺背景图接口：按屏幕尺寸渲染成 PNG 交给 `document:setBackgroundImage`，正文直接画在图上。
只有 crengine 文档（EPUB / TXT / HTML 等）有这个接口，PDF / 漫画不生效；打开书时设置，改开关下次开书生效。

位图按「路径 + 尺寸 + 铺法 + 透明度」只缓存一张：两个作用面尺寸不同会来回换，但界面
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
local Screen = Device.screen

local M = {}

--- 作用面：桌面各页签（id 同页签 id）、设置叠层、其余弹窗、阅读页。
M.SCOPES = require("features.wallpaper.setting").SCOPES
--- 旧版只有 desktop（各页签）与 dialog（设置叠层和其余弹窗）两个开关：新键没存过就沿用旧键。
local LEGACY = { home = "desktop", library = "desktop", store = "desktop", insight = "desktop", settings = "dialog" }

---@return table
local function conf()
    return MoonSettings.get("features.wallpaper")
end

local function save()
    MoonSettings.save("features.wallpaper", conf())
    M.invalidate()
end

-- ── 全局：图 / 铺法 / 透明度 ──────────────

local picks = {} -- 文件夹 → { picked = 本轮抽中的图, previous = 上一轮的图（重抽时避开） }

--- 文件夹壁纸：从里面随机抽一张，每次启动 / 唤醒换一张（同一轮固定，不然每次重绘都变）。
---@param dir string
---@return string|nil
local function folderPick(dir)
    local state = picks[dir] or {}
    picks[dir] = state
    if state.picked and Image.ok(state.picked) then return state.picked end
    local files = {}
    for name in lfs.dir(dir) do
        local path = dir .. "/" .. name
        if Image.suffix(name) and Image.ok(path) then files[#files + 1] = path end
    end
    if #files == 0 then return nil end
    table.sort(files)
    math.randomseed(os.time())
    state.picked = files[math.random(#files)]
    if #files > 1 and state.picked == state.previous then state.picked = files[state.picked == files[1] and 2 or 1] end
    return state.picked
end

--- 配置里的图可以是文件，也可以是文件夹（从中随机抽）。
---@param candidate string
---@return string|nil
local function resolve(candidate)
    if lfs.attributes(candidate, "mode") == "directory" then return folderPick(candidate) end
    return candidate
end

--- 全局壁纸（文件或文件夹）；没选过且旧版图源是「自定义」时用 .moon/screensaver/wallpaper.png。
---@return string|nil
function M.image()
    local c = conf()
    if c.wallpaper_custom_image then return c.wallpaper_custom_image end
    if c.wallpaper_source == "custom" then return Paths.screensaverDir() .. "/wallpaper.png" end
end

--- 唤醒时每个文件夹重抽一张（没配文件夹就什么都不做）。
function M.onResume()
    for _dir, state in pairs(picks) do state.previous, state.picked = state.picked, nil end
    if next(picks) then M.invalidate() end
end

---@param path string 图片文件或文件夹
function M.setImage(path)
    conf().wallpaper_custom_image = path
    save()
end

--- 某个界面的覆盖值（图 / 铺法 / 透明度），nil = 跟随全局。
---@param scope string
---@param field "image"|"contain"|"opacity"
---@overload fun(scope: string, field: "image"): string|nil
---@overload fun(scope: string, field: "contain"): boolean|nil
---@overload fun(scope: string, field: "opacity"): integer|nil
---@return string|boolean|integer|nil
function M.override(scope, field)
    return conf()["wallpaper_" .. field .. "_" .. scope]
end

---@param scope string
---@param field "image"|"contain"|"opacity"
---@param value string|boolean|integer|nil nil = 清除覆盖
function M.setOverride(scope, field, value)
    conf()["wallpaper_" .. field .. "_" .. scope] = value
    save()
end

--- 铺法：整图缩进（两侧留底色）为 true，缺省铺满裁切。scope 有覆盖用覆盖。
---@param scope string|nil
---@return boolean
function M.contain(scope)
    local own = scope and M.override(scope, "contain")
    if own ~= nil then return own end
    return conf().wallpaper_contain == true
end

---@param on boolean
function M.setContain(on)
    conf().wallpaper_contain = on == true
    save()
end

--- 壁纸不透明度（百分比，10~100，缺省 30）。scope 有覆盖用覆盖。
---@param scope string|nil
---@return integer
function M.opacity(scope)
    return scope and M.override(scope, "opacity") or conf().wallpaper_opacity
end

---@param percent integer
function M.setOpacity(percent)
    conf().wallpaper_opacity = percent
    save()
end

-- ── 总开关与顶栏 / 底栏 ──────────────────

--- 总开关。关上就整个不画，各界面的开关原样留着（再开就回来）。
---@return boolean
function M.isOn()
    return conf().wallpaper_enabled ~= false
end

---@param on boolean
function M.setOn(on)
    conf().wallpaper_enabled = on == true
    save()
end

--- 顶栏 / 底栏要不要跟着透出壁纸；关的那条补回页面底色。
---@return {top: boolean, bottom: boolean}
function M.bars()
    local c = conf()
    return { top = c.wallpaper_topbar ~= false, bottom = c.wallpaper_tabbar ~= false }
end

--- 底栏文字不变灰：壁纸透出底栏时，未选中格的图标文字跟正文同色。
---@return boolean
function M.plainTabbar()
    return conf().wallpaper_tabbar_plain == true
end

---@param on boolean
function M.setPlainTabbar(on)
    conf().wallpaper_tabbar_plain = on == true
    save()
end

---@param which string top / bottom
---@param on boolean
function M.setBar(which, on)
    conf()[which == "bottom" and "wallpaper_tabbar" or "wallpaper_topbar"] = on == true
    save()
end

-- ── 各界面开关 ──────────────────────────

--- 某个界面是否铺壁纸：总开关开、该界面开关开、且有图。
---@param scope string|nil 页签 id / settings / dialog / reader；不认识的页签（扩展页签）算旧版的 desktop
---@return boolean
function M.enabled(scope)
    if not scope or not M.isOn() then return false end
    return M.scopeOn(scope) and (M.override(scope, "image") or M.image()) ~= nil
end

--- 该界面自己的开关（不看总开关与有没有图）。
---@param scope string
---@return boolean
function M.scopeOn(scope)
    local c = conf()
    local value = c["wallpaper_" .. scope]
    -- 阅读页是新增的，没开过就不开：沿用旧开关会让升级用户的书页突然铺上壁纸。
    if value == nil and scope ~= "reader" then value = c["wallpaper_" .. (LEGACY[scope] or "desktop")] end
    return value == true
end

--- 任一界面开着（总开关关了就不算）。
---@return boolean
function M.anyEnabled()
    for _idx, scope in ipairs(M.SCOPES) do
        if M.enabled(scope) then return true end
    end
    return false
end

---@param scope string
---@param on boolean
function M.setScope(scope, on)
    conf()["wallpaper_" .. scope] = on == true
    save()
end

-- ── 解析与缓存 ──────────────────────────

local revision = 0
---@type { revision: number, [string]: string|false }
local resolved = { revision = -1 }
local cache = { key = nil, bb = nil }

--- 丢掉已解析的路径与位图；改了任何设置之后调用。
function M.invalidate()
    revision = revision + 1
    if cache.bb and cache.bb.free then cache.bb:free() end
    cache.key, cache.bb = nil, nil
end

--- 该界面实际用的壁纸文件（专用图优先，专用图读不了回全局图）；scope 缺省取全局图。图不可读返回 nil。
--- 结果按 revision 记忆：绘制是热路径，不能每次都开文件读头。
---@param scope string|nil
---@return string|nil
function M.path(scope)
    if resolved.revision ~= revision then resolved = { revision = revision } end
    local id = scope or ""
    if resolved[id] == nil then
        local path
        for _idx, candidate in ipairs({ scope and M.override(scope, "image") or false, M.image() or false }) do
            local file = candidate and resolve(candidate)
            if file and Image.ok(file) then path = file break end
        end
        resolved[id] = path or false
    end
    return (resolved[id] or nil) --[[@as string|nil]]
end

--- 按目标尺寸取铺好的位图；解图失败返回 nil（表层保留底色）。
--- bpp 用目标画布的类型：C 版 addblitFrom 两张图类型不同会直接退出进程。
---@param w number
---@param h number
---@param bpp integer|nil 缺省按屏幕是否彩色选 BB8 / RGB32
---@param scope string 界面（专用图按它取）
---@return table|nil
local function surface(w, h, bpp, scope)
    local path = M.path(scope)
    if not path then return nil end
    local contain = M.contain(scope)
    local opacity = M.opacity(scope)
    local key = table.concat({ path, w, h, contain and "contain" or "cover", bpp or "auto", opacity }, "|")
    if cache.key == key then return cache.bb end
    ---@type BlitBuffer|nil
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
            and Blitbuffer.TYPE_BBRGB32 or Blitbuffer.TYPE_BB8)) --[[@as BlitBuffer]]
        bb:fill(Blitbuffer.COLOR_WHITE)
        image:paintTo(bb, 0, 0)
        image:free()
        if opacity < 100 then bb:lightenRect(0, 0, w, h, 1 - opacity / 100) end
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
    local img = surface(w, h, bb.getType and bb:getType() or nil, scope)
    if not img then return false end
    bb:blitFrom(img, x, y, 0, 0, w, h)
    return true
end

--- 把这层方块的底色摘掉（只摘「只有 bg」的那层），记在 out 里好还原。
--- 底色本身就是内容的方块（热力图格子）设 keep_bg = true 跳过。
---@param widget table
---@param out table[]
---@param depth number
local function hollowTree(widget, out, depth)
    if type(widget) ~= "table" or depth > 24 then return end
    if widget.box_w ~= nil then
        local style = widget.style
        if type(style) == "table" and style.bg ~= nil and not widget._hollow_style and not widget.keep_bg then
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
    local img = surface(sw, sh, bb.getType and bb:getType() or nil, scope)
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

local reader_key

--- 阅读页壁纸：把整屏位图写成 PNG 交给 crengine 平铺（尺寸正好等于屏幕，一张铺满）。
--- 同一张图 / 尺寸 / 铺法 / 透明度本进程只写一次。
---@param plugin BookPlugin
function M.onReaderReady(plugin)
    local document = plugin.ui.document
    if not (document and document.setBackgroundImage and M.enabled("reader")) then return end
    local w, h = Screen:getWidth(), Screen:getHeight()
    local path = M.path("reader")
    local img = path and surface(w, h, nil, "reader")
    if not img then return end
    Paths.ensureCacheRoot()
    local file = Paths.cacheDir() .. "/wallpaper_reader.png"
    local key = table.concat({ path, w, h, M.contain("reader") and "contain" or "cover", M.opacity("reader") }, "|")
    if reader_key ~= key or not lfs.attributes(file, "mode") then
        img:writePNG(file)
        reader_key = key
    end
    document:setBackgroundImage(file)
end

local Ext = require("utils.extension")

Ext.add("desktop.backdrop", {
    content = function(widget, tab) M.hollow(widget, tab) end,
    tabbar = function(bar, tab) M.hollowBars(bar, tab, M.bars().bottom) end,
    plain_tabbar = function(tab) return M.plainTabbar() and M.bars().bottom and M.enabled(tab) end,
    wrap = function(w, h, child, tab) return M.wrap(tab, w, h, child) end,
})

Ext.add("modal.backdrop", function(modal, bb, x, y)
    local scope = modal.name == "book_settings_overlay" and "settings" or "dialog"
    local painted = M.paintWindow(bb, x, y, modal.dimen.w, modal.dimen.h, scope)
    if painted then M.hollow(modal[1], scope) else M.restore(modal[1]) end
end)

return M
