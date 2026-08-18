--[[--
拼音候选栏：zh_CN 键盘首行候选条。

拦截点与 pinyinplus.koplugin 一致：挂在 VirtualKeyboard.addChar/delChar 上
（键盘类方法，每个虚拟键敲击的必经之路，上游多年未变）。不去替换
wrapInputBox 包装表的 func——那依赖 generic_ime 包装结构的内部细节，
结构对不上就静默退回原生 IME（候选混进输入框文本），已经在真机上踩过。

不同之处：候选来源是 Book 词库（pinyin.dictionary，rime-ice 词频序），
不是 zh_pinyin_data 单字码表；标签更新走 TextWidget:setText/setMaxWidth 公开 API；
固定键宽（◀ 1.0 + 7×1.1 候选 + 0.3 空档 + ▶ 1.0 = 10 单位，与字母行对齐）。

激活时（开关开 + 词库在 + 当前 zh_CN 布局）：小写字母不进原生 IME，
原样写进输入框（所见即所输），词库候选显示在键盘首行；
点候选 = 删掉已输入字母、插入整词。退格逐字母回退。
大写字母与非字母结束本次拼写（已输入字母留作普通文本），按键走原路。

已知取舍：物理键盘 / SDL 文本输入（InputText:onTextInput → inputbox:addChars）
不经过 VirtualKeyboard.addChar，仍走原生 IME——与 pinyinplus 行为一致。
目标设备（Android）用的是屏幕键盘，不受影响。

两条硬约束（踩过坑）：
- 候选行只在真能用（开关开 + 词库在）时插进 zh_CN 布局，其余情况必须摘掉：
  否则留下一整行按不动的 ◀▶ 幽灵行，而输入还是原生 IME 行内候选。
- 键位绑定跟着 VirtualKeyboard:addKeys 走，不是 init：换层（Shift/Sym、number 输入框
  从 layer 4 切字母层）只调 addKeys，全部 VirtualKey 会重建，绑 init 必然拿到死引用。

@module koplugin.book.pinyin.candidate_bar
--]]

local Bar = {}

local ZH_MODULE = "ui/data/keyboardlayouts/zh_CN_keyboard"
local CANDIDATE_SLOT_COUNT = 7

local _enabled ---@type fun(): boolean 由 install 注入（pinyin.init 的开关判定）
local _hooked = false

-- 输入会话状态
local _want = false ---@type boolean 本次键盘：开关开且词库可用（决定候选行在不在）
local _active = false ---@type boolean 当前布局是 zh_CN 且 want：拦截字母输入
local _keyboard ---@type table|nil 当前 VirtualKeyboard 实例
local _code = ""
local _pages = {}
local _page = 1
local _prev_key, _next_key, _spacer_key
local _cand_keys = {}
local _width_signature

-- ── 基础工具 ─────────────────────────────────────────

--- 绕过 IME 包装直写输入框：是 wrapMethod 包装表就走 raw_method_call，否则直调。
---@param inputbox table
---@param chars string
local function rawAddChars(inputbox, chars)
    local f = inputbox.addChars
    if type(f) == "table" and f.raw_method_call then
        f:raw_method_call(chars)
    else
        inputbox:addChars(chars)
    end
end

---@param inputbox table
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
---@param want boolean
local function syncRow(want)
    if not (want or package.loaded[ZH_MODULE]) then
        return -- 从没插过行，不必为了摘行去加载布局模块
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
    local row = { _pinyin_bar = true }
    for i = 1, 10 do
        row[i] = { label = "", width = (i == 1 or i == 10) and 1.0 or 0 }
    end
    row[1].label = "◀"
    row[9].width = 8.0
    row[10].label = "▶"
    table.insert(keys, 1, row)
end

--- 更新候选键文本。
---@param key table VirtualKey 实例（结构：[1]=FrameContainer [1]=CenterContainer [1]=TextWidget）
---@param text string
---@param gray boolean|nil
local function setKeyText(key, text, gray)
    key.label = text
    key.callback = nil
    local tw = key[1][1][1]
    local Blitbuffer = require("ffi/blitbuffer")
    tw.fgcolor = gray and Blitbuffer.COLOR_GRAY or Blitbuffer.COLOR_BLACK
    tw:setText(text)
end

local function redraw()
    if _keyboard then
        require("ui/uimanager"):setDirty(_keyboard, function()
            return "ui", _keyboard.dimen
        end)
    end
end

-- ── 候选状态 ─────────────────────────────────────────

local function clearCode()
    _code = ""
    _pages = {}
    _page = 1
end

local function charCount(s)
    local _, n = tostring(s):gsub("[^\128-\191]", "")
    return n
end

