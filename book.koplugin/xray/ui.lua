--[[--
X-Ray 阅读 UI：底部分栏主菜单、TextViewer 详情、划词补全。

@module koplugin.book.xray.ui
--]]

require("l10n").apply()

local Popup = require("ui.components.popup")
local UIManager = require("ui/uimanager")
local Text = require("utils.text")
local Kinds = require("xray.kinds")
local XrayDB = require("db.xray")
local _ = require("gettext")
local T = require("ffi/util").template

local UI = {}

--- 当前打开的 X-Ray 主菜单（生成成功后刷新列表）。
---@type table|nil
local main_holder

--- 弹一条 3 秒自动消失的提示。
---@param text string
local function info(text)
    UIManager:show(require("ui/widget/infomessage"):new{ text = text, timeout = 3 })
end

--- 当前阅读会话的书籍身份；没有会话时 nil。
---@return BookIdentity|nil
local function currentIdentity()
    local current = require("ui.reader.session").current()
    return current and current.identity
end

---@param title string
---@param text string
local function showInfoBox(title, text)
    local Screen = require("device").screen
    UIManager:show(require("ui/widget/textviewer"):new{
        title = title,
        text = text ~= "" and text or _("（无内容）"),
        add_default_buttons = true,
        height = math.floor(Screen:getHeight() * 0.65),
    })
end

