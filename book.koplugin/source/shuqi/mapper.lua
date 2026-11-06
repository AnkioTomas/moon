--[[--
书旗网页响应 → 领域对象。纯函数，不发请求。

搜索签名把缺省的密钥参数拼进字符串，网页因此得到字面量 "undefined"。
正文是 ROT13 后再 Base64 的 HTML。

@module source.shuqi.mapper
--]]

local Text = require("utils.text")

local Mapper = {}

local SOURCE_ID = "shuqi"
local WALDEN_KEY = "37e81a9d8f02596e1b895d07c171d5c9"
local AND_KEY = "4b283ed2f94f02242415cc49fc4e3616"
local OCEAN_KEY = "eefc4798f28ea41622487ad80ef7e81c"

--- 目录缓存格式。首章携带，变了就当缓存失效。
Mapper.TOC_VERSION = 1

---@type fun(text: string): string
local md5 = require("ffi/sha2").md5

--- encodeURIComponent 后按网页 forceJava 再编码。
---@param value any
---@return string
function Mapper.javaEncode(value)
    local encoded = tostring(value):gsub("([^%w%-_%.!*'%(%)~])", function(char)
        return string.format("%%%02X", char:byte())
    end)
    encoded = encoded:gsub("%%20", "+")
    encoded = encoded:gsub("%(", "%%28")
    encoded = encoded:gsub("%)", "%%29")
    encoded = encoded:gsub("~", "%%7E")
    encoded = encoded:gsub("!", "%%21")
    return (encoded:gsub("'", "%%27"))
end

