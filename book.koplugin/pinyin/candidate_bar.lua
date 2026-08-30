--[[--
拼音候选栏：zh_CN 键盘首行候选条。

@module koplugin.book.pinyin.candidate_bar
--]]

local Bar = {}

local Strip = require("pinyin.strip")
local util = require("util")
local SimpleJob = require("workers.simple_job")

local ZH_MODULE = "ui/data/keyboardlayouts/zh_CN_keyboard"
local SLOT_COUNT = Strip.SLOT_COUNT

local _enabled
local _hooked = false

local _want = false
local _active = false
local _keyboard
local _strip
local lookup = {
    code = "",
    pages = {},
    page = 1,
    debounce = nil,
    job = nil,
    generation = 0,
}

-- ── 基础工具 ─────────────────────────────────────────

--- 绕过 IME 包装直写输入框，避免候选字再次进入原生 IME。
---@param inputbox table InputText 实例
---@param chars string
local function rawAddChars(inputbox, chars)
    local f = inputbox.addChars
    if type(f) == "table" and f.raw_method_call then
        f:raw_method_call(chars)
    else
        inputbox:addChars(chars)
    end
end

--- 绕过 IME 包装删除光标前一个字符。
---@param inputbox table InputText 实例
local function rawDelChar(inputbox)
    local f = inputbox.delChar
    if type(f) == "table" and f.raw_method_call then
        f:raw_method_call()
    else
        inputbox:delChar()
    end
end

--- 把光标前 count 个字符整体换成 chars。
--- InputText 没有批量替换 API。候选提交若循环 delChar，会让每个拼音字母都
--- free/init 一遍 TextBoxWidget；Kindle 上这比查词慢得多。真实 InputText 直接
--- 改 charlist 后只重排一次；非标准输入框保留原来的兼容路径。
---@param inputbox table InputText 实例
---@param count number 待替换的字符数（已输入的拼音码长度）
---@param chars string 替换成的词
---@return boolean 只读、不可编辑或光标前不足 count 个字符时 false
local function rawReplaceBeforeCursor(inputbox, count, chars)
    if inputbox.readonly
            or inputbox.isTextEditable and not inputbox:isTextEditable(true) then
        return false
    end
    if type(inputbox.charlist) ~= "table"
            or type(inputbox.charpos) ~= "number"
            or type(inputbox.initTextBox) ~= "function" then
        for _ = 1, count do
            rawDelChar(inputbox)
        end
        rawAddChars(inputbox, chars)
        return true
    end

    local start_pos = inputbox.charpos - count
    if start_pos < 1 then
        return false
    end
    for _ = 1, count do
        table.remove(inputbox.charlist, start_pos)
    end
    local added = util.splitToChars(chars)
    for i = #added, 1, -1 do
        table.insert(inputbox.charlist, start_pos, added[i])
    end
    inputbox.charpos = start_pos + #added
    inputbox.undo_charlist = nil
    inputbox.is_text_edited = true
    inputbox:initTextBox(nil, true)
    return true
end

--- 候选行随 want 插入/摘除 zh_CN 布局数据（幂等）。
--- 必须在 VirtualKeyboard:init 读 keys 之前调用——键盘高度按行数算。
--- 行内保留 10 个空键：addKeys 以 #KEYS[1] 为基准键宽。建出来的首行随后
--- 被 Strip 整条顶掉，这些键只是占位。
---@param want boolean 候选行是否应存在
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
    local row = { _pinyin_bar = true }
    for i = 1, 10 do
        row[i] = { label = "", width = 1.0 }
    end
    row[1].label = "◀"
    row[10].label = "▶"
    table.insert(keys, 1, row)
end

--- 把当前键盘标记为脏区，让候选行在本轮刷新里重画（无键盘时无操作）。
--- 只标记脏区，让 UIManager 在本轮 forceRePaint 里画：
--- 自行 widgetRepaint 候选条会跟 VirtualKey 的 invert/forceRePaint 抢 buffer，真机闪退。
--- 刷新类型必须留灰阶（ui）：fast 在 Kindle 上是 DU 波形（2 级灰），
--- 会把键缝透出的浅灰分割线量化成白，打字后候选行就没线了。
local function redraw()
    if not _keyboard then
        return
    end
    require("ui/uimanager"):setDirty(_keyboard, function()
        return "ui", _keyboard.dimen
    end)
end

-- ── 候选状态 ─────────────────────────────────────────

--- 结束本次拼写：取消在途查询，清空输入码与候选分页。
local function clearCode()
    lookup.generation = lookup.generation + 1
    if lookup.debounce then
        lookup.debounce:cancel()
    end
    if lookup.job then
        lookup.job:cancel()
    end
    lookup.job = nil
    lookup.code = ""
    lookup.pages = {}
    lookup.page = 1
