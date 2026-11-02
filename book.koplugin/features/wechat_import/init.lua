--[[--
微信书架大快照导入：全量同步回包过大时设备不解码、原文落盘（source.wechat.shelf_import），
这里经 `web.routes` 挂点开一页（/wechat_import.html，不进远程管理首页与顶栏；由大书架同步时的二维码直达），由浏览器下载原文、解码、分批回传入库。
没有生命周期钩子。

@module koplugin.book.features.wechat_import
--]]

local Ext = require("utils.extension")
local ShelfImport = require("source.wechat.shelf_import")

-- 导入要几分钟，设备自动休眠会停掉远程管理：每个请求算一次操作（网页导入期间还会定时 ping status），
-- 导入一结束请求停了，自然恢复休眠计时，不留开关状态。
local keepAwake = require("utils.awake").poke

Ext.add("web.routes", {
    name = "wechat_import",
    dir = (debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$") or ".") .. "/web",
    assets = { "wechat_import.html", "wechat_import.js" },
    l10n = "features.wechat_import.l10n.web",
    download = function(action)
        keepAwake()
        if action ~= "file" or not ShelfImport.size() then return nil end
        return { ctype = "application/json; charset=utf-8", filename = "wechat_shelf.json", path = ShelfImport.path() }
    end,
    handle = function(method, action, params, cb)
        keepAwake()
        if method == "GET" and action == "status" then
            cb(200, { size = ShelfImport.size() })
        elseif method == "POST" and action == "batch" then
            local ids, err = ShelfImport.ingest(params)
            if ids then cb(200, { ids = ids }) else cb(500, { error = err }) end
        elseif method == "POST" and action == "commit" then
            local hidden, err = ShelfImport.commit(params.ids or {}, tonumber(params.synckey))
            if hidden then cb(200, { hidden = hidden }) else cb(500, { error = err }) end
        elseif method == "POST" and action == "discard" then
            ShelfImport.discard()
            cb(200, {})
        else
            cb(404, { error = "unknown action" })
        end
    end,
})

return {}
