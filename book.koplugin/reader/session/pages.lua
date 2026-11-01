--[[--
全书页码。

按章打开：每字页数 = 本章页数 / 本章字数，再乘目录总字数。缺字数的章用已知章平均值。
一章字数都没有、但目录不止一章时，按本章页数外推——否则全书页码和章内页码是同一个数。
一章或没目录估不了，调用方用文档页码。

整本书：与章内页码同一套序号（页码标签、隐藏流，否则屏幕页）。
顶栏 / 侧栏 / 锁屏经 Session.bookPages 共用这一份，不各自再算。

@module koplugin.book.reader.session.pages
--]]

local Pages = {}

--- 用目录字数估全书页码。
---@param toc table[]|nil 章节目录（条目带 words）
---@param idx integer|nil 当前章序号（toc 下标）
---@param page integer|nil 本章当前页
---@param pages integer|nil 本章页数
---@return integer|nil page, integer|nil total
function Pages.estimate(toc, idx, page, pages)
    idx, page, pages = tonumber(idx), tonumber(page), tonumber(pages)
    if type(toc) ~= "table" or not idx or not page or not pages or page <= 0 or pages <= 0 then return nil end
    local known_sum, known_n = 0, 0
    for _i, ch in ipairs(toc) do
        local w = tonumber(ch.words)
        if w and w > 0 then known_sum, known_n = known_sum + w, known_n + 1 end
    end
    local avg = known_n > 0 and (known_sum / known_n) or nil
    local cur = toc[idx]
    local cur_words = cur and tonumber(cur.words)
    if not cur_words or cur_words <= 0 then cur_words = avg end
    if not cur_words or cur_words <= 0 then
        if #toc > 1 and idx >= 1 and idx <= #toc then
            return (idx - 1) * pages + page, #toc * pages
        end
        return nil
    end
    local before, total = 0, 0
    for i, ch in ipairs(toc) do
        local w = tonumber(ch.words)
        if not w or w <= 0 then w = avg end
        if not w or w <= 0 then return nil end
        total = total + w
        if i < idx then before = before + w end
    end
    local ratio = pages / cur_words
    local est_total = math.max(math.floor(total * ratio + 0.5), math.floor(before * ratio + 0.5) + pages)
    return math.floor(before * ratio + 0.5) + page, est_total
end

--- 整本书的当前页与总页，和 ReaderToc 章内页数同一套序号。
--- 页码标签优先（标签序号，不是屏幕页），其次隐藏流里的流内页码。
---@param ui table|nil ReaderUI
---@param page integer|nil 屏幕页
---@param total integer|nil 屏幕总页
---@return integer page
---@return integer total
function Pages.document(ui, page, total)
    page, total = tonumber(page) or 0, tonumber(total) or 0
    local pagemap = ui and ui.pagemap
    if pagemap and pagemap:wantsPageLabels() then
        local _label, idx, count = pagemap:getCurrentPageLabel(false)
        idx, count = tonumber(idx), tonumber(count)
        if idx and count and idx > 0 and count > 0 then
            return idx, count
        end
    end
    local document = ui and ui.document
    if document and page > 0 and document:hasHiddenFlows() then
        local in_flow = document:getPageNumberInFlow(page)
        local pages = document:getTotalPagesInFlow(document:getPageFlow(page))
        in_flow, pages = tonumber(in_flow), tonumber(pages)
        if in_flow and pages and in_flow > 0 and pages > 0 then
            return in_flow, pages
        end
    end
    return page, total
end

return Pages
