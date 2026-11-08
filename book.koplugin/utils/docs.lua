--[[--
官网用户手册链接：统一拼 URL、能开链接就开、否则出二维码。
路径与 moon.ankio.net/manual 树对齐；设置页用 docs 字段挂「查看指南」。

@module koplugin.book.utils.docs
--]]

require("l10n").apply()
local _ = require("gettext")

local Docs = {}

Docs.BASE = "https://moon.ankio.net"

--- 设置分组落地页（根页点分组打开的叠层）。
local GROUPS = {
    device = "/manual/device",
    library = "/manual/library",
    appearance = "/manual/appearance",
    desktop = "/manual/desktop",
    games = "/manual/games",
    reader = "/manual/reader",
    system = "/manual/system",
    security = "/manual/security",
    maintenance = "/manual/maintenance",
}

--- 内置书源账号页；第三方没有条目就不挂指南。
local SOURCES = {
    ["local"] = "/manual/library/sources/local-host/local",
    kindle = "/manual/library/sources/local-host/kindle",
    moon = "/manual/library/sources/local-host/moon",
    legado = "/manual/library/sources/local-host/legado",
    kavita = "/manual/library/sources/local-host/kavita",
    bookorbit = "/manual/library/sources/local-host/bookorbit",
    wechat = "/manual/library/sources/novels/wechat",
    jdread = "/manual/library/sources/novels/jdread",
    fanqie = "/manual/library/sources/novels/fanqie",
    qimao = "/manual/library/sources/novels/qimao",
    jjwxc = "/manual/library/sources/novels/jjwxc",
    qidian = "/manual/library/sources/novels/qidian",
    qqreader = "/manual/library/sources/novels/qqreader",
    iread = "/manual/library/sources/novels/iread",
    changpei = "/manual/library/sources/novels/changpei",
    xiaoxiang = "/manual/library/sources/novels/xiaoxiang",
    dedao = "/manual/library/sources/novels/dedao",
    tadu = "/manual/library/sources/novels/tadu",
    shuqi = "/manual/library/sources/novels/shuqi",
    douban = "/manual/library/sources/novels/douban",
    netease = "/manual/library/sources/novels/netease",
    zhihu = "/manual/library/sources/novels/zhihu",
    ireader = "/manual/library/sources/novels/ireader",
    ["18ta"] = "/manual/library/sources/novels/18ta",
    copymanga = "/manual/library/sources/comics/copymanga",
    kuaikan = "/manual/library/sources/comics/kuaikan",
    zymk = "/manual/library/sources/comics/zymk",
}

local STORES = {
    zlib = "/manual/desktop/pages/zlib",
    opds = "/manual/desktop/pages/opds",
}

--- 拼完整 URL；空路径落到手册首页。
---@param path string|nil
---@return string
function Docs.url(path)
    if not path or path == "" then return Docs.BASE .. "/manual" end
    if path:sub(1, 4) == "http" then return path end
    if path:sub(1, 1) ~= "/" then path = "/" .. path end
    return Docs.BASE .. path
end

---@param id string|nil
---@return string|nil
function Docs.group(id)
    return id and GROUPS[id] or nil
end

---@param id string|nil
---@return string|nil
function Docs.source(id)
    return id and SOURCES[id] or nil
end

---@param id string|nil
---@return string|nil
function Docs.store(id)
    return id and STORES[id] or nil
end

--- 能开链接就开；墨水屏等开不了的出二维码。
---@param path string|nil
---@param title string|nil
function Docs.open(path, title)
    local url = Docs.url(path)
    local label = title or _("使用指南")
    local Hardware = require("device")
    if Hardware:canOpenLink() then
        Hardware:openLink(url)
    else
        require("ui.themes.widgets.qr"):new{ title = label, text = url, caption = url }:show()
    end
end

--- 设置页底部「查看指南」行；path 是 Docs.url 认的相对路径。
---@param path string
---@return fun(iw: number): table
function Docs.row(path)
    return function(iw)
        return require("ui.themes.widgets.row").widget({
            width = iw,
            kind = "nav",
            icon = "menu_book",
            title = _("查看指南"),
            subtitle = _("打开官网对应说明"),
            callback = function() Docs.open(path, _("使用指南")) end,
        })
    end
end

return Docs
