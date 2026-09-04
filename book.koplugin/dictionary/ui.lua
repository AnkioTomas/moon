--[[--
StarDict 词典下载、切换、删除弹窗。

供 dictionary.init 注入的原生菜单与查词弹窗调用。

@module koplugin.book.dictionary.ui
--]]

require("l10n").apply()

local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template
local Text = require("utils.text")

local Dictionary = {}

--- 弹一条自动消失的提示。
---@param text string 提示文案
---@param timeout number|nil 停留秒数，默认 3
local function info(text, timeout)
    UIManager:show(require("ui/widget/infomessage"):new{ text = text, timeout = timeout or 3 })
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
---@param ui table|nil ReaderUI 实例
---@param changed_callback function|nil
function Dictionary.manage(ui, changed_callback)
    local dictionary = ui and ui.dictionary
    if not dictionary or not dictionary.data_dir then info(_("字典模块不可用")); return end
    local Manager = require("dictionary.manager")
    local paths = Manager.installed(dictionary.data_dir)
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
                            UIManager:show(require("ui/widget/confirmbox"):new{
                                text = T(_("删除字典“%1”？"), name),
                                ok_text = _("删除"),
                                ok_callback = function()
                                    local ok, err = Manager.remove(dictionary, id)
                                    if ok and changed_callback then changed_callback() end
                                    info(ok and _("字典已删除") or T(_("删除失败：%1"), tostring(err)))
                                end,
                            })
                        end,
                    }
                end
                require("ui.components.popup").sheet{ title = name, items = actions }
            end,
        }
    end
    require("ui.components.popup").list{
        title = _("管理已安装字典"),
        subtitle = _("选择当前字典，或删除月读安装的字典"),
        items = items,
    }
end

--- 下载安装一本字典，成功后刷新并设为当前。
---@param ui table|nil ReaderUI 实例
---@param item table 目录项，含 id / name / size
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
        for index = 1, #installed do
            local path = installed[index]
            if path:sub(1, #prefix) == prefix then
                require("dictionary.manager").activate(dictionary, path)
                break
            end
        end
        info(_("字典已安装并切换"))
    end)
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
---@param ui table|nil
---@param lang_name string
---@param items table[]
local function downloadLang(ui, lang_name, items)
    local dictionary = ui and ui.dictionary
    local rows = {}
    for index = 1, #items do
        local item = items[index]
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
    require("ui.components.popup").list{
        title = T(_("下载字典 · %1"), lang_name),
        subtitle = _("选择要安装的 StarDict 字典"),
        items = rows,
    }
end

--- 拉取远程目录并按语言分组弹出下载列表。
---@param ui table|nil
function Dictionary.download(ui)
    require("ui/network/manager"):runWhenOnline(function()
        local loading = require("ui/widget/infomessage"):new{ text = _("正在获取字典目录…") }
        UIManager:show(loading)
        require("dictionary.manager").catalog(function(items, err)
            UIManager:close(loading)
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
                    keep_menu_open = true,
                    callback = function()
                        downloadLang(ui, group.name, group.items)
                    end,
                }
            end
            require("ui.components.popup").list{
                title = _("下载 StarDict 字典"),
                subtitle = _("按语言选择"),
                items = rows,
            }
        end)
    end)
end

--- 查词弹窗内切换词典：选中后激活并重查当前词（对齐翻译切语言）。
---@param ui table|nil ReaderUI
---@param opts { word: string|nil, current_name: string|nil, close_window: fun()|nil }
function Dictionary.pick(ui, opts)
    opts = opts or {}
    local dictionary = ui and ui.dictionary
    if not dictionary or not dictionary.data_dir then info(_("字典模块不可用")); return end
    local Manager = require("dictionary.manager")
    local paths = Manager.installed(dictionary.data_dir)
    if #paths == 0 then
        info(_("尚未安装字典"))
        Dictionary.download(ui)
        return
    end
    table.sort(paths, function(a, b) return bookName(a) < bookName(b) end)
    local items = {}
    local current_path
    local current_name = opts.current_name
    for index = 1, #paths do
        local path = paths[index]
        local name = bookName(path)
        local active = (current_name and name == current_name)
            or (not current_name and not (dictionary.dicts_disabled and dictionary.dicts_disabled[path]))
        if active then current_path = path end
        items[#items + 1] = {
            text = name,
            value = path,
            checked = active,
            mandatory = active and _("当前") or nil,
            icon = "book",
        }
    end
    require("ui.components.popup").single{
        title = _("切换词典"),
        subtitle = _("选择后重新查询当前词"),
        choice_icons = true,
        centered = true,
        current = current_path,
        items = items,
        on_select = function(path)
            if type(path) ~= "string" then return end
            Manager.activate(dictionary, path)
            if opts.close_window then opts.close_window() end
            local word = opts.word
            if type(word) == "string" and word ~= "" and dictionary.onLookupWord then
                dictionary:onLookupWord(word, true)
            end
        end,
    }
end

return Dictionary
