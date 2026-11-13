--[[--
锁屏历史壁纸的远程管理接口（/api/lockscreen/*，经 web.routes 挂入，不依赖 server）。

只有 list：图片下载走现成的 /download?path=&inline=1（配对令牌由 Cookie 带）。

@module koplugin.book.features.lockscreen.remote
--]]

local History = require("features.lockscreen.history")
local _ = require("gettext")

local Remote = {}

local GET, POST = {}, {}

function GET.list(_q, cb)
    cb(200, { items = History.list() })
end

--- 分发；回调只回一次由调用方（remote/ext_route）保证。
---@param method "GET"|"POST"
---@param action string
---@param params table
---@param cb fun(status: integer, result: table)
function Remote.handle(method, action, params, cb)
    local fn = (method == "GET" and GET or POST)[action]
    if not fn then return cb(404, { error = _("接口不存在") }) end
    fn(params or {}, cb)
end

return Remote
