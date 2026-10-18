--[[--
主题图片内核：网络 URL（长期磁盘缓存）/ 本地路径 / 插件相对路径。
外框和占位文案的样式归 ui.themes.widgets.image（主题 Box + Text），这里不画边框。

布局（定宽高占位，异步替换内容）：
  +----------+     +----------+
  | fallback | →   |  image   |
  |  控件    |     |          |
  +----------+     +----------+

  Image.widget{
    src = "https://...",   -- 网络 URL：磁盘缓存命中再出图；
                           -- 未命中先下载，落地后再出图
    -- src = "/abs/path.png"  -- 本地文件
    headers = { Authorization = "Bearer …" },  -- 仅网络请求
    width = n, height = n,
    alpha = true,
    invert_in_night = false,  -- 单色字形图随夜间模式反色；默认保持原色
    fallback = widget,        -- 下载中/失败/无图时居中显示的控件（本地文件解码前留白）；省略则空白占位
    on_ready = function(path) end,  -- 可选：下载并替换完成后
    stretch = true,           -- 拉伸铺满目标框（不保比例）；缺省按比例缩进
  }

UI 图标请用 ui.themes.widgets.icon（Material Icons 字体），不要走本组件。

  Image.fetchAsync(url, headers, function(path, err) end)  -- 只下载不显示（刮削封面）
  Image.invalidate(path)  -- 原地替换过的文件，之后绕过按路径的位图缓存
  Image.await(root, cb)  -- 已构建树内的图片落定后回调（锁屏写 PNG）
  box:cancel()  -- 只取消这一张的下载

下载单独限流，解码不 fork。
小图（目标面积且文件都小）当场解，走 ImageWidget（file=，自带 BB 缓存）。
封面这种大图走本模块位图缓存：命中则拼页时直接出图；未命中排队，每拍按时间预算连续解，超预算才让出输入轮询。

@module koplugin.book.ui.themes.widgets.image.core
--]]

local CenterContainer = require("ui/widget/container/centercontainer")
local Geom = require("ui/geometry")
local UIManager = require("ui/uimanager")
local Widget = require("ui/widget/widget")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local logger = require("utils.log")
local Perf = require("utils.perf")
local Theme = require("ui.themes")
local Download = require("ui.themes.widgets.image.download")
local ImageWidget = require("ui/widget/imagewidget")

---@class BookImage
local Image = {}

-- 本会话内被原地替换过的文件。ImageWidget 的位图缓存只按路径+尺寸寻址，
-- 同路径换了内容仍会命中旧图，这些路径必须自己解码绕过缓存。
local replaced = {}

-- 大图位图缓存：key = 路径|宽|高 → { path, bb, bytes, used }，按字节 LRU。
-- KOReader ImageCache 只有 8 MiB 且全局共用，彩屏或内存告急时装不下一屏封面，
-- 每次重建都要从文件全尺寸重解，按队列逐张上屏。
-- 淘汰只丢引用、不 free：仍在显示的 ImageWidget 持有同一张位图，释放交给 Blitbuffer 的 GC 终结器。
-- 6 MiB ≈ 灰度屏 4 屏封面、彩屏 1 屏；256 MiB 设备上常驻缓存不能更大。
local BITMAP_BUDGET = 6 * 1024 * 1024
local bitmaps = {}
local bitmap_bytes, bitmap_tick = 0, 0

---@param path string
---@param w number
---@param h number
---@return string
local function bitmapKey(path, w, h)
    return path .. "|" .. w .. "|" .. h
end

--- 丢掉一条位图缓存。
---@param key string
local function dropBitmap(key)
    bitmap_bytes = bitmap_bytes - bitmaps[key].bytes
    bitmaps[key] = nil
end

--- 取缓存位图，未命中就解码入缓存；超预算按最久未用淘汰。
---@param path string
---@param w number
---@param h number
---@return table bb
local function bitmap(path, w, h)
    local key = bitmapKey(path, w, h)
    bitmap_tick = bitmap_tick + 1
    local hit = bitmaps[key]
    if hit then
        hit.used = bitmap_tick
        return hit.bb
    end
    local bb = assert(require("ui/renderimage"):renderImageFile(path, false, w, h), "render failed")
    local bytes = tonumber(bb.stride) * bb.h
    bitmaps[key] = { path = path, bb = bb, bytes = bytes, used = bitmap_tick }
    bitmap_bytes = bitmap_bytes + bytes
    while bitmap_bytes > BITMAP_BUDGET do
        local oldest
        for k, item in pairs(bitmaps) do
            if k ~= key and (not oldest or item.used < bitmaps[oldest].used) then oldest = k end
        end
        if not oldest then break end
        dropBitmap(oldest)
    end
    return bb
