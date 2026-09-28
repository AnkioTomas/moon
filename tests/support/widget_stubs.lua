--[[--
ui/themes 组件测试用的最小 KOReader 控件桩。

只模拟主题组件真实用到的行为：
  - 类：extend / new（new 调 init），InputContainer 每实例一份 key_events / ges_events
  - 尺寸：容器按子件累加，Span / Line / Text 给固定可预测尺寸
  - 绘制：容器把坐标传给子件，InputContainer 回写 dimen.x/y（点击命中靠它）
  - UIManager：记录 show / close / setDirty / scheduleIn / unschedule；close 触发 onCloseWidget
  - 画布：Kit.canvas() 记录 paintRoundedRect / paintBorder 调用，setPixel 计数
  - 字体：ui/font 的 getFace 返回 { name, size }，主题图标 / 遮罩走真实实现

  local Kit = require("support.widget_stubs")
  Kit.install("bold")          -- 每个 spec 顶部调用；主题 id 写进 display.ui_theme
  Kit.use("soft")              -- 切主题（之后新建的组件生效）

@module tests.support.widget_stubs
--]]

local Kit = {}

Kit.SCREEN_W, Kit.SCREEN_H = 600, 800

local Rect = {}
Rect.__index = Rect

--- 点在矩形内（左闭右开）。
function Rect:intersectWith(o)
    return self.x >= o.x and self.x < o.x + o.w and self.y >= o.y and self.y < o.y + o.h
end

local function geom(o)
    return setmetatable(o or {}, Rect)
end

--- 最小类：extend 继承，new 调 _prep 再调 init。
local function class(proto)
    proto.__index = proto
    function proto:extend(sub)
        sub = sub or {}
        sub.__index = sub
        return setmetatable(sub, { __index = self })
    end
    function proto:new(o)
        o = setmetatable(o or {}, self)
        if self._prep then self._prep(o) end
        if o.init then o:init() end
        return o
    end
    return proto
end

local Widget = class{
    getSize = function(self) return self.dimen end,
    paintTo = function() end,
}

local Container = Widget:extend{
    getSize = function(self)
        return self.dimen or (self[1] and self[1]:getSize()) or geom{ w = 0, h = 0 }
    end,
    paintTo = function(self, bb, x, y)
        if self.dimen then self.dimen.x, self.dimen.y = x, y end
        if self[1] then self[1]:paintTo(bb, x, y) end
    end,
}

local InputContainer = Container:extend{}
function InputContainer._prep(o)
    o.key_events = o.key_events or {}
    o.ges_events = o.ges_events or {}
end

--- 固定尺寸容器：子件按 kind 在框内对齐。
local function aligned(kind)
    return Container:extend{
        paintTo = function(self, bb, x, y)
            self.dimen.x, self.dimen.y = x, y
            local child = self[1]
            if not child then return end
            local cs = child:getSize()
            local dx = kind == "center" and math.floor((self.dimen.w - cs.w) / 2)
                or kind == "right" and self.dimen.w - cs.w or 0
            child:paintTo(bb, x + dx, y + math.floor((self.dimen.h - cs.h) / 2))
        end,
    }
end

local function group(vertical)
    return Widget:extend{
        getSize = function(self)
            local w, h = 0, 0
            for _, c in ipairs(self) do
                local s = c:getSize()
                if vertical then w, h = math.max(w, s.w), h + s.h else w, h = w + s.w, math.max(h, s.h) end
            end
            return geom{ w = w, h = h }
        end,
        paintTo = function(self, bb, x, y)
            for _, c in ipairs(self) do
                c:paintTo(bb, x, y)
                local s = c:getSize()
                if vertical then y = y + s.h else x = x + s.w end
            end
        end,
    }
end

