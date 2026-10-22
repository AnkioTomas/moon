--[[--
统计页的纯计算：环、趋势、周对比、热力图、完成预测、月挑战与排行。

输入是 Catalog.toInsight 产出的日表 `days[ymd] = { duration_seconds, pages }`、
StatsDB.sessionRows 的逐页记录和 StatsDB.progressBooks 的书；输出给 UI 直接画。
无 UI、无 DB、无 KOReader 依赖；`now` 一律由调用方传入（时间戳）。
目标不做配置：全部由用户自己的历史推算，没有历史走常量兜底。

@module koplugin.book.book.insight_calc
--]]

local Calc = {}

local DAY = 86400
--- 两次翻页间隔超过这个秒数就算新的一次阅读。
local SESSION_GAP = 600

---@param ts number
---@return string
local function ymdOf(ts) return os.date("%Y-%m-%d", ts) end

--- 取当天中午避开夏令时跳变。
---@param ymd string
---@return number
local function noonOf(ymd)
    local y, m, d = ymd:match("^(%d+)-(%d+)-(%d+)$")
    return os.time{ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 }
end

---@param ymd string
---@param delta integer
---@return string
function Calc.addDays(ymd, delta)
    return ymdOf(noonOf(ymd) + delta * DAY)
end

--- 本地当天零点。
---@param now number
---@return number
local function midnight(now)
    local t = os.date("*t", now)
    return os.time{ year = t.year, month = t.month, day = t.day, hour = 0 }
end

---@param days table
---@param ymd string
---@return boolean
local function read(days, ymd)
    local d = days[ymd]
    return d ~= nil and (d.duration_seconds or 0) > 0
end

---@param value number
---@param lo number
---@param hi number
---@return number
local function clamp(value, lo, hi) return math.max(lo, math.min(hi, value)) end

--- [第 first 天前, 第 last 天前] 闭区间求和（0 = 今天，1 = 昨天）。
---@return table { seconds, pages, read_days, len }
local function windowSum(days, now, first, last)
    local out = { seconds = 0, pages = 0, read_days = 0, len = first - last + 1 }
    for off = last, first do
        local d = days[ymdOf(now - off * DAY)]
        if d and d.duration_seconds > 0 then
            out.seconds = out.seconds + d.duration_seconds
            out.pages = out.pages + (d.pages or 0)
            out.read_days = out.read_days + 1
        end
    end
    return out
end

---@param days table
---@return string|nil
local function firstDay(days)
    local first
    for ymd, d in pairs(days) do
        if d.duration_seconds > 0 and (not first or ymd < first) then first = ymd end
    end
    return first
end

--- 以 ymd 结尾（当天没读就从前一天算）的连续阅读天数。
---@param days table
---@param ymd string
---@return integer
function Calc.streak(days, ymd)
    local cur = ymd
    if not read(days, cur) then cur = Calc.addDays(cur, -1) end
    local n = 0
    while read(days, cur) do
        n = n + 1
        cur = Calc.addDays(cur, -1)
    end
    return n
end

--- 活动环：选中日的页数 / 分钟 / 连续天数。页数与分钟的目标取近 30 天有读那几天的日均（取整到 5），
--- 没有历史就用 30 / 30。连续天数目标固定 7。
---@param days table
---@param now number
---@param sel string 选中日
---@return table { pages = {value,target}, minutes = {value,target}, streak = {value,target} }
function Calc.rings(days, now, sel)
    local w = windowSum(days, now, 30, 1)
    local minutes_target, pages_target = 30, 30
    if w.read_days > 0 then
        local function nice(v, lo, hi) return clamp(math.floor(v / 5 + 0.5) * 5, lo, hi) end
        minutes_target = nice(w.seconds / w.read_days / 60, 15, 120)
        if w.pages > 0 then pages_target = nice(w.pages / w.read_days, 10, 200) end
    end
    local d = days[sel] or {}
    return {
        pages = { value = d.pages or 0, target = pages_target },
        minutes = { value = math.floor((d.duration_seconds or 0) / 60), target = minutes_target },
        streak = { value = Calc.streak(days, sel), target = 7 },
    }
end

