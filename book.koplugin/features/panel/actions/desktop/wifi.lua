--[[-- Wi-Fi 快捷动作。
@module koplugin.book.features.panel.actions.desktop.wifi
--]]

local Device = require("device")
local NetworkMgr = require("ui/network/manager")
local _ = require("gettext")

local kindle_network_list_patched = false

--- Kindle 后端会把空 ESSID 转成 false，原生自动连接与列表却按字符串使用。
--- 首次长按时包装一次，弹出的原生网络列表后续重扫也需要这层过滤。
local function patchKindleNetworkList()
    if not Device:isKindle() or kindle_network_list_patched then return end
    local getNetworkList = NetworkMgr.getNetworkList
    function NetworkMgr:getNetworkList(...)
        local networks, err = getNetworkList(self, ...)
        if not networks then return networks, err end
        local valid = {}
        for _idx, network in ipairs(networks) do
            if type(network.ssid) == "string" and network.ssid ~= "" then
                valid[#valid + 1] = network
            end
        end
        return valid, err
    end
    kindle_network_list_patched = true
end

---@type BookQuickPanelAction
return {
    id = "wifi",
    title = _("Wi-Fi"),
    icon = "wifi",
    scope = "desktop",
    event = "ToggleWifi",
    keep_open = true,
    refresh_delay = 1,
    --- 设备支持 Wi-Fi 开关时显示。
    ---@return boolean
    available = function()
        return Device:hasWifiToggle()
    end,
    --- 读取当前 Wi-Fi 状态，用于按钮激活态。
    ---@return boolean
    active = function()
        return NetworkMgr:isWifiOn()
    end,
    --- 已连接时显示当前网络名。
    ---@return string|nil
    label = function()
        if not NetworkMgr:isWifiOn() then return nil end
        local nw = NetworkMgr:getCurrentNetwork()
        if nw and type(nw.ssid) == "string" and nw.ssid ~= "" then return nw.ssid end
    end,
    --- 长按：Android 打开系统 Wi-Fi 设置，其余设备走 KOReader 原生长按路径，开着也弹网络列表。
    hold = function()
        if Device:isAndroid() then
            NetworkMgr:openSettings()
        else
            patchKindleNetworkList()
            NetworkMgr:toggleWifiOn(nil, true, true)
        end
    end,
}
