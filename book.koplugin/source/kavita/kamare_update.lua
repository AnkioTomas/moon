--[[--
kamare 增强版在线更新：流程在 utils.plugin_update，这里只给 kamare 的目标描述。

版本和 digest 先问 api.ankio.net 的 GitHub 转发，挂了回落 api.github.com。
kamare 已装就地替换，没装装进月读同级插件目录。装好立即重启：旧模块还在内存里。

@module source.kavita.kamare_update
--]]

local Cache = require("source.kavita.cache")
local Updater = require("utils.plugin_update")
local _ = require("gettext")
local T = require("ffi/util").template

local NAME = "kamare.koplugin"

local Update = Updater.new({
    repo = "backtracker/kamare.koplugin",
    api_urls = {
        "https://api.ankio.net/gh/repos/backtracker/kamare.koplugin/releases/latest",
        "https://api.github.com/repos/backtracker/kamare.koplugin/releases/latest",
    },
    asset = function() return "kamare.koplugin.zip" end,
    archive = "kamare-update.zip",
    job = "kamare.update",
    installed = function()
        local probe = Cache.probe()
        return probe.ok and probe.version or nil
    end,
    name = NAME,
    parent = function(plugin) return Cache.pluginsDir(plugin and plugin.path) end,
    text = {
        checking = _("正在检查 kamare 更新…"),
        downloading = _("正在下载 kamare 更新…"),
        installing = _("正在安装 kamare 更新…"),
        failed = _("kamare 更新失败：%1"),
        title = _("更新 kamare"),
        latest = function(release) return "kamare " .. release.installed end,
        header = function(release)
            if release.installed then
                return T(_("发现 kamare %1（当前 %2）。下载并完整替换插件目录？"), release.version, release.installed)
            end
            return T(_("当前未安装可用的 kamare 增强版。安装最新版 %1？"), release.version)
        end,
    },
})

return Update
