--[[--
首页模块注册表（SimpleUI moduleregistry 精简版）

@module koplugin.book.modules.registry
--]]

local Registry = {
    order = { "clock", "recent" },
}

local CACHE = {}

function Registry.load(id)
    if CACHE[id] then return CACHE[id] end
    local mod
    if id == "clock" then
        mod = require("modules/clock")
    elseif id == "recent" then
        mod = require("modules/recent")
    elseif id == "covergrid" then
        mod = require("modules/covergrid")
    end
    CACHE[id] = mod
    return mod
end

function Registry.buildHome(ctx)
    local VerticalGroup = require("ui/widget/verticalgroup")
    local vg = VerticalGroup:new{ align = "left" }
    for _, id in ipairs(Registry.order) do
        local mod = Registry.load(id)
        if mod and mod.build then
            local ok, widget = pcall(mod.build, ctx)
            if ok and widget then
                table.insert(vg, widget)
            end
        end
    end
    return vg
end

return Registry
