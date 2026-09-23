--[[--
通用图片组件：网络 URL（长期磁盘缓存）/ 本地路径

布局（定宽高占位，异步替换内容）：
  +----------+     +----------+
  | fallback | →   |  image   |
  |  文案    |     |          |   border 时画框
  +----------+     +----------+

  Image.widget{
    src = "https://...",   -- 网络 URL：磁盘缓存命中再出图；
                           -- 未命中先下载，落地后再出图
    -- src = "/abs/path.png"  -- 本地文件
    headers = { Authorization = "Bearer …" },  -- 仅网络请求
    width = n, height = n,
    alpha = true,
    border = false,           -- 是否画边框
    fallback = "…",           -- 未就绪/失败文案；空/省略则空白占位
    show_parent = desk,       -- 窗口级父；嵌套 setDirty 必须靠它
    on_ready = function(path) end,  -- 可选：下载并替换完成后
  }

UI 图标请用 ui.components.icon（Material Icons 字体），不要走本组件。

  Image.fetchAsync(url, headers, function(path, err) end)  -- 只下载不显示（刮削封面）
  Image.await(root, cb)  -- 已构建树内的图片落定后回调（锁屏写 PNG）
  box:cancel()  -- 只取消这一张的下载

下载单独限流。解码走 ImageWidget（file=，自带 BB 缓存），不 fork。
小图（目标面积且文件都小）当场解；封面这种大图 nextTick 排队，一帧一张。

@module koplugin.book.ui.components.image
--]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local UIManager = require("ui/uimanager")
local Widget = require("ui/widget/widget")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local TextWidget = require("ui/widget/textwidget")
local lfs = require("libs/libkoreader-lfs")
local logger = require("utils.log")
local UI = require("ui.components.bookui")
local Download = require("ui.components.image.download")
local ImageWidget = require("ui/widget/imagewidget")

---@class BookImage
local Image = {}

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
    ---@return nil
    local function done()
        pending = pending - 1
        if closed and pending == 0 and not finished then
            finished = true
            cb()
        end
    end
    --- 遍历 Widget 数字索引子树，订阅未落定的图片，同一节点只访问一次。
    ---@param widget table 参与布局或绘制的 Widget
    ---@return nil
    local function visit(widget)
        if seen[widget] then return end
        seen[widget] = true
        if widget._image_waiters and not widget._settled then
            pending = pending + 1
            widget._image_waiters[done] = true
            subscriptions[#subscriptions + 1] = widget
        end
        for _, child in ipairs(widget) do
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
        for _, widget in ipairs(subscriptions) do
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

--- 截断占位文案。
---@param fb any 图片不可用时显示的占位内容
---@return string
local function truncFallback(fb)
    local label = fb or "?"
    if type(label) ~= "string" then
        label = tostring(label)
    end
    if #label > 24 then
        label = label:sub(1, 24) .. "…"
    end
    return label
end

--- 居中并可选加边框包裹子控件。
---@param child table 要包装或接收事件的子控件
---@param w number 可用宽度，单位像素
---@param h number 可用高度，单位像素
---@param border boolean|nil 是否绘制边框
---@return table
local function frame(child, w, h, border)
    local centered = CenterContainer:new{
        dimen = Geom:new{ w = w, h = h },
        child,
    }
    if not border then
        return centered
    end
    local line = UI.line()
    return FrameContainer:new{
        bordersize = line,
        color = UI.rule(),
        padding = 0,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        dimen = Geom:new{ w = w, h = h },
        centered,
    }
end

--- 空白或文案占位；border 时带边框（封面格子）。
---@param w number 可用宽度，单位像素
---@param h number 可用高度，单位像素
---@param fb any 图片不可用时显示的占位内容
---@param border boolean|nil 是否绘制边框
---@return table
local function placeholder(w, h, fb, border)
    w = math.max(1, tonumber(w) or 1)
    h = math.max(1, tonumber(h) or 1)
    local child
    if type(fb) == "string" and fb ~= "" then
        child = TextWidget:new{
            text = truncFallback(fb),
            face = UI.face("xx_smallinfofont", 14),
            max_width = math.max(8, w - UI.sz(8)),
            fgcolor = UI.muted(),
        }
    else
        child = Widget:new{ dimen = Geom:new{ w = w, h = h } }
    end
    return frame(child, w, h, border)
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
    local path = UI.pluginRoot() .. src
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

--- 跳过失效图片任务，每个 UI tick 最多解码一张仍存活的排队图片。
---@return nil
local function pump()
    pumping = false
    while wait[1] do
        local item = table.remove(wait, 1)
        local box = item.box
        if not box._alive then
            box:_settle()
        else
            box:_applyFile(item.path)
            box:_settle()
            if wait[1] then
                pumping = true
                UIManager:nextTick(pump)
            end
            return
        end
    end
end

--- 将图片解码加入队列，尚未调度时安排下一个 UI tick。
---@param box table 持有图片状态与取消句柄的占位容器
---@param path string 图片或书籍的本地文件路径
---@return nil
local function enqueue(box, path)
    wait[#wait + 1] = { box = box, path = path }
    if pumping then
        return
    end
    pumping = true
    UIManager:nextTick(pump)
end

--- 没上过屏就不 setDirty，否则会为尚未显示的占位额外刷新。
---@param box table 持有图片状态与取消句柄的占位容器
---@return nil
local function requestPaint(box)
    if not box._screen then
        return
    end
    local host = box.show_parent
    if not host and UIManager.getTopmostVisibleWidget then
        host = UIManager:getTopmostVisibleWidget()
    end
    if not host then
        host = "all"
    end
    UIManager:setDirty(host, function()
        return "ui", box._screen
    end)
end

--- 通用图片框：固定尺寸占位；文件就绪后交给 ImageWidget（和封面浏览器一样）。
---@param src string|nil 图片来源地址或参与像素读取的源画布，具体形式由参数类型限定
---@param headers table|nil 图片下载所需的 HTTP 请求头
---@param w number 可用宽度，单位像素
---@param h number 可用高度，单位像素
---@param alpha boolean|nil 是否保留图片透明通道
---@param border boolean|nil 是否绘制边框
---@param fb any 图片不可用时显示的占位内容
---@param show_parent table|nil 异步图片就绪时请求刷新的屏幕宿主
---@param on_ready fun(path: string|nil)|nil
---@param fallback_src string|nil 远程下载失败时使用的本地图片
---@return table
local function asyncBox(src, headers, w, h, alpha, border, fb, show_parent, on_ready, fallback_src)
    local box = WidgetContainer:new{
        dimen = Geom:new{ x = 0, y = 0, w = w, h = h },
        align = "center",
        show_parent = show_parent,
        placeholder(w, h, fb, border),
    }

    --- 记录屏幕绝对位置；勿写回 dimen.x/y（WidgetContainer:paintTo 会再加一次）。
    ---@param bb any 用于绘制的 Blitbuffer 画布
    ---@param x number 目标区域左上角横坐标，单位像素
    ---@param y number 目标区域左上角纵坐标，单位像素
    ---@return nil
    function box:paintTo(bb, x, y)
        self._screen = Geom:new{ x = x, y = y, w = self.dimen.w, h = self.dimen.h }
        WidgetContainer.paintTo(self, bb, x, y)
    end

    local inner_w, inner_h = w, h
    if border then
        local line = UI.line()
        inner_w = math.max(1, w - line * 2)
        inner_h = math.max(1, h - line * 2)
    end

    box._alive = true
    box._image_waiters = {}
    box._settled = false
    box._on_ready = on_ready
    box._w = w
    box._h = h
    box._border = border
    box._inner_w = inner_w
    box._inner_h = inner_h
    box._alpha = alpha

    --- 把本张图片标记为落定，并且仅一次通知等待该图片的批次。
    ---@return nil
    function box:_settle()
        if self._settled then return end
        self._settled = true
        local callbacks = self._image_waiters
        self._image_waiters = {}
        for cb in pairs(callbacks) do cb() end
    end

    --- 只取消这一张的下载。
    ---@return nil
    function box:cancel()
        if self._download then
            self._download:cancel()
            self._download = nil
        end
    end

    --- 暂停时保留已绘制内容，但取消下载并拒绝后到的图片结果。
    -- 首页暂停时保留已绘制的图片，但停止任务并拒绝晚到结果。
    ---@return nil
    function box:onHomePause()
        self._alive = false
        self:cancel()
        self:_settle()
    end

    --- 换成已落地的图片。
    ---@param widget table|nil 参与布局或绘制的 Widget
    ---@param path string|nil 图片或书籍的本地文件路径
    ---@return nil
    function box:_apply(widget, path)
        if not widget then
            return
        end
        if not self._alive then
            widget:free()
            return
        end
        if self[1] and self[1].free then
            self[1]:free()
        end
        self[1] = frame(widget, self._w, self._h, self._border)
        requestPaint(self)
        if self._on_ready then
            self._on_ready(path)
        end
    end

    --- 释放占位并取消在飞下载。
    ---@param full any 原样传给子控件 free 的释放选项
    ---@return nil
    function box:free(full)
        self._alive = false
        self:cancel()
        self:_settle()
        WidgetContainer.free(self, full)
    end

    --- 解这一张。getSize 会触发 ImageWidget:_render。
    ---@param path string 图片或书籍的本地文件路径
    ---@return nil
    function box:_applyFile(path)
        local widget
        local ok, err = pcall(function()
            widget = ImageWidget:new{
                file = path,
                width = self._inner_w,
                height = self._inner_h,
                alpha = self._alpha and true or false,
            }
            widget:getSize()
        end)
        if not ok then
            if widget then widget:free() end
            logger.warn("book image decode failed", path, err)
            return
        end
        self:_apply(widget, path)
    end

    --- 小图当场解；大图进队，一帧一张。
    ---@param path string 图片或书籍的本地文件路径
    ---@return nil
    function box:_showFile(path)
        if cheap(path, self._inner_w, self._inner_h) then
            self:_applyFile(path)
            self:_settle()
            return
        end
        enqueue(self, path)
    end

    local path = resolve(src)
    if path then
        box:_showFile(path)
    elseif type(src) == "string" and isHttp(src) then
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
---@param opts table|nil 布局尺寸、样式及行为选项；缺省项使用组件默认值
---@return table
function Image.widget(opts)
    opts = opts or {}
    local src = opts.src
    local headers = opts.headers
    local w = math.max(1, tonumber(opts.width) or UI.iconSz())
    local h = math.max(1, tonumber(opts.height) or w)
    local alpha = opts.alpha
    if alpha == nil then
        alpha = true
    end
    local border = opts.border and true or false
    return asyncBox(
        src, headers, w, h, alpha, border, opts.fallback, opts.show_parent,
        opts.on_ready, opts.fallback_src
    )
end

return Image