---@param entity table
---@return string[]
local function entityLines(entity)
    local lines = {}
    local kind_label = Kinds.label(entity.kind)
    if kind_label ~= "" then
        lines[#lines + 1] = T(_("类型：%1"), kind_label)
    end
    if entity.aliases and #entity.aliases > 0 then
        lines[#lines + 1] = T(_("别名：%1"), table.concat(entity.aliases, "、"))
    end
    if entity.role and entity.role ~= "" then
        lines[#lines + 1] = T(_("身份：%1"), entity.role)
    end
    if entity.description and entity.description ~= "" then
        if #lines > 0 then
            lines[#lines + 1] = ""
        end
        for line in (entity.description .. "\n"):gmatch("([^\n]*)\n") do
            lines[#lines + 1] = line
        end
    end
    return lines
end

--- 实体详情的纯文本形式：首行名字，其后是类型/别名/身份/简介。
---@param entity table
---@return string
local function formatEntity(entity)
    local lines = { entity.name }
    for i, line in ipairs(entityLines(entity)) do
        lines[#lines + 1] = line
    end
    return table.concat(lines, "\n")
end

--- 展示已收录实体详情。
---@param entity table
function UI.showEntity(entity)
    if not entity then return end
    showInfoBox(entity.name, table.concat(entityLines(entity), "\n"))
end

UI.formatEntity = formatEntity

--- 未配置 AI 时提示并拦下操作。
---@return boolean 是否可以继续
local function ensureConfigured()
    if not require("ai").isConfigured() then
        info(_("请先在月读设置中配置 AI 服务"))
        return false
    end
    return true
end

---@param tab_id string
---@param identity BookIdentity
---@return table[]
local function rowsForTab(tab_id, identity)
    local items = {}
    for i, entity in ipairs(XrayDB.list(identity.source_id, identity.stable_id, tab_id)) do
        local subtitle = entity.role or ""
        if subtitle == "" then subtitle = entity.description or "" end
        items[#items + 1] = {
            text = entity.name,
            mandatory = Text.truncateUtf8(subtitle, 40),
            keep_menu_open = true,
            callback = function()
                UI.showEntity(entity)
            end,
        }
    end
    if #items == 0 then
        items[1] = {
            text = _("暂无数据，点左上角重新生成"),
            enabled = false,
            dim = true,
        }
    end
    return items
end

---@param holder table
---@param opts table|nil
local function refreshMainTab(holder, opts)
    opts = opts or {}
    if not holder or not holder.menu then
        return
    end
    local items = rowsForTab(holder.active, holder.identity)
    Popup.setListItems(holder.menu, _("X-Ray"), items, nil, {
        subtitle = Kinds.label(holder.active),
        preserve_page = opts.preserve_page == true,
    })
    if holder.menu.setBottomTabActive then
        holder.menu:setBottomTabActive(holder.active)
    end
    holder.menu:updateItems(nil, true)
end

--- 跑一次综合拉取：显示进行中提示，完成后报数、失效页内标记并刷新当前分栏。
---@param ui table ReaderUI
---@param identity BookIdentity
---@param force boolean|nil 为真则忽略已有缓存重新生成
local function runFetch(ui, identity, force)
    local Fetch = require("xray.fetch")
    local loading = require("ui/widget/infomessage"):new{
        text = force and _("正在重新生成 X-Ray…") or _("正在生成 X-Ray…"),
    }
    UIManager:show(loading)
    --- 拉取回调：关掉进行中提示，成功报三类数量，失败提示原因。
    ---@param result table|nil
    ---@param err any
    local cb = function(result, err)
        UIManager:close(loading)
        if not result then
            info(T(_("X-Ray 失败：%1"), tostring(err or _("未知错误"))))
            return
        end
        info(T(_("X-Ray 已更新：人物 %1，地点 %2，专有名词 %3"),
            tostring(#result.characters),
            tostring(#result.locations),
            tostring(#result.terms)))
        require("xray.marks").invalidate()
        refreshMainTab(main_holder, { preserve_page = true })
    end
    Fetch.comprehensive(ui, identity, { force = force == true }, cb)
end

--- 打开 X-Ray 主菜单（底部分栏，左上角重新生成）。
---@param ui table|nil
---@param initial_tab string|nil
function UI.openMain(ui, initial_tab)
    local identity = currentIdentity()
    if not ui or not identity then
        info(_("当前书籍没有可用身份"))
        return
    end
    initial_tab = initial_tab or "character"
    local holder = {
        menu = nil,
        active = initial_tab,
        ui = ui,
        identity = identity,
    }
    main_holder = holder

    --- 切换底部分栏并重载列表。
    ---@param tab_id string
    local function switch(tab_id)
        holder.active = tab_id
        refreshMainTab(holder)
    end

    holder.menu = Popup.list{
        title = _("X-Ray"),
        title_material_icon = "sync",
        subtitle = Kinds.label(initial_tab),
        items = rowsForTab(initial_tab, identity),
        bottom_tabs = { tabs = Kinds, active = initial_tab, on_tab = switch },
        on_left_tap = function()
            if not ensureConfigured() then return end
            require("ui/network/manager"):runWhenOnline(function()
                runFetch(ui, identity, true)
            end)
        end,
        close_callback = function()
            if main_holder == holder then
                main_holder = nil
            end
        end,
    }
end

---@param ui table|nil
---@param mode "characters"|"locations"|"terms"|nil
function UI.open(ui, mode)
    local tab = "character"
    if mode == "locations" then
        tab = "location"
    elseif mode == "terms" then
        tab = "term"
    end
    UI.openMain(ui, tab)
end

--- 选词查询 / 补全实体（划词菜单入口，不在 X-Ray 主菜单）。
---@param ui table|nil
---@param word string|nil
function UI.lookup(ui, word)
    local identity = currentIdentity()
    if not ui or not identity then
        info(_("当前书籍没有可用身份"))
        return
    end
    word = Text.trim(word)
    if word == "" then
        return
    end
    if not ensureConfigured() then return end
    require("ui/network/manager"):runWhenOnline(function()
        local loading = require("ui/widget/infomessage"):new{ text = _("X-Ray 查询中…") }
        UIManager:show(loading)
        require("xray.fetch").lookupWord(ui, identity, word, function(entity, err)
            UIManager:close(loading)
            if not entity then
                info(T(_("未找到：%1"), tostring(err or word)))
                return
            end
            UI.showEntity(entity)
            require("xray.marks").invalidate()
        end)
    end)
end

return UI
