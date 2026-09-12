--[[--
顶栏后台缓存任务。Resume 听队列，Pause 停听，进度原地更新。

@module koplugin.book.ui.components.topbar.cache
--]]

local CacheQueue = require("source.cache_queue")
local _ = require("gettext")
local Base = require("ui.components.topbar.base")

---@class BookTopBarCache : BookTopBarItem
local Cache = setmetatable({}, Base)
Cache.__index = Cache
Cache.id = "cache"

--- 订阅缓存队列变化并立即刷新进度；订阅句柄由 Lifecycle 拥有。
---@return nil
function Cache:onResume()
    if not self._watch then
        self._watch = self.lifecycle:addHttp(CacheQueue.watch(function()
            self:updateView()
        end))
    end
    self:updateView()
end

--- 读取后台缓存任务进度和下载图标；设置隐藏或数据不可用时返回 nil。
---@return string|nil, string|nil
function Cache:read()
    if not Base.visible("cache") then
        return nil
    end
    local status = CacheQueue.status()
    if not status then return nil end
    local text
    if status.state == "retry_wait" then
        text = _("缓存重试中")
    elseif status.total > 0 then
        text = _("缓存") .. " " .. tostring(status.cached) .. "/" .. tostring(status.total)
    else
        text = _("缓存中")
    end
    return text, "download"
end

--- 构建后台缓存任务进度和下载图标对应的指标控件；隐藏时返回零尺寸占位 Widget。
---@return table|nil
function Cache:createWidget()
    self.metric_widget = nil
    self.rect = nil
    self.metric_widget = Base.metric("download", self:read())
    return self.metric_widget or require("ui/widget/widget"):new{ dimen = require("ui/geometry"):new{ w = 0, h = 0 } }
end

--- 清除已由 Lifecycle 取消的缓存队列订阅引用。
---@return nil
function Cache:onPause()
    self._watch = nil
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
