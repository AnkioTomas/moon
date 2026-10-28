--[[--
StarDict 词典下载、切换、删除弹窗。

供 dictionary.init 注入的原生菜单与查词弹窗调用。

@module koplugin.book.dictionary.ui
--]]

require("l10n").apply()

local Confirm = require("ui.themes.widgets.confirm")
local List = require("ui.themes.widgets.list")
local Sheet = require("ui.themes.widgets.sheet")
local Toast = require("ui.themes.widgets.toast")
local _ = require("gettext")
local T = require("ffi/util").template
local Text = require("utils.text")

--- 入口的 ui 是 ReaderUI 或 FileManager，两者都挂着 ReaderDictionary（ui.dictionary）。
local Dictionary = {}

--- 弹一条自动消失的提示。
---@param text string 提示文案
---@param timeout number|nil 停留秒数，默认 3
local function info(text, timeout)
    Toast:new{ text = text, timeout = timeout or 3 }:show()
end

--- 读取 .ifo 里的 bookname 作为字典显示名。
---@param path string 字典 .ifo 绝对路径
---@return string
local function bookName(path)
    local file = io.open(path, "rb")
    local body = file and file:read("*a") or ""
    if file then file:close() end
    return Text.trim(body:match("\nbookname=(.-)\r?\n") or path:match("/([^/]+)%.ifo$") or path)
end

