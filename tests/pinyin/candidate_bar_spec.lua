--[[--
pinyin.candidate_bar 离线用例：VirtualKeyboard / zh_CN 布局 / 词库全 stub。

候选条是自研 Strip widget（顶掉 addKeys 建的首行），假键盘给出最小容器壳：
kb[1][1][1][1] = VerticalGroup（其 [1] = 首行，行内键/span 交错，奇数位是键）。

验证：候选行按「开关 + 词库」插入与摘除、Strip 顶替首行、addChar/delChar 级
字母拦截与候选刷新、点候选提交、翻页、退格回退、换层（addKeys 重建）后
候选条仍活着、光标移走后不误删文本、大写与非字母走原路、
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
        nextTick = function(_, f)
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
    return { COLOR_BLACK = 0, COLOR_GRAY = 1, COLOR_WHITE = 2 }
end
package.preload["ui/widget/textwidget"] = function()
    return { new = function(_, o)
        return { text = o.text, fgcolor = o.fgcolor, setText = function(self, t) self.text = t end,
            getSize = function(self) return { w = #self.text * 10, h = 20 } end,
            free = function() end }
    end }
end

-- ── 桩：词库 ─────────────────────────────────────────

local dict_available = true
local dict_file_exists = true
local lookup_calls = {}
local WORDS = { "你好", "你好吗", "内耗", "拟合", "泥沼", "尼龙", "匿迹", "逆转", "匿名", "溺爱" }
package.preload["pinyin.dictionary"] = function()
    return {
        isAvailable = function()
            return dict_available
        end,
        fileExists = function()
            return dict_file_exists
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
-- init 照真机语义：读布局模块 keys → addKeys 造键（layout[i][j]）与最小容器壳
-- → 照 zh_CN wrapInputBox 语义把 inputbox.addChars/delChar 包成 wrapMethod 表
-- （虚拟键与物理键盘/SDL 文本输入都经过这层包装表）。
-- 换层（Shift/Sym、number 输入框切字母层）只调 addKeys，键位全部重建。

local native_adds = {}
local native_dels = 0
local layout_rebuilds = 0

local function fakeKey(width)
    return {
        label = "",
        width = width or 60,
        face = {},
        bold = false,
        flash_keyboard = true,
    }
end

--- 假输入框：charlist/charpos 照 InputText 语义（候选栏靠它校验输入码没脱节）
local function fakeInputBox()
    local inputbox = {
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
    function inputbox:initTextBox()
        layout_rebuilds = layout_rebuilds + 1
    end
    return inputbox
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
    key_padding = 2,
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
        -- 最小容器壳：kb[1][1][1][1] = vg，vg[1] = 首行（键/span 交错，奇数位是键）
        local row1 = self.layout[1]
        local hg = { getSize = function() return { w = 618, h = 64 } end }
        for j = 1, #row1 do
            hg[2 * j - 1] = row1[j]
            if j < #row1 then
                hg[2 * j] = { width = 2 }
            end
        end
        local vg = { hg, getSize = function() return { w = 618, h = 64 } end }
        self[1] = { { { vg } } }
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
    kb:init() -- 走包装后的 init：同步候选行 + addKeys 装候选条 + 替换包装表 func
    return kb
end

local function typeCode(kb, code)
    for i = 1, #code do
        VK.addChar(kb, code:sub(i, i))
    end
end

--- 打完字并冲刷防抖 → 查库回调
local function typeAndLookup(kb, code)
    typeCode(kb, code)
    flush()
end

--- 当前键盘的候选条（layout[1] 被候选条顶掉）
local function stripOf(kb)
    return kb.layout[1][1]
end

--- cells 里没有固定槽位：◀ 在 1，▶ 在末位，候选词紧挨着排在中间（含空档）
local function rowLabels(kb)
    local labels = {}
    local cells = stripOf(kb).cells
    for j = 1, #cells do
        local tw = cells[j] and cells[j].tw
        labels[j] = tw and tw.text or ""
    end
    return labels
end

--- 第 n 个候选词 cell（1 起；cells = ◀ 左档? 词×k 右档 ▶）
local function wordCell(kb, n)
    local cells = stripOf(kb).cells
    local count = 0
    for j = 2, #cells - 1 do
        local cell = cells[j]
        if cell.tw and cell.tw.text ~= "" then
            count = count + 1
            if count == n then
                return cell
            end
        end
    end
end

--- 条总宽守恒：cells 宽度和 + 缝数×gap == dimen.w
local function assertTotalWidth(kb)
    local strip = stripOf(kb)
    local sum = (#strip.cells - 1) * strip.gap
    for _, cell in ipairs(strip.cells) do
        sum = sum + cell.w
    end
    Assert.eq(sum, strip.dimen.w, "条总宽必须恒定")
end

--- 队列居中：两侧空档宽度差不超过 1px
local function assertCentered(kb)
    local cells = stripOf(kb).cells
    Assert.is_true(math.abs(cells[2].w - cells[#cells - 1].w) <= 1, "两侧空档必须对称（居中）")
end

-- ── 用例 ─────────────────────────────────────────────

-- 候选行注入：zh_CN 布局 keys[1] 被插入带标记的 10 键行，首行被 Strip 顶掉
do
    local kb = newKeyboard()
    Assert.is_true(zh_keys[1]._pinyin_bar == true, "候选行必须插到布局第一行")
    Assert.eq(#zh_keys[1], 10)
    Assert.eq(#zh_keys, 2, "原字母行保留")
    local strip = stripOf(kb)
    Assert.is_true(type(strip.paintTo) == "function", "首行必须是自研候选条")
    Assert.eq(#kb.layout[1], 1, "FocusManager 布局里整行一个部件")
    Assert.eq(strip.nav_w, 60, "◀▶ 宽度取自被顶掉的键")
    Assert.eq(strip.budget, 480, "预算 = 7 槽 + 空档的原宽之和")
    Assert.eq(strip.gap, 2, "缝宽取自 keyboard.key_padding")
    Assert.eq(rowLabels(kb)[1], "◀")
    local labels = rowLabels(kb)
    Assert.eq(labels[#labels], "▶")
    Assert.is_false(kb.layout[2][1].flash_keyboard, "启用时所有布局键必须跳过阻塞式闪烁")
end

-- 候选 cell 宽 = 文本自然宽 + 左右内边距；条总宽恒定
do
    local kb = newKeyboard()
    typeCode(kb, "nihao") -- 停键前只显示拼音码
    local cell = wordCell(kb, 1)
    Assert.eq(cell.tw.text, "nihao")
    Assert.eq(cell.w, 5 * 10 + 2 * 10, "cell 宽 = 文本宽 + 左右 padding")
    assertTotalWidth(kb)
    flush()
    for i = #lookup_calls, 1, -1 do
        lookup_calls[i] = nil
    end
end

-- 队列不满时整体居中：余量均分到两侧空档，词紧凑排布（右侧不留透底灰带）
do
    local kb = newKeyboard()
    typeAndLookup(kb, "nihao")
    -- 词宽（文本+padding）：你好 80、你好吗 110、内耗/拟合/泥沼各 80 → 累计 430，尼龙 80 放不下
    Assert.eq(wordCell(kb, 1).tw.text, "你好")
    Assert.eq(wordCell(kb, 1).w, 80, "不拉长：词 cell 保持 文本宽+padding")
    Assert.eq(wordCell(kb, 5).tw.text, "泥沼")
    Assert.is_nil(wordCell(kb, 6), "放不下的词不占槽")
    assertCentered(kb)
    assertTotalWidth(kb)
    for i = #lookup_calls, 1, -1 do
        lookup_calls[i] = nil
    end
end

-- 字母输入：拼音码进输入框，候选条只重建 cells，不重建键盘。
do
    local kb = newKeyboard()
    local dirty_before = require("ui/uimanager")._dirtyCalls()
    typeCode(kb, "nihao")
    Assert.eq(text(kb), "nihao", "拼音码应先显示在输入框")
    Assert.eq(#lookup_calls, 0, "防抖未到期不得查库")
    Assert.eq(wordCell(kb, 1).tw.text, "nihao", "停键前候选条只显示拼音码")
    Assert.eq(require("ui/uimanager")._dirtyCalls(), dirty_before, "连打期间不得每键重绘整块键盘")
    flush()
    Assert.eq(lookup_calls[#lookup_calls], "nihao")
    Assert.eq(#lookup_calls, 1, "连打只查最后一次")
    Assert.eq(require("ui/uimanager")._dirtyCalls(), dirty_before + 1, "查询完成后只重绘一次候选行")
    Assert.eq(#native_adds, 0, "激活时字母不进原生 IME")
    Assert.eq(kb._addKeys_count, 1, "打字只重建候选条 cells，不得 addKeys 重建键盘")
    Assert.eq(wordCell(kb, 1).tw.text, "你好")
    Assert.eq(wordCell(kb, 2).tw.text, "你好吗")
    Assert.eq(wordCell(kb, 3).tw.text, "内耗")
    Assert.is_true(kb.KEYS[1][2].width > 0, "占位键宽必须有效（addKeys 基准行）")
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

-- 点候选：插整词，候选条清空
do
    local kb = newKeyboard()
    typeAndLookup(kb, "nihao")
    local rebuilds_before = layout_rebuilds
    wordCell(kb, 2).callback() -- 第 2 个候选「你好吗」
    Assert.eq(text(kb), "你好吗")
    Assert.eq(layout_rebuilds, rebuilds_before + 1, "候选提交只能重建一次文本布局")
    Assert.is_nil(wordCell(kb, 1), "提交后候选条清空")
end

-- 空格提交首选：查词完成后提交首个词，不把空格写进输入框。
do
    local before = #native_adds
    local kb = newKeyboard()
    typeAndLookup(kb, "nihao")
    VK.addChar(kb, " ")
    Assert.eq(text(kb), "你好")
    Assert.eq(#native_adds, before, "拼写中的空格不应进入原生 IME")
    Assert.is_nil(wordCell(kb, 1), "空格提交后候选条清空")
end

-- 空格不等待查词：候选尚未返回时提交当前拼音，也不留下空格。
do
    local before = #native_adds
    local kb = newKeyboard()
    typeCode(kb, "ni")
    VK.addChar(kb, " ")
    Assert.eq(text(kb), "ni")
    Assert.eq(#native_adds, before, "查词未完成时空格也不应透传")
    flush()
    Assert.is_nil(wordCell(kb, 1), "已提交的拼写不得被延迟查词重新显示")
end

-- 换层：addKeys 重建全部键位（Shift/Sym、number 输入框切字母层），候选条必须重装
do
    local kb = newKeyboard()
    typeAndLookup(kb, "nihao")
    kb:addKeys() -- 换层
    Assert.eq(wordCell(kb, 1).tw.text, "你好", "换层后候选必须画在新候选条上")
    wordCell(kb, 1).callback() -- 新候选条上的候选可点
    Assert.eq(text(kb), "你好")
end

-- 翻页：固定七个候选槽；▶ 翻页、◀ 回翻（第二页不满员，队列居中）
do
    local kb = newKeyboard()
    typeAndLookup(kb, "nihao")
    local cells = stripOf(kb).cells
    cells[#cells].callback() -- ▶
    Assert.eq(wordCell(kb, 1).tw.text, "逆转")
    Assert.eq(wordCell(kb, 3).tw.text, "溺爱")
    Assert.is_nil(wordCell(kb, 4), "第二页只剩三个候选")
    assertCentered(kb)
    assertTotalWidth(kb)
    stripOf(kb).cells[1].callback() -- ◀
    Assert.eq(wordCell(kb, 1).tw.text, "你好")
end

-- 翻页按钮的灰显与可用性
do
    local kb = newKeyboard()
    typeAndLookup(kb, "nihao")
    local cells = stripOf(kb).cells
    Assert.is_nil(cells[1].callback, "第一页 ◀ 不可点")
    Assert.eq(cells[1].tw.fgcolor, 1, "第一页 ◀ 灰显")
    Assert.eq(cells[#cells].tw.fgcolor, 0, "有下一页时 ▶ 正常色")
    cells[#cells].callback() -- ▶
    cells = stripOf(kb).cells
    Assert.eq(cells[1].tw.fgcolor, 0, "第二页 ◀ 可点")
    Assert.is_nil(cells[#cells].callback, "最后一页 ▶ 不可点")
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
    wordCell(kb, 1).callback()
    Assert.eq(text(kb), "nihao", "光标移走后不应错误替换文本")
end

-- 非字母 / 大写：结束拼写、字母留作普通文本、按键走原路（原生 IME 收到时码栈是空的，
-- 等价普通文本写入）、候选条清空
do
    local before = #native_adds
    local kb = newKeyboard()
    typeAndLookup(kb, "nihao")
    VK.addChar(kb, "，")
    Assert.eq(#native_adds, before + 1, "非字母走原路进原生通道")
    Assert.eq(text(kb), "nihao，", "拼音码和标点应保留")
    Assert.is_nil(wordCell(kb, 1), "候选条已清空")
    VK.addChar(kb, "N")
    Assert.eq(text(kb), "nihao，n", "大写字母也应进入拼音候选状态")
end

-- 非字符串键（上游偶发空键位）：吞掉，不进原生（addChars(nil) 会崩）
do
    local before = #native_adds
    local kb = newKeyboard()
    VK.addChar(kb, nil)
    Assert.eq(#native_adds, before, "空键必须吞掉")
end

-- 预算耗尽：放不下的词整词跳过（不截断、不显示、不可点），后面的短词照常上屏；
-- 没坐满的队列整体居中。回归：截断出 0/过小的 max_width 会让
-- xtext makeLine 抛错（Kindle 真机崩溃）。
do
    local dict = require("pinyin.dictionary")
    local orig_lookup = dict.lookup
    local long1 = string.rep("a", 40) -- 400+20 = 420 ≤ 预算 480，占满后剩 60
    local long2 = string.rep("b", 20) -- 200+20 = 220 > 剩余 60：跳过
    local short = string.rep("c", 6) -- 60+20 = 80 > 60：也跳过
    dict.lookup = function()
        return { long1, long2, short, "ddd" } -- "ddd" = 30+20 = 50 ≤ 60：上屏
    end
    local kb = newKeyboard()
    typeAndLookup(kb, "nihao")
    Assert.eq(wordCell(kb, 1).tw.text, long1)
    Assert.eq(wordCell(kb, 1).w, 420)
    Assert.eq(wordCell(kb, 2).tw.text, "ddd", "放不下的词跳过后，短词紧凑上屏")
    Assert.eq(wordCell(kb, 2).w, 50)
    Assert.is_nil(wordCell(kb, 3), "放不下的词不占槽")
    assertCentered(kb)
    assertTotalWidth(kb)
    dict.lookup = orig_lookup
end

-- 词库文件存在但 SQLite 不可用：不得接管输入，也不得插入幽灵候选行。
do
    dict_available = false
    dict_file_exists = true
    local before = #native_adds
    local kb = newKeyboard()
    Assert.is_nil(zh_keys[1]._pinyin_bar, "损坏词库时候选行必须摘掉")
    Assert.is_true(kb.layout[1][1].flash_keyboard, "损坏词库时不得改变原生键盘反馈")
    VK.addChar(kb, "n")
    Assert.eq(#native_adds, before + 1, "损坏词库时字母必须透传原生 IME")
    dict_available = true
end

-- 词库不可用：候选行必须摘掉（不留按不动的幽灵行），输入全透传原生 IME
do
    dict_available = false
    local before = #native_adds
    local kb = newKeyboard()
    Assert.is_nil(zh_keys[1]._pinyin_bar, "词库缺失时候选行必须摘掉")
    Assert.is_true(kb.layout[1][1].flash_keyboard, "词库缺失时不得改变原生键盘反馈")
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
    Assert.eq(wordCell(kb, 1).tw.text, "你好")
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
    "ui/widget/textwidget",
}) do
    package.preload[name] = nil
    package.loaded[name] = nil
end
package.loaded["pinyin.candidate_bar"] = nil
