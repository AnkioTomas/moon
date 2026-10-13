--[[--
X-Ray 阅读 UI：底部分栏主菜单、TextViewer 详情、划词补全。

@module koplugin.book.features.xray.ui
--]]

require("l10n").apply()

local List = require("ui.themes.widgets.list")
local ProgressDialog = require("ui.themes.widgets.progress_dialog")
local TextViewer = require("ui.themes.widgets.text_viewer")
local Toast = require("ui.themes.widgets.toast")
local Text = require("utils.text")
local Kinds = require("features.xray.kinds")
local XrayDB = require("features.xray.db")
local _ = require("gettext")
local T = require("ffi/util").template

local UI = {}

--- 当前打开的 X-Ray 主菜单（生成成功后刷新列表）。
---@type table|nil
local main_holder

--- 弹一条 3 秒自动消失的提示。
---@param text string
local function info(text)
    Toast:new{ text = text, timeout = 3 }:show()
end

--- 当前阅读会话的书籍身份；没有会话时 nil。
---@return BookIdentity|nil
local function currentIdentity()
    local current = require("reader.session").current()
    return current and current.identity
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

--- 展示已收录实体详情。
---@param entity table
function UI.showEntity(entity)
    local text = table.concat(entityLines(entity), "\n")
    TextViewer:new{
        title = entity.name,
        text = text ~= "" and text or _("（无内容）"),
        fullscreen = false,
    }:show()
end

--- 未配置 AI 或没联网时提示并拦下操作；离线立即失败，不等联网回调。
---@return boolean 是否可以继续
local function ensureReady()
    if not require("ai").isConfigured() then
        info(_("请先在月读设置中配置 AI 服务"))
        return false
    end
    if not require("ui/network/manager"):isConnected() then
        info(_("网络不可用，请先连接 Wi-Fi"))
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
            keep_open = true,
            callback = function()
                UI.showEntity(entity)
            end,
        }
    end
    if #items == 0 then
        items[1] = {
            text = _("暂无数据，点左上角重新生成"),
            enabled = false,
        }
    end
    return items
end

--- 生成完成后重载当前分栏，停在原页。
---@param holder table|nil
local function refreshMainTab(holder)
    if not holder or not holder.menu then
        return
    end
    holder.menu:setItems(rowsForTab(holder.menu.tabs.active, holder.identity))
end

--- 跑一次综合拉取：显示进行中提示，完成后报数、失效页内标记并刷新当前分栏。
---@param ui table ReaderUI
---@param identity BookIdentity
---@param force boolean|nil 为真则忽略已有缓存重新生成
local function runFetch(ui, identity, force)
    local Fetch = require("features.xray.fetch")
    local loading = ProgressDialog:new{
        title = _("X-Ray"),
        text = force and _("正在重新生成 X-Ray…") or _("正在生成 X-Ray…"),
        dismissable = false,
    }
    loading:show()
    --- 拉取回调：关掉进行中提示，成功报三类数量，失败提示原因。
    ---@param result table|nil
    local cb = function(result, err)
        loading:close()
        if not result then
            info(T(_("X-Ray 失败：%1"), tostring(err or _("未知错误"))))
            return
        end
        info(T(_("X-Ray 已更新：人物 %1，地点 %2，专有名词 %3"),
            tostring(#result.characters),
            tostring(#result.locations),
            tostring(#result.terms)))
        require("features.xray.marks").invalidate()
        refreshMainTab(main_holder)
    end
    Fetch.comprehensive(ui, identity, { force = force == true }, cb)
end

--- 强制重新生成当前书籍的 X-Ray。
---@param ui table|nil
---@param identity BookIdentity|nil
function UI.refresh(ui, identity)
    identity = identity or currentIdentity()
    if not ui or not identity then
        info(_("当前书籍没有可用身份"))
        return
    end
    if not ensureReady() then return end
    runFetch(ui, identity, true)
end

--- 分析全书：前台取出全书正文（不可取消），再交给后台任务逐段请求 AI；
--- 这本书已在分析就只跟随它的进度。
---@param ui table ReaderUI
---@param identity BookIdentity
function UI.scanBook(ui, identity)
    if not ensureReady() then return end
    local TaskDialog = require("workers.ui.task_dialog")
    local key = "xray\0" .. identity.source_id .. "\0" .. identity.stable_id
    local running = require("workers.tasks").get(key)
    if running then
        TaskDialog.follow(running)
        return
    end
    local function start()
        local dialog = ProgressDialog:new{ title = _("X-Ray"), dismissable = false }
        dialog:show()
        require("features.reflow.extract").run(ui, function(text, err)
            dialog:close()
            if not text then
                info(T(_("X-Ray 失败：%1"), tostring(err)))
                return
            end
            local title = Text.trim((identity.book or {}).title)
            TaskDialog.start{
                key = key,
                kind = "ai",
                title = title ~= "" and title or _("X-Ray"),
                restartable = true,
                run = require("features.xray.fetch").scanBook(identity, text),
                retryable = function() return true end,
                on_done = function(result)
                    if not result.ok then
                        info(T(_("X-Ray 失败：%1"), tostring(result.err or _("未知错误"))))
                        return
                    end
                    info(_("X-Ray 全书分析完成"))
                    refreshMainTab(main_holder)
                end,
            }
        end, function(step, done, total) dialog:update(step, done, total) end)
    end
    require("ui.themes.widgets.confirm"):new{
        text = _("逐段读取全书，由 AI 一次性提取所有人物、地点和专有名词，结果包含剧透。书越长请求越多、耗时越久，可转到后台运行。继续？"),
        ok_text = _("继续"),
        ok_callback = start,
    }:show()
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
    local holder = { identity = identity }
    main_holder = holder
    holder.menu = List:new{
        title = _("X-Ray"),
        subtitle = Kinds.label(initial_tab),
        items = rowsForTab(initial_tab, identity),
        left_icon = "sync",
        left_callback = function()
            require("ui.themes.widgets.sheet"):new{ title = _("X-Ray"), items = {
                { text = _("按当前位置更新"), callback = function() UI.refresh(ui, identity) end },
                { text = _("分析全书（含剧透）"), callback = function() UI.scanBook(ui, identity) end },
            } }:show()
        end,
        tabs = { tabs = Kinds, active = initial_tab, on_tab = function(tab_id)
            holder.menu.subtitle = Kinds.label(tab_id)
            return rowsForTab(tab_id, identity)
        end },
        close_callback = function()
            if main_holder == holder then
                main_holder = nil
            end
        end,
    }
    holder.menu:show()
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
    local Fetch = require("features.xray.fetch")
    -- 已收录的直接出详情：离线、未配置 AI 也能查。
    local hit = Fetch.findLocal(identity, word)
    if hit then
        UI.showEntity(hit)
        return
    end
    if not ensureReady() then return end
    local loading = ProgressDialog:new{ title = word, text = _("X-Ray 查询中…"), dismissable = false }
    loading:show()
    Fetch.lookupWord(ui, identity, word, function(entity, err)
        loading:close()
        if not entity then
            info(T(_("未找到：%1"), tostring(err or word)))
            return
        end
        UI.showEntity(entity)
        require("features.xray.marks").invalidate()
    end)
end

return UI