--- 逐页记录合并为阅读段：同一本书、间隔不超过 SESSION_GAP 的连续记录算一次。
---@param rows table[] StatsDB.sessionRows（按开始时间升序）
---@return table[] { source_id, stable_id, start, finish, seconds, pages }
function Calc.sessions(rows)
    local out, cur = {}, nil
    for _idx, r in ipairs(rows) do
        local finish = r.start_time + r.duration
        if cur and cur.stable_id == r.stable_id and cur.source_id == r.source_id
            and r.start_time - cur.finish <= SESSION_GAP then
            cur.finish = math.max(cur.finish, finish)
            cur.seconds = cur.seconds + r.duration
            cur.pages = cur.pages + r.pages
        else
            cur = {
                source_id = r.source_id, stable_id = r.stable_id,
                start = r.start_time, finish = finish, seconds = r.duration, pages = r.pages,
            }
            out[#out + 1] = cur
        end
    end
    return out
end

---@param sessions table[]
---@param ymd string
---@return table[]
function Calc.sessionsOn(sessions, ymd)
    local out = {}
    for _idx, s in ipairs(sessions) do
        if ymdOf(s.start) == ymd then out[#out + 1] = s end
    end
    return out
end

--- 近 7 天与前 7 天对比。
---@return table { bars = {{ymd, seconds}...7, 旧→新}, seconds, prev_seconds, pages, prev_pages, change }
function Calc.weekCompare(days, now)
    local bars = {}
    for off = 6, 0, -1 do
        local ymd = ymdOf(now - off * DAY)
        bars[#bars + 1] = { ymd = ymd, seconds = days[ymd] and days[ymd].duration_seconds or 0 }
    end
    local this, prev = windowSum(days, now, 6, 0), windowSum(days, now, 13, 7)
    return {
        bars = bars,
        seconds = this.seconds, prev_seconds = prev.seconds,
        pages = this.pages, prev_pages = prev.pages,
        change = prev.seconds > 0 and (this.seconds - prev.seconds) / prev.seconds or nil,
    }
end

--- 近 90 天对比过去一年（都截止到昨天；历史不足一年按已有天数算）。
--- 不到 120 天历史，所有指标都是 nodata。
---@param days table
---@param sessions table[] Calc.sessions 的结果
---@param finished table[] StatsDB.progressBooks(…, true)
---@param now number
---@return table { enough, metrics = { {key, recent, base, status} } }
function Calc.trends(days, sessions, finished, now)
    local first = firstDay(days)
    local today = ymdOf(now)
    local age = first and math.floor((noonOf(today) - noonOf(first)) / DAY) or 0
    if age < 120 then return { enough = false, metrics = {} } end

    local base_len = math.min(365, age)
    local recent, base = windowSum(days, now, 90, 1), windowSum(days, now, base_len, 1)
    local mid = midnight(now)
    local function sessionStats(len)
        local from, n, sec, pages = mid - len * DAY, 0, 0, 0
        for _idx, s in ipairs(sessions) do
            if s.start >= from and s.start < mid then
                n, sec, pages = n + 1, sec + s.seconds, pages + s.pages
            end
        end
        return { n = n, seconds = sec, pages = pages }
    end
    local function books(len)
        local from, n = mid - len * DAY, 0
        for _idx, b in ipairs(finished) do
            if b.last_time >= from and b.last_time < mid then n = n + 1 end
        end
        return n
    end
    local rs, bs = sessionStats(90), sessionStats(base_len)
    local function per(session, f) return session.n > 0 and f(session) or nil end
    local function sessionMin(s) return s.seconds / s.n / 60 end
    local function speed(s) return s.seconds > 0 and s.pages / (s.seconds / 3600) or nil end
    local raw = {
        { "minutes", recent.seconds / 90 / 60, base.seconds / base_len / 60 },
        { "pages", recent.pages / 90, base.pages / base_len },
        { "days", recent.read_days / 90 * 7, base.read_days / base_len * 7 },
        { "session", per(rs, sessionMin), per(bs, sessionMin) },
        { "speed", per(rs, speed), per(bs, speed) },
        { "books", books(90) / 90 * 30, books(base_len) / base_len * 30 },
    }
    local metrics = {}
    for _idx, m in ipairs(raw) do
        local status = "nodata"
        if m[2] and m[3] and m[3] > 0 then
            status = m[2] > m[3] * 1.03 and "up" or (m[2] >= m[3] * 0.97 and "flat" or "down")
        end
        metrics[#metrics + 1] = { key = m[1], recent = m[2], base = m[3], status = status }
    end
    return { enough = true, metrics = metrics }
end

--- 近 53 周热力图：cols[c][r]，c 为周（旧→新），r=1..7 周一到周日；未来日为 false。
--- level 0..4 按有阅读那些天的时长四分位。
---@param days table
---@param now number
---@return table { cols, first }
function Calc.heatmap(days, now)
    local wday = tonumber(os.date("%w", now))
    local monday = Calc.addDays(ymdOf(now), -((wday + 6) % 7))
    local first = Calc.addDays(monday, -52 * 7)
    local today = ymdOf(now)
    local values = {}
    for c = 0, 52 do
        for r = 0, 6 do
            local d = days[Calc.addDays(first, c * 7 + r)]
            if d and d.duration_seconds > 0 then values[#values + 1] = d.duration_seconds end
        end
    end
    table.sort(values)
    local function cut(q) return values[math.max(1, math.ceil(#values * q))] or 0 end
    local q1, q2, q3 = cut(0.25), cut(0.5), cut(0.75)
    local cols = {}
    for c = 0, 52 do
        local col = {}
        for r = 0, 6 do
            local ymd = Calc.addDays(first, c * 7 + r)
            if ymd > today then
                col[r + 1] = false
            else
                local s = days[ymd] and days[ymd].duration_seconds or 0
                local level = 0
                if s > 0 then level = s <= q1 and 1 or (s <= q2 and 2 or (s <= q3 and 3 or 4)) end
                col[r + 1] = { ymd = ymd, seconds = s, level = level }
            end
        end
        cols[c + 1] = col
    end
    return { cols = cols, first = first }
end

---@param ym string YYYY-MM
---@return integer
local function daysIn(ym)
    local y, m = ym:match("^(%d+)-(%d+)$")
    return tonumber(os.date("%d", os.time{ year = tonumber(y), month = tonumber(m) + 1, day = 0 }))
end

--- 本月挑战：目标 = 近 90 天日均 × 1.1 × 本月天数（取整到 5 分钟）；没有历史返回 nil。
---@return table|nil { target, done, per_day, on_pace, ratio }
function Calc.challenge(days, now)
    local base = windowSum(days, now, 90, 1)
    if base.seconds <= 0 then return nil end
    local ym, today = os.date("%Y-%m", now), ymdOf(now)
    local dim, elapsed = daysIn(ym), tonumber(today:sub(9, 10))
    local target = math.max(300, math.floor(base.seconds / 90 * 1.1 * dim / 300 + 0.5) * 300)
    local done = 0
    for d = 1, elapsed do
        local info = days[string.format("%s-%02d", ym, d)]
        if info then done = done + info.duration_seconds end
    end
    return {
        target = target,
        done = done,
        per_day = math.max(0, target - done) / (dim - elapsed + 1),
        on_pace = done >= target * elapsed / dim,
        ratio = math.min(1, done / target),
    }
end

--- 完成预测：在读的书按各自速度与近 30 天日均推完成日；年度节奏 = 今年已读完 / 已过天数 × 365。
---@param days table
---@param reading table[] StatsDB.progressBooks(…, false)
---@param finished table[]
---@param now number
---@return table { avg, books = {{book, days_left, date}}, done, projected }
function Calc.forecast(days, reading, finished, now)
    local avg = windowSum(days, now, 29, 0).seconds / 30
    local out = {}
    for _idx, b in ipairs(reading) do
        if avg > 0 and b.fraction > 0.01 and b.seconds > 0 then
            local left = math.max(1, math.ceil((b.seconds / b.fraction - b.seconds) / avg))
            out[#out + 1] = { book = b, days_left = left, date = ymdOf(now + left * DAY) }
        end
    end
    local year_start = os.time{ year = tonumber(os.date("%Y", now)), month = 1, day = 1, hour = 0 }
    local done = 0
    for _idx, b in ipairs(finished) do
        if b.last_time >= year_start then done = done + 1 end
    end
    local elapsed = math.max(1, math.floor((now - year_start) / DAY) + 1)
    return { avg = avg, books = out, done = done, projected = math.floor(done / elapsed * 365 + 0.5) }
end

--- 时间范围内读完的书。
---@param finished table[]
---@param from_ts number
---@param to_ts number 不含
---@return table[] 按完成时间升序
function Calc.finishedIn(finished, from_ts, to_ts)
    local out = {}
    for _idx, b in ipairs(finished) do
        if b.last_time >= from_ts and b.last_time < to_ts then out[#out + 1] = b end
    end
    table.sort(out, function(a, b) return a.last_time < b.last_time end)
    return out
end

---@param books table[]
---@param n integer
---@return table[] 按本机阅读时长降序，只含有时长的
function Calc.longest(books, n)
    local list = {}
    for _idx, b in ipairs(books) do
        if b.seconds > 0 then list[#list + 1] = b end
    end
    table.sort(list, function(a, b) return a.seconds > b.seconds end)
    return { unpack(list, 1, n) }
end

--- 按字段（authors / category，可含多个，逗号等分隔）统计读完本数与时长。
---@param books table[]
---@param field string
---@param n integer
---@return table[] { name, count, seconds }，本数降序、时长降序
function Calc.top(books, field, n)
    local by, list = {}, {}
    for _idx, b in ipairs(books) do
        -- 字符集里不能放多字节分隔符（会按字节切坏汉字），先统一成 ASCII 逗号
        local list_text = tostring(b[field] or ""):gsub("、", ","):gsub("，", ","):gsub("；", ",")
        for part in list_text:gmatch("[^,;/|]+") do
            local name = part:match("^%s*(.-)%s*$")
            if name ~= "" then
                local e = by[name]
                if not e then
                    e = { name = name, count = 0, seconds = 0 }
                    by[name] = e
                    list[#list + 1] = e
                end
                e.count = e.count + 1
                e.seconds = e.seconds + b.seconds
            end
        end
    end
    table.sort(list, function(a, b)
        if a.count ~= b.count then return a.count > b.count end
        if a.seconds ~= b.seconds then return a.seconds > b.seconds end
        return a.name < b.name
    end)
    return { unpack(list, 1, n) }
end

--- 某年月（"YYYY-MM"）或某年（"YYYY"）的合计：时长、页数、有读天数。
---@param days table
---@param prefix string
---@return table { seconds, pages, days }
function Calc.sum(days, prefix)
    local out = { seconds = 0, pages = 0, days = 0 }
    for ymd, d in pairs(days) do
        if d.duration_seconds > 0 and ymd:sub(1, #prefix) == prefix then
            out.seconds = out.seconds + d.duration_seconds
            out.pages = out.pages + (d.pages or 0)
            out.days = out.days + 1
        end
    end
    return out
end

return Calc
