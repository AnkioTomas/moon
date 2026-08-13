---@meta

--- 阅读统计总览 KPI（insight 页英雄区 + 次级指标）。
--- 时长以展示文案为准（源可能只给格式化字符串，不给秒数）。
---@class StatsTotal
---@field has_data boolean 是否有可展示的统计数据
---@field total_pages number|nil 累计阅读页数
---@field total_text string|nil 总阅读时长文案（英雄区大字）
---@field last7_text string|nil 近 7 天阅读时长文案
---@field longest_day_text string|nil 单日最长阅读时长文案
