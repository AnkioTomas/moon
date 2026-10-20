--[[--
中文输入法设置。语言选择留在主模块。

@module koplugin.book.features.ime.setting
--]]

local _ = require("gettext")
local T = require("ffi/util").template

local RELEASES_URL = "https://github.com/AnkioTomas/moon/releases"

--- 造一行小字灰色提示，高度按文本实测撑开。
---@param width number
---@param text string
---@return table
local function hintRow(width, text)
    local Geom = require("ui/geometry")
    local LeftContainer = require("ui/widget/container/leftcontainer")
    local Text = require("ui.themes.widgets.text")
    local Theme = require("ui.themes")
    local t = Theme.current()
    local box_w = math.max(1, width - Theme.px(t.space.xs))
    local box = Text.box("caption", text, box_w, { color = t.color.muted })
    local box_h = box:getSize().h
    return LeftContainer:new{
        dimen = Geom:new{ w = width, h = box_h },
        box,
    }
end

---@param desktop BookDesktop
---@param enable_after boolean|nil
local function download(desktop, enable_after)
    local IME = require("features.ime")
    local Toast = require("ui.themes.widgets.toast")
    require("workers.ui.task_dialog").start{
        key = "ime",
        kind = "download",
        title = _("输入法词库"),
        run = function(report, done)
            IME.downloadDict(function(ok, err)
                done({ ok = ok, err = err })
            end, function(stage, done_bytes, total)
                if stage == "part" then
                    report(nil, done_bytes, total)
                elseif stage == "assemble" then
                    report(_("拼接校验词库…"), done_bytes, total)
                end
            end)
        end,
        on_done = function(result)
            Toast:new{
                text = result.ok and _("输入法词库已就绪")
                    or T(_("下载失败: %1"), tostring(result.err or _("未知错误"))),
                timeout = 2,
            }:show()
            if result.ok and enable_after then IME.setEnabled(true) end
            if desktop.closed then return end
            desktop:updateView()
        end,
    }
end

---@param desktop BookDesktop
---@param enable_after boolean|nil
local function confirmDownload(desktop, enable_after)
    require("ui.themes.widgets.confirm"):new{
        text = _("新词库可能需要新版插件支持。是否继续下载？"),
        ok_text = _("继续下载"),
        ok_callback = function() download(desktop, enable_after) end,
    }:show()
end

