--[[--
拼音候选栏：zh_CN 键盘首行候选条。

拦截点与 pinyinplus.koplugin 一致：挂在 VirtualKeyboard.addChar/delChar 上
（键盘类方法，每个虚拟键敲击的必经之路，上游多年未变）。不去替换
wrapInputBox 包装表的 func——那依赖 generic_ime 包装结构的内部细节，
结构对不上就静默退回原生 IME（候选混进输入框文本），已经在真机上踩过。

候选来自 Book 词库（pinyin.dictionary，rime-ice 词频序）。候选格按字数调整
已有 VirtualKey 的 dimen，总宽仍为 10 单位；不得调用 addKeys 重建整张键盘。

激活时（开关开 + 词库在 + 当前 zh_CN 布局）：字母不进原生 IME，
原样写进输入框（所见即所输），词库候选显示在键盘首行；
点候选 = 删掉已输入字母、插入整词。退格逐字母回退。
连打走 utils.timing.debounce，查库和候选绘制在 scheduleIn 回调里跑（不在按键路径）。
KOReader 没有 Lua 线程；不能用 Task.run fork（父进程 sqlite 连接 + fork = 闪退）。
非字母结束本次拼写，按键走原路。大写字母并进输入码（按小写查词）。

已知取舍：物理键盘 / SDL 文本输入（InputText:onTextInput → inputbox:addChars）
不经过 VirtualKeyboard.addChar，仍走原生 IME——与 pinyinplus 行为一致。
目标设备（Android）用的是屏幕键盘，不受影响。

关键约束：
- 候选行只在真能用（开关开 + 词库在）时插进 zh_CN 布局，其余情况必须摘掉：
  否则留下一整行按不动的 ◀▶ 幽灵行，而输入还是原生 IME 行内候选。
- 键位绑定跟着 VirtualKeyboard:addKeys 走，不是 init：换层（Shift/Sym、number 输入框
  从 layer 4 切字母层）只调 addKeys，全部 VirtualKey 会重建，绑 init 必然拿到死引用。

@module koplugin.book.pinyin.candidate_bar
--]]

local Bar = {}

local Blitbuffer = require("ffi/blitbuffer")
local Size = require("ui/size")

local ZH_MODULE = "ui/data/keyboardlayouts/zh_CN_keyboard"
local SLOT_COUNT = 7
local NAV_WIDTH = 1.0
local AREA = 8.0 -- 10 - 2*NAV；空档至少 0.3，候选合计最多 7.7
local MIN_SPACER = 0.3

local _enabled
local _hooked = false

local _want = false
local _active = false
local _keyboard
local _code = ""
local _pages = {}
local _page = 1
local _prev_key, _next_key, _spacer_key
local _cand_keys = {}
local _width_signature
local _requestLookup
local stopSearch

-- ── 基础工具 ─────────────────────────────────────────

-- 绕过 IME 包装直写输入框，避免候选字再次进入原生 IME。
local function rawAddChars(inputbox, chars)
    local f = inputbox.addChars
    if type(f) == "table" and f.raw_method_call then
        f:raw_method_call(chars)
    else
        inputbox:addChars(chars)
    end
end

local function rawDelChar(inputbox)
    local f = inputbox.delChar
    if type(f) == "table" and f.raw_method_call then
        f:raw_method_call()
    else
        inputbox:delChar()
    end
end

--- 候选行随 want 插入/摘除 zh_CN 布局数据（幂等）。
--- 必须在 VirtualKeyboard:init 读 keys 之前调用——键盘高度按行数算。
local function syncRow(want)
    if not (want or package.loaded[ZH_MODULE]) then
        return
    end
    local keys = require(ZH_MODULE).keys
    if type(keys) ~= "table" then
        return
    end
    if (keys[1] and keys[1]._pinyin_bar == true) == want then
        return
    end
    if not want then
        table.remove(keys, 1)
        return
    end
    -- 候选格初始必须有正常宽度。VirtualKey 在 width≈0 时会把空标签字号压到 8，
    -- 之后只改 dimen 不改 face，汉字会一直是蚂蚁字。
    local row = { _pinyin_bar = true }
    for i = 1, 10 do
        local w = NAV_WIDTH
        if i >= 2 and i <= 8 then
            w = 1.0
        elseif i == 9 then
            w = AREA - SLOT_COUNT -- 1.0 空档
        end
        row[i] = { label = "", width = w }
    end
    row[1].label = "◀"
    row[10].label = "▶"
    table.insert(keys, 1, row)
end

-- VirtualKey 的文本节点在三层容器内；同时恢复空键被压小的字号。
local function setKeyText(key, text, gray)
    key.label = text
    key.callback = nil
    local tw = key[1][1][1]
    -- 兜底：若键仍带着被压小的 face，恢复 VirtualKey 自己的键盘字号
    if key.face and tw.face ~= key.face then
        tw.face = key.face
        tw._face_adjusted = nil
    end
    tw.fgcolor = gray and Blitbuffer.COLOR_GRAY or Blitbuffer.COLOR_BLACK
    tw:setText(text)
