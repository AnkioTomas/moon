--[[--
把一本书已经分析过的页面合并成人物、事件和关系图谱。

@module koplugin.book.ai.graph
--]]

local Text = require("utils.text")
require("l10n").apply()
local _ = require("gettext")

local Graph = {}

local function appendUnique(out, seen, item, key)
    if key ~= "" and not seen[key] then
        seen[key] = true
        out[#out + 1] = item
    end
end

--- 合并多页分析结果为去重后的人物 / 事件 / 关系。
---@param analyses table[]
---@return table
function Graph.merge(analyses)
    local graph = { characters = {}, events = {}, relations = {} }
    local characters, events, relations = {}, {}, {}
    for _, analysis in ipairs(analyses or {}) do
        for _, item in ipairs(analysis.characters or {}) do
            appendUnique(graph.characters, characters, item, Text.trim(item.name))
        end
        for _, item in ipairs(analysis.events or {}) do
            local participants = table.concat(item.participants or {}, ",")
            appendUnique(graph.events, events, item,
                Text.trim(item.name) .. "\0" .. Text.trim(item.description) .. "\0" .. participants)
        end
        for _, item in ipairs(analysis.relations or {}) do
            appendUnique(graph.relations, relations, item, table.concat({
                Text.trim(item.from), Text.trim(item.to), Text.trim(item.type), Text.trim(item.description),
            }, "\0"))
        end
    end
    return graph
end

--- 图谱格式化为可读纯文本。
---@param graph table
---@return string
function Graph.format(graph)
    local lines = {}
    lines[#lines + 1] = _("人物")
    for _, item in ipairs(graph.characters or {}) do
        local details = {}
        if Text.trim(item.role) ~= "" then details[#details + 1] = Text.trim(item.role) end
        if Text.trim(item.description) ~= "" then details[#details + 1] = Text.trim(item.description) end
        local detail = table.concat(details, " · ")
        lines[#lines + 1] = "• " .. (item.name or "?") .. (detail ~= "" and "：" .. detail or "")
    end
    if #(graph.characters or {}) == 0 then lines[#lines + 1] = _("（暂无）") end
    lines[#lines + 1] = "\n" .. _("事件")
    for _, item in ipairs(graph.events or {}) do
        local people = table.concat(item.participants or {}, "、")
        lines[#lines + 1] = "• " .. (item.name ~= "" and item.name or item.description or "?")
            .. (people ~= "" and " [" .. people .. "]" or "")
            .. (item.name ~= "" and item.description ~= "" and "：" .. item.description or "")
    end
    if #(graph.events or {}) == 0 then lines[#lines + 1] = _("（暂无）") end
    lines[#lines + 1] = "\n" .. _("关系")
    for _, item in ipairs(graph.relations or {}) do
        lines[#lines + 1] = string.format("• %s → %s [%s]%s", item.from or "?", item.to or "?",
            item.type ~= "" and item.type or _("关联"),
            item.description ~= "" and "：" .. item.description or "")
    end
    if #(graph.relations or {}) == 0 then lines[#lines + 1] = _("（暂无）") end
    return table.concat(lines, "\n")
end

return Graph
