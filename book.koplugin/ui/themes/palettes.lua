--[[--
彩色主题色板：配色移植自 mooncolor（W-Boat/mooncolor，月读的彩墨扩展）。

mooncolor 是 12 套主题 × 多角色分色；月读实测分角色和全场单色看不出区别，
不值一套角色管线，这里只取每套的代表色做单色主题。混色主题压成单色后
主色重复的（极光 / 日落 / 竹影 / 浆果）不进名单，剩 8 个互不相同的颜色。

色值是存储值，Theme.current 派生时统一经 Theme.vivid 补饱和（彩屏会冲淡），
这里不要预先补。

@module koplugin.book.ui.themes.palettes
--]]

---@class BookPalette
---@field id string
---@field name string
---@field rgb number 0xRRGGBB

local Palettes = {}

Palettes.list = {
    { id = "ocean", name = "深海蓝", rgb = 0x205CA8 },
    { id = "pine", name = "松石绿", rgb = 0x16685C },
    { id = "clay", name = "赤陶红", rgb = 0xA34434 },
    { id = "garden", name = "花园", rgb = 0x246648 },
    { id = "nord", name = "北境", rgb = 0x285D88 },
    { id = "sakura", name = "樱花", rgb = 0xA34454 },
    { id = "lavender", name = "薰衣草", rgb = 0x66509A },
    { id = "amber", name = "琥珀", rgb = 0x865E20 },
}

local by_id = {}
for _idx, palette in ipairs(Palettes.list) do by_id[palette.id] = palette end

---@param id string|nil
---@return BookPalette|nil
function Palettes.find(id)
    return id and by_id[id] or nil
end

--- 当前生效的主题色：给了色板用色板；没给用旧 theme_color（v0.2.46–48 的单色选色器写过这个键，
--- 之后版本只读不写），老用户升级后画面不变，选过色板才换色。
---@param id string|nil
---@param legacy number|nil 旧单色主题色 0xRRGGBB
---@return number 0xRRGGBB（未补饱和）
function Palettes.color(id, legacy)
    local palette = Palettes.find(id)
    if palette then return palette.rgb end
    return legacy or 0x0756AD
end

return Palettes
