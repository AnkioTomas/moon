--[[--
数据源登录失效状态（进程内，不落盘）。

源 / 客户端在「静默续期也救不回来」时调 ``Auth.expire(id, msg)``；
``msg`` 必须是给人看的中文（如「微信读书登录已失效」），禁止塞 ``NOT.LOGIN`` / ``code=`` /
``HTTP 401`` 一类接口原文——弹窗由 ``Sync.promptLogin`` 统一写清楚，技术细节只打日志。
任一带凭据请求成功调 ``Auth.ok(id)``；改登录配置走 ``Registry.reload`` → ``Auth.reset()``。
每个源每次运行（或每次重新登录后）只回调一次上层注入的 handler（引导重新登录的弹窗），
之后后台同步跳过该源，直到用户重新登录或手动操作成功，不会每轮同步都弹。
本模块不 require 上层：提示 UI 由 main 经 ``Auth.onExpired`` 注入。

@module koplugin.book.source.auth
--]]

local logger = require("utils.log")

local Auth = {}

---@type table<string, string> 源 id → 失效原因（给人看的）
local expired = {}
---@type fun(id: string, msg: string)|nil
local handler
---@type table<string, boolean> 本次运行已提示过的源；只在重新登录（reset）时清掉，免得反复弹
local prompted = {}

--- 接口原文 / 调试串：不能进弹窗。
---@param msg any
---@return boolean
function Auth.isTechnical(msg)
    if type(msg) ~= "string" or msg == "" then return true end
    local upper = msg:upper()
    if upper:find("NOT.LOGIN", 1, true) or upper:find("NOT_LOGIN", 1, true) then return true end
    if msg:find("code=", 1, true) or msg:find("HTTP ", 1, true) then return true end
    -- 无非 ASCII：多半是英文错误码，不是给用户的中文说明
    if not msg:find("[\128-\255]") then return true end
    return false
end

--- 弹窗可用的附加说明；技术串返回 nil（只留统一模板）。
---@param msg any
---@return string|nil
function Auth.userDetail(msg)
    if Auth.isTechnical(msg) then return nil end
    return msg
end

--- 注入失效提示（上层 UI）。
---@param fn fun(id: string, msg: string)|nil
function Auth.onExpired(fn) handler = fn end

--- 标记源登录失效；原样返回 msg 方便 ``cb(nil, Auth.expire(id, msg))``。
--- msg 应是中文说明；技术串仍会记日志并触发弹窗，但不会作为弹窗正文细节。
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
