--[[--
pinyin.candidate_bar × 真实 KOReader 前端集成用例。

与 candidate_bar_spec（全 stub）不同，这里加载真家伙：
真实 VirtualKeyboard / 真实 zh_CN 键盘布局 / 真实 generic_ime / 真实 util.wrapMethod，
只 stub 叶子依赖（Device/Screen/Font/TextWidget/Blitbuffer 等渲染与硬件层）。

验证真机语义的四个关键交互：
1. 键盘 init 后候选行真实插进 zh_CN 布局（6 行），wrapMethod 包装结构保持原样可用；
2. 字母经 VirtualKeyboard.addChar 拦截直写输入框、候选上键、点候选提交（走真 wrapMethod 的 raw_method_call 链）；
3. 换层（Sym/ABC，number 输入框的 layer 4 起点）后候选行仍绑在新键位上；
4. 🌐 切布局 en→zh→en：uwrap_func revert 与重包装后拦截依然生效，en 下完全原生。

@module tests.pinyin.real_frontend_spec
--]]

local Assert = require("support.assert")
local Config = require("support.config")

if not Config.setupNativePath() then
    Assert.skip("需要 KOReader 模拟器原生库")
end
local frontend = io.open(Config.root() .. "/koreader/frontend/ui/uimanager.lua", "r")
if not frontend then
    Assert.skip("需要本机 KOReader 源码")
end
frontend:close()

-- run.lua 的 package.path 是相对路径，本 spec 要 chdir 到 koreader/ 根
--（真实键盘布局模块内部 dofile("frontend/...")），先把所有搜索路径转绝对。
local lfs = require("libs/libkoreader-lfs")
local BASE = lfs.currentdir()
local KO = BASE .. "/koreader"
local EMU
for name in lfs.dir(KO) do
    if name:match("^koreader%-emulator%-.+%-debug$") then
        local candidate = KO .. "/" .. name .. "/koreader"
        if lfs.attributes(candidate, "mode") == "directory" then
            EMU = candidate
            break
        end
    end
end
if not EMU then
    Assert.skip("未找到 KOReader 模拟器构建目录")
end
package.cpath = EMU .. "/?.so;" .. EMU .. "/libs/?.so;" .. package.cpath
package.path = table.concat({
    KO .. "/frontend/?.lua",
    KO .. "/frontend/?/init.lua",
    KO .. "/base/?.lua",
    KO .. "/base/?/init.lua",
    BASE .. "/book.koplugin/?.lua",
    BASE .. "/book.koplugin/?/init.lua",
    BASE .. "/tests/?.lua",
    BASE .. "/tests/?/init.lua",
    package.path,
}, ";")

-- ── 叶子桩 ───────────────────────────────────────────

-- ffi/utf8proc 用了 KOReader 定制 luajit 的 ffi.loadlib，系统 luajit 没有；
-- 本用例只碰 ASCII，大小写映射恒等即可
package.preload["ffi/utf8proc"] = function()
    return {
        lowercase = function(s)
            return s
        end,
        uppercase_dumb = function(s)
            return (s:upper())
        end,
    }
end

package.preload["ffi/blitbuffer"] = function()
    return setmetatable({
        isColor8 = function() return true end,
    }, {
        __index = function()
            return 0
        end,
    })
end

local Screen = {
    getWidth = function()
        return 1080
    end,
    getHeight = function()
        return 1440
    end,
    scaleBySize = function(_, n)
        return n
    end,
    getSize = function()
        return { w = 1080, h = 1440 }
    end,
    getDPI = function()
        return 300
    end,
}
package.preload["device"] = function()
    return {
        screen = Screen,
        hasKeys = function()
            return false
        end,
        hasDPad = function()
            return false
        end,
        hasKeyboard = function()
            return false
        end,
        hasClipboard = function()
            return false
        end,
        isTouchDevice = function()
            return true
        end,
        performHapticFeedback = function() end,
    }
end

package.preload["ui/font"] = function()
    return {
        getFace = function(_, f, s)
            return { orig_font = f, orig_size = s or 22, size = s or 22 }
        end,
    }
end

