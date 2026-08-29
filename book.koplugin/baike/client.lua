--[[--
百度百科卡片接口：请求与响应清洗，不涉及 UI。

接口只返回单条词条，歧义词由百度的默认消歧规则决定；因此这里不伪造
维基百科的多语言、搜索结果列表或全文导出能力。

@module koplugin.book.baike.client
--]]

local JSON = require("json")
local logger = require("logger")
local Text = require("utils.text")

local Client = {
    endpoint = "https://baike.baidu.com/api/openapi/BaikeLemmaCardApi",
}

local MAX_CARD_ITEMS = 12

--- 构造百科卡片请求地址。
---@param word string
---@return string
function Client.url(word)
    return Client.endpoint
        .. "?scope=103&format=json&appid=379020&bk_length=600&bk_key="
        .. Text.urlEncode(Text.trim(word))
end

---@param value any
---@return string
local function cleanText(value)
    if type(value) == "table" then
        local parts = {}
        for _, item in ipairs(value) do
            local text = cleanText(item)
            if text ~= "" then
                parts[#parts + 1] = text
            end
        end
        value = table.concat(parts, "、")
    end
    local text = Text.xmlDecode(tostring(value or ""))
    text = text:gsub("<%s*[bB][rR][^>]*>", "\n")
        :gsub("</%s*[pP]%s*>", "\n")
        :gsub("<[^>]->", "")
    text = text:gsub("\r\n?", "\n")
    local lines = {}
    for line in text:gmatch("[^\n]+") do
        line = Text.trim(line)
        if line ~= "" then
            lines[#lines + 1] = line
        end
    end
    return table.concat(lines, "\n")
end

--- 把接口响应规整成原生词典弹窗所需的单条结果。
---@param payload table
---@return { title: string, definition: string }|nil
function Client.parseResponse(payload)
    if type(payload) ~= "table" then
        return nil
    end
    local title = cleanText(payload.title)
    if title == "" then
        return nil
    end

    local parts = {}
    local abstract = cleanText(payload.abstract)
    if abstract ~= "" then
        parts[#parts + 1] = abstract
    end

    local details = {}
    for _, item in ipairs(payload.card or {}) do
        if #details >= MAX_CARD_ITEMS then
            break
        end
        local name = cleanText(item.name)
        local value = cleanText(item.value)
        if name ~= "" and value ~= "" then
            details[#details + 1] = name .. "：" .. value
        end
    end
    if #details > 0 then
        parts[#parts + 1] = table.concat(details, "\n")
    end
    return {
        title = title,
        definition = table.concat(parts, "\n\n"),
    }
end

--- 异步查询百度百科。
---@param word string
---@param callback fun(entry: { title: string, definition: string }|nil, err: string|nil)
---@return { cancel: fun() }|nil
function Client.lookupAsync(word, callback)
    local query = Text.trim(word)
    if query == "" then
        callback(nil, "empty query")
        return nil
    end
    local Request = require("http.request")
    return Request.get(Client.url(query), {
        accept = "application/json",
        connect_timeout = 10,
        timeout = 20,
    }, function(content, err)
        if err then
            callback(nil, tostring(err))
            return
        end
        local ok, payload = pcall(JSON.decode, content, JSON.decode.simple)
        if not ok then
            logger.warn("invalid Baidu Baike response:", payload)
            callback(nil, "invalid response")
            return
        end
        local entry = Client.parseResponse(payload)
        if not entry then
            callback(nil, "not found")
            return
        end
        callback(entry)
    end)
end

return Client
