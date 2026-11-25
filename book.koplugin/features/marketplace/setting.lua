--[[--
插件市场：挂在设置根页「设备」分组，与「我的设备」并列。
右上角为刷新与生态筛选；页面在 `page.lua`。

@module koplugin.book.features.marketplace.setting
--]]

local _ = require("gettext")
local T = require("ffi/util").template

local Setting = {}

Setting.defaults = {
    filter = { tab = "browse", q = "", category = "", kind = "moon" },
}

---@param desktop BookDesktop
---@return BookSettingEntry[]
function Setting.entries(desktop)
    local status
    -- 状态是附加信息：算失败不能挡设置行出现（测试环境也可能没有完整 HTTP 栈）。
    pcall(function()
        local Catalog = require("features.marketplace.catalog")
        if Catalog.isRefreshing() then
            status = _("刷新中")
        elseif Catalog.lastError() then
            status = _("刷新失败")
        else
            local n = Catalog.count()
            if n > 0 then
                status = T(_("%1 个插件"), tostring(n))
            end
        end
    end)
    return {
        {
            group = "device",
            order = 25,
            id = "marketplace",
            icon = "inventory_2",
            title = _("插件市场"),
            subtitle = _("浏览并安装月读与 KOReader 插件"),
            status = status,
            status_on = status ~= nil,
            page = {
                title = _("插件市场"),
                searchable = false,
                on_close = function()
                    require("features.marketplace.page").onClose()
                end,
                right_actions = {
                    { icon = "refresh", callback = function()
                        require("features.marketplace.page").refresh(desktop)
                    end },
                    { icon = "tune", callback = function()
                        require("features.marketplace.page").chooseKind(desktop)
                    end },
                },
                nav = function(width)
                    return require("features.marketplace.page").nav(desktop, width)
                end,
                sections = function()
                    return require("features.marketplace.page").sections(desktop)
                end,
            },
        },
    }
end

return Setting
