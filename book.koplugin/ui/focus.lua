--[[--
纯按键焦点：把绘制后的 widget 树收成可点控件链，方向键按屏幕方位跳到该方向最近的控件，中心键激活。

纯按键设备（Kindle K3 这类，fiveway + 翻页键）没有触摸。不复用 KOReader 的 FocusManager
（那是 layout[y][x] 网格，要各控件配合填表）：这里只按绘制后的几何中心找方向上的近邻，
焦点是「顶层窗口」的属性，收口在两个宿主里——主题弹窗基类 Modal 和桌面 Desktop，各控件零改动。

宿主接线：`:init` 里 `Focus.registerKeys(self)`，类上 `Focus.mixin(Class)`，面板变了置 `_focus_dirty`，
paintTo 末尾调 `Focus.paint`。宿主字段：`self[1]` 面板、`_focus_list`/`_focus_idx`/`_focus_dirty`，
可选 `self:focusInitIdx(list)`；可覆盖 `onFocusHold`（中心键长按）。

可点控件三种标记：Tap.wrap 的 `onTapThemeArea`、Button 的 `onTapThemeButton`、
封面 / Hero 的 `onTapBookInfo`。遇到即收、停止下探；禁用按钮（enabled=false）、没绘制过（无 dimen）跳过。
嵌入的子窗口（侧栏借来的 List，Modal:handleEvent 的 Input.isTop 挡掉子窗口的按键）不自己处理焦点，
它的可点行被父窗口的链一并收走。翻页滚动归翻页键（List/TextViewer/Pager），方向键只在当前屏的项间走。

@module koplugin.book.ui.focus
--]]

local Theme = require("ui.themes")

local Focus = {}

--- 中心键按住多久算长按（毫秒）。K3 的中心键无重复 / 长按事件，只能按按下—松开的间隔判定。
Focus.HOLD_MS = 500

--- 焦点导航是否生效：有方向键且没有触摸。带触屏的设备即便有方向键也靠点按操作，
--- 不注册焦点键、不画焦点框。宿主注册按键和绘制统一问这里。
---@return boolean
function Focus.enabled()
    local Device = require("device")
    return Device:hasDPad() and not Device:isTouchDevice()
end

--- 可点才值得框：没有点击回调的控件框了也无从激活。
--- Tap.wrap 的 onTapThemeArea、Book.tappable 的 onTapBookInfo 只在有回调时才挂（见各自实现）；
--- Button 的 onTapThemeButton 是类方法、恒在，额外要求 callback。
---@param w table
---@return boolean
local function focusable(w)
    if w.onTapThemeButton ~= nil then return w.callback ~= nil end
    return w.onTapThemeArea ~= nil or w.onTapBookInfo ~= nil
end

