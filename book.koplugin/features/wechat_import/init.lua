--[[--
微信书架大快照导入：全量同步回包过大时设备不解码、原文落盘（source.wechat.shelf_import），
这里经 `web.routes` 挂点开一页（/wechat_import.html），由浏览器下载原文、解码、分批回传入库。
没有生命周期钩子。

@module koplugin.book.features.wechat_import
--]]

local Ext = require("utils.extension")
local ShelfImport = require("source.wechat.shelf_import")

Ext.add("web.routes", {
    name = "wechat_import",
    dir = (debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$") or ".") .. "/web",
    assets = { "wechat_import.html", "wechat_import.js" },
    page = {
        href = "/wechat_import.html", title = "微信书架导入", title_long = "微信书架分批导入", tile = "tile-green",
        desc = "书架太大、设备无法直接同步时，用浏览器解码后分批导入。",
        icon = "M4 4h16v4H4V4zm0 6h16v4H4v-4zm0 6h16v4H4v-4z",
    },
    l10n = "features.wechat_import.l10n.web",
    download = function(action)
        if action ~= "file" or not ShelfImport.size() then return nil end
        return { ctype = "application/json; charset=utf-8", filename = "wechat_shelf.json", path = ShelfImport.path() }
    end,
    handle = function(method, action, params, cb)
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
