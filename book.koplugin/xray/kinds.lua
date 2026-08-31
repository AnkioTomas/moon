--[[--
X-Ray 实体种类标签。

@module koplugin.book.xray.kinds
--]]

local _ = require("gettext")

local Kinds = {
    { id = "character", text = _("人物"), icon = "person" },
    { id = "location", text = _("地点"), icon = "location_on" },
    { id = "term", text = _("专有名词"), icon = "label" },
}

---@param kind string|nil
---@return string
function Kinds.label(kind)
    for index, item in ipairs(Kinds) do
        if item.id == kind then
            return item.text
        end
    end
    return kind or ""
end

return Kinds
