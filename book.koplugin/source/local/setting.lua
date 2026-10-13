--[[--
本地源设置 UI（书库目录由本模块自绘）。
读写：utils.settings.getSource / saveSource("local")

@module koplugin.book.source.local.setting
--]]

local _ = require("gettext")

local SOURCE_ID = "local"

local Setting = {}

--- 设置行状态文案与高亮开关。
---@return string status, boolean status_on
function Setting.rowStatus()
    local cfg = require("utils.settings").getSource(SOURCE_ID)
    if type(cfg.webdav_url) == "string" and cfg.webdav_url ~= "" then
        return "WebDAV · " .. cfg.webdav_url, true
    end
    local path = cfg.path or ""
    if path ~= "" then
        return path, true
    end
    return _("未配置"), false
end

---@param plugin table|nil
function Setting.rows(plugin)
    local Row = require("ui.themes.widgets.row")
    local Text = require("utils.text")
    local function localPathRow(iw)
        local path = require("utils.settings").getSource(SOURCE_ID).path or ""
        return Row.widget({ width = iw, chevron = true, kind = "nav", icon = "folder",
            title = _("本地书库目录"), status = path ~= "" and path or _("未设置"), status_on = path ~= "",
            callback = Setting.open })
    end
    local function edit(key, title, password)
        local cfg = require("utils.settings").getSource(SOURCE_ID)
        require("ui.themes.widgets.input"):new{
            title = title,
            fields = { { text = tostring(cfg[key] or ""), text_type = password and "password" or nil } },
            ok_text = _("保存"),
            callback = function(text)
                cfg[key] = Text.trim(text)
                require("utils.settings").saveSource(SOURCE_ID, cfg)
                require("source.registry").invalidate()
                if plugin and plugin.desktop then plugin.desktop:updateView() end
            end,
        }:show()
    end
    local function row(key, title, password, icon)
        return function(iw)
            local value = require("utils.settings").getSource(SOURCE_ID)[key] or ""
            return Row.widget({ width = iw, chevron = true, kind = "nav", icon = icon, title = title,
                status = value ~= "" and (password and "******" or value) or _("未设置"),
                status_on = value ~= "", callback = function() edit(key, title, password) end })
        end
    end
    local function testRow(iw)
        return Row.widget({ width = iw, chevron = false, kind = "action", icon = "network_check", title = _("测试 WebDAV 连接"),
            subtitle = _("写入、读回并删除一个测试文件"), callback = function()
                local waiting = require("ui.themes.widgets.progress_dialog"):new{
                    title = _("测试 WebDAV 连接"), text = _("正在测试 WebDAV 连接…"), dismissable = false,
                }
                waiting:show()
                local client = require("source.local.client").new(require("utils.settings").getSource(SOURCE_ID))
                client:testWebdavAsync(function(ok, err)
                    waiting:close()
                    require("ui.themes.widgets.toast"):new{ text = ok and _("WebDAV 连接正常，可读写") or err, timeout = ok and 2 or nil }:show()
                end)
            end })
    end
    return {
        localPathRow,
        row("webdav_url", _("WebDAV 地址"), false, "dns"),
        row("webdav_username", _("WebDAV 用户名"), false, "person"),
        row("webdav_password", _("WebDAV 密码"), true, "key"),
        row("webdav_path", _("WebDAV 目录"), false, "folder"),
        testRow,
    }
end

--- 目录选择列表：逐层浏览（原地换项），首行「使用此目录」确认当前目录。
function Setting.open()
    local lfs = require("libs/libkoreader-lfs")
    local List = require("ui.themes.widgets.list")
    local MoonSettings = require("utils.settings")
    local cfg = MoonSettings.getSource(SOURCE_ID)
    local start_path = cfg.path
    if type(start_path) ~= "string" or start_path == "" then
        local home = G_reader_settings:readSetting("home_dir")
        start_path = type(home) == "string" and home:match("^(.*)/[^/]+/?$") or nil
        if not start_path or start_path == "" then
            local ffiUtil = require("ffi/util")
            local data = require("datastorage"):getFullDataDir()
            local resolved = ffiUtil.realpath(data) or data
            local dir = ffiUtil.dirname(type(resolved) == "string" and resolved or data)
            start_path = type(dir) == "string" and dir or data
        end
    end
    if lfs.attributes(start_path, "mode") ~= "directory" then start_path = "/" end

    local list
    ---@param dir string
    ---@param name string
    ---@return string
    local function join(dir, name)
        return dir == "/" and "/" .. name or dir .. "/" .. name
    end
    local enter
    --- 一层目录的列表项：确认行、上一级（根目录没有）、按名排序的子目录。
    ---@param path string
    ---@return table[]
    local function entries(path)
        local items = { { text = _("使用此目录"), icon = "check", callback = function()
            cfg.path = path
            MoonSettings.saveSource(SOURCE_ID, cfg)
            require("ui.themes.widgets.toast"):new{ text = _("已保存"), timeout = 2 }:show()
            require("source.registry").reload()
        end } }
        if path ~= "/" then
            local parent = path:match("^(.*)/[^/]+$")
            items[#items + 1] = { text = "..", icon = "arrow_upward", keep_open = true,
                callback = function() enter(parent ~= "" and parent or "/") end }
        end
        local names = {}
        for name in lfs.dir(path) do
            if name ~= "." and name ~= ".." and lfs.attributes(join(path, name), "mode") == "directory" then
                names[#names + 1] = name
            end
        end
        table.sort(names)
        for _idx, name in ipairs(names) do
            items[#items + 1] = { text = name, icon = "folder", keep_open = true,
                callback = function() enter(join(path, name)) end }
        end
        return items
    end
    ---@param path string
    enter = function(path)
        list.subtitle = path
        list.page = 1
        list:setItems(entries(path))
    end
    list = List:new{ title = _("选择书库目录"), subtitle = start_path, items = entries(start_path) }
    list:show()
end

return Setting
