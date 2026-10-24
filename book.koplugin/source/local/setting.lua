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
    --- 按文件夹分类（默认开）：切换后重扫一次，分类 / 系列随之刷新。
    local function folderCategoryRow(iw)
        local Settings = require("utils.settings")
        local cfg = Settings.getSource(SOURCE_ID)
        local on = cfg.folder_category ~= false
        return Row.widget({ width = iw, chevron = false, kind = "toggle", icon = "folder",
            title = _("按文件夹分类"), subtitle = _("第一层文件夹作为分类，第二层作为系列"),
            status = on and _("开") or _("关"), status_on = on,
            callback = function()
                cfg.folder_category = not on
                Settings.saveSource(SOURCE_ID, cfg)
                -- 关闭：目录派生的分类 / 系列一次清掉，之后只由手动编辑设置；打开：下次扫盘按目录重算。
                if on then require("book.books_db").clearCategories(SOURCE_ID) end
                -- 重建源实例并通知桌面，桌面重开时照常后台扫盘（指纹快路径），分类 / 系列不一致会整轮写库。
                require("source.registry").reload()
            end })
    end
    --- 关闭后本地加入书架的书不上传到各源的云书架，只同步进度、笔记和统计。
    local function pushShelfRow(iw)
        local Settings = require("utils.settings")
        local conf = Settings.get("source")
        local on = conf.push_local_shelf
        return Row.widget({ width = iw, chevron = false, kind = "toggle", icon = "cloud_upload",
            title = _("上传本地加入书架的书"),
            subtitle = _("关闭后只同步进度、笔记和统计，不把本地加架的书推到云书架"),
            status = on and _("开") or _("关"), status_on = on,
            callback = function()
                conf.push_local_shelf = not on
                Settings.save("source", conf)
            end })
    end
    return {
        localPathRow,
        folderCategoryRow,
        pushShelfRow,
        row("webdav_url", _("WebDAV 地址"), false, "dns"),
        row("webdav_username", _("WebDAV 用户名"), false, "person"),
        row("webdav_password", _("WebDAV 密码"), true, "key"),
        row("webdav_path", _("WebDAV 目录"), false, "folder"),
        testRow,
    }
end

--- 是否 Kindle 默认的 documents 目录（忽略结尾斜杠）。
---@param path string|nil
---@return boolean
function Setting.isKindleDocuments(path)
    return type(path) == "string" and path:gsub("/+$", "") == "/mnt/us/documents"
end

--- 列出可作书库的子目录名（排序，跳过 .sdr）；目录不可读（如 Android 的 /storage）返回 nil, err。
---@param path string
---@return string[]|nil, string|nil
function Setting.subdirs(path)
    local lfs = require("libs/libkoreader-lfs")
    local ok, iter, state = pcall(lfs.dir, path)
    if not ok then return nil, tostring(iter) end
    local names = {}
    for name in iter, state do
        -- KOReader 的 .sdr 边车目录不是书库目录，不列出
        local full = path == "/" and "/" .. name or path .. "/" .. name
        if name ~= "." and name ~= ".." and name:sub(-4) ~= ".sdr"
            and lfs.attributes(full, "mode") == "directory" then
            names[#names + 1] = name
        end
    end
    table.sort(names)
    return names
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
        start_path = type(home) == "string" and home or nil
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
        local names, err = Setting.subdirs(path)
        if not names then
            require("utils.log").warn("book local picker skip unreadable dir", path, err)
            return nil
        end
        local function save()
            cfg.path = path
            MoonSettings.saveSource(SOURCE_ID, cfg)
            require("ui.themes.widgets.toast"):new{ text = _("已保存"), timeout = 2 }:show()
            require("source.registry").reload()
        end
        -- Kindle 的 documents 先劝一句：列表不关，「重新选择」接着挑子目录
        local warn = Setting.isKindleDocuments(path)
        local items = { { text = _("使用此目录"), icon = "check", keep_open = warn, callback = function()
            if not warn then return save() end
            require("ui.themes.widgets.confirm"):new{
                text = _("这是 Kindle 的 documents 目录，里面有系统文件、.sdr 边车和 Kindle 书库的书，扫描会慢且杂。建议在里面新建一个子文件夹专门放书。"),
                ok_text = _("仍然使用"),
                cancel_text = _("重新选择"),
                ok_callback = function()
                    list:close()
                    save()
                end,
            }:show()
        end } }
        local parent = path ~= "/" and (path:match("^(.*)/[^/]+$") or "")
        if parent == "" then parent = "/" end
        -- Android 的 /storage 等上级目录不可读：读不了就不给「..」，停在可读的根
        if parent and Setting.subdirs(parent) then
            items[#items + 1] = { text = "..", icon = "arrow_upward", keep_open = true,
                callback = function() enter(parent) end }
        end
        for _idx, name in ipairs(names) do
            items[#items + 1] = { text = name, icon = "folder", keep_open = true,
                callback = function() enter(join(path, name)) end }
        end
        return items
    end
    ---@param path string
    enter = function(path)
        -- 读不了就原地不动（日志在 entries 里）
        local items = entries(path)
        if not items then return end
        list.subtitle = path
        list.page = 1
        list:setItems(items)
    end
    if not Setting.subdirs(start_path) then start_path = "/" end
    list = List:new{ title = _("选择书库目录"), subtitle = start_path, items = entries(start_path) or {} }
    list:show()
end

return Setting