end

--- 按候选槽数把词表切成分页（保持词频序）。
---@param words string[]
---@return string[][]
local function makePages(words)
    local pages, page = {}, {}
    for _, word in ipairs(words) do
        if #page == SLOT_COUNT then
            pages[#pages + 1], page = page, {}
        end
        page[#page + 1] = word
    end
    if #page > 0 then
        pages[#pages + 1] = page
    end
    return pages
end

--- 校验光标前紧邻的字符确实是当前输入码。
--- 用户点走光标或别处改了文本时会不成立，此时必须放弃这次拼写而不是乱替换。
---@param inputbox table InputText 实例
---@return boolean
local function codeAtCursor(inputbox)
    local pos = inputbox.charpos
    if not pos then
        return false
    end
    for i = #lookup.code, 1, -1 do
        pos = pos - 1
        if inputbox.charlist[pos] ~= lookup.code:sub(i, i) then
            return false
        end
    end
    return true
end

--- 提交候选：删掉已输入的字母、插入整词，并结束本次拼写。
---@param word string
---@return boolean 无输入码、光标已离开输入码或替换失败时 false
local function commit(word)
    local inputbox = _keyboard and _keyboard.inputbox
    if not inputbox or lookup.code == "" then
        return false
    end
    if not codeAtCursor(inputbox) then
        clearCode()
        return false
    end
    if not rawReplaceBeforeCursor(inputbox, #lookup.code, word) then
        return false
    end
    clearCode()
    return true
end

--- 页码收口后把当前页词表交给候选条重建 cells（布局规则全在 strip.lua）。
--- 同时挂上翻页与选词回调；未装候选条时无操作。
local function refresh()
    local strip = _strip
    if not strip then
        return
    end
    local pages = math.max(1, #lookup.pages)
    if lookup.page > pages then
        lookup.page = pages
    end
    strip:setCells(lookup.pages[lookup.page] or {}, {
        page = lookup.page,
        pages = pages,
        on_page = function(delta)
            lookup.page = lookup.page + delta
            refresh()
            redraw()
        end,
        on_word = function(word)
            commit(word)
            refresh()
            redraw()
        end,
    })
end

--- 候选条挂进键盘：addKeys 建完整棵树后，把首行 HorizontalGroup 整条顶掉。
--- 布局树：kb[1]=BottomContainer → 键盘框 FrameContainer → CenterContainer
--- → VerticalGroup，其 [1] 即首行（行内键与 span 交错，奇数位是键）。
--- 结构对不上就不装（候选栏停用、输入全透传；首行退回等宽空键行）。
---@param kb table VirtualKeyboard 实例
---@return boolean 是否装上候选条
local function installStrip(kb)
    _strip = nil
    if not (kb.KEYS and kb.KEYS[1] and kb.KEYS[1]._pinyin_bar) then
        return false
    end
    local vg = kb[1] and kb[1][1] and kb[1][1][1] and kb[1][1][1][1]
    local row = vg and vg[1]
    if not (row and row.getSize and row[1] and row[1].width) then
        return false
    end
    local budget = 0
    for j = 3, 17, 2 do -- 第 2..9 个键（7 候选槽 + 空档）
        budget = budget + row[j].width
    end
    local size = row:getSize()
    local strip = Strip:new{
        dimen = { w = size.w, h = size.h },
        gap = kb.key_padding or 2,
        face = row[1].face, -- 与被顶掉的键同款键盘字体（含 keyboard_key_font_size/bold 设置）
        bold = row[1].bold,
        nav_w = row[1].width,
        budget = budget,
        cells = {},
    }
    vg[1] = strip -- 顶掉的首行是 addKeys 刚建的（空标签，无 xtext），丢弃无泄漏
    kb.layout[1] = { strip } -- FocusManager 方向键导航按 layout 遍历：整行一个部件
    _strip = strip
    return true
end

-- ── VirtualKeyboard 拦截 ─────────────────────────────

local orig_init, orig_addKeys, orig_addChar, orig_delChar

-- 连打只查最后一次；查询和候选行重绘都在 UIManager 调度里跑，不在按键路径。
local LOOKUP_WAIT = 0.15

--- 查库结果回来之前先只显示输入码本身，避免候选行空一拍。
local function showCodeOnly()
    if lookup.code == "" then
        lookup.pages = {}
    else
        lookup.pages = makePages({ lookup.code })
    end
    lookup.page = 1
end

--- 实际查词并刷新候选行（debounce 到期后执行）。
---@param keyboard table 发起查询的 VirtualKeyboard 实例
---@param code string 输入码（小写字母串）
local function startLookup(keyboard, code)
    if keyboard ~= _keyboard or code == "" or code ~= lookup.code then
        return
    end
    local generation = lookup.generation
    lookup.job = SimpleJob.run(function()
        return require("pinyin.dictionary").lookup(code)
    end, {
        on_done = function(words)
            if generation ~= lookup.generation
                    or keyboard ~= _keyboard or code ~= lookup.code then
                return
            end
            if type(words) ~= "table" or #words == 0 then
                words = { code }
            end
            lookup.pages = makePages(words)
            lookup.page = 1
            refresh()
            redraw()
        end,
    })
end

--- 连打去抖：只查最后一次输入码（debounce 句柄进程内共用，首次调用时建）。
---@param keyboard table 发起查询的 VirtualKeyboard 实例
---@param code string 输入码
local function requestLookup(keyboard, code)
    if lookup.job then
        lookup.job:cancel()
        lookup.job = nil
    end
    if not lookup.debounce then
        lookup.debounce = require("utils.timing").debounce(startLookup, LOOKUP_WAIT)
    end
    -- The debounce handle is shared, so keep the owner in its arguments. A
    -- callback from an old keyboard must never repaint the current one.
    lookup.debounce(keyboard, code)
end

--- 关掉该键盘实例所有按键的闪烁：原生闪烁会在字符回调前强制提交一次墨水刷新，
--- Kindle 上后续 UI 刷新会阻塞等 marker，整屏发卡。
---@param kb table VirtualKeyboard 实例
local function disableKeyFlash(kb)
    for _, row in ipairs(kb.layout or {}) do
        for _, key in ipairs(row) do
            key.flash_keyboard = false
        end
    end
end

--- VirtualKeyboard:addKeys 包装：键位重建后（init、换层、换布局都会走这里）
--- 重新挂候选条。安装失败时必须停用拦截，避免吞掉原生输入。
---@param ... any 透传给原方法
local function wrappedAddKeys(self, ...)
    orig_addKeys(self, ...)
    if _want then
        -- 只改这个键盘实例；插件关闭或词库不可用时仍服从 KOReader 设置。
        disableKeyFlash(self)
    end
    _keyboard = self
    _active = _want and installStrip(self)
    refresh()
end

--- VirtualKeyboard:init 包装：建键盘树之前定下这次要不要候选行并同步布局数据
--- （键盘高度按行数算，晚了就来不及）。
--- 文件存在不等于 SQLite 可用；损坏或未完成的文件必须保留原生 IME。
--- number 输入框从符号层起步、不打字，候选行直接不装。
---@param ... any 透传给原方法
local function wrappedInit(self, ...)
    _want = not not (_enabled() and require("pinyin.dictionary").isAvailable()
        and not (self.inputbox and self.inputbox.input_type == "number"))
    syncRow(_want)
    clearCode()
    orig_init(self, ...)
end

--- VirtualKeyboard:addChar 包装：候选栏激活时接管字母键。
--- 字母就地小写写进输入框并追加到输入码；空格提交首选（提交失败才透传）；
--- 其余键结束本次拼写后走原路。未激活时全透传。
--- 上游偶发非字符串键（如空键位）会被吞掉：透传给原生会 addChars(nil) 直接崩。
---@param key string 按键字符
local function wrappedAddChar(self, key)
    _keyboard = self
    if type(key) ~= "string" then
        return
    end
    if not _active then
        return orig_addChar(self, key)
    end
    if lookup.code ~= "" and not codeAtCursor(self.inputbox) then
        clearCode()
    end
    if key:match("^%a$") then
        lookup.code = lookup.code .. key:lower()
        rawAddChars(self.inputbox, key:lower())
        showCodeOnly()
        refresh()
        requestLookup(self, lookup.code)
        return
    end
    if key == " " and lookup.code ~= "" then
        local first = lookup.pages[1] and lookup.pages[1][1]
        if first and commit(first) then
            refresh()
            redraw()
            return
        end
        refresh()
        redraw()
        return orig_addChar(self, key)
    end
    if lookup.code ~= "" then
        clearCode()
        refresh()
        redraw()
    end
    return orig_addChar(self, key)
end

--- VirtualKeyboard:delChar 包装：拼写中逐字母回退输入码并重查，
--- 光标已离开输入码则先结束拼写再走原路。
local function wrappedDelChar(self)
    _keyboard = self
    if _active and lookup.code ~= "" then
        if not codeAtCursor(self.inputbox) then
            clearCode()
            refresh()
            redraw()
            return orig_delChar(self)
        end
        lookup.code = lookup.code:sub(1, -2)
        rawDelChar(self.inputbox)
        showCodeOnly()
        refresh()
        requestLookup(self, lookup.code)
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
