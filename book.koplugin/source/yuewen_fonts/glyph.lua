--[[--
QQ阅读乱序字体还原：把章节字体里的字形认回真字。

反盗版有两层：randomFont 把最常用的一批字换成生僻码位（CJK 扩展 A）；fixedFont 把次常用的 2000 字
码位不变、字形互换（码位“陵”画出来是“李”）。都没有码位→字的表，所以只能“看”：把字形和候选字（GB2312 一二级，用 KOReader 自带 Noto Sans CJK 画）
按外框归一后缩到 16x16 比相关系数。字形可能被镜像（页面 CSS 再翻回来），两种朝向都比，取高者。
先 8x8 粗筛取前几名再用 16x16 精排；得分低于 THRESHOLD 的不认（宁缺勿错）。
标点（，。“” 等）不在 GB2312 汉字里，且外框归一后形状几乎一样，只能靠外框在字面里的位置认：
网页字体与参考字体是同一套 Noto 字形，同一个标点的外框位置几乎重合。

@module source.yuewen_fonts.glyph
--]]--

local ffi = require("ffi")

local Glyph = {}

local CHAR = "[%z\1-\127\194-\244][\128-\191]*"

local CANDIDATES = require("source.yuewen_fonts.glyph_chars")
local PX = 56
local FINE, COARSE = 16, 8
local SHORTLIST = 12
local THRESHOLD = 0.75
local CONFIDENT = 0.95
local SCALE = 127

--- 一个字形 → 归一化向量 n*n（外框裁剪、面积平均缩放、去均值、单位长）。
local function signature(size, code, n)
    local ok, g = pcall(size.renderGlyph, size, code)
    if not ok then return nil end
    local bb = g.bb
    local w, h = bb:getWidth(), bb:getHeight()
    if w == 0 or h == 0 then return nil end
    local buf = ffi.cast("uint8_t*", bb.data)
    local stride = bb.stride
    local x0, x1, y0, y1 = w, -1, h, -1
    for y = 0, h - 1 do
        for x = 0, w - 1 do
            if buf[y * stride + x] > 40 then
                if x < x0 then x0 = x end
                if x > x1 then x1 = x end
                if y < y0 then y0 = y end
                if y > y1 then y1 = y end
            end
        end
    end
    if x1 < 0 then return nil end
    local cw, ch = x1 - x0 + 1, y1 - y0 + 1
    local v, sum = {}, 0
    for j = 0, n - 1 do
        local ya, yb = y0 + j * ch / n, y0 + (j + 1) * ch / n
        for i = 0, n - 1 do
            local xa, xb = x0 + i * cw / n, x0 + (i + 1) * cw / n
            local acc, cnt = 0, 0
            for y = math.floor(ya), math.max(math.ceil(yb) - 1, math.floor(ya)) do
                for x = math.floor(xa), math.max(math.ceil(xb) - 1, math.floor(xa)) do
                    acc = acc + buf[y * stride + x]
                    cnt = cnt + 1
                end
            end
            local val = acc / cnt
            v[j * n + i + 1] = val
            sum = sum + val
        end
    end
    local mean, norm = sum / (n * n), 0
    for k = 1, n * n do
        v[k] = v[k] - mean
        norm = norm + v[k] * v[k]
    end
    norm = math.sqrt(norm)
    if norm < 1e-6 then return nil end
    local q = ffi.new("int8_t[?]", n * n)
    for k = 1, n * n do q[k - 1] = math.floor(v[k] / norm * SCALE + 0.5) end
    return q
end

local function flipped(v, n)
    local out = ffi.new("int8_t[?]", n * n)
    for j = 0, n - 1 do
        for i = 0, n - 1 do out[j * n + i] = v[j * n + (n - 1 - i)] end
    end
    return out
end

local function dot(a, a_off, b, b_off, len)
    local s = 0
    for k = 0, len - 1 do s = s + a[a_off + k] * b[b_off + k] end
    return s
end

-- “一”只有一横，归一化后是均匀块、签名无效，和标点一样靠外框位置认。
local PUNCTUATION = "一，。、；：？！“”‘’（）《》…「」『』【】"
local PUNCT_TOLERANCE = 0.035

