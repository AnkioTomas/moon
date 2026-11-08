--[[--
账号源退出登录。

先停在飞同步、删掉本地凭证、丢掉还握着令牌的源实例，再清书架和阅读记录。
凭证还在时不许动本地书架：清库一旦被看成删书，同步就会把远端书架删掉。
清库本身不写墓碑、不上传。

@module koplugin.book.source.logout
--]]

require("l10n").apply()
local _ = require("gettext")

local Logout = {}

local TASK_PREFIXES = { "dirty\0", "books\0", "books-upload\0", "cache\0", "install\0" }

--- 停掉这个源还在跑的同步和缓存，免得清完之后回调又写回来。
---@param source_id string
function Logout.abort(source_id)
    local Tasks = require("workers.tasks")
    for _idx, prefix in ipairs(TASK_PREFIXES) do
        Tasks.cancelPrefixed(prefix .. source_id)
    end
    local stack = require("ui/uimanager")._window_stack
    for index = #stack, 1, -1 do
        local widget = stack[index].widget
        if widget.name == "book_desktop" then
            require("desktop.sync").abort(widget, source_id)
            return
        end
    end
end

--- 退出与换号共用清理；不弹提示，不发远端删书请求。
---@param source_id string
---@param clear fun()
---@return boolean
function Logout.clear(source_id, clear)
    local snapshot = require("reader.session").current()
    if snapshot and snapshot.identity and snapshot.identity.source_id == source_id then snapshot.ui:onClose() end
    require("source.auth").beginLogin(source_id)
    Logout.abort(source_id)
    clear()
    local Registry = require("source.registry")
    Registry.invalidate()
    local forgotten = require("book.store").forgetSource(source_id)
    if not forgotten then Registry.reload() end
    return forgotten
end

--- 清库失败也保持登出：宁可本地残留，不许带着凭证改书架。
---@param source_id string
---@param clear fun()
---@return boolean
function Logout.perform(source_id, clear)
    local forgotten = Logout.clear(source_id, clear)
    if forgotten then require("source.registry").reload() end
    require("ui.themes.widgets.toast"):new{
        text = forgotten and _("已退出登录") or _("清除本地记录失败"),
        timeout = forgotten and 2 or 3,
    }:show()
    return forgotten
end

--- 设置页「退出登录」行。text 是确认文案，后面会补上本地记录一并清除的说明。
---@param source_id string
---@param text string
---@param clear fun()
---@return fun(iw: integer): table
function Logout.row(source_id, text, clear)
    return function(iw)
        return require("ui.themes.widgets.row").widget({
            width = iw, chevron = false, kind = "action", icon = "logout",
            title = _("退出登录"),
            callback = function()
                require("ui.themes.widgets.confirm"):new{
                    text = text .. "\n\n" .. _("这台设备上这个书源的书架、阅读进度、笔记和缓存会一并清除。"),
                    ok_text = _("退出登录"),
                    ok_callback = function() Logout.perform(source_id, clear) end,
                }:show()
            end,
        })
    end
end

return Logout
