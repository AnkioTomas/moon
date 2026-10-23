--[[--
段评热点定位（番茄 / 晋江 / 起点共用）：把「第 range 段」按段末文字定位到章节 HTML 的 xpointer。
各源只负责给出 range → 段落纯文本（`paras`），段序怎么数由源自己定。

@module koplugin.book.book.review_locate
--]]

local Text = require("utils.text")

local ReviewLocate = {}

-- 气泡跟在段末：只用段尾这么多个字定位（要唯一），气泡画在最后一行右侧。
local MARK_RUNES = 24

--- 取串尾最多 n 个字（UTF-8 按首字节计，不会切坏字符）。
---@param s string
---@param n integer
---@return string
local function tail(s, n)
    local count, at = 0, #s + 1
    while at > 1 and count < n do
        at = at - 1
        while at > 1 and s:byte(at) >= 0x80 and s:byte(at) < 0xC0 do at = at - 1 end
        count = count + 1
    end
    return s:sub(at)
end

--- 章节 HTML 里每个非空 <p> 的纯文本，键为第几个非空段（晋江 / 起点的段序）。
---@param html string
---@return table<string, string>
function ReviewLocate.paragraphs(html)
    local out, n = {}, 0
    for seg in html:gmatch("<p[%s>].-</p>") do
        local text = Text.trim((Text.stripHtml(seg):gsub("\n", "")))
        if text ~= "" then
            n = n + 1
            out[tostring(n)] = text
        end
    end
    return out
end

--- 同文重复按段序消歧，仍无法消歧的丢弃。返回的 text 是整段原文（评论页上方的引用）。
---@param paras table<string, string> range → 段落纯文本
---@param hotspots { range: string, total: integer }[]
---@param html string
---@return table[] spots { range, text, total, pos0, pos1, badge }
function ReviewLocate.locate(paras, hotspots, html)
    local items = {}
    for _idx, hotspot in ipairs(hotspots) do
        local text = paras[hotspot.range]
        if text and text ~= "" then
            items[#items + 1] = { text = tail(text, MARK_RUNES), wr_range = hotspot.range, hotspot = hotspot, full = text }
        end
    end
    local located = require("book.annotations").locateBatch(html, items)
    local out = {}
    for _idx, entry in ipairs(items) do
        local hit = located[entry]
        if hit then
            local hotspot = entry.hotspot
            out[#out + 1] = {
                range = hotspot.range, text = entry.full, total = hotspot.total, pos0 = hit.pos0, pos1 = hit.pos1,
                badge = hotspot.total > 99 and "99+" or tostring(hotspot.total),
            }
        end
    end
    return out
end

return ReviewLocate
