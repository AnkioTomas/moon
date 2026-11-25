--[[--
月读插件市场 API 客户端（https://moon-store.ankio.net/）。

接口：
  GET /api/v1/store/plugins?page=&pageSize=100
  GET /api/v1/store/plugins/{uid}
  GET /api/v1/store/categories

@module koplugin.book.features.marketplace.client
--]]

local Request = require("http.request")
local Text = require("utils.text")
local Json = require("utils.json")

local Client = {}

Client.BASE_URL = "https://moon-store.ankio.net"
Client.PAGE_SIZE = 100
Client.MAX_PAGES = 50

---@param err any
---@param res table|nil
---@return string
function Client.classify(err, res)
    local code = res and res.code
    if code == 429 then return "rate_limit" end
    if code == 404 then return "not_found" end
    if code == 401 or code == 403 then return "forbidden" end
    if type(err) == "string" then
        if err:find("HTTP 429", 1, true) then return "rate_limit" end
        if err:find("HTTP 404", 1, true) then return "not_found" end
        if err:find("HTTP 403", 1, true) or err:find("HTTP 401", 1, true) then return "forbidden" end
    end
    if err then return "network" end
    return "http"
end

---@param text string|nil
---@return any
---@return string|nil
function Client.decodeJson(text)
    if type(text) ~= "string" or text == "" then return nil, "not_json" end
    if not text:match("^%s*([{%[])") then
        return nil, "not_json"
    end
    local ok, data = pcall(Json.decode, text)
    if not ok or data == nil then return nil, "not_json" end
    return data
end

--- GET 指定相对路径并解码 JSON。
---@param path string 以 / 开头
---@param cb fun(data: table|nil, err: string|nil, res: table|nil)
---@return table job
function Client.getJson(path, cb)
    local url = Client.BASE_URL .. path
    return Request.get(url, {
        headers = { Accept = "application/json" },
        allow_redirects = true,
        cache_ttl = 0,
    }, function(body, err, res)
        if err then
            cb(nil, Client.classify(err, res), res)
            return
        end
        local data, parse_err = Client.decodeJson(body)
        if not data or type(data) ~= "table" then
            cb(nil, parse_err or "not_json", res)
            return
        end
        cb(data, nil, res)
    end)
end

--- 按页拉取全部插件目录，供离线浏览、搜索与更新比对。
---@param cb fun(items: table[]|nil, err: string|nil)
---@param on_progress (fun(done: integer, total: integer))|nil
---@return table job
function Client.listPlugins(cb, on_progress)
    local cancelled = false
    local current
    local all, seen = {}, {}
    local page = 1

    local function fetchPage()
        if cancelled then return end
        local path = string.format("/api/v1/store/plugins?page=%d&pageSize=%d", page, Client.PAGE_SIZE)
        current = Client.getJson(path, function(data, err)
            if cancelled then return end
            if err or type(data) ~= "table" or type(data.data) ~= "table" then
                cb(nil, err or "not_json")
                return
            end
            local rows = data.data
            local total = tonumber(data.count) or #rows
            for _idx, row in ipairs(rows) do
                if type(row) == "table" and type(row.uid) == "string" and row.uid ~= "" and not seen[row.uid] then
                    seen[row.uid] = true
                    all[#all + 1] = row
                end
            end
            if type(on_progress) == "function" then
                on_progress(#all, math.max(total, #all))
            end
            local more = #rows >= Client.PAGE_SIZE
                and #all < total
                and page < Client.MAX_PAGES
            if more then
                page = page + 1
                fetchPage()
                return
            end
            cb(all, nil)
        end)
    end

    fetchPage()
    return { cancel = function()
        cancelled = true
        if current and current.cancel then current.cancel() end
    end }
end

--- 获取固定分类目录。
---@param cb fun(items: table[]|nil, err: string|nil)
---@return table job
function Client.listCategories(cb)
    return Client.getJson("/api/v1/store/categories", function(data, err)
        if err or type(data) ~= "table" or type(data.data) ~= "table" then
            cb(nil, err or "not_json")
            return
        end
        cb(data.data, nil)
    end)
end

--- 获取单个插件详情（含 meta、default_branch、release_assets 与 readme）。
---@param uid string
---@param cb fun(detail: table|nil, err: string|nil)
---@return table job
function Client.getDetail(uid, cb)
    if type(uid) ~= "string" or uid == "" then
        cb(nil, "not_found")
        return { cancel = function() end }
    end
    local path = "/api/v1/store/plugins/" .. Text.urlEncode(uid)
    return Client.getJson(path, function(data, err)
        if err or type(data) ~= "table" or type(data.data) ~= "table" then
            cb(nil, err or "not_found")
            return
        end
        cb(data.data, nil)
    end)
end

return Client
