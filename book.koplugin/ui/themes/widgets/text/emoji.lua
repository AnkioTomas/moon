--[[--
评论 emoji 的行内图片：Twemoji 16 PNG（CC-BY 4.0），沿用主题图片下载与缓存。
保留原文字串；图片不可用时由文字控件显示原标记。普通符号不替换，除非带 emoji 变体选择符。

@module koplugin.book.ui.themes.widgets.text.emoji
--]]

local Text = require("utils.text")
local Emoji = {
    BASE = "https://cdn.jsdelivr.net/gh/jdecked/twemoji@16.0.1/assets/72x72/",
}

---@param char string UTF-8 字符
---@return integer
local function codepoint(char)
    local first = char:byte()
    if #char == 1 then return first end
    local value = first % (2 ^ (7 - #char))
    for idx = 2, #char do value = value * 64 + char:byte(idx) % 64 end
    return value
end

---@param code integer
---@return boolean
local function regional(code)
    return code >= 0x1F1E6 and code <= 0x1F1FF
end

---@param text string
---@param inline_images table|nil
---@return table
function Emoji.images(text, inline_images)
    local images = {}
    for key, image in pairs(inline_images or {}) do images[key] = image end
    local chars, codes = Text.chars(text), {}
    for idx, char in ipairs(chars) do codes[idx] = codepoint(char) end
    local idx = 1
    while idx <= #chars do
        local code = codes[idx]
        local keycap = (code == 0x23 or code == 0x2A or code >= 0x30 and code <= 0x39)
            and (codes[idx + 1] == 0x20E3 or codes[idx + 1] == 0xFE0F and codes[idx + 2] == 0x20E3)
        local pictograph = code >= 0x1F300 and code <= 0x1FAFF
        local variant = code >= 0x2000 and code <= 0x2BFF and codes[idx + 1] == 0xFE0F
        if keycap or pictograph or variant or regional(code) and regional(codes[idx + 1] or 0) then
            local last = idx
            if regional(code) then last = idx + 1 end
            while last < #chars do
                local following = codes[last + 1]
                if following == 0xFE0F or following == 0x20E3
                    or following >= 0x1F3FB and following <= 0x1F3FF
                    or following >= 0xE0020 and following <= 0xE007F then
                    last = last + 1
                elseif following == 0x200D and codes[last + 2]
                    and (codes[last + 2] >= 0x1F300 and codes[last + 2] <= 0x1FAFF
                        or codes[last + 2] >= 0x2000 and codes[last + 2] <= 0x2BFF) then
                    last = last + 2
                else
                    break
                end
            end
            local hex, joined = {}, false
            for pos = idx, last do if codes[pos] == 0x200D then joined = true end end
            for pos = idx, last do
                if codes[pos] ~= 0xFE0F or joined then hex[#hex + 1] = string.format("%x", codes[pos]) end
            end
            local token = table.concat(chars, "", idx, last)
            if not images[token] then images[token] = { url = Emoji.BASE .. table.concat(hex, "-") .. ".png" } end
            idx = last + 1
        else
            idx = idx + 1
        end
    end
    return images
end

return Emoji