local function makePages(words)
    local pages, page, used = {}, {}, 0
    for _, word in ipairs(words) do
        local width = math.min(7.7, 0.7 + charCount(word) * 0.5)
        if #page > 0 and (used + width > 7.7 or #page == CANDIDATE_SLOT_COUNT) then
            pages[#pages + 1], page, used = page, {}, 0
        end
        page[#page + 1], used = { word = word, width = width }, used + width
    end
    if #page > 0 then pages[#pages + 1] = page end
    return pages
end

local function reload()
    if _code == "" then
        _pages = {}
    else
        local words = require("pinyin.dictionary").lookup(_code) or {}
        if #words == 0 then words = { _code } end
        _pages = makePages(words)
    end
    _page = 1
end

local function applyWidths(page)
    local widths = { 1.0 }
    local used = 0
    for i = 1, CANDIDATE_SLOT_COUNT do
        local item = page[i]
        widths[1 + i] = item and item.width or 0
        used = used + widths[1 + i]
    end
    widths[9] = math.max(0.3, 7.7 - used)
    widths[10] = 1.0
    local signature = table.concat(widths, ",")
    if signature == _width_signature then return false end
    _width_signature = signature
    for i = 1, 10 do _keyboard.KEYS[1][i].width = widths[i] end
    _keyboard:addKeys()
    return true
end

local function codeAtCursor(inputbox)
    local pos = inputbox.charpos
    if not pos then return false end
    for i = #_code, 1, -1 do
        pos = pos - 1
        if inputbox.charlist[pos] ~= _code:sub(i, i) then return false end
    end
    return true
end

--- 点候选：插整词、清空本次拼写。
---@param word string
local function commit(word)
    local inputbox = _keyboard and _keyboard.inputbox
    if not inputbox then
        return
    end
    if _code == "" then
        return
    end
    if not codeAtCursor(inputbox) then
        clearCode()
        return
    end
    for _ = 1, #_code do rawDelChar(inputbox) end
    rawAddChars(inputbox, word)
    clearCode()
end

--- 把当前页候选/翻页键写到键盘首行并刷新。
local function refresh()
    if not _prev_key then
        return
    end
    if not _active then
        setKeyText(_prev_key, "")
        setKeyText(_next_key, "")
        setKeyText(_spacer_key, "")
        for i = 1, CANDIDATE_SLOT_COUNT do
            setKeyText(_cand_keys[i], "")
        end
        return
    end
    local pages = math.max(1, #_pages)
    if _page > pages then
        _page = pages
    end
    local page = _pages[_page] or {}
    if applyWidths(page) then return end
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
    for i = 1, CANDIDATE_SLOT_COUNT do
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

--- 绑定键盘实例首行的候选键引用（仅 zh_CN 候选行存在时）。
---@param kb table VirtualKeyboard 实例
---@return boolean
local function bindKeys(kb)
    _prev_key, _next_key, _spacer_key = nil, nil, nil
    _cand_keys = {}
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
    for i = 1, CANDIDATE_SLOT_COUNT do
        _cand_keys[i] = row[1 + i]
    end
    _spacer_key = row[9]
    _next_key = row[10]
    return true
end

-- ── VirtualKeyboard 拦截 ─────────────────────────────

local orig_init, orig_addKeys, orig_addChar, orig_delChar

--- 键位重建（init / 换层 / 换布局都经这里）：重新绑定候选行并刷新。
--- 绑 init 会在换层后拿到死引用——换层只走 addKeys。
local function wrappedAddKeys(self, ...)
    orig_addKeys(self, ...)
    _keyboard = self
    local zh = self.KEYS[1] and self.KEYS[1]._pinyin_bar == true
    local bound = bindKeys(self) -- 无论激活与否都要重绑：旧键位已经废了
    _active = _want and zh or false
    if zh and not bound then
        -- 输入拦截仍生效（候选行显示不了而已）；真机上出现过，留日志好定位
        require("logger").warn("book.pinyin candidate row present but key bind failed")
    end
    refresh()
end

local function wrappedInit(self, ...)
    -- 布局装配前决定候选行在不在（键盘高度按行数算，必须先于 orig_init）
    _want = (_enabled and _enabled() and require("pinyin.dictionary").isAvailable()) and true or false
    syncRow(_want)
    clearCode()
    orig_init(self, ...) -- 内部 addKeys → wrappedAddKeys 完成绑定
end

--- 拼写会话主入口：每个虚拟键敲击都经过 VirtualKeyboard:addChar。
--- 激活时小写字母就地拦截（原生 IME 根本看不到字母，输入框不会出现行内候选）。
local function wrappedAddChar(self, key)
    _keyboard = self
    if type(key) ~= "string" then
        return -- 候选行空键会给 nil（未激活时重建的键），addChars(nil) 会崩，吞掉
    end
    if not _active then
        return orig_addChar(self, key)
    end
    if key:match("^%a$") then
        _code = _code .. key:lower()
        rawAddChars(self.inputbox, key:lower())
        reload()
        refresh()
        redraw()
        return
    end
    -- 非字母：结束本次拼写，按键走原路
    if _code ~= "" then
        clearCode()
        refresh()
        redraw()
    end
    return orig_addChar(self, key)
end

--- 退格：有输入码逐字母回退，码空走原路（原生删普通文本）。
local function wrappedDelChar(self)
    _keyboard = self
    if _active then
        if _code ~= "" then
            _code = _code:sub(1, -2)
            rawDelChar(self.inputbox)
            reload()
            refresh()
            redraw()
            return
        end
    end
    return orig_delChar(self)
end

--- 安装 VirtualKeyboard hook（幂等）。词库后续下载完成无需重装：
--- 候选行与激活判定都在每次键盘 init 时重算。
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
