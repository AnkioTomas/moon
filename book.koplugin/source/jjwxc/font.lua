--[[--
晋江 VIP 章反爬字体解码。正文里的常用字被换成私有区码点，页面附带一份 TTF（jjwxcfont_<串>），
每章随机洗牌，但同一个字的字形轮廓固定：按轮廓哈希查 `font_table`（tools/build_jjwxc_font.py 生成）即可还原。

@module koplugin.book.source.jjwxc.font
--]]

local Table = require("source.jjwxc.font_table")

local Font = {}

local M1, M2 = 2147483647, 1000000007

local function u16(s, pos) local a, b = s:byte(pos, pos + 1); return a * 256 + b end
local function i16(s, pos) local v = u16(s, pos); return v >= 32768 and v - 65536 or v end
local function u32(s, pos) return u16(s, pos) * 65536 + u16(s, pos + 2) end

--- sfnt 表目录 → { tag = 偏移 }（偏移从 1 起）。
local function tables(ttf)
    local dir = {}
    for i = 0, u16(ttf, 5) - 1 do
        local rec = 13 + i * 16
        dir[ttf:sub(rec, rec + 3)] = u32(ttf, rec + 8) + 1
    end
    return dir
end

--- cmap 里 BMP 的 format 4 子表 → { [码点] = 字形号 }。
local function cmap(ttf, base)
    local sub
    for i = 0, u16(ttf, base + 2) - 1 do
        local rec = base + 4 + i * 8
        local pos = base + u32(ttf, rec + 4)
        if u16(ttf, pos) == 4 then sub = pos end
    end
    if not sub then return nil end
    local segs = math.floor(u16(ttf, sub + 6) / 2)
    local ends, starts, deltas, offsets = sub + 14, sub + 16 + segs * 2, sub + 16 + segs * 4, sub + 16 + segs * 6
    local map = {}
    for i = 0, segs - 1 do
        local last, first = u16(ttf, ends + i * 2), u16(ttf, starts + i * 2)
        local delta, off = i16(ttf, deltas + i * 2), u16(ttf, offsets + i * 2)
        for code = first, math.min(last, 0xFFFE) do
            local gid
            if off == 0 then
                gid = (code + delta) % 65536
            else
                local pos = offsets + i * 2 + off + (code - first) * 2
                gid = u16(ttf, pos)
                if gid ~= 0 then gid = (gid + delta) % 65536 end
            end
            if gid ~= 0 then map[code] = gid end
        end
    end
    return map
end

--- 简单字形的轮廓哈希；算法与 tools/build_jjwxc_font.py 的 key 一致。复合字形与空字形返回 nil。
local function key(ttf, glyf, start, stop, upm)
    if stop <= start then return nil end
    local pos = glyf + start
    local contours = i16(ttf, pos)
    if contours <= 0 then return nil end
    local h1, h2 = 7, 7
    local function feed(v)
        v = v + 100000
        h1 = (h1 * 131 + v) % M1
        h2 = (h2 * 137 + v) % M2
    end
    feed(contours)
    pos = pos + 10
    local count = 0
    for i = 0, contours - 1 do
        count = u16(ttf, pos + i * 2) + 1
        feed(count - 1)
    end
    pos = pos + contours * 2
    pos = pos + 2 + u16(ttf, pos)
    local flags = {}
    while #flags < count do
        local f = ttf:byte(pos)
        pos = pos + 1
        flags[#flags + 1] = f
        if f % 16 >= 8 then
            for _rep = 1, ttf:byte(pos) do flags[#flags + 1] = f end
            pos = pos + 1
        end
    end
    local function axis(short_bit, same_bit)
        local out, cur = {}, 0
        for i = 1, count do
            local f = flags[i]
            if math.floor(f / short_bit) % 2 == 1 then
                local d = ttf:byte(pos)
                pos = pos + 1
                cur = cur + (math.floor(f / same_bit) % 2 == 1 and d or -d)
            elseif math.floor(f / same_bit) % 2 == 0 then
                cur = cur + i16(ttf, pos)
                pos = pos + 2
            end
            out[i] = cur
        end
        return out
    end
    local xs = axis(2, 16)
    local ys = axis(4, 32)
    for i = 1, count do
        feed(flags[i] % 2)
        feed(math.floor(xs[i] * 1000 / upm + 0.5))
        feed(math.floor(ys[i] * 1000 / upm + 0.5))
    end
    return string.format("%08x%08x", h1, h2)
end

--- 字体里每个码点对应的真字：{ [码点] = 字 }。字体解析不了或没有哈希命中的字形不入表。
---@param ttf string
---@return table<integer, string>|nil
function Font.mapping(ttf)
    local ok, result = pcall(function()
        local dir = tables(ttf)
        local upm = u16(ttf, dir.head + 18)
        local long_loca = i16(ttf, dir.head + 50) == 1
        local codes = cmap(ttf, dir.cmap)
        local map = {}
        for code, gid in pairs(codes) do
            local at = dir.loca + gid * (long_loca and 4 or 2)
            local from, to
            if long_loca then from, to = u32(ttf, at), u32(ttf, at + 4) else from, to = u16(ttf, at) * 2, u16(ttf, at + 2) * 2 end
            local char = Table[key(ttf, dir.glyf, from, to, upm) or ""]
            if char then map[code] = char end
        end
        return map
    end)
    return ok and result or nil
end

--- 把正文里的私有区字符还原成真字，并去掉零宽字符（反爬字体后面跟的占位）。
---@param text string UTF-8
---@param map table<integer, string>
---@return string
function Font.decode(text, map)
    local out = text:gsub("[\238\239][\128-\191][\128-\191]", function(ch)
        local b1, b2, b3 = ch:byte(1, 3)
        local code = (b1 % 16) * 4096 + (b2 % 64) * 64 + (b3 % 64)
        if code >= 0xE000 and code <= 0xF8FF then return map[code] end
        if code == 0xFEFF then return "" end
    end)
    return (out:gsub("\226\128[\139-\141]", ""))
end

return Font