-- 假 TextWidget/ImageWidget：候选栏只要 setText/setMaxWidth/getWidth/getSize/free
local function fakeWidgetClass()
    local W = {}
    W.__index = W
    function W:new(o)
        o = o or {}
        o.text = o.text or ""
        return setmetatable(o, self)
    end

    function W:getWidth()
        return 0
    end

    function W:getSize()
        return { w = 0, h = 0 }
    end

    function W:setText(t)
        self.text = t
    end

    function W:setMaxWidth(w)
        self.max_width = w
    end

    function W:paintTo() end

    function W:free() end
    return W
end
package.preload["ui/widget/textwidget"] = fakeWidgetClass
package.preload["ui/widget/imagewidget"] = fakeWidgetClass
package.preload["ui/widget/keyboardlayoutdialog"] = function()
    return {
        new = function()
            error("KeyboardLayoutDialog not expected in this spec")
        end,
    }
end

-- support stubs 的 gettext 没有 pgettext/ngettext，真实 util.lua 需要
package.preload["gettext"] = function()
    local GetText = {
        current_lang = "C",
        translation = {},
        pgettext = function(_, s)
            return s
        end,
        ngettext = function(_, s)
            return s
        end,
    }
    return setmetatable(GetText, {
        __call = function(_, s)
            return s
        end,
    })
end

-- dbg.lua（size.lua 引入）需要 logger.levels / setLevel
package.preload["logger"] = function()
    return {
        levels = { dbg = 1, info = 2, warn = 3, err = 4 },
        setLevel = function() end,
        dbg = function() end,
        info = function() end,
        warn = function() end,
        err = function() end,
    }
end

-- G_reader_settings 全局（zh_CN 布局模块加载时就要读）
_G.G_reader_settings = {
    _d = { keyboard_layout = "zh_CN" },
}
function G_reader_settings:readSetting(k, def)
    local v = self._d[k]
    if v == nil then
        return def
    end
    return v
end

function G_reader_settings:saveSetting(k, v)
    self._d[k] = v
end

function G_reader_settings:isTrue(k)
    return self._d[k] == true
end

function G_reader_settings:isFalse(k)
    return self._d[k] == false
end

function G_reader_settings:nilOrTrue(k)
    return self._d[k] ~= false
end

function G_reader_settings:flush() end

-- support 基建给 util 装了残缺桩（只有 writeToFile/urlEncode），会挡住真实
-- frontend/util.lua（focusmanager 等需要 tableDeepCopy）；本 spec 要用真身，摘掉
package.preload["util"] = nil

-- ── 词库桩 ───────────────────────────────────────────

