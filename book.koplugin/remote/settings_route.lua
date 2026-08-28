--[[--
远程配置路由：GET/POST /api/settings。

@module koplugin.book.remote.settings_route
--]]

local JSON = require("json")
local SettingsApi = require("remote.settings")

local Route = {}

Route.BODY_LIMIT = SettingsApi.BODY_LIMIT

--- /api/settings body 收尾：解析 JSON 后做部分更新，回写实际生效的字段。
--- JSON 非法或 apply 拒绝都回 400（带原因）。
---@param conn table
---@param text string 收齐的请求体 JSON 文本
function Route.finishSettings(self, conn, text)
    local payload, err = JSON.decode(text)
    if not payload then
        return self:_fail(conn, 400, err or "invalid json")
    end
    local applied
    applied, err = SettingsApi.apply(payload)
    if not applied then
        return self:_fail(conn, 400, err)
    end
    return self:_queueResponse(conn, {
        code = 200,
        ctype = "application/json; charset=utf-8",
        body = JSON.encode(applied),
    })
end

--- GET /api/settings 回配置快照；POST 收 JSON 走 finishSettings 做部分更新。
--- 其余方法 405；空 body 等价于提交 {}。
---@param conn table
---@param method string
---@param headers table 已小写化的请求头
---@return true|nil true=已进 body 状态，等收齐后回调
function Route.settings(self, conn, method, headers, _query)
    if method == "GET" then
        return self:_queueResponse(conn, {
            code = 200,
            ctype = "application/json; charset=utf-8",
            body = JSON.encode(SettingsApi.snapshot()),
        })
    end
    if method ~= "POST" then
        return self:_fail(conn, 405, "Method Not Allowed")
    end
    local st = self:_acceptText(conn, headers, Route.BODY_LIMIT, Route.finishSettings)
    if st == nil then
        return
    end
    if st then
        return true
    end
    -- 空 body = 空 JSON 部分更新
    return Route.finishSettings(self, conn, "{}")
end

return Route