--- 从字典路径反解出本插件安装时使用的字典 id。
---@param dictionary table KOReader ReaderDictionary 实例
---@param path string 字典 .ifo 绝对路径
---@return string|nil
local function managedId(dictionary, path)
    local prefix = dictionary.data_dir .. "/book-"
    if path:sub(1, #prefix) ~= prefix then return nil end
    return path:sub(#prefix + 1):match("^([%w_%-]+)/")
end

--- 弹出已安装字典列表，可切换当前字典或删除本插件装的字典。
---@param ui table ReaderUI / FileManager
---@param changed_callback function|nil
function Dictionary.manage(ui, changed_callback)
    local dictionary = ui.dictionary
    local Manager = require("features.dictionary.manager")
    local paths = Manager.list(dictionary.data_dir)
    if #paths == 0 then info(_("尚未安装字典")); return end
    local items = {}
    table.sort(paths, function(a, b) return bookName(a) < bookName(b) end)
    for index = 1, #paths do
        local path = paths[index]
        local id = managedId(dictionary, path)
        local name = bookName(path)
        local current = not (dictionary.dicts_disabled and dictionary.dicts_disabled[path])
        items[#items + 1] = {
            text = name,
            mandatory = current and _("当前") or _("停用"),
            icon = "book",
            callback = function()
                local actions = {
                    {
                        text = _("设为当前字典"),
                        callback = function()
                            Manager.activate(dictionary, path)
                            if changed_callback then changed_callback() end
                            info(_("已切换字典"))
                        end,
                    },
                }
                if id then
                    actions[#actions + 1] = {
                        text = _("删除字典"),
                        callback = function()
                            Confirm:new{
                                text = T(_("删除字典“%1”？"), name),
                                ok_text = _("删除"),
                                ok_callback = function()
                                    local ok, err = Manager.remove(dictionary, id)
                                    if ok and changed_callback then changed_callback() end
                                    info(ok and _("字典已删除") or T(_("删除失败：%1"), tostring(err)))
                                end,
                            }:show()
                        end,
                    }
                end
                Sheet:new{ title = name, items = actions }:show()
            end,
        }
    end
    List:new{
        title = _("管理已安装字典"),
        subtitle = _("选择当前字典，或删除月读安装的字典"),
        items = items,
    }:show()
end

--- 下载安装一本字典（资源下载任务，前台显示进度，可转后台），成功后刷新并设为当前。
---@param ui table ReaderUI / FileManager
---@param item table 目录项，含 id / name / size
local function install(ui, item)
    local dictionary = ui.dictionary
    local Manager = require("features.dictionary.manager")
    require("workers.ui.task_dialog").start{
        key = "dict\0" .. item.id,
        kind = "download",
        title = item.name,
        run = function(report, done)
            Manager.install(item, dictionary.data_dir, function(ok, err)
                done({ ok = ok, err = err })
            end, function(stage, bytes, total)
                report(stage == "install" and _("正在解压安装…") or nil, bytes, total)
            end)
        end,
        on_done = function(result)
            if not result.ok then info(T(_("字典安装失败：%1"), tostring(result.err))); return end
            Manager.refresh(dictionary)
            local installed = Manager.list(dictionary.data_dir)
            local prefix = dictionary.data_dir .. "/book-" .. item.id .. "/"
            for index = 1, #installed do
                local path = installed[index]
                if path:sub(1, #prefix) == prefix then
                    Manager.activate(dictionary, path)
                    break
                end
            end
            info(_("字典已安装并切换"))
        end,
    }
end

--- 语言分组显示名。
---@param lang string|nil
---@param fallback string|nil
---@return string
local function langLabel(lang, fallback)
    if type(fallback) == "string" and fallback ~= "" then return fallback end
    local names = {
        zh_CN = _("简体中文"),
        en = _("英语"),
        ja = _("日语"),
        ko = _("韩语"),
        de = _("德语"),
        fr = _("法语"),
        ru = _("俄语"),
    }
    return names[lang] or lang or _("其他")
end

--- 按语言弹出某一组词典下载列表。
---@param ui table ReaderUI / FileManager
---@param lang_name string
---@param items table[]
local function downloadLang(ui, lang_name, items)
    local rows = {}
    for index = 1, #items do
        local item = items[index]
        local installed = require("features.dictionary.manager").isInstalled(ui.dictionary.data_dir, item.id)
        rows[#rows + 1] = {
            text = item.name,
            mandatory = installed and _("已安装") or string.format("%.1f MB", item.size / 1048576),
            icon = installed and "download_done" or "cloud_download",
            enabled = not installed,
            callback = function()
                Confirm:new{
                    text = T(_("下载并安装字典“%1”？"), item.name),
                    ok_text = _("下载"),
                    ok_callback = function() install(ui, item) end,
                }:show()
            end,
        }
    end
    List:new{
        title = T(_("下载字典 · %1"), lang_name),
        subtitle = _("选择要安装的 StarDict 字典"),
        items = rows,
    }:show()
end

--- 拉取远程目录并按语言分组弹出下载列表。
---@param ui table ReaderUI / FileManager
function Dictionary.download(ui)
    require("ui/network/manager"):runWhenConnected(function()
        local loading = require("ui.themes.widgets.progress_dialog"):new{
            title = _("下载 StarDict 字典"), text = _("正在获取字典目录…"), dismissable = false,
        }
        loading:show()
        require("features.dictionary.manager").catalog(function(items, err)
            loading:close()
            if not items then info(T(_("获取字典目录失败：%1"), tostring(err))); return end
            local groups, order = {}, {}
            for index = 1, #items do
                local item = items[index]
                local lang = type(item.lang) == "string" and item.lang ~= "" and item.lang or "other"
                local bucket = groups[lang]
                if not bucket then
                    bucket = {
                        lang = lang,
                        name = langLabel(lang, item.lang_name),
                        items = {},
                    }
                    groups[lang] = bucket
                    order[#order + 1] = lang
                end
                bucket.items[#bucket.items + 1] = item
            end
            if #order == 1 then
                local only = groups[order[1]]
                downloadLang(ui, only.name, only.items)
                return
            end
            local rows = {}
            for index = 1, #order do
                local lang = order[index]
                local group = groups[lang]
                rows[#rows + 1] = {
                    text = group.name,
                    mandatory = T(_("%1 本"), #group.items),
                    icon = "book",
                    keep_open = true,
                    callback = function()
                        downloadLang(ui, group.name, group.items)
                    end,
                }
            end
            List:new{
                title = _("下载 StarDict 字典"),
                subtitle = _("按语言选择"),
                items = rows,
            }:show()
        end)
    end)
end

return Dictionary