---@param w any
---@param out table[]
local function collect(w, out)
    if type(w) ~= "table" then return end
    if focusable(w) then
        if w.enabled ~= false and w.dimen then out[#out + 1] = w end
        return
    end
    for i = 1, #w do collect(w[i], out) end
end

--- 收集 root 子树里的可点控件，按阅读顺序（竖向中心，同行按 x）排序；初始焦点取靠前的项。
---@param root table 绘制后的 widget 树（dimen 已有屏幕坐标）
---@return table[]|nil 没有可点控件返回 nil
function Focus.list(root)
    local items = {}
    collect(root, items)
    if #items == 0 then return nil end
    table.sort(items, function(a, b)
        local ay, by = a.dimen.y + a.dimen.h / 2, b.dimen.y + b.dimen.h / 2
        if math.abs(ay - by) < 0.5 then return a.dimen.x < b.dimen.x end
        return ay < by
    end)
    return items
end

--- 对焦点项调它的 tap 回调（三种标记各一个无参入口，Button 自己判 enabled）。
---@param w table
function Focus.activate(w)
    if w.onTapThemeButton then return w:onTapThemeButton() end
    if w.onTapBookInfo then return w:onTapBookInfo() end
    if w.onTapThemeArea then return w:onTapThemeArea() end
end

--- 绘制后：面板变过就重收链（有链必有焦点项），再在焦点项外沿描边框。宿主在 paintTo 末尾调。
---@param host table Modal / Desktop
---@param bb table Blitbuffer
function Focus.paint(host, bb)
    if host._focus_dirty then
        host._focus_dirty = false
        local list = Focus.list(host[1])
        host._focus_list = list
        if not list then
            host._focus_idx = nil
        elseif not host._focus_idx then
            host._focus_idx = host.focusInitIdx and host:focusInitIdx(list) or 1
        else
            host._focus_idx = math.min(host._focus_idx, #list)
        end
    end
    local w = host._focus_list and host._focus_list[host._focus_idx]
    if w then Theme.focusBorder(bb, w.dimen.x, w.dimen.y, w.dimen.w, w.dimen.h) end
end

--- 两个屏幕矩形的外包框。
---@param a table
---@param b table
---@return table
local function union(a, b)
    local x, y = math.min(a.x, b.x), math.min(a.y, b.y)
    return require("ui/geometry"):new{
        x = x, y = y,
        w = math.max(a.x + a.w, b.x + b.w) - x,
        h = math.max(a.y + a.h, b.y + b.h) - y,
    }
end

---@param w table
---@return number, number 控件中心
local function center(w)
    return w.dimen.x + w.dimen.w / 2, w.dimen.y + w.dimen.h / 2
end

--- 方向单位向量（屏幕坐标，y 向下）。
local DIRS = { up = { 0, -1 }, down = { 0, 1 }, left = { -1, 0 }, right = { 1, 0 } }

--- 方向键：跳到该方向最近的控件。候选须落在该方向半平面（沿方向投影 > 0.5，焦点项自身为 0 被排除）；
--- 代价 = 投影距离 + 2×横向偏移，偏爱对齐的近邻；没有候选就不动。
--- 只刷新旧框∪新框：整屏重刷墨水屏在 K3 上很慢，框会落后于按键。嵌入窗口（有 show_parent）重画父窗口。
---@param host table
---@param dir "up"|"down"|"left"|"right"
---@return true
function Focus.moveDir(host, dir)
    local list = host._focus_list
    local cur = list and list[host._focus_idx]
    if not cur then return true end
    local ux, uy = DIRS[dir][1], DIRS[dir][2]
    local cx, cy = center(cur)
    local best, best_cost
    for i, w in ipairs(list) do
        local wx, wy = center(w)
        local dx, dy = wx - cx, wy - cy
        local along = dx * ux + dy * uy
        if along > 0.5 then
            local cost = along + 2 * math.abs(dx * uy - dy * ux)
            if not best_cost or cost < best_cost then best_cost, best = cost, i end
        end
    end
    if not best then return true end
    local region = union(cur.dimen, list[best].dimen)
    host._focus_idx = best
    require("ui/uimanager"):setDirty(host.show_parent or host, function() return "ui", region end)
    return true
end

--- 长按：在焦点项中心合成 hold 手势，只在宿主自己的控件树里派发（不经宿主入口，免得漏给下层），
--- 触屏的长按入口（如书卡菜单）原样生效。
---@param host table
---@return boolean|nil handled 有控件接住
function Focus.hold(host)
    local w = host._focus_list and host._focus_list[host._focus_idx]
    if not w then return end
    local d = w.dimen
    return require("ui/widget/container/inputcontainer").handleEvent(host, require("ui/event"):new("Gesture", {
        ges = "hold",
        pos = require("ui/geometry"):new{ x = d.x + math.floor(d.w / 2), y = d.y + math.floor(d.h / 2), w = 0, h = 0 },
    }))
end

--- 给宿主注册方向键与中心键（仅 Focus.enabled 时）。宿主在 :init 里调一次。
---@param host table
function Focus.registerKeys(host)
    if not Focus.enabled() then return end
    local ke = host.key_events
    ke.FocusUp = { { "Up" } }
    ke.FocusDown = { { "Down" } }
    ke.FocusLeft = { { "Left" } }
    ke.FocusRight = { { "Right" } }
    ke.FocusSelect = { { "Press" } }
end

local handlers = {
    onFocusUp = function(self) return Focus.moveDir(self, "up") end,
    onFocusDown = function(self) return Focus.moveDir(self, "down") end,
    onFocusLeft = function(self) return Focus.moveDir(self, "left") end,
    onFocusRight = function(self) return Focus.moveDir(self, "right") end,
    -- 中心键按下只记时；松开（onKeyRelease，KOReader 直接发给栈顶窗口）按间隔分流：短按激活，长按 onFocusHold。
    onFocusSelect = function(self)
        self._focus_press_at = require("ui/time").now()
        return true
    end,
    onKeyRelease = function(self, key)
        if not key:match({ "Press" }) then return end
        local at = self._focus_press_at
        self._focus_press_at = nil
        -- 没配对的松开（按下落在别的窗口）忽略。
        if not at then return true end
        local time = require("ui/time")
        if time.to_ms(time.since(at)) >= Focus.HOLD_MS then
            self:onFocusHold()
        else
            local w = self._focus_list and self._focus_list[self._focus_idx]
            if w then Focus.activate(w) end
        end
        return true
    end,
    onFocusHold = function(self)
        Focus.hold(self)
        return true
    end,
}

--- 把方向键 / 中心键回调混入宿主类；宿主要改长按行为就在之后定义自己的 onFocusHold。
---@param class table Modal / Desktop
function Focus.mixin(class)
    for name, fn in pairs(handlers) do class[name] = fn end
end

return Focus
