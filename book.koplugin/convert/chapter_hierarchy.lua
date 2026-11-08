--[[--
目录层级：优先沿用源目录，缺少层级时从中文卷章标题推断。

@module koplugin.book.convert.chapter_hierarchy
--]]

local Text = require("utils.text")

local Hierarchy = {}
local CHINESE_NUMBERS = { "零", "〇", "一", "二", "三", "四", "五", "六", "七", "八", "九", "十", "百", "千", "万", "两" }
local CHAPTER_MARKERS = { "章", "回", "节", "集", "幕" }

---@param value string
---@return boolean
function Hierarchy.isNumberToken(value)
    value = value:gsub("%s+", "")
    if value == "" or value:match("^%d+$") or value:match("^[IVXLCDMivxlcdm]+$") then
        return value ~= ""
    end
    for _idx, char in ipairs(CHINESE_NUMBERS) do
        value = value:gsub(char, "")
    end
    return value == ""
end

---@param title string
---@return string
function Hierarchy.titleKey(title)
    return Text.trim((title:gsub("　", " "):gsub("\194\160", " "):gsub("%s+", " ")))
end

---@param title string
---@return string|nil
local function chapterNumber(title)
    for _idx, marker in ipairs(CHAPTER_MARKERS) do
        local number = title:match("^第%s*(.-)%s*" .. marker)
        if number and Hierarchy.isNumberToken(number) then return (number:gsub("%s+", "")) end
    end
end

--- “第一卷-第一章 标题”与分开的卷标题共用卷号；正文标题不按章号去重。
---@param title string
---@return string|nil volume, string|nil chapter
local function volumeTitle(title)
    local number, suffix = title:match("^第%s*(.-)%s*卷(.*)$")
    if not number or not Hierarchy.isNumberToken(number) then return nil end
    local volume = "第" .. number:gsub("%s+", "") .. "卷"
    local tail = Text.trim((suffix:gsub("^%s*[-:]+", ""):gsub("^%s*：", ""):gsub("^%s*—", "")))
    return volume, chapterNumber(tail) and tail or nil
end

--- 给没有层级的条目分卷；合写标题缺少卷节点时补一个。
---@param entries table[]
---@return table[]
local function infer(entries)
    local out, current_volume = {}, nil
    for _idx, entry in ipairs(entries) do
        local volume, chapter = volumeTitle(Hierarchy.titleKey(entry.title))
        if volume and not chapter then
            current_volume = volume
            entry.depth = 1
        else
            if chapter then
                if volume ~= current_volume then
                    out[#out + 1] = { title = volume, depth = 1, xpointer = entry.xpointer }
                    current_volume = volume
                end
                entry.title = chapter
            end
            entry.depth = current_volume and 2 or 1
        end
        out[#out + 1] = entry
    end
    return out
end

--- 目录同名条目按出现顺序匹配。原目录中的父节点即使不在正文里，也能在首个子章前补回。
---@param sections table[]
---@param headings (string|{ title: string, depth: integer|nil })[]|nil
---@return table[]|nil
local function preserve(sections, headings)
    local by_title, parents, nested = {}, {}, false
    for index, heading in ipairs(headings or {}) do
        if type(heading) == "table" and type(heading.title) == "string" then
            local key = Hierarchy.titleKey(heading.title)
            if key ~= "" then
                local depth = math.min(#parents + 1, math.max(1, math.floor(tonumber(heading.depth) or 1)))
                while #parents >= depth do parents[#parents] = nil end
                local entry = { title = heading.title, depth = depth, index = index, parent = parents[depth - 1] }
                if entry.parent then entry.parent.has_children = true end
                parents[depth] = entry
                by_title[key] = by_title[key] or { next = 1 }
                table.insert(by_title[key], entry)
                nested = nested or depth > 1
            end
        end
    end
    if not nested then return nil end

    local matches, cursor, matched_child = {}, 0, false
    for i, section in ipairs(sections) do
        local entries = by_title[Hierarchy.titleKey(section.title)]
        if entries then
            while entries[entries.next] and entries[entries.next].index <= cursor do
                entries.next = entries.next + 1
            end
            local entry = entries[entries.next]
            if entry then
                matches[i], cursor = entry, entry.index
                matched_child = matched_child or entry.depth > 1
            end
        end
    end
    if not matched_child then return nil end

    local out, emitted = {}, {}
    local function addParent(entry)
        if not entry or emitted[entry] then return end
        addParent(entry.parent)
        out[#out + 1] = { title = entry.title, depth = entry.depth }
        emitted[entry] = true
    end
    local previous
    for i, section in ipairs(sections) do
        local entry = matches[i]
        if entry then
            addParent(entry.parent)
            section.depth = entry.depth
            emitted[entry], previous = true, entry
        else
            -- 排版额外识别的标题保留在当前分组，不能成为原目录条目的父节点。
            section.depth = previous and previous.depth + (previous.has_children and 1 or 0) or 1
        end
        out[#out + 1] = section
    end
    return out
end

--- 倒序记录每个候选卷到下一卷之间的首个章号，供区分卷首和正文中的卷名提及。
---@param entries table[]
---@return table
local function volumeStarts(entries)
    local volumes, next_volume, first_chapter = {}, nil, nil
    for index = #entries, 1, -1 do
        local entry = entries[index]
        local title = Hierarchy.titleKey(entry.title)
        local volume, chapter = volumeTitle(title)
        if volume and not chapter then
            local restarts = tonumber(first_chapter) == 1 or first_chapter == "一" or first_chapter == "I" or first_chapter == "i"
            local later_start = next_volume and next_volume.id == volume and next_volume.depth == entry.depth and next_volume.restarts
            next_volume = { id = volume, depth = entry.depth, restarts = restarts, later_start = later_start }
            volumes[entry] = next_volume
            first_chapter = nil
        else
            first_chapter = chapterNumber(chapter or title) or first_chapter
        end
    end
    return volumes
end

--- 同卷号只有在章节重新编号时才另开一卷；若下一处同卷号才从第一章开始，先前提及归回正文。
--- 被误挂的目录子章仍按正文顺序留在所属卷下。
---@param sections table[]
---@param headings (string|{ title: string, depth: integer|nil })[]|nil
---@return table[]
function Hierarchy.organize(sections, headings)
    local entries = preserve(sections, headings) or infer(sections)
    local volumes = volumeStarts(entries)
    local root = { depth = 0 }
    local parents, last_volume, enclosing_volume = { [0] = root }, {}, {}
    for _idx, entry in ipairs(entries) do
        local depth = entry.depth
        local parent = parents[depth - 1] or root
        local previous = last_volume[parent]
        local volume = volumes[entry]
        local inside_same_volume = volume and enclosing_volume[parent] == volume.id
        local repeated = inside_same_volume or (volume and previous and volumes[previous].id == volume.id)
        if volume and not volume.restarts and (repeated or volume.later_start) then
            entry.toc = false
            parents[depth] = not inside_same_volume and previous or parent
        else
            entry.depth = parent.depth + 1
            parents[depth] = entry
            last_volume[parent] = volume and entry or nil
            enclosing_volume[entry] = volume and volume.id or enclosing_volume[parent]
        end
    end
    return entries
end

return Hierarchy
