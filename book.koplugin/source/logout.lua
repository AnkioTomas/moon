--[[--
账号源退出登录与连接切换。

先停在飞同步、删掉本地凭证、丢掉还握着令牌的源实例，再清书架和阅读记录。
凭证还在时不许动本地书架：清库一旦被看成删书，同步就会把远端书架删掉。
清库本身不写墓碑、不上传。

换账号 / 服务器保留本地书籍与阅读记录；可加架的成员重推，其余由新书架快照下架。
旧账号墓碑不送往新账号，主动退出仍清除本地记录。

@module koplugin.book.source.logout
--]]

require("l10n").apply()
local _ = require("gettext")

local Logout = {}

local TASK_PREFIXES = { "dirty\0", "books\0", "books-upload\0", "cache\0", "install\0" }

--- 停掉这个源还在跑的同步和缓存，免得清完之后回调又写回来。
---@param source_id string
function Logout.abort(source_id)
    for _idx, name in ipairs({ "book.progress", "book.note", "book.stats" }) do
        local domain = package.loaded[name]
        if domain then domain.abortSource(source_id) end
    end
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

--- 换号公共前缀：准备本地同步、抬账号版本、停在飞任务（关阅读器由调用方先做）。
---@param source_id string
---@param shelf_add boolean
---@param stable_prefix string|nil
---@param source BookSource|nil
---@return boolean
local function beginSwitch(source_id, shelf_add, stable_prefix, source)
    if not require("book.books_db").prepareAccountSync(source_id, shelf_add, stable_prefix, source) then
        return false
    end
    require("source.auth").changeAccount(source_id)
    Logout.abort(source_id)
    return true
end

--- 换号前撤销旧凭证；保留数据并准备向新账号同步，不弹提示、不发网络请求。
---@param source_id string
---@param clear fun()
---@return boolean
function Logout.clear(source_id, clear)
    closeReader(source_id)
    local Registry = require("source.registry")
    local source = Registry.resolve(source_id)
    if not source then return false end
    if not beginSwitch(source_id, source:capabilities().shelf_add == true, nil, source) then
        return false
    end
    clear()
    Registry.invalidate()
    return true
end

--- 换服务器 / 换账号库：保留数据，准备成功后才提交新配置。
---@param source_id string
---@param commit fun()|nil
---@return boolean
function Logout.replaceLibrary(source_id, commit)
    closeReader(source_id)
    local Registry = require("source.registry")
    local source = Registry.resolve(source_id)
    if not source then return false end
    if not beginSwitch(source_id, source:capabilities().shelf_add == true, nil, source) then
        return false
    end
    Registry.invalidate()
    if commit then commit() end
    Registry.reload()
    return true
end

--- 换 WebDAV 地址 / 目录 / 账号：保留远端书身份与镜像，不动纯本地书。
---@param commit fun()|nil
---@return boolean
function Logout.replaceWebdav(commit)
    closeReader("local")
    local Registry = require("source.registry")
    local cfg = require("utils.settings").getSource("local")
    if not beginSwitch("local", cfg.webdav_upload_local ~= false, "webdav://") then
        return false
    end
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
    closeReader(source_id)
    require("source.auth").changeAccount(source_id)
    Logout.abort(source_id)
    clear()
    require("source.registry").invalidate()
    local forgotten = require("book.store").forgetSource(source_id)
    require("source.registry").reload()
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
