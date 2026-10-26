--[[-- Wi-Fi 长按：Kindle 空网络名不能进入原生自动连接和网络列表。 --]]
---@diagnostic disable: undefined-field, missing-fields

local Assert = require("support.assert")

package.preload["gettext"] = function() return function(value) return value end end

local kindle, android, wifi_on = true, false, true
package.preload["device"] = function()
    return {
        isKindle = function() return kindle end,
        isAndroid = function() return android end,
        hasWifiToggle = function() return true end,
    }
end

local good = { ssid = "家里的 Wi-Fi", password = "saved", signal_quality = 80, connected = true }
local spaces = { ssid = "   ", signal_quality = 20 }
local networks = {
    { ssid = false, password = "saved" }, -- Kindle 将空 ESSID 转成 false。
    { ssid = "", password = "saved" },
    { password = "saved" },
    { ssid = true, password = "saved" },
    { ssid = 42, password = "saved" },
    { ssid = {}, password = "saved" },
    good,
    spaces,
}
local scan_result, scan_error, scan_exception = networks, nil, nil
local scans, toggles, settings_opened = 0, 0, 0
local shown, current = nil, good
local NetworkMgr = {}
function NetworkMgr:getNetworkList()
    Assert.eq(self, NetworkMgr, "保留后端调用的 self")
    scans = scans + 1
    if scan_exception then error(scan_exception) end
    return scan_result, scan_error
end
local raw_get_network_list = NetworkMgr.getNetworkList
function NetworkMgr:toggleWifiOn(callback, long_press, interactive)
    toggles = toggles + 1
    Assert.is_nil(callback)
    Assert.eq(long_press, true)
    Assert.eq(interactive, true)
    local list, err = self:getNetworkList()
    if not list then return list, err end
    -- 复现 KOReader：自动认证前会先求值日志里的 fixUtf8(ssid)，内部对 ssid 取长度。
    for _idx, network in ipairs(list) do
        if network.password then
            local len = #network.ssid
            Assert.is_true(len > 0)
        end
    end
    shown = list
end
function NetworkMgr:isWifiOn() return wifi_on end
function NetworkMgr:getCurrentNetwork() return current end
function NetworkMgr:openSettings() settings_opened = settings_opened + 1 end
package.preload["ui/network/manager"] = function() return NetworkMgr end

-- 原生路径先证明能复现这次 boolean 长度错误，避免桩本身把问题吞掉。
Assert.errors(function() NetworkMgr:toggleWifiOn(nil, true, true) end, "boolean")
local Action = require("features.panel.actions.desktop.wifi")
Action.hold({})
Assert.eq(toggles, 2)
Assert.len(shown, 2)
Assert.eq(shown[1], good, "正常网络保留原对象和连接字段")
Assert.eq(shown[2], spaces, "全空格也可以是合法 SSID，不做 trim")
Assert.len(networks, 8, "不改写后端共享的扫描结果")
Assert.eq(networks[1].ssid, false)

-- 弹窗异步重扫仍受保护；反复长按不叠加包装，每次扫描只调用一次原后端。
local filtered_get_network_list = NetworkMgr.getNetworkList
local before = scans
local rescanned = NetworkMgr:getNetworkList()
Assert.len(rescanned, 2)
Assert.eq(rescanned[1], good)
Action.hold({})
Assert.eq(NetworkMgr.getNetworkList, filtered_get_network_list)
Assert.eq(scans, before + 2)

-- 全部无效等同于没有可用网络；扫描失败保留原生错误语义，不伪装成成功。
scan_result = { { ssid = false }, { ssid = "" }, {} }
Action.hold({})
Assert.len(shown, 0)
scan_result = {}
Assert.len(NetworkMgr:getNetworkList(), 0)
scan_result, scan_error = nil, "scan failed"
local result, err = NetworkMgr:getNetworkList()
Assert.is_nil(result)
Assert.eq(err, "scan failed")
scan_exception = "backend exploded"
Assert.errors(function() Action.hold({}) end, "backend exploded", "意外异常仍冒到入口 guard")
scan_exception, scan_error, scan_result = nil, nil, networks

-- 动态标题只接受非空字符串；关 Wi-Fi、没有当前网络时使用默认标题。
for _idx, ssid in ipairs({ false, true, 42, {}, "" }) do
    current = { ssid = ssid }
    Assert.is_nil(Action.label())
end
current = {}
Assert.is_nil(Action.label())
current = nil
Assert.is_nil(Action.label())
current = good
Assert.eq(Action.label(), good.ssid)
wifi_on = false
Assert.is_nil(Action.label())
wifi_on = true

-- 其他平台保留原生路径，Android 只开系统设置。
kindle = false
NetworkMgr.getNetworkList = raw_get_network_list
scan_result = { good }
package.loaded["features.panel.actions.desktop.wifi"] = nil
Action = require("features.panel.actions.desktop.wifi")
Action.hold({})
Assert.eq(NetworkMgr.getNetworkList, raw_get_network_list)
Assert.eq(shown, scan_result)
android = true
before = toggles
Action.hold({})
Assert.eq(settings_opened, 1)
Assert.eq(toggles, before)
Assert.eq(NetworkMgr.getNetworkList, raw_get_network_list)
