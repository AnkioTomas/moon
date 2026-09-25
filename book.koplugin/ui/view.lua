--[[--
统一视图：稳定骨架、具名区域、实例生命周期和独立离屏出图。
构建由 createWidget 实现；一次性数据加载由 loadData 实现。
@module koplugin.book.ui.view
--]]
local Lifecycle = require("ui.lifecycle")

---@alias ViewRect table|fun():table

---@class ViewRegion
---@field container table 持有区域子控件的容器
---@field index integer 子控件在容器中的数组索引
---@field rect ViewRect 区域矩形或动态矩形回调

--- 视图实例：字段与实例方法挂在此类型上。
--- 子类类表声明须用 `local Sub = {}; Sub.__index = Sub; setmetatable(Sub, Parent)`，
--- 禁止 `local Sub = setmetatable({}, Parent)`（LuaLS 会把类表推成 Sub|Parent，new 返回值失真）。
---@class View
---@field name string|nil 生命周期日志中的实例名称
---@field lifecycle Lifecycle 本实例的阶段状态及异步取消句柄
---@field widget table|nil 本实例拥有的稳定根容器，销毁后清空
---@field regions table<string, ViewRegion> 按名称登记的局部刷新区域
---@field width number|nil 显式布局宽度，单位像素
---@field height number|nil 显式布局高度，单位像素
---@field data any 当前加载的视图数据
---@field host table|nil 屏幕刷新宿主；离屏实例为 nil
---@field children table<string, View> 拥有的子视图；隐藏后保留，Destroy 时释放
---@field offscreen boolean|nil 是否用于独立离屏导出
local View = {}
View.__index = View

--- 由类表构造实例。业务 state 不参与生命周期记录。
---@generic T : View
---@param self T 子类类表（`Sub:new` 时的 self）
---@param opts table|nil 布局尺寸、样式及行为选项；缺省项使用组件默认值
---@return T 与类表同型的实例
function View:new(opts)
    local view = setmetatable({}, self)
    for key, value in pairs(opts or {}) do view[key] = value end
    view.regions = {}
    view.children = {}
    view.widget = nil
    local destroy = view.onDestroy
    view.onDestroy = function(instance, ...)
        local widget = instance.widget
        instance.widget = nil
        instance.regions = {}
        instance.host = nil
        -- 子类清理失败仍须释放 native Widget；随后传播原错误。
        local ok, err = pcall(destroy, instance, ...)
        for _, child in pairs(instance.children) do
            if child.lifecycle.state ~= "Destroy" then
                local cleaned, reason = pcall(child.onDestroy, child)
                if not cleaned and ok then ok, err = false, reason end
            end
        end
        instance.children = {}
        if widget and widget.free then
            local cleaned, reason = pcall(widget.free, widget)
            if not cleaned and ok then ok, err = false, reason end
        end
        if not ok then error(err, 0) end
    end
    view.lifecycle = Lifecycle.attach(view)
    return view
end

--- 已有 KOReader 父类的控件组合使用；不接管其 Widget 释放。
---@param owner table 已绑定 Lifecycle 的宿主对象
---@return View
function View.attach(owner)
    return setmetatable({
        host = owner,
        lifecycle = assert(owner.lifecycle, "attach Lifecycle before View"),
        regions = {},
        children = {},
    }, View)
end

--- 子类只生成 Widget，不做网络请求、调度或窗口操作。
---@return table
function View:createWidget()
    error("view must implement createWidget")
end

--- 同一实例重复 build 不重建骨架。
---@param self View 视图实例
---@return table
function View:build()
    assert(self.lifecycle.state ~= "Destroy", "cannot build destroyed view")
    if self.widget then return self.widget end
    local content = assert(self:createWidget(), "createWidget must return a Widget")
    -- TextWidget.free 也是缓存失效操作，生命周期只能挂在独立根容器上。
    local Container = require("ui/widget/container/widgetcontainer")
    local widget = Container:new{ content }
    if self.width and self.height then
        widget.dimen = require("ui/geometry"):new{ w = self.width, h = self.height }
    end
    self.widget = widget
    widget._view_owner = self
    local paint = widget.paintTo
    widget.paintTo = function(root, bb, x, y)
        root._view_x, root._view_y = x, y
        return paint(root, bb, x, y)
    end
    self:registerRegion("content", widget, 1, function()
        local size = widget:getSize()
        return { x = widget._view_x or 0, y = widget._view_y or 0, w = size.w, h = size.h }
    end)
    local free, freed = widget.free, false
    widget.free = function(root, ...)
        if freed then return end
        freed = true
        local ok, err = true, nil
        if self.widget == root then
            self.widget = nil
            if self.lifecycle.state ~= "Destroy" then ok, err = pcall(self.onDestroy, self) end
        end
        -- 子类销毁抛错也不能跳过 native 子树释放。
        if free then
            local cleaned, reason = pcall(free, root, ...)
            if not cleaned and ok then ok, err = false, reason end
        end
        if not ok then error(err, 0) end
    end
    return widget
