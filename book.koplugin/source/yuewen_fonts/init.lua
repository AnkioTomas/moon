--[[--
阅文系 VIP 章节的乱序字体还原（QQ阅读 / 起点共用）。

Fock 解出的 HTML 里，常用字码位被换成别的字，靠随章下发的 fixedFont 画回真字；
扩展 A 区的生僻码位再靠 randomFont + CSS 排序/伪元素还原。这里把
`source.yuewen_fonts.glyph` 的字形识别和 `source.yuewen_fonts.scramble` 的 HTML 解析拼起来。

字体是随章下发的，写临时文件给 FreeType 读；参考字签名会落盘缓存。

@module source.yuewen_fonts
--]]--

local Text = require("utils.text")

local FontRestore = {}

local RARE_LIMIT, FIXED_LIMIT = 6763, 3755

--- 下载回来的字节是不是字体文件（TTF / OTF / TTC / WOFF 魔数）。CDN 的 HTML 错误页也会 200 回来，
--- 写进缓存会被当字体复用，一章章都解不出来。
---@param bytes string|nil
---@return boolean
function FontRestore.looksLikeFont(bytes)
    if type(bytes) ~= "string" or #bytes < 4 then return false end
    local head = bytes:sub(1, 4)
    return head == "\0\1\0\0" or head == "OTTO" or head == "true" or head == "ttcf" or head == "wOFF"
end

local function writeTemp(bytes)
    local path = os.tmpname()
    local file = assert(io.open(path, "wb"))
    file:write(bytes)
    file:close()
    return path
end

local function randomFontBytes(font)
    local parts = {}
    for idx, byte in ipairs(font and font.data or {}) do parts[idx] = string.char(byte) end
    return table.concat(parts)
end

