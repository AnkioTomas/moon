--[[--
账号源退出登录；换服务器 / 换 WebDAV 根时清本地书架。

先停在飞同步、删掉本地凭证、丢掉还握着令牌的源实例，再清书架和阅读记录。
凭证还在时不许动本地书架：清库一旦被看成删书，同步就会把远端书架删掉。
清库本身不写墓碑、不上传。

换库身份（`replaceLibrary` / `replaceWebdav`）时先清旧库投影，成功后才保存新凭证并重载。
清理失败保留旧配置与源实例，不写墓碑，不把旧库记录送往新库。

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

--- 正在读这个源的书就先关文档，免得清库后会话握着幽灵身份。
---@param source_id string
local function closeReader(source_id)
    local snapshot = require("reader.session").current()
    if snapshot and snapshot.identity and snapshot.identity.source_id == source_id then
        snapshot.ui:onClose()
    end
end

--- 退出与换号共用清理；不弹提示，不发远端删书请求。
---@param source_id string
---@param clear fun()
---@return boolean
function Logout.clear(source_id, clear)
    closeReader(source_id)
    require("source.auth").beginLogin(source_id)
    Logout.abort(source_id)
    clear()
    local Registry = require("source.registry")
    Registry.invalidate()
    local forgotten = require("book.store").forgetSource(source_id)
    if not forgotten then Registry.reload() end
    return forgotten
end

--- 换服务器 / 换账号库：本地书架与旧库无关，整源撕掉再 reload 拉新库。
--- 新配置通过 commit 在清理成功后落盘；不写墓碑。
---@param source_id string
---@param commit fun()|nil
---@return boolean
function Logout.replaceLibrary(source_id, commit)
    closeReader(source_id)
    Logout.abort(source_id)
    if not require("book.store").forgetSource(source_id) then return false end
    local Registry = require("source.registry")
    Registry.invalidate()
    if commit then commit() end
    Registry.reload()
    return true
end

--- 换 WebDAV 地址 / 目录：只撕 local 源里 webdav:// 的书；纯本地绝对路径书不动。
---@param commit fun()|nil
---@return boolean
function Logout.replaceWebdav(commit)
    closeReader("local")
    Logout.abort("local")
    if not require("book.store").forgetWebdav() then return false end
    local Registry = require("source.registry")
    Registry.invalidate()
    if commit then commit() end
    Registry.reload()
    return true
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