local TextWidget = Widget:extend{
    getSize = function(self)
        return geom{ w = math.min(#self.text * 5, self.max_width or math.huge), h = 10 }
    end,
    setText = function(self, text) self.text = text end,
}

local TextBoxWidget = Widget:extend{
    getSize = function(self) return geom{ w = self.width, h = self.height or 20 } end,
    getAllLineCount = function(self) return math.ceil(#self.text / 10) end,
    getVisLineCount = function(self)
        return self.height and math.floor(self.height / 10) or self:getAllLineCount()
    end,
    scrollDown = function(self) self.scrolled = (self.scrolled or 0) + 1 end,
    scrollUp = function(self) self.scrolled = (self.scrolled or 0) - 1 end,
}

local InputText = InputContainer:extend{
    getSize = function(self) return geom{ w = self.width, h = self.height or 10 } end,
    getText = function(self) return self.text end,
    focus = function(self) self.focused = true end,
    unfocus = function(self) self.focused = false end,
    onShowKeyboard = function(self) self.kb = true end,
    onCloseKeyboard = function(self) self.kb = false end,
    isKeyboardVisible = function(self) return self.kb == true end,
}

local Leaf = Widget:extend{}
function Leaf:init()
    local size = self.size or 10
    self.dimen = geom{ w = self.width or size, h = self.height or size }
end

--- 递归找满足条件的控件（只走数组子件）。
---@param root table
---@param pred fun(w: table): boolean
---@return table[]
function Kit.find(root, pred)
    local out = {}
    local function walk(w)
        if type(w) ~= "table" then return end
        if pred(w) then out[#out + 1] = w end
        for _, c in ipairs(w) do walk(c) end
    end
    walk(root)
    return out
end

--- 所有主题按钮（按树序）。
function Kit.buttons(root)
    return Kit.find(root, function(w) return w.onTapThemeButton ~= nil end)
end

--- 所有 Tap.wrap 点击区（按树序）。
function Kit.taps(root)
    return Kit.find(root, function(w) return w.onTapThemeArea ~= nil end)
end

--- 所有 TextWidget 文案（按树序）。
function Kit.texts(root)
    local out = {}
    for _, w in ipairs(Kit.find(root, function(w) return getmetatable(w) == TextWidget end)) do
        out[#out + 1] = w.text
    end
    return out
end

--- 点按手势。
function Kit.tap(x, y)
    return { pos = geom{ x = x, y = y, w = 0, h = 0 } }
end

--- 记录绘制调用的假画布（setPixel 只计数：遮罩逐像素画）。
function Kit.canvas()
    local ops = {}
    return {
        ops = ops,
        pixels = 0,
        setPixel = function(self) self.pixels = self.pixels + 1 end,
        paintRoundedRect = function(_, x, y, w, h, c, r)
            ops[#ops + 1] = { op = "rect", x = x, y = y, w = w, h = h, c = c, r = r }
        end,
        paintBorder = function(_, x, y, w, h, bw, c, r)
            ops[#ops + 1] = { op = "border", x = x, y = y, w = w, h = h, bw = bw, c = c, r = r }
        end,
    }
end

--- 切换当前主题（写 display.ui_theme）。
function Kit.use(id)
    Kit.display.ui_theme = id
end

--- 安装全部桩并清空记录。
---@param theme string|nil 主题 id，缺省 paper
function Kit.install(theme)
    -- ui_scale = 100 且 scaleBySize 恒等：逻辑像素 = 物理像素，断言可以直接写令牌值。
    Kit.display = { ui_theme = theme or "paper", ui_scale = 100, mesh_mask = true }
    Kit.shown, Kit.closed, Kit.dirty, Kit.scheduled, Kit.unscheduled = {}, {}, {}, {}, {}
    local modules = {
        ["ffi/blitbuffer"] = { Color8 = function(v) return v end, COLOR_BLACK = 0, COLOR_WHITE = 255 },
        ["ffi/util"] = {
            template = function(s, ...)
                local args = { ... }
                return (s:gsub("%%(%d)", function(i) return tostring(args[tonumber(i)]) end))
            end,
        },
        ["gettext"] = function(s) return s end,
        ["l10n"] = { apply = function() end },
        ["device"] = {
            screen = {
                getSize = function() return geom{ x = 0, y = 0, w = Kit.SCREEN_W, h = Kit.SCREEN_H } end,
                getWidth = function() return Kit.SCREEN_W end,
                getHeight = function() return Kit.SCREEN_H end,
                scaleBySize = function(_, n) return n end,
            },
            hasKeys = function() return false end,
            input = { group = { Back = "Back" } },
        },
        ["ui/geometry"] = { new = function(_, o) return geom(o) end },
        ["ui/gesturerange"] = { new = function(_, o) return o end },
        ["ui/uimanager"] = {
            show = function(_, w) Kit.shown[#Kit.shown + 1] = w end,
            close = function(_, w)
                Kit.closed[#Kit.closed + 1] = w
                if w.onCloseWidget then w:onCloseWidget() end
            end,
            setDirty = function(_, w, mode) Kit.dirty[#Kit.dirty + 1] = { widget = w, mode = mode } end,
            scheduleIn = function(_, delay, fn) Kit.scheduled[#Kit.scheduled + 1] = { delay = delay, fn = fn } end,
            unschedule = function(_, fn) Kit.unscheduled[#Kit.unscheduled + 1] = fn end,
        },
        ["utils.settings"] = {
            get = function(section)
                assert(section == "display", "only display section stubbed")
                return Kit.display
            end,
            saveSection = function(section)
                assert(section == "display", "only display section stubbed")
                Kit.saved = (Kit.saved or 0) + 1
            end,
        },
        ["ui/font"] = {
            fontmap = {},
            getFace = function(_, name, size) return { name = name, size = size } end,
        },
        ["fontlist"] = { fontlist = {}, getFontList = function() end },
        -- 图片内核（下载 / 解码）另有 tests/ui/themes/widgets/image/core_spec.lua；这里只记参数。
        ["ui.themes.widgets.image.core"] = {
            widget = function(opts)
                return Widget:new{ dimen = geom{ w = opts.width, h = opts.height }, src = opts.src, image_opts = opts }
            end,
            fetchAsync = function() end,
            invalidate = function() end,
            await = function() end,
        },
        ["ui/widget/widget"] = Widget,
        ["ui/widget/container/widgetcontainer"] = Container,
        ["ui/widget/container/inputcontainer"] = InputContainer,
        ["ui/widget/container/centercontainer"] = aligned("center"),
        ["ui/widget/container/leftcontainer"] = aligned("left"),
        ["ui/widget/container/rightcontainer"] = aligned("right"),
        ["ui/widget/verticalgroup"] = group(true),
        ["ui/widget/horizontalgroup"] = group(false),
        ["ui/widget/horizontalspan"] = { new = function(_, o) return Widget:new{ dimen = geom{ w = o.width, h = 0 } } end },
        ["ui/widget/verticalspan"] = { new = function(_, o) return Widget:new{ dimen = geom{ w = 0, h = o.width } } end },
        ["ui/widget/linewidget"] = Widget,
        ["ui/widget/textwidget"] = TextWidget,
        ["ui/widget/textboxwidget"] = TextBoxWidget,
        ["ui/widget/inputtext"] = InputText,
        ["ui/widget/qrwidget"] = Leaf,
    }
    for name, mod in pairs(modules) do
        package.preload[name] = function() return mod end
        package.loaded[name] = nil
    end
    for name in pairs(package.loaded) do
        if name == "ui.themes" or name:match("^ui%.themes%.") then package.loaded[name] = nil end
    end
end

return Kit