end

-- 只改已有键的像素宽；绘制实际读取 dimen，不会重建键盘。
local function setKeyPixelWidth(key, px)
    px = math.max(0, px)
    key.width = px
    if key.dimen then
        key.dimen.w = px
    end
    local frame = key[1]
    if type(frame) ~= "table" then
        return
    end
    if frame.dimen then
        frame.dimen.w = px
    end
    local b = key.bordersize or 0
    local center = frame[1]
    if type(center) == "table" and center.dimen then
        center.dimen.w = math.max(0, px - 2 * b)
    end
    local tw = center and center[1]
    if type(tw) == "table" and tw.setMaxWidth then
        tw:setMaxWidth(math.max(8, px - 2 * Size.padding.small))
    end
end

local function redraw()
    if not _keyboard then
        return
    end
    -- 只标记脏区，让 UIManager 在本轮 forceRePaint 里画。
    -- 按键回调里自行 widgetRepaint 候选行会跟 VirtualKey 的 invert/forceRePaint 抢 buffer，真机闪退。
    require("ui/uimanager"):setDirty(_keyboard, function()
        return "fast", _keyboard.dimen
    end)
end

-- ── 候选状态 ─────────────────────────────────────────

local function clearCode()
    if stopSearch then
        stopSearch()
    end
    _code = ""
    _pages = {}
    _page = 1
end

local function charCount(s)
    local _, n = s:gsub("[^\128-\191]", "")
    return n
end

