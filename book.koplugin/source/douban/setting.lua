--[[--
豆瓣阅读账号：只用豆瓣阅读 App 扫码。登录态是 read.douban.com 的 Cookie 和用户编号。

@module source.douban.setting
--]]

require("l10n").apply()
local _ = require("gettext")

local SOURCE_ID = "douban"
local Setting = {}

---@return boolean
local function loggedIn()
    return require("source.douban.client").loggedIn()
end

---@param user { id: string, name: string }
local function save(user)
    require("source.auth").ok(SOURCE_ID)
    require("source.registry").reload()
    local name = user.name ~= "" and user.name or _("已登录")
    require("ui.themes.widgets.toast"):new{ text = name, timeout = 2 }:show()
end

function Setting.rowTitle()
    return _("豆瓣阅读账号")
end

---@return string, boolean
function Setting.rowStatus()
    local on = loggedIn()
    return on and _("已登录") or _("未登录 · 点此扫码"), on
end

function Setting.open()
    require("ui/network/manager"):runWhenConnected(function()
        require("source.douban.qrlogin"):new(save):start()
    end)
end

---@return table[]
function Setting.rows()
    local Row = require("ui.themes.widgets.row")
    local rows = {
        function(iw)
            local status, status_on = Setting.rowStatus()
            return Row.widget({
                width = iw, chevron = true, kind = "nav", icon = "account_circle",
                title = Setting.rowTitle(),
                subtitle = _("打开豆瓣阅读 App，扫屏幕上的二维码"),
                status = status, status_on = status_on,
                callback = function() Setting.open() end,
            })
        end,
    }
    rows[#rows + 1] = require("source.review_setting").row(SOURCE_ID)
    if loggedIn() then
        rows[#rows + 1] = require("source.logout").row(SOURCE_ID, _("确定退出豆瓣阅读账号？"), function()
            local settings = require("utils.settings")
            local cfg = settings.getSource(SOURCE_ID)
            cfg.cookie, cfg.user_id, cfg.name, cfg.logged_in = nil, nil, nil, nil
            settings.saveSource(SOURCE_ID)
            require("source.douban.client").reset()
        end)
    end
    return rows
end

Setting.login = Setting.open

return Setting
