--[[--
浏览器授权登录：配合浏览器扩展 moon-cookie-storage，把网页登录态（cookie / localStorage）交给数据源。

没有生命周期钩子：只经 `web.routes` 挂点在远程管理里开一页（/cookie.html）与接口（/api/cookie/*，见 remote.lua）。
数据源在自己的 setting.lua 里声明 `Setting.browser`（契约见 remote.lua 头注释）。

@module koplugin.book.features.cookie
--]]

local Ext = require("utils.extension")

Ext.add("web.routes", {
    name = "cookie",
    dir = (debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$") or ".") .. "/web",
    assets = { "cookie.html", "cookie.js", "cookie.css" },
    page = {
        href = "/cookie.html", title = "浏览器登录", title_long = "浏览器授权登录", tile = "tile-green",
        desc = "用浏览器扩展把网页登录态交给数据源（如七猫、京东读书）。",
        icon = "M12 2a10 10 0 1 0 0 20 10 10 0 0 0 0-20zm-1 17.9A8 8 0 0 1 4.1 13H8v1a2 2 0 0 0 2 2v3.9zM17.9 17A2 2 0 0 0 16 16h-1v-3a1 1 0 0 0-1-1H8v-2h2a1 1 0 0 0 1-1V7h2a2 2 0 0 0 2-2v-.4A8 8 0 0 1 19.9 11H19a1 1 0 0 0-1 1v5z",
    },
    l10n = "features.cookie.l10n.web",
    -- login 是浏览器扩展的回调，不经网页、没有配对令牌；它自己用一次性 ticket 鉴权
    public = { login = true },
    handle = function(method, action, params, cb) require("features.cookie.remote").handle(method, action, params, cb) end,
})

return {}
