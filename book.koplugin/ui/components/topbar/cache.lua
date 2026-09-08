--[[--
顶栏后台缓存任务。onStart 听队列，onStop 停听，进度原地更新。

@module koplugin.book.ui.components.topbar.cache
--]]

local CacheQueue = require("source.cache_queue")
local _ = require("gettext")
local Base = require("ui.components.topbar.base")

local Cache = setmetatable({}, Base)
Cache.__index = Cache
Cache.id = "cache"

function Cache:onResume()
    local text, icon = self:read()
    self:updateMetric(icon, text)
end

---@return string|nil
function Cache:read()
    if not Base.visible("cache") then
        return nil
    end
    local status = CacheQueue.status()
    if not status then return nil end
    if status.state == "retry_wait" then
        return _("缓存重试中")
    end
    if status.total > 0 then
        return _("缓存") .. " " .. tostring(status.cached) .. "/" .. tostring(status.total)
    end
    return _("缓存中")
end

---@return table|nil
function Cache:build()
    self.widget = nil
    self.rect = nil
    self.widget = Base.metric("download", self:read())
    return self.widget
end

function Cache:onStart()
    if self._watch then return end
    self._watch = CacheQueue.watch(function()
        self:updateMetric("download", self:read())
    end)
end

function Cache:onStop()
    if self._watch then
        self._watch:cancel()
        self._watch = nil
    end
end

function Cache:onDestroy()
    self:onStop()
end

--- 打开全本缓存任务快照；队列本身继续在后台运行。
---@return nil
function Cache:show()
    local tasks = CacheQueue.tasks()
    local ButtonDialog = require("ui/widget/buttondialog")
    local UIManager = require("ui/uimanager")
    local rows = {}
    for _i, task in ipairs(tasks) do
        local state = task.state == "running" and _("正在缓存")
            or task.state == "retry_wait" and _("缓存重试中")
            or _("等待缓存")
        local text = tostring(task.title or task.stable_id or "") .. " · " .. state
        if task.total > 0 then
            text = text .. " " .. tostring(task.cached) .. "/" .. tostring(task.total)
        end
        rows[#rows + 1] = {{ text = text, enabled = false }}
    end
    if #rows == 0 then
        rows[1] = {{ text = _("当前没有缓存任务"), enabled = false }}
    end
    local dialog
    rows[#rows + 1] = {{ text = _("关闭"), callback = function()
        if dialog then UIManager:close(dialog) end
    end }}
    dialog = ButtonDialog:new{
        title = _("缓存任务"),
        buttons = rows,
    }
    UIManager:show(dialog)
end

return Cache