--- 字形外框占字面（PX）的比例 { 左, 下, 右, 上 }；渲染不出来返回 nil。
local function extent(size, code)
    local ok, g = pcall(size.renderGlyph, size, code)
    if not ok then return nil end
    local w, h = g.bb:getWidth(), g.bb:getHeight()
    if w == 0 or h == 0 then return nil end
    return { g.l / PX, (g.t - h) / PX, (g.l + w) / PX, g.t / PX }
end

--- 参考字体里各标点的外框。
local function punctuationRefs(ref_path)
    local size = require("ffi/freetype").newFaceSize(ref_path, PX)
    local refs = {}
    for ch in PUNCTUATION:gmatch(CHAR) do
        local box = extent(size, Glyph.codepoint(ch))
        if box then refs[#refs + 1] = { ch = ch, box = box } end
    end
    return refs
end

--- 外框与某个标点的四边偏差都在容差内就认作它（取偏差总和最小）。
local function matchPunctuation(refs, box)
    local best, best_dist = nil, math.huge
    for _idx, ref in ipairs(refs) do
        local dist, fit = 0, true
        for k = 1, 4 do
            local d = math.abs(box[k] - ref.box[k])
            if d > PUNCT_TOLERANCE then fit = false; break end
            dist = dist + d
        end
        if fit and dist < best_dist then best, best_dist = ref.ch, dist end
    end
    return best
end

-- 参考字的签名每章都一样：第一次算好落盘（候选序固定，每字 FINE² + COARSE² 字节），之后直接读。
local STRIDE = FINE * FINE + COARSE * COARSE

---@return string[] chars
local function candidateChars()
    local chars = {}
    for ch in CANDIDATES:gmatch(CHAR) do chars[#chars + 1] = ch end
    return chars
end

---@return table chars, ffi.cdata* sigs 每字 STRIDE 字节：前 FINE² 是精排、后 COARSE² 是粗筛；字形渲染不出来的全 0
local function reference(ref_path, cache_path)
    local chars = candidateChars()
    local size = #chars * STRIDE
    local file = io.open(cache_path, "rb")
    local raw = file and file:read("*a")
    if file then file:close() end
    if raw and #raw == size then
        local sigs = ffi.new("int8_t[?]", size)
        ffi.copy(sigs, raw, size)
        return chars, sigs
    end
    local rsize = require("ffi/freetype").newFaceSize(ref_path, PX)
    local sigs = ffi.new("int8_t[?]", size)
    for k, ch in ipairs(chars) do
        local code = Glyph.codepoint(ch)
        local fine, coarse = signature(rsize, code, FINE), signature(rsize, code, COARSE)
        if fine then
            ffi.copy(sigs + (k - 1) * STRIDE, fine, FINE * FINE)
            ffi.copy(sigs + (k - 1) * STRIDE + FINE * FINE, coarse, COARSE * COARSE)
        end
    end
    local tmp = cache_path .. "." .. os.time() .. math.random(1e6) .. ".tmp"
    local out = io.open(tmp, "wb")
    if out then
        out:write(ffi.string(sigs, size))
        out:close()
        os.rename(tmp, cache_path)
        -- 同目录里别的版本 / 别的参考字体留下的旧缓存不会再被读到，顺手清掉
        local dir, name = cache_path:match("^(.*)/([^/]+)$")
        local prefix = name and (name:match("^(.-_glyph_)") or name:match("^(glyph_)"))
        if prefix then
            local lfs = require("libs/libkoreader-lfs")
            for entry in lfs.dir(dir) do
                if entry ~= name and entry:sub(1, #prefix) == prefix and entry:match("%.bin$") then
                    os.remove(dir .. "/" .. entry)
                end
            end
        end
    end
    return chars, sigs
end

--- 一种字体里要认的字。limit：候选字只取 GB2312 序的前多少个（一级 3755 字，全集 6763）。
--- 不能按字体 cmap 收窄：字形互换后，字体画出的真字集合和它的码位集合并不相同。
---@class QQGlyphTask
---@field font_path string
---@field codes integer[]
---@field limit integer
---@field threshold number|nil 认字阈值，缺省 0.75；起点有些字形更接近，传 0.65

--- 把各字体里指定码位的字形认成真字。
---@param ref_path string 参考字体（Noto Sans CJK SC）
---@param cache_path string 参考字签名缓存文件
---@param tasks QQGlyphTask[]
---@return table<integer, string|false>[] maps 与 tasks 同序，码位 → 真字；字体里有字形但认不出是 false，字体没有该码位不在表里
function Glyph.recognize(ref_path, cache_path, tasks)
    local FT = require("ffi/freetype")
    local chars, sigs = reference(ref_path, cache_path)
    local puncts = punctuationRefs(ref_path)

    local maps = {}
    for t_idx, task in ipairs(tasks) do
        local threshold = task.threshold or THRESHOLD
        local gsize = FT.newFaceSize(task.font_path, PX) --[[@as FreeTypeSize]]
        local cands = {}
        for k = 1, math.min(task.limit, #chars) do
            local base = (k - 1) * STRIDE
            local keep = dot(sigs, base + FINE * FINE, sigs, base + FINE * FINE, COARSE * COARSE) > 0
            if keep then cands[#cands + 1] = k end
        end
        local out, claims = {}, {}
        for _i, cp in ipairs(task.codes) do
            local has = gsize:hasGlyph(cp)
            local gf0 = has and signature(gsize, cp, FINE)
            local gc0 = gf0 and signature(gsize, cp, COARSE)
            local best_char, best_score = nil, -1
            local scored = {}
            local box = has and extent(gsize, cp)
            local punct = box and matchPunctuation(puncts, box)
            if punct then best_char, best_score = punct, 1 end
            for mirror = 0, (gf0 and not punct) and 1 or -1 do
                -- 原朝向已经认得很准就不必再试镜像
                if mirror == 1 and best_score >= CONFIDENT then break end
                local gf, gc = gf0, gc0
                if mirror == 1 then gf, gc = flipped(gf0, FINE), flipped(gc0, COARSE) end
                local top, floor = {}, -math.huge
                for _c, k in ipairs(cands) do
                    local s = dot(gc, 0, sigs, (k - 1) * STRIDE + FINE * FINE, COARSE * COARSE)
                    if s > floor then
                        top[#top + 1] = { s, k }
                        table.sort(top, function(a, b) return a[1] > b[1] end)
                        if #top > SHORTLIST then top[#top] = nil end
                        if #top == SHORTLIST then floor = top[#top][1] end
                    end
                end
                for _j, entry in ipairs(top) do
                    local s = dot(gf, 0, sigs, (entry[2] - 1) * STRIDE, FINE * FINE) / (SCALE * SCALE)
                    local ch = chars[entry[2]]
                    if s > (scored[ch] or -1) then scored[ch] = s end
                    if s > best_score then best_score, best_char = s, ch end
                end
            end
            if punct then
                out[cp] = punct
            elseif has and gf0 then
                out[cp] = false
                for ch, score in pairs(scored) do
                    if score >= threshold then claims[#claims + 1] = { score, cp, ch } end
                end
            end
        end
        -- 一种字体里每个真字只画一次：按得分从高到低认领，形近字（于/干）不会被同时认成一个
        table.sort(claims, function(a, b)
            if a[1] ~= b[1] then return a[1] > b[1] end
            return a[2] < b[2]
        end)
        local taken = {}
        for _cp, ch in pairs(out) do
            if ch then taken[ch] = true end
        end
        for _i, claim in ipairs(claims) do
            if not out[claim[2]] and not taken[claim[3]] then
                out[claim[2]] = claim[3]
                taken[claim[3]] = true
            end
        end
        maps[t_idx] = out
    end
    return maps
end

--- UTF-8 单字 → 码位。
---@param ch string
---@return integer
function Glyph.codepoint(ch)
    local b = ch:byte(1)
    if b < 0x80 then return b end
    if b < 0xE0 then return (b - 0xC0) * 64 + ch:byte(2) - 0x80 end
    if b < 0xF0 then return (b - 0xE0) * 4096 + (ch:byte(2) - 0x80) * 64 + ch:byte(3) - 0x80 end
    return (b - 0xF0) * 262144 + (ch:byte(2) - 0x80) * 4096 + (ch:byte(3) - 0x80) * 64 + ch:byte(4) - 0x80
end

return Glyph
