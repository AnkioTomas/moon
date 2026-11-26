--[[--
本地源设置 UI（书库目录由本模块自绘）。
读写：utils.settings.getSource / saveSource("local")。
WebDAV 连接在月读同步设置页。这一页分两节：书库、同步（上传书籍）。

@module koplugin.book.source.local.setting
--]]

local _ = require("l10n").get("source.local")

local SOURCE_ID = "local"

local Setting = {}

--- 设置行状态文案与高亮开关。
---@return string status, boolean status_on
function Setting.rowStatus()
    local cfg = require("utils.settings").getSource(SOURCE_ID)
    local path = cfg.path or ""
    if path ~= "" then
        return path, true
    end
    return _("未配置"), false
end

---@param plugin table|nil
---@return table[]
function Setting.sections(plugin)
    local Row = require("ui.themes.widgets.row")
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
    local function styleRow(iw)
        local Settings = require("utils.settings")
        local Layout = require("source.local.layout")
        local cfg = Settings.getSource(SOURCE_ID)
        local current = Layout.get(cfg.webdav_sync_style)
        local items = {}
        for i, layout in ipairs(Layout.all()) do
            items[i] = { value = layout.id, text = _(layout.label) }
        end
        return Row.widget({ width = iw, chevron = true, kind = "nav", icon = "cloud_sync",
            title = _("同步风格"),
            subtitle = _(current.detail),
            status = _(current.label), status_on = true,
            callback = function()
                require("ui.themes.widgets.list"):new{
                    title = _("同步风格"),
                    items = items,
                    current = current.id,
                    centered = true,
                    on_select = function(value)
                        if Layout.get(value).id ~= value then return end
                        -- 缺省不落盘，旧配置没有这个键就仍是缺省布局。
                        local next_style = nil
                        if value ~= Layout.default_id then next_style = value end
                        if cfg.webdav_sync_style == next_style then return end
                        cfg.webdav_sync_style = next_style
                        Settings.saveSource(SOURCE_ID, cfg)
                        repaint()
                    end,
                }:show()
            end })
    end
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
        { title = _("书库"), rows = { localPathRow, folderCategoryRow } },
        { title = _("同步"), rows = { uploadRow, styleRow } },
    }
end

---@param plugin table|nil
function Setting.rows(plugin)
    local rows = {}
    for _idx, section in ipairs(Setting.sections(plugin)) do
        for _row_idx, row in ipairs(section.rows) do
            rows[#rows + 1] = row
        end
    end
    return rows
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
---@param desktop table|nil 有桌面时换目录先收成待重匹配并强制重扫；没有则 Registry.reload
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
        local next_path = Text.rtrimSlashes(Text.rtrim(path))
        local function save()
            -- 换目录：旧根书先下架但保留记录，随后扫描按 md5 迁到新路径；无法再匹配的墓碑才撕掉。
            if previous ~= next_path and previous ~= ""
                and not require("book.store").stashOldRoot(previous, next_path) then
                require("ui.themes.widgets.toast"):new{ text = _("准备书库记录失败"), timeout = 3 }:show()
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
        -- 只是分类的话不必换根；换根后同一本书移进新目录再扫，阅读记录会跟过来。
        if previous ~= next_path and previous ~= "" then
            local relocate = _("只是给书分类的话，请留在当前书库目录下建文件夹（最多两层，并打开「按文件夹分类」）。换目录后，把同一本书移进新目录再扫描，阅读记录会跟过来。")
            warning = warning and (warning .. "\n\n" .. relocate) or relocate
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
