--[[--
防自动休眠：长任务期间别让设备睡下去（休眠会掐 Wi-Fi、停远程管理）。

KOReader 的 `PluginShare.pause_auto_suspend` 只拦它自己的休眠计时；Kindle 的 powerd t1 看的是最后一次
InputEvent，超过自动休眠时长就不再重置、系统照睡。所以两样都要：
- `poke()`：算一次用户操作。随操作的场景（请求、进度回调）每次调一下，结束后自然恢复休眠计时，不留状态。
- `hold(owner, on)`：按持有者持续撑着，任一持有者为真即撑着。置 `pause_auto_suspend` 并每 `PULSE` 秒补一次 `poke()`；全部放开时
  降旗时还原升旗前的原值（autoturn、reMarkable / Sony 设备层也会写 true，不能清成 false）。

@module koplugin.book.utils.awake
--]]

local Awake = {
    PULSE = 60, -- 持续撑着时补 InputEvent 的间隔（秒）
}

local owners = {}
local held = false
local before

local function pulse()
    if not held then return end
    Awake.poke()
    require("ui/uimanager"):scheduleIn(Awake.PULSE, pulse)
end

function Awake.poke()
    require("ui/uimanager").event_hook:execute("InputEvent")
end

--- 按持有者撑着：任一持有者为真即撑着，全部放开才还原并取消补拍定时器。
---@param owner string
---@param on boolean
function Awake.hold(owner, on)
    owners[owner] = on or nil
    local want = next(owners) ~= nil
    if want == held then return end
    held = want
    local share = require("pluginshare")
    if want then
        before = share.pause_auto_suspend
        share.pause_auto_suspend = true
        pulse()
    else
        require("ui/uimanager"):unschedule(pulse)
        share.pause_auto_suspend = before
        before = nil
    end
end

---@return boolean
function Awake.held()
    return held
end

return Awake
