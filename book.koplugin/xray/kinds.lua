--[[--
X-Ray 实体种类标签。

@module koplugin.book.xray.kinds
--]]

local _ = require("gettext")

local Kinds = {
    character = _("人物"),
    location = _("地点"),
    term = _("专有名词"),
}

---@param kind string|nil
---@return string
function Kinds.label(kind)
    return Kinds[kind] or kind or ""
end

return Kinds
