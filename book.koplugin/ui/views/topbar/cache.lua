--[[--
顶栏后台任务（全本缓存、书城下载、手动同步书架）。Resume 听队列，Pause 停听，进度原地更新。
id 仍叫 cache：用户的顶栏显示设置按这个键存。

@module koplugin.book.ui.views.topbar.cache
--]]

local Tasks = require("tasks")
local _ = require("gettext")
local T = require("ffi/util").template
local Base = require("ui.views.topbar.base")

---@class BookTopBarCache : BookTopBarItem
local Cache = {}
Cache.__index = Cache
setmetatable(Cache, Base)
Cache.id = "cache"

--- 订阅任务队列变化并立即刷新进度；订阅句柄由 Lifecycle 拥有。
function Cache:onResume()
    if not self._watch then
        self._watch = self.lifecycle:addHttp(Tasks.watch(function()
            self:updateView()
        end))
    end
    self:updateView()
end

--- 读取排在最前的后台任务进度；设置隐藏或没有任务时返回 nil。
---@return string|nil, string|nil
function Cache:read()
    if not Base.visible("cache") then
        return nil
    end
    local task = Tasks.tasks()[1]
    if not task then return nil end
    local text
    if task.state == "waiting" then
        text = _("等待网络")
    elseif task.state == "retry_wait" then
        text = T(_("%1重试中"), task.label)
    elseif task.total > 0 then
        text = task.label .. " " .. tostring(task.count) .. "/" .. tostring(task.total)
    else
        text = T(_("%1中"), task.label)
    end
    return text, "download"
end

--- 构建后台任务进度和下载图标对应的指标控件；隐藏时返回零尺寸占位 Widget。
---@return table|nil
function Cache:createWidget()
    self.metric_widget = nil
    self.rect = nil
    self.metric_widget = Base.metric("download", self:read())
    return self.metric_widget or require("ui/widget/widget"):new{ dimen = require("ui/geometry"):new{ w = 0, h = 0 } }
end

--- 清除已由 Lifecycle 取消的任务队列订阅引用。
function Cache:onPause()
    self._watch = nil
end

--- 打开实时刷新的后台任务列表；关窗不影响任务。
function Cache:show()
    require("ui.components.task_dialog"):new{}:show()
end

return Cache
