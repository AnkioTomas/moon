--[[--
pinyin.candidate_bar 离线用例：VirtualKeyboard / zh_CN 布局 / 词库全 stub。

验证：候选行按「开关 + 词库」插入与摘除、VirtualKeyboard.addChar/delChar 级
字母拦截与候选刷新、点候选提交、翻页、退格回退、换层（addKeys 重建键位）后
候选行仍然活着、光标移走后不误删文本、大写与非字母走原路、
物理键盘 / SDL 文本输入（直调 inputbox 包装表）回退原生 IME、
关闭/词库缺失时全透传且不留幽灵行。

@module tests.pinyin.candidate_bar_spec
--]]

local Assert = require("support.assert")

-- ── 桩：UI 基础件 ────────────────────────────────────

package.preload["ui/uimanager"] = function()
    local q = {}
    local dirty_calls = 0
    return {
        setDirty = function()
            dirty_calls = dirty_calls + 1
        end,
        nextTick = function(f)
            q[#q + 1] = f
        end,
        scheduleIn = function(_, _delay, f)
            q[#q + 1] = f
        end,
        unschedule = function(_, f)
            for i = #q, 1, -1 do
                if q[i] == f then
                    table.remove(q, i)
                end
            end
        end,
        _flush = function()
            while #q > 0 do
                local batch = q
                q = {}
                for i = 1, #batch do
                    batch[i]()
                end
            end
        end,
        _dirtyCalls = function()
            return dirty_calls
        end,
    }
end
package.preload["ui/size"] = function()
    return { padding = { small = 4 } }
end
package.preload["ffi/blitbuffer"] = function()
    return { COLOR_BLACK = 0, COLOR_GRAY = 1 }
end

-- ── 桩：词库 ─────────────────────────────────────────

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
            if code == "nihao" then
                return WORDS
            end
            return {}
        end,
    }
end

-- ── 桩：zh_CN 键盘布局（只有一行字母键，候选行由被测模块注入）──────

local zh_keys = {
    { "q", "w", "e", "r", "t", "y", "u", "i", "o", "p" },
}
package.preload["ui/data/keyboardlayouts/zh_CN_keyboard"] = function()
    return { keys = zh_keys }
end

-- ── 桩：VirtualKeyboard 原型 ─────────────────────────
-- init 照真机语义：读布局模块 keys → addKeys 造 VirtualKey（layout[i][j]）→
-- 照 zh_CN wrapInputBox 语义把 inputbox.addChars/delChar 包成 wrapMethod 表
-- （虚拟键与物理键盘/SDL 文本输入都经过这层包装表）。
-- 换层（Shift/Sym、number 输入框切字母层）只调 addKeys，键位全部重建。

local native_adds = {}
local native_dels = 0

local function fakeTextWidget()
    return {
        text = "",
        max_width = nil,
        fgcolor = nil,
        setText = function(self, t)
            self.text = t
        end,
        setMaxWidth = function(self, w)
            self.max_width = w
        end,
    }
end

local function fakeKey(width)
    return {
        label = "",
        width = width or 60,
        callback = nil,
        hold_callback = function() end,
        swipe_callback = function() end,
        { { fakeTextWidget() } },
    }
end

--- 假输入框：charlist/charpos 照 InputText 语义（候选栏靠它校验输入码没脱节）
local function fakeInputBox()
    return {
        charlist = {},
        charpos = 1,
        addChars = function(self, s)
            for c in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
                table.insert(self.charlist, self.charpos, c)
                self.charpos = self.charpos + 1
            end
        end,
        delChar = function(self)
            if self.charpos > 1 then
                self.charpos = self.charpos - 1
                table.remove(self.charlist, self.charpos)
            end
        end,
    }
end

local function text(kb)
    return table.concat(kb.inputbox.charlist)
end

local wrapped_mt = { __call = function(self, ...) return self.func(...) end }

--- 模拟 zh_CN wrapInputBox：包装表默认 func 即原生 generic_ime 入口
---（字母被 IME 吃掉换成行内候选，不直接进文本；非字母直接落文本——照真身语义）。
local function wrapInputBox(ib)
    local plain_add = ib.addChars
    local plain_del = ib.delChar
    ib.addChars = setmetatable({
        func = function(_, s)
            native_adds[#native_adds + 1] = s
            if type(s) ~= "string" or not s:match("^%l+$") then
                plain_add(ib, s) -- 非字母：原生 IME 直接写文本
            end
        end,
        raw_method_call = function(_, s)
            plain_add(ib, s)
        end,
    }, wrapped_mt)
    ib.delChar = setmetatable({
        func = function()
            native_dels = native_dels + 1
        end,
        raw_method_call = function()
            plain_del(ib)
        end,
    }, wrapped_mt)
end

local VK = {
    addKeys = function(self)
        self._addKeys_count = (self._addKeys_count or 0) + 1
        self.layout = {}
        for _, row in ipairs(self.KEYS) do
            local widgets = {}
            for j = 1, #row do
                local key = fakeKey()
                local def = row[j]
                if type(def) == "table" then
                    key.label = def.label or ""
                elseif type(def) == "string" then
                    key.label = def
                end
                widgets[j] = key
            end
            self.layout[#self.layout + 1] = widgets
        end
    end,
    init = function(self)
        self.KEYS = require("ui/data/keyboardlayouts/zh_CN_keyboard").keys
        self:addKeys()
        wrapInputBox(self.inputbox)
    end,
    addChar = function(self, key)
        self.inputbox:addChars(key)
    end,
    delChar = function(self)
        self.inputbox:delChar()
    end,
}
package.preload["ui/widget/virtualkeyboard"] = function()
    return VK
end

-- ── 被测模块 ─────────────────────────────────────────

local pinyin_on = true
local Bar = require("pinyin.candidate_bar")
Bar.install({ enabled = function() return pinyin_on end })

local function flush()
    require("ui/uimanager")._flush()
end

local function newKeyboard()
    local kb = setmetatable({ inputbox = fakeInputBox() }, { __index = VK })
    kb:init() -- 走包装后的 init：同步候选行 + addKeys 绑定 + 替换包装表 func
    return kb
end

local function typeCode(kb, code)
    for i = 1, #code do
        VK.addChar(kb, code:sub(i, i))
    end
end

--- 打完字并冲刷防抖 → 子进程查库回调
local function typeAndLookup(kb, code)
    typeCode(kb, code)
    flush()
end

local function rowLabels(kb)
    local labels = {}
    for j = 1, 10 do
        labels[j] = kb.layout[1][j][1][1][1].text
    end
    return labels
end

-- ── 用例 ─────────────────────────────────────────────

-- 候选行注入：zh_CN 布局 keys[1] 被插入带标记的 10 键行
do
    local kb = newKeyboard()
    Assert.is_true(zh_keys[1]._pinyin_bar == true, "候选行必须插到布局第一行")
    Assert.eq(#zh_keys[1], 10)
    Assert.eq(#zh_keys, 2, "原字母行保留")
    Assert.eq(rowLabels(kb)[1], "◀")
    Assert.eq(rowLabels(kb)[10], "▶")
    Assert.is_nil(kb.layout[1][2].swipe_callback, "候选键没有 key_chars，划动回调必须摘掉")
end

-- setKeyText 必须把被压小的 face 恢复成 VirtualKey.face（真机字号回归）
do
    local kb = newKeyboard()
    local key = kb.layout[1][2]
    local tw = key[1][1][1]
    key.face = { name = "keyboard" }
    tw.face = { name = "shrunk-to-8" }
    typeAndLookup(kb, "nihao")
    Assert.eq(tw.face, key.face, "写候选字时必须恢复键盘字号")
    Assert.eq(tw.text, "你好")
    for i = #lookup_calls, 1, -1 do
        lookup_calls[i] = nil
    end
end

-- 字母输入：拼音码进输入框，候选按宽度分页显示。
do
    local kb = newKeyboard()
    local dirty_before = require("ui/uimanager")._dirtyCalls()
    typeCode(kb, "nihao")
    Assert.eq(text(kb), "nihao", "拼音码应先显示在输入框")
    Assert.eq(#lookup_calls, 0, "防抖未到期不得查库")
    Assert.eq(rowLabels(kb)[2], "nihao", "停键前候选行只显示拼音码")
    Assert.eq(require("ui/uimanager")._dirtyCalls(), dirty_before, "连打期间不得每键重绘整块键盘")
    flush()
    Assert.eq(lookup_calls[#lookup_calls], "nihao")
    Assert.eq(#lookup_calls, 1, "连打只查最后一次")
    Assert.eq(require("ui/uimanager")._dirtyCalls(), dirty_before + 1, "查询完成后只重绘一次候选行")
    Assert.eq(#native_adds, 0, "激活时字母不进原生 IME")
    Assert.eq(kb._addKeys_count, 1, "打字只改键宽，不得 addKeys 重建键盘")
    local labels = rowLabels(kb)
    Assert.eq(labels[2], "你好")
    Assert.eq(labels[3], "你好吗")
    Assert.eq(labels[4], "", "加宽后首页只放得下两个词")
    Assert.eq(labels[9], "", "空档键无文本")
end

-- 物理键盘 / SDL 文本输入：直调 inputbox 包装表，不经过 VirtualKeyboard.addChar，
-- 回退原生 IME（与 pinyinplus 一致的取舍，Android 屏幕键盘不走这条路）
do
    local before = #native_adds
    local kb = newKeyboard()
    kb.inputbox:addChars("n")
    kb.inputbox:addChars("i")
    Assert.eq(#native_adds, before + 2, "SDL 文本输入必须走原生 IME")
    Assert.eq(text(kb), "", "字母被原生 IME 吃掉（行内候选），不进文本")
end

-- 点候选：插整词，候选行清空
do
    local kb = newKeyboard()
    typeAndLookup(kb, "nihao")
    kb.layout[1][3].callback() -- 第 2 个候选「你好吗」
    Assert.eq(text(kb), "你好吗")
    Assert.eq(rowLabels(kb)[2], "", "提交后候选行清空")
end

-- 换层：addKeys 重建全部键位（Shift/Sym、number 输入框切字母层），候选行必须重绑
do
    local kb = newKeyboard()
    typeAndLookup(kb, "nihao")
    kb:addKeys() -- 换层
    Assert.eq(rowLabels(kb)[2], "你好", "换层后候选必须画在新键位上")
    kb.layout[1][2].callback() -- 新键位上的候选可点
    Assert.eq(text(kb), "你好")
end

-- 翻页：候选按文本宽度分页；▶ 翻页、◀ 回翻
do
    local kb = newKeyboard()
    typeAndLookup(kb, "nihao")
    kb.layout[1][10].callback() -- ▶
    local labels = rowLabels(kb)
    Assert.eq(labels[2], "内耗")
    Assert.eq(labels[4], "泥沼")
    Assert.eq(labels[5], "", "加宽后第二页三个候选")
    kb.layout[1][1].callback() -- ◀
    Assert.eq(rowLabels(kb)[2], "你好")
end

-- 退格：有输入码时逐字母回退；码空后删普通文本
do
    local kb = newKeyboard()
    typeAndLookup(kb, "nihao")
    VK.delChar(kb)
    Assert.eq(text(kb), "niha")
    Assert.eq(lookup_calls[#lookup_calls], "nihao", "退格后防抖未到期不查库")
    flush()
    Assert.eq(lookup_calls[#lookup_calls], "niha")
    for _ = 1, 4 do
        VK.delChar(kb) -- 删空剩余字母
    end
    Assert.eq(text(kb), "")
    Assert.eq(native_dels, 0, "激活时退格不走原生 IME")
end

-- 拼音码不属于输入框文本：移动光标后点候选仍在当前位置提交。
do
    local kb = newKeyboard()
    typeAndLookup(kb, "nihao")
    kb.inputbox.charpos = 1 -- 用户点了文本别处
    kb.layout[1][2].callback()
    Assert.eq(text(kb), "nihao", "光标移走后不应错误替换文本")
end

-- 非字母 / 大写：结束拼写、字母留作普通文本、按键走原路（原生 IME 收到时码栈是空的，
-- 等价普通文本写入）、候选行清空
do
    local before = #native_adds
    local kb = newKeyboard()
    typeAndLookup(kb, "nihao")
    VK.addChar(kb, "，")
    Assert.eq(#native_adds, before + 1, "非字母走原路进原生通道")
    Assert.eq(text(kb), "nihao，", "拼音码和标点应保留")
    Assert.eq(rowLabels(kb)[2], "", "候选行已清空")
    VK.addChar(kb, "N")
    Assert.eq(text(kb), "nihao，n", "大写字母也应进入拼音候选状态")
end

-- 非字符串键（候选行空键）：吞掉，不进原生（addChars(nil) 会崩）
do
    local before = #native_adds
    local kb = newKeyboard()
    VK.addChar(kb, nil)
    Assert.eq(#native_adds, before, "空键必须吞掉")
end

-- 词库不可用：候选行必须摘掉（不留按不动的幽灵行），输入全透传原生 IME
do
    dict_available = false
    local before = #native_adds
    local kb = newKeyboard()
    Assert.is_nil(zh_keys[1]._pinyin_bar, "词库缺失时候选行必须摘掉")
    Assert.eq(#zh_keys, 1)
    Assert.eq(#kb.layout, 1, "键盘少一行")
    typeCode(kb, "ni")
    Assert.eq(#native_adds, before + 2, "词库缺失时字母透传原生 IME")
    Assert.eq(text(kb), "", "不透写输入框")
    dict_available = true
end

-- 词库就位后：下次键盘 init 自己把候选行加回来（无需重装 hook）
do
    local kb = newKeyboard()
    Assert.is_true(zh_keys[1]._pinyin_bar == true, "词库可用后候选行回来")
    typeAndLookup(kb, "nihao")
    Assert.eq(rowLabels(kb)[2], "你好")
end

-- 功能关闭：全透传且摘行
do
    pinyin_on = false
    local before = #native_adds
    local kb = newKeyboard()
    Assert.is_nil(zh_keys[1]._pinyin_bar, "关闭后候选行必须摘掉")
    typeCode(kb, "abc")
    Assert.eq(#native_adds, before + 3, "关闭时字母全透传")
    pinyin_on = true
end

-- 清理：preload 桩不卸会污染后续 spec
for _, name in ipairs({
    "ui/uimanager", "ui/size", "ffi/blitbuffer", "pinyin.dictionary",
    "ui/data/keyboardlayouts/zh_CN_keyboard", "ui/widget/virtualkeyboard",
}) do
    package.preload[name] = nil
    package.loaded[name] = nil
end
package.loaded["pinyin.candidate_bar"] = nil