--- 乱序码位 / 互换字形 → 真字。
---@param random_font table|nil fontResponse.randomFont（{data={...}}）
---@param fixed_font string fixedFontTtf/woff2 下载下来的字节
---@param rare integer[] 扩展 A 区码位
---@param han integer[] 常用汉字码位
---@param opts table|nil { threshold=number }
---@return table rare_map
---@return table han_map
local function recognize(random_font, fixed_font, rare, han, opts)
    local rare_bytes = randomFontBytes(random_font)
    local paths, labels, tasks = {}, {}, {}
    local function cleanup()
        for _idx, path in ipairs(paths) do os.remove(path) end
    end
    if #rare > 0 and #rare_bytes > 0 then
        paths[#paths + 1] = writeTemp(rare_bytes)
        labels[#labels + 1] = "rare"
        tasks[#tasks + 1] = {
            font_path = paths[#paths], codes = rare, limit = RARE_LIMIT, threshold = opts and opts.threshold,
        }
    end
    if #han > 0 and fixed_font and #fixed_font > 0 then
        paths[#paths + 1] = writeTemp(fixed_font)
        labels[#labels + 1] = "han"
        tasks[#tasks + 1] = {
            font_path = paths[#paths], codes = han, limit = FIXED_LIMIT, threshold = opts and opts.threshold,
        }
    end
    if #tasks == 0 then return {}, {} end

    local ref = require("fontlist").fontdir .. "/noto/NotoSansCJKsc-Regular.otf"
    local ref_file, ref_err = io.open(ref, "rb")
    if not ref_file then cleanup(); error(ref_err, 0) end
    local ref_size = ref_file:seek("end")
    ref_file:close()
    -- 签名只取决于参考字体和算法参数；参考字体换了（大小变）自动重算。
    -- 兼容旧版缓存名（qqreader_glyph_v1_ / glyph_v1_），避免重新渲染 6763 个参考字。
    local cache_dir = require("utils.paths").cacheDir()
    local cache = cache_dir .. "/yuewen_glyph_v1_" .. ref_size .. ".bin"
    for _idx, legacy in ipairs({ "yuewen_glyph_v1_", "qqreader_glyph_v1_", "glyph_v1_" }) do
        local path = cache_dir .. "/" .. legacy .. ref_size .. ".bin"
        local f = io.open(path, "rb")
        if f then
            f:close()
            cache = path
            break
        end
    end
    local ok, maps = pcall(require("source.yuewen_fonts.glyph").recognize, ref, cache, tasks)
    cleanup()
    if not ok then error(maps, 0) end
    local rare_map, han_map = {}, {}
    for idx, label in ipairs(labels) do
        if label == "rare" then rare_map = maps[idx] else han_map = maps[idx] end
    end
    return rare_map, han_map
end

local function utf8len(text)
    return #Text.chars(text)
end

local DECOY_SIMILARITY = 0.8

local chars = Text.chars

--- 起点 cES=2 的正文会把同一章再追加一份改了几个字的诱饵副本。
--- 前后两半段落字数一一对应、且逐字位置上 ≥80% 相同才丢后一半，避免把真实的对称段落误删。
---@param paragraphs string[]
---@return string[]
local function dropDecoyHalf(paragraphs)
    local n = #paragraphs
    if n < 4 or n % 2 ~= 0 then return paragraphs end
    local half = n / 2
    local same, total = 0, 0
    for i = 1, half do
        local a, b = chars(paragraphs[i]), chars(paragraphs[i + half])
        if #a ~= #b then return paragraphs end
        for k = 1, #a do
            if a[k] == b[k] then same = same + 1 end
        end
        total = total + #a
    end
    if total == 0 or same / total < DECOY_SIMILARITY then return paragraphs end
    for i = n, half + 1, -1 do paragraphs[i] = nil end
    return paragraphs
end

local fixConfusions

--- 解出的 HTML 段落还原成纯文本。
---@param plain string Fock 解出的正文
---@param font table { css=string, randomFont=table|nil }
---@param fixed_font string|nil fixedFont 下载下来的字节；没有字体加密的章为 nil
---@param opts table|nil { dedupe=boolean, threshold=number }
---@return string
function FontRestore.restore(plain, font, fixed_font, opts)
    opts = opts or {}
    local Scramble = require("source.yuewen_fonts.scramble")
    local paragraphs = Scramble.paragraphs(plain, font.css or "")
    if #paragraphs == 0 then return plain end
    if opts.dedupe then paragraphs = dropDecoyHalf(paragraphs) end
    local rare, han = Scramble.codes(paragraphs)
    local rare_map, han_map = {}, {}
    if #rare + #han > 0 then
        rare_map, han_map = recognize(font.randomFont, fixed_font, rare, han, opts)
    end
    local text = Scramble.text(paragraphs, rare_map, han_map)
    if opts.confusions then text = fixConfusions(text) end
    return text
end

FontRestore.dropDecoyHalf = dropDecoyHalf

-- 起点 fixedFont 里 于/干、责/贵 两组字形太近，16x16 相关度会把“关于/终于/负责”
-- 认成“关干/终干/负贵”。只修这些固定搭配；“对干部/在干活”这类保留干。
local YU_PREFIX = {
    ["关"] = true, ["终"] = true, ["对"] = true, ["等"] = true, ["至"] = true,
    ["由"] = true, ["属"] = true, ["便"] = true, ["利"] = true, ["善"] = true,
    ["敢"] = true, ["勇"] = true, ["难"] = true, ["易"] = true, ["在"] = true,
    ["位"] = true, ["鉴"] = true,
}
local YU_KEEP_NEXT = {
    ["部"] = true, ["活"] = true, ["事"] = true, ["劲"] = true, ["什"] = true, ["嘛"] = true, ["啥"] = true,
    ["吗"] = true, ["吧"] = true, ["净"] = true, ["脆"] = true, ["燥"] = true, ["旱"] = true, ["扰"] = true,
    ["预"] = true, ["练"] = true, ["掉"] = true, ["架"] = true, ["涸"] = true,
}
local ZE_PREFIX = { ["职"] = true, ["担"] = true, ["负"] = true, ["责"] = true, ["贵"] = true }
-- 少数整词在 fixedFont 里稳定认错（“泮”几乎只出现在“泮池”，不会误伤正文）。
local TEXT_FIXES = {
    ["同泮"] = "同伴",
    ["泮随"] = "伴随",
    ["聚干"] = "聚于",
}

--- 修正两类固定形近字；只在起点字体层启用。
--- Lua 的字符类是字节级，不能直接拿“部/活”做 [^...]，这里按 UTF-8 单字扫描。
---@param text string
---@return string
fixConfusions = function(text)
    local list = Text.chars(text)
    for i = 2, #list do
        local ch, prev, nxt = list[i], list[i - 1], list[i + 1]
        if ch == "干" and YU_PREFIX[prev] and not (nxt and YU_KEEP_NEXT[nxt]) then
            list[i] = "于"
        elseif ch == "贵" and (ZE_PREFIX[prev] or nxt == "任") then
            list[i] = "责"
        end
    end
    local fixed = table.concat(list)
    for from, to in pairs(TEXT_FIXES) do fixed = fixed:gsub(from, to) end
    return fixed
end

FontRestore.fixConfusions = fixConfusions

return FontRestore
