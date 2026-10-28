--[[--
远程配置路由：GET/POST /api/settings。

@module koplugin.book.features.remote.settings_route
--]]

local JSON = require("json")
local SettingsApi = require("features.remote.settings")

local Route = {}

--- /api/settings body 收尾：做部分更新，回写实际生效的字段。
--- 空 body 等价于提交 {}（_acceptJson 处理）；apply 拒绝回 400（带原因）。
---@param conn table
---@param payload table 已解析的请求体
function Route.finishSettings(self, conn, payload)
    local applied, err = SettingsApi.apply(payload)
    if not applied then
        return self:_fail(conn, 400, err)
    end
    return self:_json(conn, 200, JSON.encode(applied))
end

--- GET /api/settings 回配置快照；POST 收 JSON 走 finishSettings 做部分更新。其余方法 405。
---@param conn table
---@param method string
---@param headers table 已小写化的请求头
function Route.settings(self, conn, method, headers, _query)
    if method == "GET" then
        return self:_json(conn, 200, JSON.encode(SettingsApi.snapshot()))
    end
    if method ~= "POST" then
        return self:_fail(conn, 405, "Method Not Allowed")
    end
    return self:_acceptJson(conn, headers, SettingsApi.BODY_LIMIT, Route.finishSettings)
end

return Route
