--[[--
阅读页 StarDict 字典下载、切换、删除与查词入口。

@module koplugin.book.ui.reader.dictionary
--]]

require("l10n").apply()

local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template
local Text = require("utils.text")

local Dictionary = {}

local function info(text, timeout)
    UIManager:show(require("ui/widget/infomessage"):new{ text = text, timeout = timeout or 3 })
end

local function bookName(path)
    local file = io.open(path, "rb")
    local body = file and file:read("*a") or ""
    if file then file:close() end
    return Text.trim(body:match("\nbookname=(.-)\r?\n") or path:match("/([^/]+)%.ifo$") or path)
end

local function managedId(dictionary, path)
    local prefix = dictionary.data_dir .. "/book-"
    if path:sub(1, #prefix) ~= prefix then return nil end
    return path:sub(#prefix + 1):match("^([%w_%-]+)/")
end

local function manage(ui)
    local dictionary = ui and ui.dictionary
    if not dictionary or not dictionary.data_dir then info(_("字典模块不可用")); return end
    local Manager = require("dictionary.manager")
    local paths = Manager.installed(dictionary.data_dir)
    if #paths == 0 then info(_("尚未安装字典")); return end
    local items = {}
    table.sort(paths, function(a, b) return bookName(a) < bookName(b) end)
    for i, path in ipairs(paths) do
        local id = managedId(dictionary, path)
        items[#items + 1] = {
            text = bookName(path),
            mandatory = dictionary.dicts_disabled and dictionary.dicts_disabled[path]
                and _("停用") or _("当前"),
            icon = "book",
            callback = function()
                local actions = {
                    {
                        text = _("设为当前字典"),
                        callback = function()
                            Manager.activate(dictionary, path)
                            info(_("已切换字典"))
                        end,
                    },
                }
                if id then
                    actions[#actions + 1] = {
                        text = _("删除字典"),
                        callback = function()
                            UIManager:show(require("ui/widget/confirmbox"):new{
                                text = T(_("删除字典“%1”？"), bookName(path)),
                                ok_text = _("删除"),
                                ok_callback = function()
                                    local ok, err = Manager.remove(dictionary, id)
                                    info(ok and _("字典已删除") or T(_("删除失败：%1"), tostring(err)))
                                end,
                            })
                        end,
                    }
                end
                require("ui.components.popup").sheet{ title = bookName(path), items = actions }
            end,
        }
    end
    require("ui.components.popup").list{
        title = _("管理已安装字典"),
        subtitle = _("选择当前字典，或删除 Book 安装的字典"),
        items = items,
    }
end

local function install(ui, item)
    local dictionary = ui and ui.dictionary
    if not dictionary or not dictionary.data_dir then info(_("字典模块不可用")); return end
    local loading = require("ui/widget/infomessage"):new{
        text = T(_("正在下载字典：%1"), item.name),
    }
    UIManager:show(loading)
    require("dictionary.manager").install(item, dictionary.data_dir, function(ok, err)
        UIManager:close(loading)
        if not ok then info(T(_("字典安装失败：%1"), tostring(err))); return end
        require("dictionary.manager").refresh(dictionary)
        local installed = require("dictionary.manager").installed(dictionary.data_dir)
        local prefix = dictionary.data_dir .. "/book-" .. item.id .. "/"
        for i, path in ipairs(installed) do
            if path:sub(1, #prefix) == prefix then
                require("dictionary.manager").activate(dictionary, path)
                break
            end
        end
        info(_("字典已安装并切换"))
    end)
end

--- 拉取远程目录并弹出下载列表。
---@param ui table|nil
function Dictionary.download(ui)
    require("ui/network/manager"):runWhenOnline(function()
        local loading = require("ui/widget/infomessage"):new{ text = _("正在获取字典目录…") }
        UIManager:show(loading)
        require("dictionary.manager").catalog(function(items, err)
            UIManager:close(loading)
            if not items then info(T(_("获取字典目录失败：%1"), tostring(err))); return end
            local dictionary = ui and ui.dictionary
            local rows = {}
            for i, item in ipairs(items) do
                local installed = dictionary and dictionary.data_dir
                    and require("dictionary.manager").isInstalled(dictionary.data_dir, item.id)
                rows[#rows + 1] = {
                    text = item.name,
                    mandatory = installed and _("已安装") or string.format("%.1f MB", item.size / 1048576),
                    icon = installed and "download_done" or "cloud_download",
                    enabled = not installed,
                    callback = function()
                        UIManager:show(require("ui/widget/confirmbox"):new{
                            text = T(_("下载并安装字典“%1”？"), item.name),
                            ok_text = _("下载"),
                            ok_callback = function() install(ui, item) end,
                        })
                    end,
                }
            end
            require("ui.components.popup").list{ title = _("下载 StarDict 字典"), items = rows }
        end)
    end)
end

--- 字典维护入口：下载 / 管理 / 查找。
---@param ui table|nil
function Dictionary.open(ui)
    local dialog
    dialog = require("ui/widget/buttondialog"):new{
        title = _("字典维护"), title_align = "center", use_info_style = false,
        buttons = { {
            { text = _("下载字典"), icon = "cloud_download", callback = function()
                UIManager:close(dialog); Dictionary.download(ui)
            end },
            { text = _("管理字典"), icon = "settings", callback = function()
                UIManager:close(dialog); manage(ui)
            end },
            { text = _("查找字典"), icon = "search", callback = function()
                UIManager:close(dialog)
                if ui and ui.dictionary and ui.dictionary.onShowDictionaryLookup then
                    ui.dictionary:onShowDictionaryLookup()
                end
            end },
        } },
    }
    UIManager:show(dialog)
end

return Dictionary
