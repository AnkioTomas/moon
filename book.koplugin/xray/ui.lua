--[[--
X-Ray 阅读 UI：人物 / 地点 / 时间线列表与选词查询。

@module koplugin.book.xray.ui
--]]

require("l10n").apply()

local UIManager = require("ui/uimanager")
local Text = require("utils.text")
local _ = require("gettext")
local T = require("ffi/util").template

local UI = {}

local function info(text)
    UIManager:show(require("ui/widget/infomessage"):new{ text = text, timeout = 3 })
end

local function viewer(title, text)
    UIManager:show(require("ui/widget/textviewer"):new{
        title = title,
        text = text,
    })
end

local function currentIdentity()
    local current = require("ui.reader.session").current()
    return current and current.identity
end

local function formatEntity(entity)
    local payload = entity.payload or {}
    local lines = { entity.name }
    if entity.aliases and #entity.aliases > 0 then
        lines[#lines + 1] = T(_("别名：%1"), table.concat(entity.aliases, "、"))
    end
    if payload.role and payload.role ~= "" then
        lines[#lines + 1] = T(_("身份：%1"), payload.role)
    end
    if payload.description and payload.description ~= "" then
        lines[#lines + 1] = ""
        lines[#lines + 1] = payload.description
    end
    return table.concat(lines, "\n")
end

local function ensureConfigured()
    if not require("ai").isConfigured() then
        info(_("请先在 Book 设置中配置 AI 服务"))
        return false
    end
    return true
end

local function runFetch(ui, identity, mode)
    local Fetch = require("xray.fetch")
    local loading = require("ui/widget/infomessage"):new{
        text = mode == "incremental" and _("正在更新 X-Ray…") or _("正在生成 X-Ray…"),
    }
    UIManager:show(loading)
    local cb = function(result, err)
        UIManager:close(loading)
        if not result then
            info(T(_("X-Ray 失败：%1"), tostring(err or _("未知错误"))))
            return
        end
        info(T(_("X-Ray 已更新：人物 %1，地点 %2，事件 %3"),
            tostring(#(result.characters or {})),
            tostring(#(result.locations or {})),
            tostring(#(result.timeline or {}))))
    end
    if mode == "incremental" then
        Fetch.incremental(ui, identity, cb)
    else
        Fetch.comprehensive(ui, identity, { force = mode == "force" }, cb)
    end
end

---@param kind "character"|"location"
local function showEntityList(ui, kind)
    local identity = currentIdentity()
    if not identity then
        info(_("当前书籍没有可用身份"))
        return
    end
    local Store = require("xray.store")
    local entities = Store.loadEntities(identity, kind)
    local title = kind == "character" and _("人物") or _("地点")
    if #entities == 0 then
        if not ensureConfigured() then return end
        UIManager:show(require("ui/widget/confirmbox"):new{
            text = _("尚无 X-Ray 数据。现在生成？"),
            ok_text = _("生成"),
            ok_callback = function()
                require("ui/network/manager"):runWhenOnline(function()
                    runFetch(ui, identity, "force")
                end)
            end,
        })
        return
    end
    local items = {}
    for _, entity in ipairs(entities) do
        local subtitle = entity.payload and entity.payload.role or ""
        if subtitle == "" and entity.payload then
            subtitle = entity.payload.description or ""
        end
        items[#items + 1] = {
            text = entity.name,
            mandatory = Text.truncateUtf8(subtitle, 40),
            callback = function()
                viewer(entity.name, formatEntity(entity))
            end,
        }
    end
    items[#items + 1] = {
        text = _("更新 X-Ray"),
        icon = "refresh",
        callback = function()
            if not ensureConfigured() then return end
            require("ui/network/manager"):runWhenOnline(function()
                runFetch(ui, identity, "incremental")
            end)
        end,
    }
    items[#items + 1] = {
        text = _("重新生成"),
        icon = "restart_alt",
        callback = function()
            if not ensureConfigured() then return end
            require("ui/network/manager"):runWhenOnline(function()
                runFetch(ui, identity, "force")
            end)
        end,
    }
    require("ui.components.popup").list{ title = title, items = items }
end

local function showTimeline(ui)
    local identity = currentIdentity()
    if not identity then
        info(_("当前书籍没有可用身份"))
        return
    end
    local events = require("xray.store").loadTimeline(identity)
    if #events == 0 then
        if not ensureConfigured() then return end
        UIManager:show(require("ui/widget/confirmbox"):new{
            text = _("尚无时间线。现在生成 X-Ray？"),
            ok_text = _("生成"),
            ok_callback = function()
                require("ui/network/manager"):runWhenOnline(function()
                    runFetch(ui, identity, "force")
                end)
            end,
        })
        return
    end
    local lines = {}
    for _, ev in ipairs(events) do
        lines[#lines + 1] = string.format("【%s】\n%s\n", ev.chapter, ev.event)
    end
    viewer(_("时间线"), table.concat(lines, "\n"))
end

--- 打开人物 / 地点 / 时间线面板。
---@param ui table|nil
---@param mode "characters"|"locations"|"timeline"
function UI.open(ui, mode)
    if mode == "locations" then
        showEntityList(ui, "location")
    elseif mode == "timeline" then
        showTimeline(ui)
    else
        showEntityList(ui, "character")
    end
end

--- 选词查询 / 补全实体。
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
        local input = require("ui/widget/inputdialog"):new{
            title = _("X-Ray 查询"),
            input_hint = _("人物或地点名称"),
            buttons = { {
                {
                    text = _("取消"),
                    id = "close",
                    callback = function()
                        UIManager:close(input)
                    end,
                },
                {
                    text = _("查询"),
                    is_enter_default = true,
                    callback = function()
                        local value = input:getInputText()
                        UIManager:close(input)
                        UI.lookup(ui, value)
                    end,
                },
            } },
        }
        UIManager:show(input)
        input:onShowKeyboard()
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
            viewer(entity.name, formatEntity(entity))
        end)
    end)
end

return UI
