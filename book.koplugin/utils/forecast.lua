--[[--
读完日期预估（纯计算，无依赖）。

@module koplugin.book.utils.forecast
--]]

local Forecast = {}

--- 按最近有记录的这段日历天数（没读的日子也算）摊出日均，推出读完日期。
---@param remaining number 剩余秒
---@param daily table[] StatsDB.dailyByBook（日期倒序）
---@return number|nil 读完日期的时间戳；没有近期记录为 nil
function Forecast.finishDate(remaining, daily)
    local sum = 0
    for _idx, r in ipairs(daily) do sum = sum + r.seconds end
    if sum <= 0 then return nil end
    local y, m, d = tostring(daily[#daily].ymd):match("^(%d+)%-(%d+)%-(%d+)$")
    if not y then return nil end
    local today = os.date("*t")
    local now = os.time{ year = today.year, month = today.month, day = today.day, hour = 12 }
    local span = math.floor((now - os.time{ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 })
        / 86400 + 0.5) + 1
    return now + math.ceil(remaining / (sum / span)) * 86400
end

return Forecast