--- 已启用时切到词库未下载的布局，直接提示下载；否则候选栏会静默退回原生键盘。
---@param desktop BookDesktop
local function pickInputMethod(desktop)
    local IME = require("features.ime")
    local items = {}
    for _idx, method in ipairs(IME.layouts()) do
        items[#items + 1] = { text = method.label, value = method.id }
    end
    require("ui.themes.widgets.list"):new{
        title = _("键盘布局"),
        items = items,
        current = IME.layout(),
        centered = true,
        on_select = function(id)
            IME.setLayout(id)
            desktop:updateView()
            if IME.isEnabled() and not require("features.ime.registry").isAvailable(id) then
                confirmDownload(desktop)
            end
        end,
    }:show()
end

--- 候选词输出字形：keep 跟随词库（拼音 / 五笔多为简体，注音多为繁体）。
---@return table[]
local function scripts()
    return {
        { value = "keep", text = _("不转换") },
        { value = "simplified", text = _("转为简体") },
        { value = "traditional", text = _("转为繁体") },
    }
end

---@param id string
---@return string
local function scriptLabel(id)
    for _idx, item in ipairs(scripts()) do
        if item.value == id then return item.text end
    end
    return id
end

---@param desktop BookDesktop
local function pickScript(desktop)
    local Settings = require("utils.settings")
    require("ui.themes.widgets.list"):new{
        title = _("简繁转换"),
        items = scripts(),
        current = Settings.get("features.ime").ime_script,
        centered = true,
        on_select = function(id)
            local settings = Settings.get("features.ime")
            settings.ime_script = id
            Settings.save("features.ime", settings)
            desktop:updateView()
        end,
    }:show()
end

---@param desktop BookDesktop
---@return table[]
local function sections(desktop)
    local IME = require("features.ime")
    local Registry = require("features.ime.registry")
    local Paths = require("utils.paths")
    local Row = require("ui.themes.widgets.row")
    local method = Registry.current()
    local dict_path = Paths.imeDictPath(method.dictionary)
    local keycaps_row = function(iw)
        local on = require("utils.settings").get("features.ime").ime_keycaps
        return Row.widget({
            width = iw,
            chevron = false,
            kind = "toggle",
            icon = "keyboard",
            title = _("显示字根键帽"),
            status = on and _("开") or _("关"),
            status_on = on,
            callback = function()
                local Settings = require("utils.settings")
                local settings = Settings.get("features.ime")
                settings.ime_keycaps = not settings.ime_keycaps
                Settings.save("features.ime", settings)
                desktop:updateView()
            end,
        })
    end
    local rows = {
                function(iw)
                    return Row.widget({
                        width = iw,
                        chevron = false,
                        kind = "toggle",
                        icon = "translate",
                        title = _("输入法"),
                        status = IME.isEnabled() and _("开") or _("关"),
                        status_on = IME.isEnabled(),
                        callback = function()
                            if not IME.isEnabled() and not Registry.isAvailable(method) then
                                confirmDownload(desktop, true)
                                return
                            end
                            local on = IME.setEnabled(not IME.isEnabled())
                            require("ui.themes.widgets.toast"):new{
                                text = on and _("中文键盘已启用，点键盘上的 🌐 键切换中英文") or _("中文键盘已停用"),
                                timeout = 3,
                            }:show()
                            desktop:updateView()
                        end,
                    })
                end,
                function(iw)
                    return Row.widget({
                        width = iw,
                        chevron = true,
                        kind = "nav",
                        icon = "keyboard",
                        title = _("键盘布局"),
                        status = method.label,
                        status_on = true,
                        callback = function() pickInputMethod(desktop) end,
                    })
                end,
                function(iw)
                    local script = require("utils.settings").get("features.ime").ime_script
                    return Row.widget({
                        width = iw,
                        chevron = true,
                        kind = "nav",
                        icon = "g_translate",
                        title = _("简繁转换"),
                        status = scriptLabel(script),
                        status_on = script ~= "keep",
                        callback = function() pickScript(desktop) end,
                    })
                end,
                function(iw)
                    local settings = require("utils.settings").get("features.ime")
                    return Row.widget({
                        width = iw,
                        chevron = false,
                        kind = "toggle",
                        icon = "keyboard_hide",
                        title = _("键盘收起键"),
                        status = settings.hide_key and _("开") or _("关"),
                        status_on = settings.hide_key,
                        callback = function()
                            settings.hide_key = not settings.hide_key
                            require("utils.settings").save("features.ime", settings)
                            desktop:updateView()
                        end,
                    })
                end,
                function(iw)
                    return Row.widget({
                        width = iw,
                        chevron = true,
                        kind = "nav",
                        icon = "spellcheck",
                        title = _("输入法词库"),
                        status = IME.dictStatus(),
                        status_on = Registry.isAvailable(method),
                        callback = function() confirmDownload(desktop) end,
                    })
                end,
                function(iw)
                    return hintRow(iw, T(_(
                        "若在线下载过慢，可到 GitHub Release（%1）下载对应词库，直接放入：%2"
                    ), RELEASES_URL, dict_path))
                end,
    }
    if method.optional_labels then table.insert(rows, 3, keycaps_row) end
    return { { title = _("输入法"), rows = rows } }
end

local Setting = {}

-- pinyin_enabled 是总开关（键名沿用拼音时代）；ime_layout 取 registry 的方法 id；
-- ime_dict_built_at 按词库记已装版本；ime_script 是候选词字形（keep / simplified / traditional）；
-- ime_keycaps 为真时五笔 / 仓颉 / 小鹤键盘把键帽换成字根 / 韵母。
Setting.defaults = {
    pinyin_enabled = false,
    ime_layout = "pinyin",
    ime_dict_built_at = {},
    ime_script = "keep",
    ime_keycaps = false,
    hide_key = true, -- 虚拟键盘末行的收起键，与中文输入法开关无关
}

---@param desktop BookDesktop
---@return BookSettingEntry[]
function Setting.entries(desktop)
    local on = require("features.ime").isEnabled()
    return {
        {
            id = "main",
            group = "system",
            order = 40,
            icon = "keyboard",
            title = _("输入法"),
            subtitle = _("键盘布局"),
            status = on and _("开") or _("关"),
            status_on = on,
            page = {
                title = _("输入法"),
                sections = function() return sections(desktop) end,
            },
        },
    }
end

return Setting
