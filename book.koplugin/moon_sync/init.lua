--[[--
月读同步（WebDAV）。

WebDAV 连接只存在本地源的 webdav_* 上，静读天下客户端读的就是那一份。
这里只多记字体开关。阅读数据没有开关：书源自己有接口的走它的云，没有的由这一轮兜底。

书架流水线不改。地址非空时本地源照旧跑静读天下（它会合并本机目录）；
本模块在那之外传设置、字体、每本书的自定义设置，以及书源自己交过来的阅读数据。

@module koplugin.book.moon_sync
--]]

local Settings = require("utils.settings")
local Text = require("utils.text")

local MoonSync = {}

local SOURCE_ID = "local"
local DEFAULT_PATH = "Apps/Books"

--- 空目录就是静读天下的 Apps/Books。首尾斜杠不算另一条路径。
---@param value string|nil
---@return string
function MoonSync.path(value)
    local path = Text.trim(value or "")
    path = path:gsub("^/+", ""):gsub("/+$", "")
    if path == "" then return DEFAULT_PATH end
    return path
end

---@return table
function MoonSync.config()
    return Settings.get("moon_sync")
end

---@param cfg table|nil
---@return boolean
function MoonSync.configured(cfg)
    cfg = cfg or Settings.getSource(SOURCE_ID)
    return Text.trim(cfg.webdav_url or "") ~= ""
end

--- 远程配置页提交的是本地源字段名。只写本地源。换库沿用原来的 replaceWebdav。
--- 空目录和 Apps/Books 是同一条路径，这种提交不算改动。
---@param cfg table 本地源配置（就地改）
---@param values table<string, string> 本次提交的键
---@return boolean|nil changed false 表示没变化；nil 表示准备同步失败
---@return string|nil err
function MoonSync.applyRemote(cfg, values)
    local _ = require("gettext")
    local function pick(key)
        if values[key] ~= nil then return Text.trim(values[key]) end
        return cfg[key] or ""
    end
    local next_cfg = {
        webdav_url = pick("webdav_url"),
        webdav_username = pick("webdav_username"),
        webdav_password = pick("webdav_password"),
        webdav_path = pick("webdav_path"),
    }
    local function identity(url, path, username, password)
        return table.concat({
            Text.trim(url or ""),
            MoonSync.path(path),
            Text.trim(username or ""),
            Text.trim(password or ""),
        }, "\0")
    end
    if identity(cfg.webdav_url, cfg.webdav_path, cfg.webdav_username, cfg.webdav_password)
        == identity(next_cfg.webdav_url, next_cfg.webdav_path, next_cfg.webdav_username, next_cfg.webdav_password) then
        return false
    end
    local function save()
        cfg.webdav_url = next_cfg.webdav_url
        cfg.webdav_username = next_cfg.webdav_username
        cfg.webdav_password = next_cfg.webdav_password
        cfg.webdav_path = next_cfg.webdav_path
        Settings.saveSource(SOURCE_ID, cfg)
    end
    local library_before = table.concat({
        Text.trim(cfg.webdav_url or ""), MoonSync.path(cfg.webdav_path), Text.trim(cfg.webdav_username or ""),
    }, "\0")
    local library_after = table.concat({
        next_cfg.webdav_url, MoonSync.path(next_cfg.webdav_path), next_cfg.webdav_username,
    }, "\0")
    if library_before ~= library_after then
        if require("source.logout").replaceWebdav(save) == false then
            return nil, _("准备本地同步失败")
        end
        return true
    end
    save()
    require("source.registry").invalidate()
    return true
end

---@return boolean
function MoonSync.syncFonts()
    return MoonSync.config().sync_fonts == true
end

--- 源没有对应的上行方法，这一项才交给月读同步。有方法的走源自己的云。
--- 书架不在这里：有书架同步的源走自己的 syncBooksAsync。
---@param source table
---@return { progress: boolean, notes: boolean, stats: boolean }
function MoonSync.fallbackOf(source)
    return {
        progress = type(source.putProgressAsync) ~= "function",
        notes = type(source.pushNotesAsync) ~= "function",
        stats = type(source.pushStatsAsync) ~= "function",
    }
end

--- 启用的源里，至少有一项阅读数据要兜底的。
---@return { id: string, progress: boolean, notes: boolean, stats: boolean }[]
function MoonSync.readingPlan()
    local Registry = require("source.registry")
    local plan = {}
    for _idx, meta in ipairs(Registry.listEnabled()) do
        if meta.id:match("^[%w_%-]+$") then
            local source = Registry.resolve(meta.id)
            if source then
                local item = MoonSync.fallbackOf(source)
                item.id = meta.id
                if item.progress or item.notes or item.stats then plan[#plan + 1] = item end
            end
        end
    end
    return plan
end

---@param interactive boolean
---@return BookTask
local function taskSpec(interactive)
    local _ = require("gettext")
    return {
        key = "sync\0moon_sync",
        kind = "sync",
        title = _("月读同步"),
        restartable = true,
        retryable = function(result) return not result.ok end,
        run = function(report, done)
            return require("moon_sync.run").start(report, done, interactive)
        end,
    }
end

--- 用户在设置页点同步。
function MoonSync.start()
    local _ = require("gettext")
    if not MoonSync.configured() then
        require("ui.themes.widgets.toast"):new{ text = _("未配置 WebDAV"), timeout = 3 }:show()
        return
    end
    if not require("ui/network/manager"):isConnected() then
        require("ui.themes.widgets.toast"):new{ text = _("网络不可用，请先连接 Wi-Fi"), timeout = 3 }:show()
        return
    end
    require("workers.ui.task_dialog").start(taskSpec(true))
end

--- 启动、唤醒、联网：有连接就入队，不弹进度窗。
function MoonSync.kick()
    if not MoonSync.configured() then return end
    if not require("ui/network/manager"):isConnected() then return end
    require("workers.tasks").enqueue(taskSpec(false))
end

return MoonSync