local function makePages(words)
    local max_used = AREA - MIN_SPACER
    local pages, page, used = {}, {}, 0
    for _, word in ipairs(words) do
        local width = math.min(max_used, math.max(1.1, charCount(word) * 1.2))
        if #page > 0 and (used + width > max_used or #page == SLOT_COUNT) then
            pages[#pages + 1], page, used = page, {}, 0
        end
        page[#page + 1], used = { word = word, width = width }, used + width
    end
    if #page > 0 then
        pages[#pages + 1] = page
    end
    return pages
end

-- 原地更新当前页的键宽；行总宽不变，避免 addKeys 释放整张键盘。
local function applyWidths(page)
    local widths = { NAV_WIDTH }
    local used = 0
    for i = 1, SLOT_COUNT do
        local item = page[i]
        widths[1 + i] = item and item.width or 0
        used = used + widths[1 + i]
    end
    widths[9] = math.max(MIN_SPACER, AREA - used)
    widths[10] = NAV_WIDTH
    local signature = table.concat(widths, ",")
    if signature == _width_signature then
        return
    end
    _width_signature = signature
    local kb = _keyboard
    local defs = kb.KEYS[1]
    for i = 1, 10 do
        defs[i].width = widths[i]
    end
    local n = #defs
    local pad = kb.key_padding
    local kb_w = kb.width
    local row = kb.layout and kb.layout[1]
    if not (n > 0 and pad and kb_w and row and #row >= 10) then
        return -- 测试桩没有像素几何，只同步 KEYS 宽度因子
    end
    local base = math.floor((kb_w - (n + 1) * pad - 2 * (kb.padding or 0)) / n)
    for i = 1, 10 do
        setKeyPixelWidth(row[i], math.max(1, math.floor((base + pad) * widths[i]) - pad))
    end
    -- HorizontalGroup 缓存了偏移；keyboard[1]=BottomContainer → frame → center → VerticalGroup
    local vg = kb[1] and kb[1][1] and kb[1][1][1] and kb[1][1][1][1]
    local hg = vg and vg[1]
    if hg and hg.resetLayout then
        hg:resetLayout()
    end
end

local function codeAtCursor(inputbox)
    local pos = inputbox.charpos
    if not pos then
        return false
    end
    for i = #_code, 1, -1 do
        pos = pos - 1
        if inputbox.charlist[pos] ~= _code:sub(i, i) then
            return false
        end
    end
    return true
end

local function commit(word)
    local inputbox = _keyboard and _keyboard.inputbox
    if not inputbox or _code == "" then
        return
    end
    if not codeAtCursor(inputbox) then
        clearCode()
        return
    end
    for _ = 1, #_code do
        rawDelChar(inputbox)
    end
    rawAddChars(inputbox, word)
    clearCode()
end

local function refresh()
    if not _prev_key then
        return
    end
    if not _active then
        setKeyText(_prev_key, "")
        setKeyText(_next_key, "")
        setKeyText(_spacer_key, "")
        for i = 1, SLOT_COUNT do
            setKeyText(_cand_keys[i], "")
        end
        return
    end
    local pages = math.max(1, #_pages)
    if _page > pages then
        _page = pages
    end
    local page = _pages[_page] or {}
    applyWidths(page)
    setKeyText(_prev_key, "◀", _page <= 1)
    if _page > 1 then
        _prev_key.callback = function()
            _page = _page - 1
            refresh()
            redraw()
        end
    end
    setKeyText(_next_key, "▶", _page >= pages)
    if _page < pages then
        _next_key.callback = function()
            _page = _page + 1
            refresh()
            redraw()
        end
    end
    setKeyText(_spacer_key, "")
    for i = 1, SLOT_COUNT do
        local item = page[i]
        local word = item and item.word
        local key = _cand_keys[i]
        if word then
            setKeyText(key, word)
            key.callback = function()
                commit(word)
                refresh()
                redraw()
            end
        else
            setKeyText(key, "")
        end
    end
end

local function bindKeys(kb)
    _prev_key, _next_key, _spacer_key = nil, nil, nil
    _cand_keys = {}
    _width_signature = nil -- 键是新的，下一轮 refresh 必须把宽度写上去
    local row = kb.layout and kb.layout[1]
    if not (kb.KEYS and kb.KEYS[1] and kb.KEYS[1]._pinyin_bar and row and #row >= 10) then
        return false
    end
    for i = 1, 10 do
        -- addKeys 只给非空标签键摘 swipe_callback，候选键标签是空串所以留着了；
        -- 而它们没有 key_chars，一划就 index nil 崩。候选行不需要长按/划动。
        row[i].hold_callback = nil
        row[i].swipe_callback = nil
    end
    _prev_key = row[1]
    for i = 1, SLOT_COUNT do
        _cand_keys[i] = row[1 + i]
    end
    _spacer_key = row[9]
    _next_key = row[10]
    return true
end

-- ── VirtualKeyboard 拦截 ─────────────────────────────

local orig_init, orig_addKeys, orig_addChar, orig_delChar

-- 连打只查最后一次；查询和候选行重绘都在 UIManager 调度里跑，不在按键路径。
local LOOKUP_WAIT = 0.15

stopSearch = function()
    if _requestLookup then
        _requestLookup:cancel()
    end
end

local function showCodeOnly()
    if _code == "" then
        _pages = {}
    else
        _pages = makePages({ _code })
    end
    _page = 1
end

-- 查询经 debounce 移出按键回调。不能用 Task.run：fork 会复制已有 sqlite
-- 连接，设备上可能 SIGSEGV。
local function startLookup(code)
    if code == "" or code ~= _code then
        return
    end
    local words = require("pinyin.dictionary").lookup(code)
    if code ~= _code then
        return
    end
    if type(words) ~= "table" or #words == 0 then
        words = { code }
    end
    _pages = makePages(words)
    _page = 1
    refresh()
    redraw()
end

local function requestLookup(code)
    if not _requestLookup then
        _requestLookup = require("utils.timing").debounce(startLookup, LOOKUP_WAIT)
    end
    _requestLookup(code)
end

-- init、换层和换布局都会重建键位。绑定失败时必须停用拦截，避免吞掉原生输入。
local function wrappedAddKeys(self, ...)
    orig_addKeys(self, ...)
    _keyboard = self
    _active = _want and bindKeys(self)
    refresh()
end

local function wrappedInit(self, ...)
    _want = not not (_enabled() and require("pinyin.dictionary").fileExists())
    syncRow(_want)
    clearCode()
    orig_init(self, ...)
end

local function wrappedAddChar(self, key)
    _keyboard = self
    -- 候选行空槽位是没有 key_chars 的 VirtualKey，点按会以 nil 键调到这里；
    -- 必须吞掉，透传给原生会 addChars(nil) 直接崩（见 candidate_bar_spec）。
    if type(key) ~= "string" then
        return
    end
    if not _active then
        return orig_addChar(self, key)
    end
    if _code ~= "" and not codeAtCursor(self.inputbox) then
        clearCode()
    end
    if key:match("^%a$") then
        _code = _code .. key:lower()
        rawAddChars(self.inputbox, key:lower())
        showCodeOnly()
        refresh()
        requestLookup(_code)
        return
    end
    if _code ~= "" then
        clearCode()
        refresh()
        redraw()
    end
    return orig_addChar(self, key)
end

local function wrappedDelChar(self)
    _keyboard = self
    if _active and _code ~= "" then
        if not codeAtCursor(self.inputbox) then
            clearCode()
            refresh()
            redraw()
            return orig_delChar(self)
        end
        _code = _code:sub(1, -2)
        rawDelChar(self.inputbox)
        showCodeOnly()
        refresh()
        requestLookup(_code)
        return
    end
    return orig_delChar(self)
end

--- 安装 VirtualKeyboard 钩子；重复安装不重复包装方法。
---@param opts { enabled: fun(): boolean }
function Bar.install(opts)
    _enabled = opts.enabled
    if _hooked then
        return
    end
    local VK = require("ui/widget/virtualkeyboard")
    orig_init = VK.init
    orig_addKeys = VK.addKeys
    orig_addChar = VK.addChar
    orig_delChar = VK.delChar
    VK.init = wrappedInit
    VK.addKeys = wrappedAddKeys
    VK.addChar = wrappedAddChar
    VK.delChar = wrappedDelChar
    _hooked = true
end

return Bar
