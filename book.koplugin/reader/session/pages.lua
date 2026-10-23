--[[--
按章打开的全书页码估算：每字页数 = 本章页数 / 本章字数，再乘目录总字数。

缺字数的章用已知章平均值；一章字数都没有就估不了，调用方退回文档页码。
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
    if not cur_words or cur_words <= 0 then return nil end
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

return Pages
