--[[--
番茄官方阅读页适配：只解析 HTML 里的 __INITIAL_STATE__，不执行页面 JS。

@module koplugin.book.source.fanqie.official
--]]

local Cookie = require("source.fanqie.cookie")
local JSON = require("json")

local Official = {}

--- 抽取平衡的 JSON 对象，尊重字符串内转义引号与花括号。
---@param html string
---@return string
function Official.extract_state(html)
    if type(html) ~= "string" or #html > 4 * 1024 * 1024 then
        error("官方阅读页为空或过大")
    end
    local _, pos = html:find("window%.__INITIAL_STATE__%s*=%s*")
    if not pos or html:sub(pos + 1, pos + 1) ~= "{" then
        error("官方阅读页未提供正文数据，可能需要验证或页面结构已变化")
    end
    local start = pos + 1
    local depth, quoted, escaped = 0, false, false
    for i = start, #html do
        local c = html:sub(i, i)
        if quoted then
            if escaped then
                escaped = false
            elseif c == "\\" then
                escaped = true
            elseif c == '"' then
                quoted = false
            end
        elseif c == '"' then
            quoted = true
        elseif c == "{" then
            depth = depth + 1
        elseif c == "}" then
            depth = depth - 1
            if depth == 0 then
                return html:sub(start, i)
            end
        end
    end
    error("官方阅读页数据不完整")
end

---@param html string
---@param decode fun(raw: string): table
---@param book_id string
---@param item_id string
---@return { content: string, title: string, author: string, source: string }
function Official.parse(html, decode, book_id, item_id)
    local ok, state = pcall(decode, Official.extract_state(html))
    if not ok or type(state) ~= "table" then
        error("官方阅读页数据格式不兼容")
    end
    local chapter = type(state.reader) == "table" and state.reader.chapterData
    if type(chapter) ~= "table" then
        error("官方阅读页未提供该章节")
    end
    if tostring(chapter.itemId or "") ~= item_id
        or tostring(chapter.bookId or "") ~= book_id
    then
        error("官方阅读页章节标识不匹配，未保存内容")
    end
    if chapter.needPay ~= 0 and chapter.needPay ~= "0" and chapter.needPay ~= false then
        error("官方网页未确认正文阅读权限，请在官方平台检查登录或购买状态")
    end
    if chapter.isPreview == true or chapter.isFull == false then
        error("官方网页仅返回试读内容，未保存为完整章节")
    end
    if type(chapter.content) ~= "string" or not chapter.content:match("%S") then
        error("官方网页正文为空，该章节可能仅支持 App 阅读")
    end
    return {
        content = chapter.content,
        title = chapter.title or "",
        author = chapter.author or "",
        source = "official_web",
    }
end

---@param client FanqieClient
---@param book_id string
---@param item_id string
---@param cb fun(data: table|nil, err: string|nil)
---@return { cancel: fun() }
function Official.fetchAsync(client, book_id, item_id, cb)
    book_id, item_id = tostring(book_id or ""), tostring(item_id or "")
    if not book_id:match("^%d+$") or not item_id:match("^%d+$") then
        cb(nil, "章节 ID 无效")
        return { cancel = function() end }
    end
    return client:requestAsync({
        url = "https://fanqienovel.com/reader/" .. item_id,
        method = "GET",
        timeout = 20,
        allow_redirects = false,
        headers = {
            ["Accept"] = "text/html",
            ["Referer"] = "https://fanqienovel.com/",
            ["Cookie"] = Cookie.to_header(client.settings:get("cookies", {})),
            ["User-Agent"] = require("source.fanqie.fanqie").USER_AGENT,
        },
    }, function(res, err)
        if not res then
            cb(nil, err)
            return
        end
        local code = tonumber(res.code)
        if code ~= 200 then
            local reasons = {
                [401] = "登录已失效",
                [403] = "访问受限或需要验证",
                [404] = "该章节网页不存在",
                [429] = "请求过于频繁，请稍后重试",
            }
            cb(nil, "官方阅读页：" .. (reasons[code] or ("请求失败 HTTP " .. tostring(code))))
            return
        end
        local ok, result = pcall(Official.parse, res.body, function(raw)
            local decoded, data = pcall(JSON.decode, raw)
            if not decoded or type(data) ~= "table" then
                error("invalid json")
            end
            return data
        end, book_id, item_id)
        if not ok then
            cb(nil, tostring(result))
            return
        end
        cb(result)
    end)
end

return Official
