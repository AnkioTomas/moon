--[[--
kindle.koplugin（Kindle 书库依赖）在线更新：流程在 utils.plugin_update，这里只给目标描述。

版本先问 api.ankio.net 的 GitHub 转发，挂了回落 api.github.com。包固定是 armv7 版，Kindle 都能用。
装在月读同级插件目录；版本读它 _meta.lua 里的 version 字面量，不执行第三方文件。

@module source.kindle.plugin_update
--]]

local Updater = require("utils.plugin_update")
local _ = require("gettext")
local T = require("ffi/util").template

local NAME = "kindle.koplugin"

-- 本文件在 <plugins>/book.koplugin/source/kindle/，往上三级
local function pluginsDir()
    local source = debug.getinfo(1, "S").source:gsub("^@", "")
    return source:match("^(.*)/[^/]+/source/kindle/[^/]+$") or "plugins"
end

local Update = Updater.new({
    repo = "kaikozlov/kindle.koplugin",
    api_urls = {
        "https://api.ankio.net/gh/repos/kaikozlov/kindle.koplugin/releases/latest",
        "https://api.github.com/repos/kaikozlov/kindle.koplugin/releases/latest",
    },
    asset = function() return "kindle-koplugin-armv7.zip" end,
    archive = "kindle-plugin-update.zip",
    job = "kindle.update",
    installed = function()
        local file = io.open(pluginsDir() .. "/" .. NAME .. "/_meta.lua", "r")
        if not file then return nil end
        local meta = file:read("*a")
        file:close()
        return meta:match('version%s*=%s*"v?([^"]+)"')
    end,
    name = NAME,
    parent = pluginsDir,
    text = {
        checking = _("正在检查 kindle.koplugin 更新…"),
        downloading = _("正在下载 kindle.koplugin 更新…"),
        installing = _("正在安装 kindle.koplugin 更新…"),
        failed = _("kindle.koplugin 更新失败：%1"),
        title = _("更新 kindle.koplugin"),
        latest = function(release) return "kindle.koplugin " .. release.installed end,
        header = function(release)
            if release.installed then
                return T(_("发现 kindle.koplugin %1（当前 %2）。下载并完整替换插件目录？"), release.version, release.installed)
            end
            return T(_("未安装 kindle.koplugin。安装最新版 %1？"), release.version)
        end,
    },
})

return Update