local dict_available = true
local lookup_calls = {}
local WORDS = { "你好", "你好吗", "内耗", "拟合", "泥沼", "尼龙", "匿迹", "逆转", "匿名", "溺爱" }
package.preload["pinyin.dictionary"] = function()
    return {
        isAvailable = function()
            return dict_available
        end,
        fileExists = function()
            return dict_available
        end,
        lookup = function(code)
            lookup_calls[#lookup_calls + 1] = code
            if code == "ni" or code == "nihao" then
                return WORDS
            end
            return {}
        end,
    }
end

-- 集成用例不测防抖调度：debounce 立即触发
package.preload["utils.timing"] = function()
    return {
        debounce = function(fn)
            local h = {}
            function h:cancel() end
            return setmetatable(h, {
                __call = function(_, ...)
                    return fn(...)
                end,
            })
        end,
    }
end

-- startLookup 使用 SimpleJob；集成用例同步执行任务体，专注验证真实键盘包装。
package.preload["workers/simple_job"] = function()
    return {
        run = function(fn, opts)
            local ok, result = pcall(fn)
            if ok then
                if opts.on_done then opts.on_done(result) end
            elseif opts.on_failed then
                opts.on_failed(result)
            end
            return { cancel = function() end }
        end,
    }
end

-- ── 假输入框：真 wrapInputBox 要包的全套方法 ─────────

local function fakeInputBox()
    local ib = {
        charlist = {},
        charpos = 1,
        layout_rebuilds = 0,
    }
    ib.addChars = function(self, s)
        for c in tostring(s):gmatch("[%z\1-\127\194-\244][\128-\191]*") do
            table.insert(self.charlist, self.charpos, c)
            self.charpos = self.charpos + 1
        end
    end
    ib.delChar = function(self)
        if self.charpos > 1 then
            self.charpos = self.charpos - 1
            table.remove(self.charlist, self.charpos)
        end
    end
    ib.initTextBox = function(self)
        self.layout_rebuilds = self.layout_rebuilds + 1
    end
    -- wrapInputBox 还会包这些（导航/清空类，本用例不触发）
    for _, name in ipairs({
        "delToStartOfLine", "clear", "upLine", "downLine", "unfocus",
        "onCloseKeyboard", "onTapTextBox", "onHoldTextBox", "onSwipeTextBox",
        "leftChar", "rightChar",
    }) do
        ib[name] = function() end
    end
    return ib
end

local function text(ib)
    return table.concat(ib.charlist)
end

-- ── 加载真实前端（dofile("frontend/...") 相对路径，CWD 必须在 koreader 根）──

local lfs = require("libs/libkoreader-lfs")
local old_cwd = lfs.currentdir()
lfs.chdir(KO)

local Bar = require("pinyin.candidate_bar")
Bar.install({ enabled = function()
    return true
end })
local VK = require("ui/widget/virtualkeyboard") -- 真身；install 已在其类表上换好方法
local ZH = require("ui/data/keyboardlayouts/zh_CN_keyboard")

local function newKeyboard(layer)
    return VK:new {
        inputbox = fakeInputBox(),
        keyboard_layer = layer or 2,
    }
end

local function cellText(kb, j)
    -- 候选条 Strip 顶掉首行：kb.layout[1] = { strip }；cells[1..10] = ◀/候选×7/空档/▶
    local cell = kb.layout[1][1].cells[j]
    return (cell and cell.tw) and cell.tw.text or ""
end

-- ── 用例 ─────────────────────────────────────────────

-- 1. init：候选行插进真实 zh_CN 布局；addChars 仍是被真 wrapMethod 包装的原生 IME
-- （本设计不碰包装表，拦截点在 VirtualKeyboard.addChar）
do
    local kb = newKeyboard()
    Assert.is_true(ZH.keys[1]._pinyin_bar == true, "候选行必须插到真实 zh_CN 布局第一行")
    Assert.eq(#ZH.keys, 6, "zh_CN 原 5 行 + 候选行")
    Assert.eq(#kb.KEYS, 6)
    Assert.eq(#kb.layout, 6, "真实 addKeys 必须造出 6 行")
    Assert.eq(#kb.layout[1], 1, "首行被候选条顶掉，FocusManager 布局里整行一个部件")
    local cells = kb.layout[1][1].cells
    Assert.eq(cellText(kb, 1), "◀")
    Assert.eq(cellText(kb, #cells), "▶")
    Assert.is_false(kb.layout[2][1].flash_keyboard, "启用时所有布局键必须跳过阻塞式闪烁")
    local ac = kb.inputbox.addChars
    Assert.eq(type(ac), "table", "zh_CN wrapInputBox 把 addChars 包成 wrapMethod 表")
    Assert.is_true(type(ac.raw_method_call) == "function", "raw 直写通道必须可用")
end

-- 2. 字母直写 + 候选上键 + 点候选提交（真 wrapMethod raw_method_call 链）+ 退格回退
do
    local kb = newKeyboard()
    kb:addChar("n")
    kb:addChar("i")
    Assert.eq(text(kb.inputbox), "ni", "拼音码应先显示在输入框")
    Assert.eq(lookup_calls[#lookup_calls], "ni", "输入码必须查词库")
    Assert.eq(cellText(kb, 2), "你好", "第一候选上键")
    Assert.eq(cellText(kb, 3), "你好吗")
    kb:delChar() -- 键盘退格：逐字母回退
    Assert.eq(text(kb.inputbox), "n")
    Assert.eq(lookup_calls[#lookup_calls], "n")
    kb:addChar("i")
    local rebuilds_before = kb.inputbox.layout_rebuilds
    kb.layout[1][1].cells[2].callback() -- 点「你好」
    Assert.eq(text(kb.inputbox), "你好", "点候选：插整词")
    Assert.eq(kb.inputbox.layout_rebuilds, rebuilds_before + 1, "候选提交只能重建一次文本布局")
    Assert.eq(cellText(kb, 2), "", "提交后候选行清空")
end

-- 3. 换层（Shift→Sym→ABC，number 输入框从 layer 4 起步）：addKeys 重建后候选行仍活
do
    local kb = newKeyboard(4) -- input_type="number" 的起点层
    Assert.eq(#kb.layout, 6, "符号层也有候选行")
    Assert.is_false(kb.layout[2][1].flash_keyboard, "数字层必须跳过阻塞式闪烁")
    kb:setLayer("ABC") -- 切到字母层（initLayer → addKeys 全量重建键位）
    Assert.is_false(kb.layout[2][1].flash_keyboard, "换层重建后仍须跳过阻塞式闪烁")
    kb:addChar("n")
    kb:addChar("i")
    Assert.eq(text(kb.inputbox), "ni")
    Assert.eq(cellText(kb, 2), "你好", "换层重建键位后候选必须画在新候选条上")
    kb.layout[1][1].cells[2].callback()
    Assert.eq(text(kb.inputbox), "你好", "换层后点候选仍可提交")
end

-- 4. 🌐 切布局：en（原生）→ zh_CN（候选栏接管）往返，uwrap/re-wrap 语义正确
do
    local kb = newKeyboard()
    kb:setKeyboardLayout("en") -- 真实 init：uwrap_func revert 掉 zh 的包装
    Assert.eq(type(kb.inputbox.addChars), "function", "en 布局下 addChars 必须是未包装的原生函数")
    Assert.is_false(kb.layout[1][1].flash_keyboard, "英文布局必须跳过阻塞式闪烁")
    kb:addChar("x")
    Assert.eq(text(kb.inputbox), "x", "en 布局输入完全原生")
    kb:setKeyboardLayout("zh_CN") -- 重新包装 + 候选栏重新接管
    local ac = kb.inputbox.addChars
    Assert.eq(type(ac), "table", "切回 zh_CN 必须重新包装")
    kb:addChar("n")
    kb:addChar("i")
    Assert.eq(text(kb.inputbox), "xni", "候选栏重新接管后拼音码应显示")
    Assert.eq(cellText(kb, 2), "你好")
end

-- 5. 词库不可用：候选行摘除（不留幽灵行），输入透传原生 generic_ime 不崩溃
do
    dict_available = false
    local zh_rows_before = #ZH.keys
    local kb = newKeyboard()
    Assert.eq(#kb.KEYS, 5, "词库缺失时候选行必须摘掉")
    Assert.is_nil(ZH.keys[1]._pinyin_bar, "布局里的候选行标记必须移除")
    Assert.is_true(kb.layout[1][1].flash_keyboard, "词库缺失时不得改变原生键盘反馈")
    Assert.eq(zh_rows_before, 6)
    kb:addChar("n") -- 走原生 generic_ime（真身），不得崩
    kb:addChar("i")
    dict_available = true
end

-- 6. 词库回来后下次键盘 init 自动恢复
do
    local kb = newKeyboard()
    Assert.is_true(ZH.keys[1]._pinyin_bar == true, "词库可用后候选行回来")
    kb:addChar("n")
    kb:addChar("i")
    Assert.eq(cellText(kb, 2), "你好")
end

-- 7. 真实 paint 链 + tap 命中：候选条自己画自己分发，不经过 VirtualKey 手势体系
do
    local kb = newKeyboard()
    kb:addChar("n")
    kb:addChar("i")
    -- 全 noop 的假 blitbuffer：真容器链 + strip:paintTo 全跑一遍
    local bb = setmetatable({}, { __index = function() return function() end end })
    kb:paintTo(bb, 0, 0)
    local strip = kb.layout[1][1]
    Assert.is_true(strip.dimen.x ~= nil and strip.dimen.y ~= nil, "paint 后候选条坐标必须落地")
    -- tap 命中第 2 个候选「你好吗」：◀ 宽 + 缝 + 词1 宽 + 缝 + 1
    local x = strip.dimen.x + strip.cells[1].w + strip.gap + strip.cells[2].w + strip.gap + 1
    local ev = { handler = "onGesture", args = { { ges = "tap", pos = { x = x, y = strip.dimen.y + 1 } } } }
    Assert.is_true(strip:handleEvent(ev), "条内 tap 必须吞掉")
    Assert.eq(text(kb.inputbox), "你好吗", "tap 候选必须提交对应词")
    -- 条外 tap 放行（交给其他行/下层）
    local outside = { handler = "onGesture", args = { { ges = "tap", pos = { x = 0, y = 0 } } } }
    Assert.is_false(strip:handleEvent(outside), "条外 tap 必须放行")
end

-- ── 清理 ─────────────────────────────────────────────

lfs.chdir(old_cwd)
_G.G_reader_settings = nil