end

--- 重建内容区域而保留根容器；纯数据变换可由子类原地 updateView 代替。
---@return table
function View:rebuild()
    if not self.widget then return self:build() end
    self:replaceRegion("content", self:createWidget())
    return self.widget
end

--- 为稳定骨架中的子槽命名。rect 可动态读取实际绘制矩形。
---@param name string 区域、组件或图标名称
---@param container table 持有区域子控件的容器
---@param index integer 子控件数组中的槽位索引，从 1 开始
---@param rect ViewRect 屏幕绝对矩形，或返回该矩形的函数
function View:registerRegion(name, container, index, rect)
    self.regions[name] = { container = container, index = index, rect = rect }
end

--- 求值具名区域的静态矩形或动态矩形回调。
---@param region ViewRegion 已登记的区域
---@return table rect 当前区域矩形
local function rectangle(region)
    local rect = region.rect
    if type(rect) == "function" then
        return rect()
    end
    return rect
end

--- 仅刷新挂载且 Resume 的视图。区域矩形必须包含受影响的布局范围。
---@param name string 区域、组件或图标名称
function View:dirty(name)
    if not self.host or not self.lifecycle:uiReady() then return end
    local region = assert(self.regions[name], "unknown view region: " .. name)
    local rect = rectangle(region)
    -- UIManager 合并刷新区域需要 Geom 方法；队列持有快照，不引用可变布局。
    local Geom = require("ui/geometry")
    require("ui/uimanager"):setDirty(self.host, "ui", Geom:new{
        x = rect.x, y = rect.y, w = rect.w, h = rect.h,
    })
end

--- 新布局复用的子树从旧布局摘除，避免旧容器递归释放仍在使用的 Widget。
---@param old table 即将释放的旧布局子树
---@param replacement table 接替旧内容的新布局子树
---@param children table<string, View>|nil 仍由父视图拥有的子实例，隐藏时也必须保留
local function detachShared(old, replacement, children)
    local retained = {}
    --- 收集新布局保留的所有数字索引子节点，避免释放复用控件。
    ---@param widget table 参与布局或绘制的 Widget
    local function collect(widget)
        if retained[widget] then return end
        retained[widget] = true
        for _, child in ipairs(widget) do
            if type(child) == "table" then collect(child) end
        end
    end
    --- 从旧布局摘除仍被新布局或父视图拥有的节点，再交由旧容器释放。
    ---@param widget table 参与布局或绘制的 Widget
    local function detach(widget)
        for i = #widget, 1, -1 do
            local child = widget[i]
            if retained[child] then
                table.remove(widget, i)
            elseif type(child) == "table" then
                detach(child)
            end
        end
    end
    collect(replacement)
    for _, child in pairs(children or {}) do
        if child.widget and child.lifecycle.state ~= "Destroy" then retained[child.widget] = true end
    end
    detach(old)
end

--- 更换槽位内容；同一 Widget 再次安装不得释放自己。
---@param name string 区域、组件或图标名称
---@param child table 要包装或接收事件的子控件
---@param keep_old boolean|nil 旧槽由外部页面拥有者保留时为 true
---@return table
function View:replaceRegion(name, child, keep_old)
    assert(self.lifecycle.state ~= "Destroy", "cannot update destroyed view")
    local region = assert(self.regions[name], "unknown view region: " .. name)
    local container, index = region.container, region.index
    local old = container[index]
    if old == child then return child end
    local before = rectangle(region)
    local x, y, w, h = before.x, before.y, before.w, before.h
    container[index] = child
    if container == self.widget and container.dimen then
        local size = child.dimen or child:getSize()
        container.dimen.w = self.width or size.w
        container.dimen.h = self.height or size.h
    end
    if container.resetLayout then container:resetLayout() end
    if old and old.free and not keep_old then
        detachShared(old, child, self.children)
        old:free()
    end
    if self.host and self.lifecycle:uiReady() then
        local after = rectangle(region)
        local left, top = math.min(x, after.x), math.min(y, after.y)
        local Geom = require("ui/geometry")
        require("ui/uimanager"):setDirty(self.host, "ui", Geom:new{
            x = left, y = top,
            w = math.max(x + w, after.x + after.w) - left,
            h = math.max(y + h, after.y + after.h) - top,
        })
    end
    return child
end

--- 默认静态视图没有异步数据。动态视图通过 done(data, err) 交付结果。
---@param done fun(data:any, err:any)
---@return table|nil
function View:loadData(done)
    done(self.data)
end

