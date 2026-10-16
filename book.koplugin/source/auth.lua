--[[--
数据源登录失效状态（进程内，不落盘）。

源 / 客户端在「静默续期也救不回来」时调 ``Auth.expire(id, msg)``；任一带凭据请求成功调
``Auth.ok(id)``；改登录配置走 ``Registry.reload`` → ``Auth.reset()``。
每个源每次运行（或每次重新登录后）只回调一次上层注入的 handler（引导重新登录的弹窗），
之后后台同步跳过该源，直到用户重新登录或手动操作成功，不会每轮同步都弹。
本模块不 require 上层：提示 UI 由 main 经 ``Auth.onExpired`` 注入。

@module koplugin.book.source.auth
--]]

local logger = require("utils.log")

local Auth = {}

---@type table<string, string> 源 id → 失效原因
local expired = {}
---@type fun(id: string, msg: string)|nil
local handler
---@type table<string, boolean> 本次运行已提示过的源；只在重新登录（reset）时清掉，免得反复弹
local prompted = {}

--- 注入失效提示（上层 UI）。
---@param fn fun(id: string, msg: string)|nil
function Auth.onExpired(fn) handler = fn end

--- 标记源登录失效；原样返回 msg 方便 ``cb(nil, Auth.expire(id, msg))``。
---@param id string
---@param msg any
---@return any
function Auth.expire(id, msg)
    if expired[id] == nil then logger.warn("book source auth expired", id, msg) end
    expired[id] = tostring(msg or "")
    if not prompted[id] then
        prompted[id] = true
        if handler then
            local ok, err = pcall(handler, id, expired[id])
            if not ok then logger.warn("book source auth handler failed", id, err) end
        end
    end
    return msg
end

--- 带凭据的请求成功：清掉失效标记。
---@param id string
function Auth.ok(id) expired[id] = nil end

---@param id string
---@return boolean
function Auth.expired(id) return expired[id] ~= nil end

--- 登录配置变了：全部重新判定。
function Auth.reset() expired, prompted = {}, {} end

return Auth
