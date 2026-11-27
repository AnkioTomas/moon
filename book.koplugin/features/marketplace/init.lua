--[[--
插件市场：设置根页「设备」分组下的扩展浏览与安装，数据来自 https://moon-store.ankio.net/。
桌面激活后延迟在后台按 6 小时周期静默刷新目录，不抢占首屏加载，也不在离线或失败时打扰用户。

@module koplugin.book.features.marketplace
--]]

local Marketplace = {}

--- 桌面打开/激活后延迟多久发起后台静默刷新（秒），避开首屏渲染、封面解码与书库同步高峰。
Marketplace.AUTO_REFRESH_DELAY = 15

local auto_timer
local pending_desk

function Marketplace.cancelAutoRefresh()
    if auto_timer then
        require("ui/uimanager"):unschedule(auto_timer)
        auto_timer = nil
    end
    pending_desk = nil
end

---@param desk table|nil
local function runAutoRefresh(desk)
    auto_timer = nil
    pending_desk = nil
    local Catalog = require("features.marketplace.catalog")
    if Catalog.isRefreshing() or not Catalog.isStale() then return end
    if not require("ui/network/manager"):isConnected() then return end
    Catalog.refresh(function(err)
        if err then
            require("utils.log").dbg("marketplace auto refresh skipped", err)
            return
        end
        if desk and not desk.closed and desk.settings_overlay
            and desk.settings_overlay.spec
            and desk.settings_overlay.spec.id == "feature:marketplace:marketplace" then
            desk.settings_overlay:updateView()
        end
    end, { silent = true })
end

--- 桌面激活时检查：若距上次刷新已满 6 小时，延迟一小会儿在后台静默刷新。
---@param desk table|nil
function Marketplace.scheduleAutoRefresh(desk)
    local Catalog = require("features.marketplace.catalog")
    if Catalog.isRefreshing() or not Catalog.isStale() then return end
    pending_desk = desk
    if auto_timer then return end
    auto_timer = require("ui.guard").wrap("marketplace.auto_refresh", function()
        runAutoRefresh(pending_desk)
    end)
    require("ui/uimanager"):scheduleIn(Marketplace.AUTO_REFRESH_DELAY, auto_timer)
end

function Marketplace.onExit()
    Marketplace.cancelAutoRefresh()
    require("features.marketplace.catalog").cancel()
    require("workers.tasks").cancelPrefixed("plugin")
    local Page = require("features.marketplace.page")
    Page.cancelPending()
    Page.onClose()
end

require("utils.extension").add("desktop.activated", function(desk)
    Marketplace.scheduleAutoRefresh(desk)
    require("features.marketplace.migrate").offer(desk)
end)

return Marketplace
