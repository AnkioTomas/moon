--[[--
远程管理的高亮与笔记页（/notes.html）与接口（/api/notes/<action>，见 features.notes.remote）。

没有生命周期钩子：只经 `web.routes` 挂点。

@module koplugin.book.features.notes
--]]

local Ext = require("utils.extension")

Ext.add("web.routes", {
    name = "notes",
    dir = (debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$") or ".") .. "/web",
    assets = { "notes.html", "notes.js", "notes.css" },
    page = {
        href = "/notes.html", title = "笔记", title_long = "高亮与笔记", tile = "tile-amber",
        desc = "查看、编辑、删除和导出全书高亮与笔记。",
        icon = "M3 17.25V21h3.75L17.81 9.94l-3.75-3.75L3 17.25zM20.71 7.04c.39-.39.39-1.02 0-1.41l-2.34-2.34a.996.996 0 0 0-1.41 0l-1.83 1.83 3.75 3.75 1.83-1.83z",
    },
    l10n = "features.notes.l10n.web",
    handle = function(method, action, params, cb) require("features.notes.remote").handle(method, action, params, cb) end,
    download = function(action) return require("features.notes.remote").download(action) end,
})

return {}
