--[[--
卷列表与系列页共用的「继续阅读」目标。

主线 = 最远碰过的那一卷（有进度）；这一卷读完就顺延到下一卷，全读完回到第一卷（重读）。
`updated_at` 只用来标记「上次翻阅」，不参与选卷——回头翻旧卷不会把入口拽回去
（Kavita 的 continue-point 是「最早未读完」，正是会被回顾劫持的那种）。

纯函数：不读网、不读盘，进度与时间由调用方注入。

@module source.kavita.continue_point
--]]

local T = require("ffi/util").template
local _ = require("l10n").get("source.kavita")

local M = {}

--- 卷名：优先 toc 的标题；没有、或退化成系列名时兜底「第 N 卷」。
---@param entry table|nil
---@param series_title string|nil
---@return string
function M.label(entry, series_title)
    local title = entry and entry.title
    if type(title) ~= "string" or title == "" or title == series_title then
        local n = tonumber(entry and (entry.idx or entry.number))
        return n and T(_("第 %1 卷"), n) or "?"
    end
    return title
end

---@class ContinueTarget
---@field entry table            要打开的卷
---@field kind "fresh"|"continue"|"done"
---@field fraction number        这一卷的进度 0..1
---@field page number            已读页（用于「第 x/y 页」）
---@field total_pages number
---@field browsed table|nil      上次翻阅且不是主线的卷

--- 选主线。
---@param toc table[]   卷目录（toc 顺序即阅读顺序）
---@param opts table    { fraction = fun(entry):number|nil, updated_at = fun(entry):number|nil,
---                       page = fun(entry):{page:number,total:number}|nil }
---@return ContinueTarget|nil
function M.pick(toc, opts)
    opts = opts or {}
    local entries = {}
    for _i, e in ipairs(toc or {}) do
        local pages = tonumber(e.pages) or 0
        if pages > 0 then
            local fraction = opts.fraction and tonumber(opts.fraction(e))
            if fraction == nil then
                fraction = (tonumber(e.pagesRead) or 0) / pages
            end
            fraction = math.max(0, math.min(1, fraction))
            -- 服务端 / 调用方说这卷已经读完：本机重新打开留下的低进度不改变「已读完」，
            -- 否则回顾旧卷会把主线拖回去，列表也会出现「已读 · 1/194 页」。
            if (tonumber(e.pagesRead) or 0) >= pages
                or (opts.complete and opts.complete(e)) then
                fraction = 1
            end
            entries[#entries + 1] = { entry = e, fraction = fraction }
        end
    end
    if #entries == 0 then return nil end

    local last
    for i, item in ipairs(entries) do
        if item.fraction > 0 then last = i end
    end

    local target, kind
    if not last then
        target, kind = entries[1], "fresh"
    elseif entries[last].fraction < 1 then
        target, kind = entries[last], "continue"
    else
        local next_item
        for i = last + 1, #entries do
            if entries[i].fraction < 1 then next_item = entries[i] break end
        end
        if next_item then
            target, kind = next_item, "continue"
        else
            target, kind = entries[1], "done"
        end
    end

    local total = tonumber(target.entry.pages) or 0
    local page
    if opts.page then
        local got = opts.page(target.entry)
        if got then
            page = tonumber(got.page)
            total = tonumber(got.total) or total
        end
    end
    if not page then page = math.floor(target.fraction * total + 0.5) end
    if kind == "fresh" then page = 0 end

    -- 「上次翻阅」：本机更新时间最新的一卷；和主线同一卷就不标。
    local browsed, browsed_at
    if opts.updated_at then
        for _i, item in ipairs(entries) do
            local ts = tonumber(opts.updated_at(item.entry)) or 0
            if ts > 0 and (not browsed_at or ts > browsed_at) then
                browsed, browsed_at = item, ts
            end
        end
    end

    return {
        entry = target.entry,
        kind = kind,
        fraction = target.fraction,
        page = page,
        total_pages = total,
        browsed = browsed and tostring(browsed.entry.chapterId) ~= tostring(target.entry.chapterId)
            and browsed.entry or nil,
    }
end

return M
