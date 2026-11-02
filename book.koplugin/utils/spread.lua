--[[--
把 slack 个多余像素均匀分进 slots 个槽，返回第 i 槽（从 1 计）分到的像素；各槽之和恰为 slack。

@module koplugin.book.utils.spread
--]]

---@param i number
---@param slots number
---@param slack number
---@return number
return function(i, slots, slack)
    if slots <= 0 or slack <= 0 then return 0 end
    return math.floor(i * slack / slots) - math.floor((i - 1) * slack / slots)
end
