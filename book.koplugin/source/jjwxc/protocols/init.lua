--[[--
晋江登录协议选择：网页（web）与 App（app）两套登录态各自独立，用户只用其中一个。

选择存在源设置 `protocol`；没设置（或所选协议没有登录态）时，哪个协议有登录态就用哪个，两个都有时先 web（沿用旧行为）。

@module koplugin.book.source.jjwxc.protocols
--]]

local Protocols = {}

local SOURCE_ID = "jjwxc"

---@type table[]
Protocols.list = { require("source.jjwxc.protocols.web"), require("source.jjwxc.protocols.app") }

---@return table|nil
function Protocols.current()
    local chosen = require("utils.settings").getSource(SOURCE_ID).protocol
    local fallback
    for _idx, protocol in ipairs(Protocols.list) do
        if protocol.available() then
            if protocol.id == chosen then return protocol end
            fallback = fallback or protocol
        end
    end
    return fallback
end

---@param id "web"|"app"
function Protocols.select(id)
    local Settings = require("utils.settings")
    Settings.getSource(SOURCE_ID).protocol = id
    Settings.saveSource(SOURCE_ID)
end

return Protocols
