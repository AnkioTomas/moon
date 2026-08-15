--[[--
RSS 订阅设置：增删 feed、从 OPML 导入。

@module koplugin.book.source.rss.setting
--]]

local _ = require("gettext")
local SOURCE_ID = "rss"
local Setting = {}

local function feeds()
    local cfg = require("utils.settings").getSource(SOURCE_ID)
    return cfg, type(cfg.feeds) == "table" and cfg.feeds or {}
end

function Setting.rowTitle()
    return _("RSS 订阅")
end

function Setting.rowStatus()
    local list = select(2, feeds())
    if #list > 0 then
        return string.format(_("已订阅 %d 个"), #list), true
    end
    return _("未配置"), false
end

local function save(plugin, cfg, list)
    cfg.feeds = list
    local Settings = require("utils.settings")
    Settings.saveSource(SOURCE_ID, cfg)
    require("source.registry").invalidate()
    if plugin and plugin.onSourceChanged then plugin:onSourceChanged() end
end

local function addFeed(plugin, parent, reopen)
    local UIManager = require("ui/uimanager")
    local MultiInputDialog = require("ui/widget/multiinputdialog")
    local InfoMessage = require("ui/widget/infomessage")
    local Parser = require("source.rss.parser")
    local dialog
    dialog = MultiInputDialog:new{
        title = _("添加 RSS 订阅"),
        fields = {
            { text = "", hint = _("https://example.com/feed.xml") },
            { text = "", hint = _("名称（可留空）") },
        },
        buttons = {{
            {
                text = _("取消"),
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("添加"),
                callback = function()
                    local values = dialog:getFields()
                    local url = Parser.normalizeUrl(values[1])
                    if not url then
                        UIManager:show(InfoMessage:new{
                            text = _("RSS 地址无效"), timeout = 2,
                        })
                        return
                    end
                    local cfg, list = feeds()
                    for _, feed in ipairs(list) do
                        if Parser.normalizeUrl(feed.url) == url then
                            UIManager:show(InfoMessage:new{
                                text = _("该订阅已存在"), timeout = 2,
                            })
                            return
                        end
                    end
                    list[#list + 1] = {
                        url = url,
                        title = (values[2] or ""):match("^%s*(.-)%s*$"),
                    }
                    save(plugin, cfg, list)
                    UIManager:close(dialog)
                    if parent then UIManager:close(parent) end
                    reopen()
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

local function importOpml(plugin, parent, reopen)
    local UIManager = require("ui/uimanager")
    local InputDialog = require("ui/widget/inputdialog")
    local InfoMessage = require("ui/widget/infomessage")
    local OPML = require("source.rss.opml")
    local Parser = require("source.rss.parser")
    local dialog
    dialog = InputDialog:new{
        title = _("从 OPML 导入"),
        input = OPML.DEFAULT_IMPORT_PATH,
        input_hint = _("OPML 文件路径"),
        buttons = {{
            {
                text = _("取消"),
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("导入"),
                callback = function()
                    local imported, err = OPML.read(dialog:getInputText())
                    if not imported then
                        UIManager:show(InfoMessage:new{
                            text = err or _("无法读取 OPML"), timeout = 3,
                        })
                        return
                    end
                    local cfg, list = feeds()
                    local seen = {}
                    for _, feed in ipairs(list) do
                        local url = Parser.normalizeUrl(feed.url)
                        if url then seen[url] = true end
                    end
                    local added = 0
                    for _, feed in ipairs(imported) do
                        local url = Parser.normalizeUrl(feed.url)
                        if url and not seen[url] then
                            seen[url] = true
                            list[#list + 1] = { url = url, title = feed.title }
                            added = added + 1
                        end
                    end
                    save(plugin, cfg, list)
                    UIManager:close(dialog)
                    if parent then UIManager:close(parent) end
                    UIManager:show(InfoMessage:new{
                        text = string.format(_("已导入 %d 个订阅"), added),
                        timeout = 2,
                    })
                    reopen()
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Setting.open(plugin)
    local UIManager = require("ui/uimanager")
    local ButtonDialog = require("ui/widget/buttondialog")
    local ConfirmBox = require("ui/widget/confirmbox")
    local dialog

    local function reopen()
        Setting.open(plugin)
    end

    local cfg, list = feeds()
    local buttons = {}
    for index, feed in ipairs(list) do
        local remove_index = index
        local label = (feed.title and feed.title ~= "") and feed.title or feed.url
        buttons[#buttons + 1] = {{
            text = label,
            callback = function()
                UIManager:show(ConfirmBox:new{
                    text = string.format(_("删除订阅“%s”？"), label),
                    ok_text = _("删除"),
                    ok_callback = function()
                        table.remove(list, remove_index)
                        save(plugin, cfg, list)
                        UIManager:close(dialog)
                        reopen()
                    end,
                })
            end,
        }}
    end
    buttons[#buttons + 1] = {
        {
            text = _("添加订阅"),
            callback = function() addFeed(plugin, dialog, reopen) end,
        },
        {
            text = _("从 OPML 导入"),
            callback = function() importOpml(plugin, dialog, reopen) end,
        },
    }
    buttons[#buttons + 1] = {{
        text = _("关闭"),
        callback = function() UIManager:close(dialog) end,
    }}
    dialog = ButtonDialog:new{
        title = _("RSS 订阅"),
        buttons = buttons,
    }
    UIManager:show(dialog)
end

return Setting