--- 书旗网关签名：排序后 key=javaEncode(value)，末尾 &skey=。
---@param fields table<string, any>
---@param skey string|nil
---@return string
function Mapper.gatewaySign(fields, skey)
    local keys = {}
    for key, value in pairs(fields) do
        if value ~= nil and key ~= "sign" and key ~= "key" and key ~= "_public" then
            keys[#keys + 1] = key
        end
    end
    table.sort(keys)
    local parts = {}
    for _idx, key in ipairs(keys) do
        parts[#parts + 1] = key .. "=" .. Mapper.javaEncode(fields[key])
    end
    return md5(table.concat(parts, "&") .. "&skey=" .. (skey or OCEAN_KEY))
end

--- 搜索签名。网页签名函数的密钥参数是 undefined，拼进字符串后就是这六个字母。
---@param timestamp string|number
---@return string
function Mapper.searchSign(timestamp)
    return md5(tostring(timestamp) .. "undefined")
end

--- 正文接口签名：参与签名的字段按键名排序，只拼接值，再加密钥。
---@param fields table<string, any>
---@return string
function Mapper.contentSign(fields)
    local keys = {}
    for key in pairs(fields) do keys[#keys + 1] = key end
    table.sort(keys)
    local parts = {}
    for _idx, key in ipairs(keys) do parts[#parts + 1] = tostring(fields[key]) end
    return md5(table.concat(parts) .. WALDEN_KEY)
end

--- 分类榜签名。参与的 imei、sn 为空，user_id 不在请求里，只剩时间戳加密钥。
---@param timestamp string|number
---@return string
function Mapper.rankSign(timestamp)
    return md5(tostring(timestamp) .. AND_KEY)
end

---@param id any
---@param title any
---@param author any
---@param intro any
---@param cover any
---@return Book
local function book(id, title, author, intro, cover)
    local function clean(value)
        if type(value) ~= "string" then return "" end
        return Text.trim(Text.xmlDecode(value))
    end
    local picture = type(cover) == "string" and cover ~= "" and Text.xmlDecode(cover) or nil
    if picture and picture:sub(1, 2) == "//" then picture = "https:" .. picture end
    return {
        source_id = SOURCE_ID,
        stable_id = tostring(id),
        title = clean(title),
        authors = clean(author),
        intro = clean(intro),
        cover = picture,
    }
end

---@param rows table|nil
---@return Book[]
local function books(rows)
    local out = {}
    if type(rows) ~= "table" then return out end
    for _idx, row in ipairs(rows) do
        if type(row) == "table" and (row.bid or row.bookId or row.bookid) then
            out[#out + 1] = book(
                row.bid or row.bookId or row.bookid,
                row.title or row.bookName,
                row.author or row.authorName,
                row.desc or row.intro,
                row.cover or row.imgUrl)
        end
    end
    return out
end

--- 搜索 / 分类榜。status 为 1 才是成功。
---@param wire table|nil
---@return Book[]|nil
---@return string|nil err
function Mapper.searchBooks(wire)
    if type(wire) ~= "table" or tonumber(wire.status) ~= 1 then
        local info = type(wire) == "table" and wire.info or nil
        return nil, type(info) == "table" and info.message or nil
    end
    return books(wire.data)
end

---@param wire table|nil
---@return Book|nil
function Mapper.detail(wire)
    if type(wire) ~= "table" or tostring(wire.state) ~= "200" or type(wire.data) ~= "table" then
        return nil
    end
    local data = wire.data
    if not data.bookId and not data.bookName then return nil end
    return book(data.bookId, data.bookName, data.authorName, data.desc or data.intro, data.imgUrl)
end

---@param value any
---@return boolean
local function flag(value)
    return value == true or value == 1 or value == "1" or value == "true"
end

--- 目录。免费章带上正文地址，未购买的 VIP 章不带地址。
---@param wire table|nil
---@return BookChapter[]|nil
function Mapper.chapters(wire)
    if type(wire) ~= "table" or tostring(wire.state) ~= "200" or type(wire.data) ~= "table" then
        return nil
    end
    local data = wire.data
    local free_prefix = type(data.freeContUrlPrefix) == "string" and data.freeContUrlPrefix or ""
    local charge_prefix = type(data.chargeContUrlPrefix) == "string" and data.chargeContUrlPrefix or ""
    local out = {}
    local volumes = type(data.chapterList) == "table" and data.chapterList or {}
    for _vol_idx, volume in ipairs(volumes) do
        local list = nil
        if type(volume) == "table" then
            list = volume.volumeList or volume.chapterList
            if type(list) ~= "table" and volume.chapterId then list = { volume } end
        end
        if type(list) == "table" then
            for _idx, row in ipairs(list) do
                if type(row) == "table" and row.chapterId then
                    local free = flag(row.isFreeRead) or row.payStatus == 0 or row.payStatus == "0"
                    local bought = flag(row.isBuy)
                    local suffix = type(row.contUrlSuffix) == "string" and row.contUrlSuffix or ""
                    local url = nil
                    if free and free_prefix ~= "" and suffix ~= "" then
                        url = free_prefix .. suffix
                    elseif bought and suffix ~= "" then
                        local prefix = charge_prefix ~= "" and charge_prefix or free_prefix
                        if prefix ~= "" then url = prefix .. suffix end
                    end
                    out[#out + 1] = {
                        idx = #out + 1,
                        uid = tostring(row.chapterId),
                        title = type(row.chapterName) == "string" and Text.trim(row.chapterName) or "",
                        source_idx = row.chapterOrdid and tostring(row.chapterOrdid) or nil,
                        vip = not free,
                        content_url = url,
                    }
                end
            end
        end
    end
    if out[1] then out[1].toc_version = Mapper.TOC_VERSION end
    return out
end

--- 网页 rot13：非字母原样，A/a 都转到 N/n。
---@param text string
---@return string
local function rot13(text)
    return (text:gsub("[%a]", function(char)
        local base = char:byte() >= 97 and 96 or 64
        local n = (char:lower():byte() - 83) % 26
        if n == 0 then n = 26 end
        return string.char(n + base)
    end))
end

--- 正文。先 ROT13 再 Base64，得到带 br 的 HTML，收成纯文本。
---@param wire table|nil
---@return string|nil
---@return string|nil err
function Mapper.chapterText(wire)
    if type(wire) ~= "table" or tostring(wire.state) ~= "200" then
        return nil, type(wire) == "table" and (wire.message or wire.msg) or nil
    end
    local cipher = wire.ChapterContent
    if type(cipher) ~= "string" or cipher == "" then return nil, "正文为空" end
    local html = Text.base64Decode(rot13(cipher))
    html = html:gsub("<[Bb][Rr]%s*/?>", "\n")
    html = html:gsub("<[^>]+>", "")
    local text = Text.trim(Text.xmlDecode(html))
    if text == "" then return nil, "正文解密失败" end
    return text
end

---@param wire table|nil
---@return { male: table, female: table, press: table }|nil
function Mapper.channels(wire)
    if type(wire) ~= "table" or tostring(wire.state) ~= "200" or type(wire.data) ~= "table" then
        return nil
    end
    local function list(key)
        local group = wire.data[key]
        local rows = type(group) == "table" and group.groupList or {}
        local chips = {}
        if type(rows) ~= "table" then return chips end
        for _idx, row in ipairs(rows) do
            if type(row) == "table" and type(row.showName) == "string" and row.showName ~= "" then
                chips[#chips + 1] = { id = row.showName, title = row.showName }
            end
        end
        return chips
    end
    return { male = list("male"), female = list("female"), press = list("press") }
end

--- 登录成功。token 在 data 里，用户号在 userInfo.userid。
---@param wire table|nil
---@return { token: string, user_id: string|nil, name: string }|nil
---@return string|nil err
function Mapper.session(wire)
    if type(wire) ~= "table" or tonumber(wire.status) ~= 200 or type(wire.data) ~= "table" then
        return nil, type(wire) == "table" and wire.message or nil
    end
    local data = wire.data
    if type(data.token) ~= "string" or data.token == "" then
        return nil, wire.message
    end
    local info = type(data.userInfo) == "table" and data.userInfo or {}
    local user_id = info.userid or info.userId or info.id
    local name = ""
    if type(info.nickName) == "string" and info.nickName ~= "" then name = info.nickName
    elseif type(info.nickname) == "string" then name = info.nickname end
    return {
        token = data.token,
        user_id = user_id and tostring(user_id) or nil,
        name = name,
    }
end

--- 短信接口。status / state 为 200 算发送成功。
---@param wire table|nil
---@return boolean
---@return string|nil err
function Mapper.sent(wire)
    if type(wire) ~= "table" then return false, nil end
    local status = tonumber(wire.status) or tonumber(wire.state)
    if status == 200 then return true end
    return false, wire.message or wire.msg
end

--- 书签同步的书在 detail。网页把同一份包在 data 里，顶层只剩 status / message。
---@param wire table|nil
---@return table|nil
local function shelfRows(wire)
    if type(wire) ~= "table" then return nil end
    if type(wire.detail) == "table" then return wire.detail end
    local data = wire.data
    if type(data) == "table" and type(data.detail) == "table" then return data.detail end
    return nil
end

--- 没有 detail 视为失败，空数组是空书架。
---@param wire table|nil
---@return Book[]|nil
---@return string|nil err
function Mapper.shelf(wire)
    local rows = shelfRows(wire)
    if not rows then return nil, type(wire) == "table" and (wire.message or wire.msg) or nil end
    return books(rows)
end

--- 书签行里的阅读位置。网页把服务端的 percent（0..1）乘 10000 再存。
--- 没有章节号就是还没读过。
---@param wire table|nil
---@param stable_id string
---@return { chapter_id: string, title: string|nil, fraction: number }|nil
function Mapper.mark(wire, stable_id)
    local rows = shelfRows(wire)
    if type(rows) ~= "table" then return nil end
    for _idx, row in ipairs(rows) do
        if type(row) == "table" and tostring(row.bid or "") == tostring(stable_id) then
            local chapter_id = row.chapterid or row.chapterId
            if chapter_id == nil or tostring(chapter_id) == "" or tostring(chapter_id) == "0" then return nil end
            local percent = tonumber(row.percent) or 0
            if percent > 1 then percent = percent / 10000 end
            if percent < 0 then percent = 0 end
            if percent > 1 then percent = 1 end
            return {
                chapter_id = tostring(chapter_id),
                title = type(row.cname) == "string" and row.cname ~= "" and row.cname or nil,
                fraction = percent,
            }
        end
    end
    return nil
end

return Mapper
