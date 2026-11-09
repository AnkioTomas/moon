--[[--
系统输入法快照协议（纯函数）。

dex 侧把系统输入法上屏的文字写到 `koboard_input`，一行一个动作：

  CH:<text>                旧版：直接追加文字
  BS                       旧版：退格
  ST:<start>:<end>:<text>  当前：base64(UTF-8) 全文 + UTF-16 选区

Java 的 `Selection` 下标按 UTF-16 code unit 计（表情占两个），Lua 按字符计；
这里负责两种坐标的换算，避免长文本与表情上的光标漂移。

@module koplugin.book.features.system_ime.snapshot
--]]

local Snapshot = {}

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64_LUT = {}
for i = 1, #B64 do
    B64_LUT[B64:sub(i, i)] = i - 1
end

--- 解码 dex 侧 `Base64.NO_WRAP` 输出的 UTF-8 文本。
---@param s string|nil
---@return string|nil
function Snapshot.decodeBase64(s)
    if type(s) ~= "string" then return nil end
    s = s:gsub("%s+", "")
    local out = {}
    for i = 1, #s, 4 do
        local a = B64_LUT[s:sub(i, i)] or 0
        local b = B64_LUT[s:sub(i + 1, i + 1)] or 0
        local c_ch = s:sub(i + 2, i + 2)
        local d_ch = s:sub(i + 3, i + 3)
        local c = B64_LUT[c_ch] or 0
        local d = B64_LUT[d_ch] or 0
        out[#out + 1] = string.char(a * 4 + math.floor(b / 16))
        if c_ch ~= "=" and c_ch ~= "" then
            out[#out + 1] = string.char((b % 16) * 16 + math.floor(c / 4))
        end
        if d_ch ~= "=" and d_ch ~= "" then
            out[#out + 1] = string.char((c % 4) * 64 + d)
        end
    end
    return table.concat(out)
end

--- 按 UTF-8 字符切分；与 KOReader util.splitToChars 同义。
---@param text string|nil
---@return string[]
local function splitChars(text)
    local ok, util = pcall(require, "util")
    if ok and type(util) == "table" and type(util.splitToChars) == "function" then
        return util.splitToChars(text or "")
    end
    local chars = {}
    for char in tostring(text or ""):gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        chars[#chars + 1] = char
    end
    return chars
end

--- 前 count 个字符占多少个 UTF-16 code unit（表情 / 增补平面字符占两个）。
---@param text string
---@param count integer
---@return integer
function Snapshot.utf16Length(text, count)
    local chars = splitChars(text)
    local units = 0
    for i = 1, math.min(count, #chars) do
        units = units + (#chars[i] == 4 and 2 or 1)
    end
    return units
end

--- UTF-16 offset 换算成 Lua 字符位置（1-based，允许 #chars+1 表示结尾）。
--- 落在代理对中间时归到该字符之前，与 Java 侧把选区夹到边界的行为一致。
---@param text string
---@param offset integer|nil
---@return integer
function Snapshot.charPosFromUtf16(text, offset)
    offset = math.max(0, tonumber(offset) or 0)
    local chars = splitChars(text)
    local units = 0
    for i = 1, #chars do
        local next_units = units + (#chars[i] == 4 and 2 or 1)
        if next_units > offset then return i end
        units = next_units
    end
    return #chars + 1
end

--- 解析一份快照；坏行忽略，返回动作数组。
---@param content string|nil
---@return { type: "chars"|"backspace"|"state", text: string|nil, sel_start: integer|nil, sel_end: integer|nil }[]
function Snapshot.parse(content)
    local actions = {}
    for line in tostring(content or ""):gmatch("[^\r\n]+") do
        if line == "BS" then
            actions[#actions + 1] = { type = "backspace" }
        elseif line:sub(1, 3) == "CH:" then
            actions[#actions + 1] = { type = "chars", text = line:sub(4) }
        else
            local start_off, end_off, encoded = line:match("^ST:(%d+):(%d+):(.*)$")
            local text = start_off and Snapshot.decodeBase64(encoded)
            if text then
                actions[#actions + 1] = {
                    type = "state",
                    text = text,
                    sel_start = tonumber(start_off),
                    sel_end = tonumber(end_off),
                }
            end
        end
    end
    return actions
end

return Snapshot
