--[[--
月读同步设置页。WebDAV 连接写本地源的 webdav_*。字体开关写 moon_sync。
上传书籍在本地书源账号里。阅读数据没有开关。

@module koplugin.book.moon_sync.page
--]]

local _ = require("gettext")
local Text = require("utils.text")

local Page = {}

local SOURCE_ID = "local"

---@param cfg table
---@return string
local function fingerprint(cfg)
    return table.concat({
        Text.trim(cfg.webdav_url or ""),
        require("moon_sync").path(cfg.webdav_path),
        Text.trim(cfg.webdav_username or ""),
    }, "\0")
end

---@param desktop table|nil
local function repaint(desktop)
    if desktop and desktop.settings_overlay then desktop.settings_overlay:updateView() end
end

--- 设置页分节。
---@param desktop table|nil
---@return table[]
function Page.sections(desktop)
    local MoonSync = require("moon_sync")
    local Settings = require("utils.settings")
    local Row = require("ui.themes.widgets.row")

    local function edit(key, title, password, present)
        local cfg = Settings.getSource(SOURCE_ID)
        local raw = tostring(cfg[key] or "")
        require("ui.themes.widgets.input"):new{
            title = title,
            fields = { { text = present and present(raw) or raw, text_type = password and "password" or nil } },
            ok_text = _("保存"),
            callback = function(text)
                local next_value = Text.trim(text)
                local before = fingerprint(cfg)
                local next_cfg = {
                    webdav_url = cfg.webdav_url,
                    webdav_path = cfg.webdav_path,
                    webdav_username = cfg.webdav_username,
                }
                next_cfg[key] = next_value
                local function save()
                    cfg[key] = next_value
                    Settings.saveSource(SOURCE_ID, cfg)
                end
                if before ~= fingerprint(next_cfg) then
                    if not require("source.logout").replaceWebdav(save) then
                        require("ui.themes.widgets.toast"):new{ text = _("准备本地同步失败"), timeout = 3 }:show()
                        return
                    end
                else
                    save()
                    require("source.registry").invalidate()
                end
                repaint(desktop)
            end,
        }:show()
    end

    local function valueRow(key, title, password, icon, present)
        return function(iw)
            local value = Settings.getSource(SOURCE_ID)[key] or ""
            local shown = present and present(value) or value
            return Row.widget({
                width = iw, chevron = true, kind = "nav", icon = icon, title = title,
                status = shown ~= "" and (password and "******" or shown) or _("未设置"),
                status_on = shown ~= "",
                callback = function() edit(key, title, password, present) end,
            })
        end
    end

    local function testRow(iw)
        return Row.widget({
            width = iw, chevron = false, kind = "action", icon = "network_check",
            title = _("测试 WebDAV 连接"),
            subtitle = _("写入、读回并删除一个测试文件"),
            callback = function()
                local waiting = require("ui.themes.widgets.progress_dialog"):new{
                    title = _("测试 WebDAV 连接"),
                    text = _("正在测试 WebDAV 连接…"),
                    dismissable = false,
                }
                waiting:show()
                local client = require("source.local.client").new(Settings.getSource(SOURCE_ID))
                client:testWebdavAsync(function(ok, err)
                    waiting:close()
                    require("ui.themes.widgets.toast"):new{
                        text = ok and _("WebDAV 连接正常，可读写") or err,
                        timeout = ok and 2 or nil,
                    }:show()
                end)
            end,
        })
    end

    local function toggleRow(icon, title, subtitle, read, write)
        return function(iw)
            local on = read()
            return Row.widget({
                width = iw, chevron = false, kind = "toggle", icon = icon, title = title, subtitle = subtitle,
                status = on and _("开") or _("关"), status_on = on,
                callback = function()
                    write(not on)
                    repaint(desktop)
                end,
            })
        end
    end

    return {
        {
            title = _("连接"),
            rows = {
                valueRow("webdav_url", _("WebDAV 地址"), false, "dns"),
                valueRow("webdav_username", _("WebDAV 用户名"), false, "person"),
                valueRow("webdav_password", _("WebDAV 密码"), true, "key"),
                valueRow("webdav_path", _("WebDAV 目录"), false, "folder", MoonSync.path),
                testRow,
            },
        },
        {
            title = _("同步内容"),
            rows = {
                toggleRow("font_download", _("同步字体"), _("把本机字体目录放进 WebDAV"), function()
                    return MoonSync.syncFonts()
                end, function(on)
                    local sync = MoonSync.config()
                    sync.sync_fonts = on
                    Settings.save("moon_sync")
                end),
                function(iw)
                    return Row.widget({
                        width = iw, chevron = false, kind = "action", icon = "cloud_sync",
                        title = _("立即同步"),
                        subtitle = _("本地书按静读天下同步，其余数据放进 .moon-koreader"),
                        callback = function() MoonSync.start() end,
                    })
                end,
            },
        },
    }
end

return Page
