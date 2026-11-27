--[[--
首页统计组件共用读库：同一次组装 / 同一次 stats_changed 刷新只扫日表一次。

有 ctx.stats_memo（Home 每次 assemble 换新表，stats_changed 清空）时走缓存；
离屏预览 / 单测没 memo 时直接查库，行为与原先一致。

@module koplugin.book.desktop.pages.home.stats_data
--]]

local Catalog = require("book.catalog")
local StatsDB = require("book.stats_db")

local M = {}

---@param scope string|string[]|nil
---@return string
local function scopeKey(scope)
    if type(scope) == "table" then return table.concat(scope, "\0") end
    return tostring(scope or "")
end

--- 当前展示范围；没源返回 nil。
---@param ctx table
---@return string|string[]|nil
function M.scope(ctx)
    local source = ctx.source or (ctx.desktop and ctx.desktop.source)
    if not source then return nil end
    return Catalog.libraryScope(source.id)
end

--- 日表：无时间窗返回全量；有窗按 ymd 过滤（日表已按本地日聚合）。
---@param ctx table
---@param start_ts number|nil
---@param end_ts number|nil
---@return table[] rows
---@return string|string[]|nil scope
function M.daily(ctx, start_ts, end_ts)
    local scope = M.scope(ctx)
    if not scope then return {}, nil end
    local memo = ctx.stats_memo
    local rows
    if memo then
        local key = scopeKey(scope)
        if memo.scope_key ~= key then
            memo.scope_key = key
            memo.daily = nil
            memo.finished_year = nil
            memo.finished_year_for = nil
        end
        if not memo.daily then
            memo.daily = StatsDB.dailyBySource(scope)
        end
        rows = memo.daily
    else
        rows = StatsDB.dailyBySource(scope, start_ts, end_ts)
        return rows, scope
    end
    if not start_ts then return rows, scope end
    local start_ymd = os.date("%Y-%m-%d", start_ts)
    local end_ymd = end_ts and os.date("%Y-%m-%d", end_ts) or nil
    local out = {}
    for _idx, row in ipairs(rows) do
        if row.ymd >= start_ymd and (not end_ymd or row.ymd < end_ymd) then
            out[#out + 1] = row
        end
    end
    return out, scope
end

--- 三卡汇总：复用同一份日表，禁止 summary + daily 双扫。
---@param ctx table
---@return table summary
---@return table[] daily
---@return string|string[]|nil scope
function M.summary(ctx)
    local daily, scope = M.daily(ctx)
    if not scope then
        return { total_seconds = 0, total_pages = 0, last7_seconds = 0, longest_day_seconds = 0 }, daily, nil
    end
    return StatsDB.summaryBySource(scope, daily), daily, scope
end

--- 今年读完本数（与 Calc.forecast 的 done 同口径）。
---@param ctx table
---@param now number|nil
---@return number
function M.finishedYear(ctx, now)
    now = now or os.time()
    local scope = M.scope(ctx)
    if not scope then return 0 end
    local year = tonumber(os.date("%Y", now))
    local year_start = os.time{ year = year, month = 1, day = 1, hour = 0 }
    local memo = ctx.stats_memo
    if not memo then
        return StatsDB.finishedCountSince(scope, year_start)
    end
    local key = scopeKey(scope)
    if memo.scope_key ~= key then
        memo.scope_key = key
        memo.daily = nil
        memo.finished_year = nil
        memo.finished_year_for = nil
    end
    if memo.finished_year_for ~= year then
        memo.finished_year_for = year
        memo.finished_year = StatsDB.finishedCountSince(scope, year_start)
    end
    return memo.finished_year
end

return M