end

--- 整体作废位图缓存（清理缓存后调用）：缓存过的路径都标成「已替换」，之后重新生成的同名文件
--- 不会命中 KOReader ImageWidget 按路径缓存的旧位图。
function Image.invalidateAll()
    for key, item in pairs(bitmaps) do
        replaced[item.path] = true
        dropBitmap(key)
    end
end

--- 标记文件内容已被替换（刮削换封面），之后显示该路径不再命中旧位图。
---@param path string
function Image.invalidate(path)
    replaced[path] = true
    for key, item in pairs(bitmaps) do
        if item.path == path then dropBitmap(key) end
    end
end

---- 等待一棵已构建 Widget 树内的图片落定。批次归调用者，不拦截全局构建。
--- 取消只移除本批监听；图片任务由拥有 Widget 的视图释放。
---@param root table 待遍历的 Widget 根节点或根节点数组
---@param cb fun() 本次异步等待结束时执行的回调
---@return table
function Image.await(root, cb)
    local pending, closed, finished = 0, false, false
    local subscriptions = {}
    local seen = {}
    --- 记录一个子任务结束，所有子任务完成后通知调用者。
    local function done()
        pending = pending - 1
        if closed and pending == 0 and not finished then
            finished = true
            cb()
        end
    end
    --- 遍历 Widget 数字索引子树，订阅未落定的图片，同一节点只访问一次。
    ---@param widget table 参与布局或绘制的 Widget
    local function visit(widget)
        if seen[widget] then return end
        seen[widget] = true
        if widget._image_waiters and not widget._settled then
            pending = pending + 1
            widget._image_waiters[done] = true
            subscriptions[#subscriptions + 1] = widget
        end
        for _idx, child in ipairs(widget) do
            if type(child) == "table" then visit(child) end
        end
    end
    visit(root)
    closed = true
    if pending == 0 then
        finished = true
        cb()
    end
    return { cancel = function()
        finished = true
        for _idx, widget in ipairs(subscriptions) do
            widget._image_waiters[done] = nil
        end
    end }
end

--- 是否 HTTP(S) URL。
---@param src any 图片来源地址或参与像素读取的源画布，具体形式由参数类型限定
---@return boolean
local function isHttp(src)
    return type(src) == "string" and (src:match("^https?://") ~= nil)
end

--- 在 w × h 框内居中子控件。
---@param child table 要包装或接收事件的子控件
---@param w number 可用宽度，单位像素
---@param h number 可用高度，单位像素
---@return table
local function frame(child, w, h)
    return CenterContainer:new{
        dimen = Geom:new{ w = w, h = h },
        child,
    }
end

--- 占位：给了 fallback 控件就居中显示，否则空白。
---@param w number 可用宽度，单位像素
---@param h number 可用高度，单位像素
---@param fb table|nil 图片不可用时显示的占位控件
---@return table
local function placeholder(w, h, fb)
    return frame(fb or Widget:new{ dimen = Geom:new{ w = w, h = h } }, w, h)
end

--- 解析为可读路径。HTTP 查缓存；绝对路径直接用；其余相对插件根。
---@param src string|nil 图片来源地址或参与像素读取的源画布，具体形式由参数类型限定
---@return string|nil
local function resolve(src)
    if type(src) ~= "string" or src == "" then
        return nil
    end
    if isHttp(src) then
        return Download.cached(src)
    end
    if lfs.attributes(src, "mode") == "file" then
        return src
    end
    local path = Theme.root() .. src
    if lfs.attributes(path, "mode") == "file" then
        return path
    end
    return nil
end

--- 只下载不解码。刮削封面用。取消走返回对象的 :cancel()。
---@param url string 要下载的 HTTP(S) 图片地址
---@param headers table|nil 图片下载所需的 HTTP 请求头
---@param cb fun(path: string|nil, err: string|nil)
---@return table
function Image.fetchAsync(url, headers, cb)
    return Download.new(url, headers, cb):start()
end

-- 小图：天气图标级别。超过任一阈值就排队，避免图书馆一页 12 张封面卡死拼页。
local SMALL_PIXELS = 80 * 80
local SMALL_BYTES = 32 * 1024
-- 每拍解码预算：预算内连续解，超了才让出。
local BUDGET_MS = 50
-- UIManager 在任务队列变脏时会反复跑任务、不去读输入；续排必须晚于一次重绘，才能让出输入轮询。
local YIELD_S = 0.1

local wait = {}
local pumping = false

--- 按目标像素数和文件体积判断图片能否立即解码。
---@param path string 图片或书籍的本地文件路径
---@param w number 可用宽度，单位像素
---@param h number 可用高度，单位像素
---@return boolean
local function cheap(path, w, h)
    if w * h > SMALL_PIXELS then
        return false
    end
    local attr = lfs.attributes(path)
    local size = attr and tonumber(attr.size) or 0
    return size <= SMALL_BYTES
end

--- 跳过失效图片任务；一个 UI tick 内按 BUDGET_MS 连续解码，超预算再续排。
local function pump()
    pumping = false
    local started = Perf.now()
    while wait[1] do
        local item = table.remove(wait, 1)
        local box = item.box
        if box._alive then
            box:_applyFile(item.path)
        end
        box:_settle()
        if wait[1] and Perf.now() - started >= BUDGET_MS then
            pumping = true
            UIManager:scheduleIn(YIELD_S, pump)
            return
        end
    end
end

--- 将图片解码加入队列，尚未调度时安排下一个 UI tick。
---@param box table 持有图片状态与取消句柄的占位容器
---@param path string 图片或书籍的本地文件路径
local function enqueue(box, path)
    wait[#wait + 1] = { box = box, path = path }
    if pumping then
        return
    end
    pumping = true
    UIManager:nextTick(pump)
end

--- 图片已换进占位后请求局部刷新。没上过屏、或已不在显示中的控件树里（关窗 / 翻页换掉）
--- 就不刷新：图已就位，下次上屏直接画出。setDirty 只认顶层窗口，所以宿主取自窗口栈。
---@param box table 持有图片状态与取消句柄的占位容器
local function requestPaint(box)
    if not box._screen then return end
    local shown, _depth, window = UIManager:isSubwidgetShown(box, 64)
    if not shown then return end
    UIManager:setDirty(window, function()
        return "ui", box._screen
    end)
end

--- 通用图片框：固定尺寸占位；文件就绪后交给 ImageWidget（和封面浏览器一样）。
---@param src string|nil 图片来源地址或参与像素读取的源画布，具体形式由参数类型限定
---@param headers table|nil 图片下载所需的 HTTP 请求头
---@param w number 可用宽度，单位像素
---@param h number 可用高度，单位像素
---@param alpha boolean|nil 是否保留图片透明通道
---@param fb table|nil 图片不可用时显示的占位控件
---@param on_ready fun(path: string|nil)|nil
---@param fallback_src string|nil 远程下载失败时使用的本地图片
---@param invert_in_night boolean|nil 夜间模式下是否随屏幕反色
---@param stretch boolean|nil 拉伸铺满目标框（不保比例），缺省按比例缩进
---@return table
local function asyncBox(src, headers, w, h, alpha, fb, on_ready, fallback_src, invert_in_night, stretch)
    -- 本地文件解码前留白：冷启动整屏封面排队解码，先画占位再换图会像整架重新加载。
    local path = resolve(src)
    local box = WidgetContainer:new{
        dimen = Geom:new{ x = 0, y = 0, w = w, h = h },
        align = "center",
        placeholder(w, h, not path and fb or nil),
    }
    box._fb = path and fb or nil

    --- 记录屏幕绝对位置；勿写回 dimen.x/y（WidgetContainer:paintTo 会再加一次）。
    ---@param bb any 用于绘制的 Blitbuffer 画布
    ---@param x number 目标区域左上角横坐标，单位像素
    ---@param y number 目标区域左上角纵坐标，单位像素
    function box:paintTo(bb, x, y)
        self._screen = Geom:new{ x = x, y = y, w = self.dimen.w, h = self.dimen.h }
        WidgetContainer.paintTo(self, bb, x, y)
    end

    box._alive = true
    box._image_waiters = {}
    box._settled = false
    box._on_ready = on_ready
    box._w = w
    box._h = h
    box._inner_w = w
    box._inner_h = h
    box._alpha = alpha
    box._invert_in_night = invert_in_night
    box._stretch = stretch

    --- 把本张图片标记为落定，并且仅一次通知等待该图片的批次。
    function box:_settle()
        if self._settled then return end
        self._settled = true
        local callbacks = self._image_waiters
        self._image_waiters = {}
        for cb in pairs(callbacks) do cb() end
    end

    --- 只取消这一张的下载。
    function box:cancel()
        if self._download then
            self._download:cancel()
            self._download = nil
        end
    end

    --- 暂停时保留已绘制内容，但取消下载并拒绝后到的图片结果。
    function box:onHomePause()
        self._alive = false
        self:cancel()
        self:_settle()
    end

    --- 换下当前内容。
    ---@param widget table 参与布局或绘制的 Widget
    function box:_replace(widget)
        if self[1] and self[1].free then
            self[1]:free()
        end
        self[1] = frame(widget, self._w, self._h)
        requestPaint(self)
    end

    --- 丢掉还没上屏的留白期占位控件。
    function box:_dropFallback()
        if self._fb and self._fb.free then self._fb:free() end
        self._fb = nil
    end

    --- 留白期解码失败：补上占位控件。
    function box:_fallback()
        local widget = self._fb
        if not (widget and self._alive) then return end
        self._fb = nil
        self:_replace(widget)
    end

    --- 换成已落地的图片。
    ---@param widget table|nil 参与布局或绘制的 Widget
    ---@param path string|nil 图片或书籍的本地文件路径
    function box:_apply(widget, path)
        if not widget then
            return
        end
        if not self._alive then
            widget:free()
            return
        end
        self:_dropFallback()
        self:_replace(widget)
        if self._on_ready then
            self._on_ready(path)
        end
    end

    --- 释放占位并取消在飞下载。
    ---@param full any 原样传给子控件 free 的释放选项
    function box:free(full)
        self._alive = false
        self:cancel()
        self:_settle()
        self:_dropFallback()
        WidgetContainer.free(self, full)
    end

    --- 解这一张。getSize 会触发 ImageWidget:_render。
    --- 大图位图归本模块缓存，ImageWidget 不得 free。
    ---@param path string 图片或书籍的本地文件路径
    function box:_applyFile(path)
        local widget
        local ok, err = pcall(function()
            local w, h = self._inner_w, self._inner_h
            local image = self._big and bitmap(path, w, h)
                or replaced[path] and assert(require("ui/renderimage"):renderImageFile(path, false, w, h))
            widget = ImageWidget:new{
                file = not image and path or nil,
                image = image or nil,
                image_disposable = not self._big,
                width = self._inner_w,
                height = self._inner_h,
                alpha = self._alpha and true or false,
                scale_factor = self._stretch and 0 or nil,
                original_in_nightmode = not self._invert_in_night,
            }
            widget:getSize()
        end)
        if not ok then
            if widget then widget:free() end
            logger.warn("book image decode failed", path, err)
            self:_fallback()
            return
        end
        self:_apply(widget, path)
    end

    --- 小图和已缓存的大图当场出图；未缓存的大图进队。
    --- SVG 不进位图缓存：ImageWidget 按后缀走 NanoSVG（保比例、直通 alpha），renderImageFile 会拉满目标框。
    ---@param path string 图片或书籍的本地文件路径
    function box:_showFile(path)
        local w, h = self._inner_w, self._inner_h
        local large = not cheap(path, w, h)
        self._big = large and not path:lower():match("%.svg$")
        if large and not (self._big and bitmaps[bitmapKey(path, w, h)]) then
            enqueue(self, path)
            return
        end
        self:_applyFile(path)
        self:_settle()
    end

    if path then
        box:_showFile(path)
    elseif isHttp(src) then
        box._download = Download.new(src, headers, function(downloaded, err)
            box._download = nil
            if not box._alive then
                return
            end
            if not downloaded then
                logger.warn("book image async failed", src, err)
                local fallback = resolve(fallback_src)
                if fallback then
                    box:_showFile(fallback)
                else
                    box:_settle()
                end
                return
            end
            box:_showFile(downloaded)
        end):start()
    else
        box:_settle()
    end
    return box
end

--- 网络先下载；本地/缓存直接出图。锁屏离屏渲染用 await 等这棵树的图片结束再画。
---@param opts table 见模块头；width / height 必填（物理像素）
---@return table
function Image.widget(opts)
    local w = math.max(1, opts.width)
    local h = math.max(1, opts.height)
    local alpha = opts.alpha
    if alpha == nil then
        alpha = true
    end
    return asyncBox(
        opts.src, opts.headers, w, h, alpha, opts.fallback,
        opts.on_ready, opts.fallback_src, opts.invert_in_night == true, opts.stretch == true
    )
end

return Image
