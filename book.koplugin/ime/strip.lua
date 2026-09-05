--[[--
拼音候选条：zh_CN 键盘首行的自足 widget。

鸭子类型（getSize/paintTo/handleEvent/free），不进 KOReader 容器体系：
VerticalGroup 只要求 getSize/paintTo，事件经 WidgetContainer.propagateEvent
逐层下发到 handleEvent。

布局规则（setCells）：
- cell = { tw?, w, callback? }，纯数据：◀▶ 是带回调的 cell，空档是只有宽度
  的 cell。w > 0 的 cell 各自画白底，缝透键盘框底色 = 分割线（与其他行同机制）。
- 候选词按自然文本宽度 + 内边距从左排；剩余预算放不下的词整词不占槽
  （不截断——0/过小的 max_width 会让 xtext makeLine 抛错，Kindle 真机崩过）。
- 队列没坐满 7 个槽（词少或有词放不下）时整体居中：余量均分到两侧空档；
  坐满才左对齐、余量归右空档。条总宽恒定，◀▶ 钉在两端。

@module koplugin.book.ime.strip
--]]

local Blitbuffer = require("ffi/blitbuffer")
local TextWidget = require("ui/widget/textwidget")

-- 候选词 cell 的最小左右内边距：词与词保持呼吸距，不是贴边绘制。
local CELL_PAD = 10

local Strip = {}
Strip.__index = Strip

-- 每页候选槽数：分页（candidate_bar.makePages）与布局共用一个语义来源。
Strip.SLOT_COUNT = 7

--- 用给定字段表建候选条实例（不拷贝，直接挂元表）。
---@param o { dimen: table, gap: number, face: table, bold: boolean|nil, nav_w: number, budget: number, cells: table[] }
---@return table
function Strip:new(o)
    return setmetatable(o, self)
end

--- 条的固定尺寸（VerticalGroup 布局用）。
---@return table
function Strip:getSize()
    return self.dimen
end

--- 释放各 cell 里 TextWidget 占的 xtext C 内存（重建 cells 与销毁时都要调）。
function Strip:free()
    for _, cell in ipairs(self.cells or {}) do
        if cell.tw and cell.tw.free then
            cell.tw:free() -- xtext 的 C 内存，主动释放不等 gc
        end
    end
end

--- 逐 cell 画白底并居中绘制文本；顺带记下实际落点供 tap 命中使用。
--- cell 之间留 gap 不画，透出键盘框底色即分割线。
---@param bb table Blitbuffer
---@param x number
---@param y number
function Strip:paintTo(bb, x, y)
    local d = self.dimen
    d.x, d.y = x, y
    local cx = x
    for _, cell in ipairs(self.cells) do
        if cell.w > 0 then
            bb:paintRoundedRect(cx, y, cell.w, d.h, Blitbuffer.COLOR_WHITE)
            if cell.tw then
                -- 文本在 cell 内水平居中（cell 恰好是文本宽时退化为 padding）
                local tw_size = cell.tw:getSize()
                local inset = math.max(CELL_PAD, math.floor((cell.w - tw_size.w) / 2))
                cell.tw:paintTo(bb, cx + inset, y + math.floor((d.h - tw_size.h) / 2))
            end
        end
        cx = cx + cell.w + self.gap
    end
end

--- 自做 tap 命中：条内 tap 一律吞掉（空档区域不得穿透到下层），命中带回调的 cell 才动作。
--- 缝算进左侧 cell 的命中区（原生键的手势区同样外扩 key_padding）。
---@param event table 事件对象，只处理 onGesture 的 tap
---@return boolean 是否已消费
function Strip:handleEvent(event)
    if event.handler ~= "onGesture" then
        return false
    end
    local ges = event.args and event.args[1]
    if not ges or ges.ges ~= "tap" or not ges.pos then
        return false
    end
    local pos, d = ges.pos, self.dimen
    if not d.x or pos.y < d.y or pos.y >= d.y + d.h
            or pos.x < d.x or pos.x >= d.x + d.w then
        return false
    end
    local cx = d.x
    for _, cell in ipairs(self.cells) do
        if pos.x < cx + cell.w + self.gap then
            if cell.callback then
                cell.callback()
            end
            return true
        end
        cx = cx + cell.w + self.gap
    end
    return true
end

--- 重建 cells：当前页候选词 + 翻页状态。放不下的词不进 cells，立刻释放
---（xtext 有 C 内存；不进 cells 就没有别的释放路径）。
---@param words string[] 当前页候选词（词频序，至多 SLOT_COUNT 个）
---@param opts { page: number, pages: number, on_page: fun(delta: number), on_word: fun(word: string) }
function Strip:setCells(words, opts)
    self:free() -- 旧 cells 的 TextWidget
    --- 造一个 ◀/▶ 翻页 cell；不可用时文字变灰且不挂回调。
    ---@param label string
    ---@param enabled boolean
    ---@param delta number 页码增量
    ---@return table
    local function navCell(label, enabled, delta)
        return {
            tw = TextWidget:new{
                text = label,
                face = self.face,
                bold = self.bold,
                fgcolor = enabled and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY,
            },
            w = self.nav_w,
            callback = enabled and function()
                opts.on_page(delta)
            end or nil,
        }
    end
    local shown = {}
    local left = self.budget
    local words_w = 0
    for _, word in ipairs(words) do
        local tw = TextWidget:new{ text = word, face = self.face, bold = self.bold }
        local w = tw:getSize().w + 2 * CELL_PAD
        if w <= left then
            left = left - w
            words_w = words_w + w
            shown[#shown + 1] = {
                tw = tw,
                w = w,
                callback = function()
                    opts.on_word(word)
                end,
            }
        else
            tw:free()
        end
    end
    local cells = { navCell("◀", opts.page > 1, -1) }
    if #shown < Strip.SLOT_COUNT then
        -- 没坐满：居中（cells = ◀ 左档 词×k 右档 ▶，缝 k+3 条）
        local slack = self.dimen.w - 2 * self.nav_w - words_w - (#shown + 3) * self.gap
        cells[#cells + 1] = { w = math.floor(slack / 2) }
        for _, cell in ipairs(shown) do
            cells[#cells + 1] = cell
        end
        cells[#cells + 1] = { w = slack - math.floor(slack / 2) }
    else
        -- 坐满：左对齐，余量归右空档（缝 9 条，条总宽恒定）
        for _, cell in ipairs(shown) do
            cells[#cells + 1] = cell
        end
        cells[#cells + 1] = { w = self.dimen.w - 2 * self.nav_w - words_w - 9 * self.gap }
    end
    cells[#cells + 1] = navCell("▶", opts.page < opts.pages, 1)
    self.cells = cells
end

return Strip
