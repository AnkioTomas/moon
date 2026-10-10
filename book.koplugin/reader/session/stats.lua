--[[--
阅读会话的统计计时：当前页停留时长写入 reading_stats 待同步记录。

上报与拉取在 ``book.stats``，由属主 Source 决定时机。

@module koplugin.book.reader.session.stats
--]]

local StatsDB = require("book.stats_db")
local logger = require("utils.log")

local SessionStats = {
    session = nil,
}
--- 单页停留计时上限（秒），与 KOReader 统计插件默认 max_sec 一致：
--- 设备不休眠（充电、关闭自动休眠）时停在一页上不能把几小时都算成阅读。
local MAX_PAGE_SECONDS = 120

--- 当前阅读页的内存计时会话。
---@class ReadingStatsSession
---@field identity BookIdentity 当前文档身份
---@field page number 当前页码；0 表示未知
---@field total_pages number 当前文档总页数；未知时为 0
---@field chapter_idx integer|nil 当前章节序号（整本书为 nil）
---@field chapter_fraction number|nil 当前章节阅读比例（0..1）
---@field started_at integer 当前页开始计时的 Unix 时间戳

--- 结清一个页面计时段并写入待同步统计。
--- 停留不足 1 秒时直接丢弃，超过 MAX_PAGE_SECONDS 按上限计；数据库错误通过 done 返回。
---@param current ReadingStatsSession
---@param done fun(err: any|nil)|nil
local function settle(current, done)
    local duration = math.min(os.time() - current.started_at, MAX_PAGE_SECONDS)
    if duration < 1 or current.page < 1 then
        if done then done() end
        return
    end
    local row = {
        source_id = current.identity.source_id,
        stable_id = current.identity.stable_id,
        record_type = "page",
        page = current.page,
        start_time = current.started_at,
        duration = duration,
        total_pages = current.total_pages,
        chapter_idx = current.chapter_idx,
        chapter_fraction = current.chapter_fraction,
    }
    local ok = StatsDB.add(row)
    if not ok then
        logger.warn("book.stats write failed", row.stable_id)
    end
    if done then done(not ok and "failed to record reading stats" or nil) end
end

--- 停止计时：移除当前内存会话，结清活动计时段；最后一段落库后调用 done。
--- 先清空 session，避免重复结算同一计时段。
---@param done fun(err: any|nil)|nil
function SessionStats.stop(done)
    local current = SessionStats.session
    SessionStats.session = nil
    if current then
        settle(current, done)
    elseif done then
        done()
    end
end

--- 开始或恢复当前页计时。
--- 启动新会话前会先结清遗留会话，防止异常生命周期丢失统计。
---@param snapshot ReaderSessionSnapshot
function SessionStats.start(snapshot)
    SessionStats.stop()
    if not snapshot or not snapshot.identity then return end
    SessionStats.session = {
        identity = snapshot.identity,
        page = tonumber(snapshot.page) or 0,
        total_pages = tonumber(snapshot.total_pages) or 0,
        chapter_idx = snapshot.identity.chapter_idx,
        chapter_fraction = snapshot.chapter_fraction,
        started_at = os.time(),
    }
end

--- 翻页时结清旧页并开始新页计时。
--- 没有活动会话、页码非法或页码未变化时不执行任何操作。
---@param snapshot ReaderSessionSnapshot|nil
function SessionStats.onPage(snapshot)
    local current = SessionStats.session
    if not snapshot then return end
    local page = tonumber(snapshot.page)
    if not current or not page or page == current.page then return end
    settle(current)
    current.page = page
    current.total_pages = tonumber(snapshot.total_pages) or 0
    current.chapter_fraction = snapshot.chapter_fraction
    current.started_at = os.time()
end

return SessionStats
