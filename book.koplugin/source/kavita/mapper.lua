--[[--
Kavita 系列书评映射；个人评价列表和章节评价不混入系列书评。

@module source.kavita.mapper
--]]

require("l10n").apply()
local Text = require("utils.text")
local _ = require("gettext")

local Mapper = {}

---@param wire table
---@param series_id string
---@return table|nil, string|nil
function Mapper.bookReviewPage(wire, series_id)
    local rows = type(wire) == "table" and wire.reviews
    if type(rows) ~= "table" then return nil, _("响应无效") end
    local items = {}
    for _idx, row in ipairs(rows) do
        if type(row) ~= "table" or type(row.body) ~= "string"
            or type(row.chapterId) ~= "number" or type(row.username) ~= "string" then
            return nil, _("响应无效")
        end
        if row.isExternal ~= true and tostring(row.seriesId) ~= series_id then
            return nil, _("响应无效")
        end
        if row.chapterId == 0 then
            local body = type(row.bodyJustText) == "string" and row.bodyJustText ~= ""
                and row.bodyJustText or Text.stripHtml(row.body)
            local title = type(row.tagline) == "string" and Text.trim(row.tagline) or ""
            local text = title ~= "" and title .. "\n" .. body or body
            if Text.trim(text) ~= "" then
                items[#items + 1] = { author = row.username, text = text, time = "",
                    grade = tonumber(row.rating), likes = tonumber(row.totalVotes) }
            end
        end
    end
    return { items = items, total = #items, pages = 1, title = _("书评") }
end

return Mapper