--- 本实例的一次性加载；取消/替换后的回调不修改数据，也不通知调用者。
---@param cb fun(ok:boolean, err:any)
---@return table
function View:load(cb)
    assert(self.lifecycle.state ~= "Destroy", "cannot load destroyed view")
    if self._load then self._load:cancel() end
    local finished, cancelled, handle = false, false, nil
    local operation
    --- 从本实例及 Lifecycle 的 HTTP 列表移除已结束的加载操作。
    local function forget()
        if self._load == operation then self._load = nil end
        local handles = self.lifecycle.http
        for i = #handles, 1, -1 do
            if handles[i] == operation then table.remove(handles, i) break end
        end
    end
    operation = { cancel = function()
        if finished then return end
        finished, cancelled = true, true
        forget()
        if handle then handle:cancel() end
    end }
    self._load = operation
    self.lifecycle:addHttp(operation)
    --- 记录加载结束，移除取消句柄并向调用者交付结果。
    ---@param data any 加载得到的视图数据
    ---@param err any 操作失败的原因
    local function done(data, err)
        if finished then return end
        finished = true
        forget()
        if not err then self.data = data end
        cb(not err, err)
    end
    local ok, result = pcall(self.loadData, self, done)
    if not ok then
        if finished then error(result, 0) end
        done(nil, result)
    else
        handle = result
        if cancelled and handle then handle:cancel() end
    end
    return operation
end

--- 创建阶段扩展点；默认不分配额外资源。
---@param self View 视图实例
function View:onCreate()
end

--- 恢复显示时把当前数据写入已存在的内容树。
---@param self View 视图实例
function View:onResume()
    if self.widget then self:updateView(self.data) end
end

--- 暂停阶段扩展点；异步句柄的取消由已绑定的 Lifecycle 处理。
---@param self View 视图实例
function View:onPause()
end

--- 销毁阶段扩展点；根 Widget 和子视图由构造器安装的清理逻辑释放。
---@param self View 视图实例
function View:onDestroy()
end

--- 静态视图无需更新；动态视图覆写并保留根骨架。
---@param self View 视图实例
---@param data any 加载得到的视图数据
function View:updateView(data)
    self.data = data
end

--- 由类表创建独立离屏实例并按目标尺寸出图。数据和图片落定后原子写 PNG。
---@param self View 子类类表（`Sub:renderToImage` 时的 self）
---@param opts table path/width/height 以及具体视图所需上下文
---@param cb fun(ok:boolean, err:any, path:string|nil)
---@return table
function View:renderToImage(opts, cb)
    local args = {}
    for key, value in pairs(opts) do args[key] = value end
    if not args.width or not args.height then
        local w, h = require("lockscreen.layout").portraitSize()
        args.width, args.height = args.width or w, args.height or h
    end
    assert(type(args.path) == "string" and args.path ~= "", "image path required")
    assert(args.width > 0 and args.width == math.floor(args.width), "invalid image width")
    assert(args.height > 0 and args.height == math.floor(args.height), "invalid image height")
    args.host = nil
    args.offscreen = true
    local view = self:new(args)
    local finished, image_wait = false, nil
    --- 取消图片等待并销毁离屏视图；清理异常在释放后继续传播。
    local function dispose()
        if image_wait then image_wait:cancel() end
        local destroyed, destroy_error = pcall(view.onDestroy, view)
        if not destroyed then error(destroy_error, 0) end
    end
    --- 仅完成一次导出，释放离屏资源后交付成功路径或失败原因。
    ---@param ok boolean 本次操作是否成功
    ---@param err any 操作失败的原因
    local function finish(ok, err)
        if finished then return end
        finished = true
        local disposed, reason = pcall(dispose)
        if not disposed then ok, err = false, reason end
        cb(ok, err, ok and args.path or nil)
    end
    --- 保护离屏构建或绘制步骤，失败时完成清理并报告错误。
    ---@param work fun() 需要执行并捕获异常的导出步骤
    local function guard(work)
        local ok, err = xpcall(work, debug.traceback)
        if not ok then
            if finished then error(err, 0) end
            finish(false, err)
        end
    end
    --- 数据加载结束后构建离屏树，等待图片落定再绘制并保存 PNG。
    ---@param ok boolean 本次操作是否成功
    ---@param err any 操作失败的原因
    local function loaded(ok, err)
        if finished then return end
        guard(function()
            if not ok then finish(false, err) return end
            local root = view:build()
            image_wait = require("ui.components.image").await(root, function()
                if finished then return end
                guard(function()
                    local Render = require("ui.render")
                    local written, reason = Render.write(args.path, args.width, args.height, function(bb)
                        Render.paintWidget(bb, { widget = root, x = 0, y = 0 }, args.width, args.height)
                    end)
                    finish(written, reason)
                end)
            end)
        end)
    end
    guard(function()
        view:onCreate()
        view:load(loaded)
    end)
    return { cancel = function()
        if finished then return end
        finished = true
        dispose()
    end }
end

return View
