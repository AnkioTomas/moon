--[[--
Kavita 源设置 UI
读写：utils.settings.getSource / saveSource("kavita")

@module koplugin.book.source.kavita.setting
--]]

local Text = require("utils.text")
local _ = require("gettext")

local SOURCE_ID = "kavita"

local Setting = {}

---@param plugin table|nil
---@param key string
---@param title string
---@param hint string
---@param password boolean|nil
---@param normalize fun(value: string|nil): string
---@param icon string|nil
local function field(plugin, key, title, hint, password, normalize, icon)
    local UIManager = require("ui/uimanager")
    local InputDialog = require("ui/widget/inputdialog")
    local cfg = require("utils.settings").getSource(SOURCE_ID)
    local dialog
    dialog = InputDialog:new{
        title = title, input = tostring(cfg[key] or ""), input_hint = hint,
        text_type = password and "password" or nil,
        buttons = {{
            { text = _("取消"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("保存"), callback = function()
                cfg[key] = normalize(dialog:getInputText())
                require("utils.settings").saveSource(SOURCE_ID, cfg)
                require("source.registry").invalidate()
                UIManager:close(dialog)
                if plugin and plugin.onSourceChanged then plugin:onSourceChanged() end
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

---@param plugin table|nil
---@param key string
---@param title string
---@param hint string
---@param password boolean|nil
---@param normalize fun(value: string|nil): string
---@param icon string|nil
---@return fun(iw: number): table
local function fieldRow(plugin, key, title, hint, password, normalize, icon)
    return function(iw)
        local value = require("utils.settings").getSource(SOURCE_ID)[key] or ""
        return require("ui.components.settingrow").build(iw, {
            kind = "nav", icon = icon or "edit", title = title,
            status = value ~= "" and (password and "******" or value) or _("未设置"),
            status_on = value ~= "", callback = function()
                field(plugin, key, title, hint, password, normalize, icon)
            end,
        })
    end
end

---@param plugin table|nil
local function libraryRow(plugin)
    return function(iw)
        local cfg = require("utils.settings").getSource(SOURCE_ID)
        local libraries = cfg.libraries or {}
        local count = 0
        for _ in pairs(libraries) do count = count + 1 end
        return require("ui.components.settingrow").build(iw, {
            kind = "nav", icon = "library_books", title = _("书库"),
            status = count > 0 and tostring(count) or _("未设置"),
            status_on = count > 0, callback = function()
                local UIManager = require("ui/uimanager")
                local InfoMessage = require("ui/widget/infomessage")
                local Popup = require("ui.views.popup")
                local waiting = InfoMessage:new{ text = _("正在加载书库列表…") }
                UIManager:show(waiting)
                local client = require("source.kavita.client").new(cfg)
                client:listLibrariesAsync(function(data, err)
                    UIManager:close(waiting)
                    if not data then
                        UIManager:show(InfoMessage:new{ text = err or _("加载书库列表失败"), timeout = 3 })
                        return
                    end
                    local items = {}
                    for _, lib in ipairs(data) do
                        local id = tostring(lib.id)
                        items[#items + 1] = {
                            text = lib.name or id,
                            value = id,
                            checked = libraries[id] == true,
                        }
                    end
                    Popup.list{
                        title = _("选择书库"),
                        select_mode = "multi",
                        items = items,
                        on_toggle = function(id, on)
                            if on then libraries[id] = true else libraries[id] = nil end
                        end,
                        close_callback = function()
                            cfg.libraries = libraries
                            require("utils.settings").saveSource(SOURCE_ID, cfg)
                            require("source.registry").invalidate()
                            if plugin and plugin.onSourceChanged then plugin:onSourceChanged() end
                        end,
                    }
                end)
            end,
        })
    end
end

---@param plugin table|nil
local function heartbeatRow(plugin)
    return function(iw)
        local cfg = require("utils.settings").getSource(SOURCE_ID)
        local interval = tonumber(cfg.heartbeat_interval) or 30
        return require("ui.components.settingrow").build(iw, {
            kind = "nav", icon = "timer", title = _("心跳间隔"),
            status = interval > 0 and tostring(interval) or _("关"),
            status_on = interval > 0, callback = function()
                field(plugin, "heartbeat_interval", _("心跳间隔"), "30", false, function(v)
                    local n = tonumber(Text.trim(v))
                    if not n or n < 0 then return "30" end
                    return tostring(math.floor(n))
                end, "timer")
            end,
        })
    end
end

---@param plugin table|nil
local function testRow(plugin)
    return function(iw)
        return require("ui.components.settingrow").build(iw, {
            kind = "action", icon = "network_check", title = _("测试连接"),
            subtitle = _("探测 Kavita 版本"), callback = function()
                local UIManager = require("ui/uimanager")
                local InfoMessage = require("ui/widget/infomessage")
                local waiting = InfoMessage:new{ text = _("正在测试连接…") }
                UIManager:show(waiting)
                local cfg = require("utils.settings").getSource(SOURCE_ID)
                local client = require("source.kavita.client").new(cfg)
                client:testVersionAsync(function(ok, version, err)
                    UIManager:close(waiting)
                    if ok then
                        local parsed = require("source.kavita.client").parseVersion(version)
                        local min = require("source.kavita.client").MIN_VERSION
                        if parsed and not require("source.kavita.client").versionGte(parsed, min) then
                            UIManager:show(InfoMessage:new{
                                text = _("Kavita 版本过低，需 0.9.0 及以上"),
                                timeout = 3,
                            })
                        else
                            UIManager:show(InfoMessage:new{
                                text = _("连接正常，版本 %1"):format(version),
                                timeout = 2,
                            })
                        end
                    else
                        UIManager:show(InfoMessage:new{
                            text = err or _("连接失败"),
                            timeout = 3,
                        })
                    end
                end)
            end,
        })
    end
end

---@param plugin table|nil
---@return table[]
function Setting.rows(plugin)
    return {
        fieldRow(plugin, "base_url", _("服务器地址"), "https://host:port/kavita", false, Text.rtrimSlashes, "dns"),
        fieldRow(plugin, "api_key", _("API Key"), "", true, Text.stripWhitespace, "key"),
        libraryRow(plugin),
        heartbeatRow(plugin),
        testRow(plugin),
    }
end

---@return string, boolean
function Setting.rowStatus()
    local cfg = require("utils.settings").getSource(SOURCE_ID)
    if (cfg.base_url or "") ~= "" and (cfg.api_key or "") ~= "" then
        return _("已配置"), true
    end
    return _("未配置"), false
end

---@param plugin table|nil
function Setting.open(plugin)
    local UIManager = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")
    local MultiInputDialog = require("ui/widget/multiinputdialog")
    local MoonSettings = require("utils.settings")
    local cfg = MoonSettings.getSource(SOURCE_ID)
    local dialog
    dialog = MultiInputDialog:new{
        title = _("Kavita 服务器"),
        fields = {
            {
                text = tostring(cfg.base_url or ""),
                hint = _("https://host:port/kavita"),
            },
            {
                text = tostring(cfg.api_key or ""),
                hint = _("API Key"),
                text_type = "password",
            },
        },
        buttons = {{
            {
                text = _("取消"),
                id = "close",
                callback = function()
                    UIManager:close(dialog)
                end,
            },
            {
                text = _("保存"),
                callback = function()
                    local values = dialog:getFields()
                    local url = Text.rtrimSlashes(values[1] or "")
                    local key = Text.stripWhitespace(values[2] or "")
                    cfg.base_url = url
                    cfg.api_key = key
                    MoonSettings.saveSource(SOURCE_ID, cfg)
                    require("source.registry").invalidate()
                    UIManager:close(dialog)
                    UIManager:show(InfoMessage:new{ text = _("已保存"), timeout = 2 })
                    if plugin and plugin.onSourceChanged then
                        plugin:onSourceChanged()
                    end
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

return Setting
