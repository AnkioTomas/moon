--[[--
本地源设置 UI（书库目录由本模块自绘）。
读写：utils.settings.getSource / saveSource("local")

@module koplugin.book.source.local.setting
--]]

local _ = require("l10n").get("source.local")

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
    local function repaint()
        local desktop = plugin and plugin.desktop
        if desktop and desktop.settings_overlay then desktop.settings_overlay:updateView() end
    end
    local function localPathRow(iw)
        local path = require("utils.settings").getSource(SOURCE_ID).path or ""
        return Row.widget({ width = iw, chevron = true, kind = "nav", icon = "folder",
            title = _("本地书库目录"), status = path ~= "" and path or _("未设置"), status_on = path ~= "",
            -- 跟「按文件夹分类」一样：有桌面就强制重扫，不要 Registry.reload（会关设置叠层）。
            callback = function()
                Setting.open(function() repaint() end, plugin and plugin.desktop)
            end })
    end
    --- WebDAV 库身份：地址 / 目录 / 用户。任一项变了旧 webdav:// 书必须撕掉（会撞相对路径）。
    local function webdavFingerprint(cfg)
        return table.concat({
            Text.trim(cfg.webdav_url or ""),
            Text.trim(cfg.webdav_path or ""),
            Text.trim(cfg.webdav_username or ""),
        }, "\0")
    end
    local function edit(key, title, password)
        local cfg = require("utils.settings").getSource(SOURCE_ID)
        require("ui.themes.widgets.input"):new{
            title = title,
            fields = { { text = tostring(cfg[key] or ""), text_type = password and "password" or nil } },
            ok_text = _("保存"),
            callback = function(text)
                local before = webdavFingerprint(cfg)
                local next_cfg = require("util").tableDeepCopy(cfg)
                next_cfg[key] = Text.trim(text)
                local function save()
                    cfg[key] = next_cfg[key]
                    require("utils.settings").saveSource(SOURCE_ID, cfg)
                end
                if before ~= webdavFingerprint(next_cfg) then
                    if not require("source.logout").replaceWebdav(save) then
                        require("ui.themes.widgets.toast"):new{ text = _("清除本地记录失败"), timeout = 3 }:show()
                        return
                    end
                else
                    save()
                    require("source.registry").invalidate()
                end
                repaint()
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
                -- cfg 是源实例的共享表，改完即可见。只重扫本地书，不要 Registry.reload：
                -- 那会广播换源，设置页把叠层全部关掉，人还停在这一行上就被扔回设置根页。
                local desktop = plugin and plugin.desktop
                if desktop and not desktop.closed then require("desktop.sync").rescan(desktop) end
                repaint()
            end })
    end
    --- 上传本地书到 WebDAV（默认开）；关了只同步进度、笔记和统计，本地书留在本地。
    local function uploadRow(iw)
        local Settings = require("utils.settings")
        local cfg = Settings.getSource(SOURCE_ID)
        local on = cfg.webdav_upload_local ~= false
        return Row.widget({ width = iw, chevron = false, kind = "toggle", icon = "cloud_upload",
            title = _("上传本地书到 WebDAV"),
            subtitle = _("关闭后只同步进度、笔记和统计，不上传本地书籍文件"),
            status = on and _("开") or _("关"), status_on = on,
            callback = function()
                cfg.webdav_upload_local = not on
                Settings.saveSource(SOURCE_ID, cfg)
                repaint()
            end })
    end
    return {
        localPathRow,
        folderCategoryRow,
        uploadRow,
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

--- 路径是否含不允许的字符。允许英文、数字、下划线、连字符和斜杠；nil 不算。
---@param path string|nil
---@return boolean
function Setting.hasNonAlnum(path)
    return type(path) == "string" and path:find("[^A-Za-z0-9_/-]") ~= nil
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
---@param on_saved fun()|nil 保存目录后回调（书城下载前引导配置用）
---@param desktop table|nil 有桌面时换目录立刻下架旧根书并强制重扫；没有则 Registry.reload
function Setting.open(on_saved, desktop)
    local lfs = require("libs/libkoreader-lfs")
    local Text = require("utils.text")
    local List = require("ui.themes.widgets.list")
    local MoonSettings = require("utils.settings")
    local cfg = MoonSettings.getSource(SOURCE_ID)
    local previous = Text.rtrimSlashes(Text.rtrim(cfg.path))
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
            local next_path = Text.rtrimSlashes(Text.rtrim(path))
            -- 换目录 = 换库：旧根书连同进度 / 笔记 / 统计整本撕掉（软下架会留在「最近阅读」里）。
            if previous ~= next_path and not require("book.store").forgetOldRoot(previous, next_path) then
                require("ui.themes.widgets.toast"):new{ text = _("清除本地记录失败"), timeout = 3 }:show()
                return
            end
            cfg.path = path
            MoonSettings.saveSource(SOURCE_ID, cfg)
            require("ui.themes.widgets.toast"):new{ text = _("已保存"), timeout = 2 }:show()
            if desktop and not desktop.closed then
                require("desktop.sync").rescan(desktop)
            else
                require("source.registry").reload()
            end
            if type(on_saved) == "function" then on_saved() end
        end
        -- 先劝一句再决定：列表不关，「重新选择」接着挑。documents 优先于字符提醒。
        local warning
        if Setting.isKindleDocuments(path) then
            warning = _("这是 Kindle 的 documents 目录，里面有系统文件、.sdr 边车和 Kindle 书库的书，扫描会慢且杂。建议在里面新建一个子文件夹专门放书。")
        elseif Setting.hasNonAlnum(path) then
            warning = _("这个路径含有英文和数字以外的字符。建议换成只含英文和数字的目录。")
        end
        local items = { { text = _("使用此目录"), icon = "check", keep_open = warning ~= nil, callback = function()
            if not warning then return save() end
            require("ui.themes.widgets.confirm"):new{
                text = warning,
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
