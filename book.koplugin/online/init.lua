--[[--
ankio.net 公共接口。不是 feature，不进设置。

main 只在 onNetworkConnected（以及启动时）ensure：
过期的天气 / 一言 / 摸鱼日报 / 必应入队。没网任务进 waiting。
缓存文件在 cache/online/（JSON + 必应/摸鱼日报图）。UI 只读 current() / imagePath()：过期或没有就是空。
禁止调用方强制刷新；换地点写 city 再 ensure。

@module koplugin.book.online
--]]

local Guard = require("ui.guard")

local Online = {}

local ENDPOINTS = { "weather", "hitokoto", "myrl", "bing" }

---@param _plugin BookPlugin
function Online.onNetworkConnected(_plugin)
    for _idx, name in ipairs(ENDPOINTS) do
        Guard.call("online." .. name, function()
            require("online." .. name):ensure()
        end)
    end
end

return Online
