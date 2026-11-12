--[[--
月读在线更新：流程在 utils.plugin_update，这里只给月读的目标描述与自动检查。

自动检查只提示可用版本，不会自动下载或安装。
先解压到同级暂存目录，换位失败回滚，不留半替换的 book.koplugin/。版本文件必须叫 bookversion.lua（version.lua 与 KOReader 冲突）。

@module koplugin.book.features.update
--]]

local MoonSettings = require("utils.settings")
local Updater = require("utils.plugin_update")
local lfs = require("libs/libkoreader-lfs")
local _ = require("gettext")
local T = require("ffi/util").template

local CHECK_INTERVAL = 24 * 60 * 60

-- api.ankio.net 是 GitHub API 的转发，挂了（522/552）就回落直连 GitHub。
local Update = Updater.new({
    repo = "AnkioTomas/moon",
    api_urls = {
        "https://api.ankio.net/gh/repos/AnkioTomas/moon/releases/latest",
        "https://api.github.com/repos/AnkioTomas/moon/releases/latest",
    },
    asset = function(tag) return "book.koplugin-" .. tag .. ".zip" end,
    archive = "plugin-update.zip",
    job = "plugin.update",
    digest_required = true,
    installed = function() return require("bookversion") end,
    name = "book.koplugin",
    parent = function(plugin_root) return plugin_root:match("^(.*)/[^/]+$") end,
    -- 空壳包不能盖掉正在跑的月读（上传的包可以是别的插件，不查）
    verify = function(name, staging)
        if name == "book.koplugin"
            and lfs.attributes(staging .. "/" .. name .. "/bookversion.lua", "mode") ~= "file" then
            return "not a moon plugin archive"
        end
    end,
    on_checked = function()
        local settings = MoonSettings.get("features.update")
        settings.update_last_checked_at = os.time()
        MoonSettings.save("features.update", settings)
    end,
    text = {
        checking = _("正在检查月读更新…"),
        downloading = _("正在下载月读更新…"),
        installing = _("正在安装月读更新…"),
        failed = _("月读更新失败：%1"),
        title = _("更新日志"),
        latest = function() return require("bookversion") end,
        header = function(release, force)
            if force and not release.available then
                return T(_("强制重装月读 %1（当前已是此版本）。下载并完整替换插件目录？"), release.version)
            end
            return T(_("发现月读 %1（当前 %2）。下载并完整替换插件目录？"), release.version, release.installed)
        end,
    },
})

Update.onExit = function() Update:cancel() end

--- 按 24 小时间隔静默检查；只有发现新版本才弹窗。没连网不发请求，等下次唤醒。
---@param plugin_root string
function Update.autoCheck(plugin_root)
    local settings = MoonSettings.get("features.update")
    if not settings.auto_check then return end
    if os.time() - settings.update_last_checked_at < CHECK_INTERVAL then return end
    if not require("ui/network/manager"):isConnected() then return end
    Update:check(function(release)
        if settings.auto_check and release and release.available then Update:prompt(release, plugin_root) end
    end)
end

-- 扩展点登记（features 加载器 require 本模块时执行一次；见 utils/extension.lua）。
-- 插件更新检查走桌面回到前台，不在插件 init / 网络回调里抢跑。
require("utils.extension").add("desktop.activated", function(desk)
    local root = desk.plugin and desk.plugin.path
    if root then Update.autoCheck(root) end
    require("features.update.resources").autoCheck()
end)

return Update
