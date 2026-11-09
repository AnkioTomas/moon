--[[--
在线订阅源目录：奇睿发现（api.ankio.net/qireader，按语言筛选标签）。

网页只能选这里的 id，设备端按 id 解析并只请求我们自己的 API，不接受网页传来的任意 URL 当 catalog 源。
奇睿 id：`qi:{lang}:{tag}`（lang 白名单 all/zh/en；tag 原样，请求时 urlEncode）。

@module koplugin.book.features.subscribe.catalog
--]]

local JSON = require("json")
local Text = require("utils.text")
local _ = require("gettext")

local Catalog = {}

local BASE = "https://api.ankio.net/qireader"
local LANG_OK = { all = true, zh = true, en = true }
local FEED_LIMIT = 250
local PAGE_SIZE = 50

--- 语言选项（id 给 API / id 解析用）。
---@return { id: string, name: string }[]
function Catalog.languages()
    return {
        { id = "all", name = _("全部语言") },
        { id = "zh", name = _("中文") },
        { id = "en", name = _("英文") },
    }
end

--- 合法语言码，非法回 all。
---@param lang any
---@return string
function Catalog.normalizeLang(lang)
    lang = tostring(lang or "")
    return LANG_OK[lang] and lang or "all"
end

--- 默认语言：设备界面是中文 → zh，否则 all。
---@return string
function Catalog.defaultLang()
    local lang = require("gettext").current_lang
        or (G_reader_settings and G_reader_settings:readSetting("language"))
        or "C"
    if tostring(lang):match("^zh") then return "zh" end
    return "all"
end

--- 奇睿 source id。
---@param lang string
---@param tag string
---@return string
function Catalog.qiId(lang, tag)
    return "qi:" .. lang .. ":" .. tag
end

--- 解析奇睿 id；非法返回 nil。
---@param id string
---@return string|nil lang
---@return string|nil tag
function Catalog.parseQiId(id)
    id = tostring(id or "")
    local lang, tag = id:match("^qi:([%w]+):(.*)$")
    if not lang or not LANG_OK[lang] then return nil end
    tag = Text.trim(tag or "")
    if tag == "" or tag:find("[\0-\31]") then return nil end
    return lang, tag
end

--- 按 id 取条目（奇睿只带 lang/tag，feeds 运行时拉）。
---@param id string
---@return { id: string, group: string, name: string, lang?: string, tag?: string, qi?: boolean }|nil
function Catalog.find(id)
    id = tostring(id or "")
    local lang, tag = Catalog.parseQiId(id)
    if not lang then return nil end
    return { id = id, group = _("奇睿发现"), name = tag, lang = lang, tag = tag, qi = true }
end

---@param lang string
---@return string
function Catalog.tagsUrl(lang)
    return BASE .. "/tags?" .. Text.formEncode({ lang = Catalog.normalizeLang(lang) })
end

---@param tag string
---@param page integer
---@param size integer
---@param q string|nil
---@return string
function Catalog.feedsUrl(tag, page, size, q)
    local params = { tag = tag, page = tostring(page), size = tostring(size) }
    if q and q ~= "" then params.q = q end
    return BASE .. "/feeds?" .. Text.formEncode(params)
end

--- 解析 /tags 响应 → 标签数组。
---@param body string|nil
---@return table[]|nil
function Catalog.decodeTags(body)
    if type(body) ~= "string" or body == "" then return nil end
    local ok, data = pcall(JSON.decode, body)
    if not ok or type(data) ~= "table" then return nil end
    local list = data.data
    if type(list) ~= "table" then return nil end
    -- 设备端 JSON 偶发把数组编成带数字键的表；按 ipairs 走。
    local out = {}
    for _idx, row in ipairs(list) do
        if type(row) == "table" and type(row.tag) == "string" and row.tag ~= "" then
            out[#out + 1] = row
        end
    end
    return out
end

--- 解析 /feeds 单页 → { items, total }。
---@param body string|nil
---@return { items: table[], total: integer }|nil
function Catalog.decodeFeedsPage(body)
    if type(body) ~= "string" or body == "" then return nil end
    local ok, data = pcall(JSON.decode, body)
    if not ok or type(data) ~= "table" or type(data.data) ~= "table" then return nil end
    local page = data.data
    local items = type(page.items) == "table" and page.items or {}
    return { items = items, total = tonumber(page.total) or #items }
end

--- 分页拉某标签下的源，硬上限 FEED_LIMIT；只认 https? feedUrl。
---@param tag string
---@param cb fun(feeds: { title: string, url: string, description?: string }[]|nil, err: any)
---@param q string|nil 搜索词（可选，带给 API）
---@return table|nil job
function Catalog.fetchFeeds(tag, cb, q)
    local Subscribe = require("features.subscribe")
    local out, page, job = {}, 1, { cancelled = false }
    local function step()
        if job.cancelled then return end
        local inner = Subscribe.fetchText(Catalog.feedsUrl(tag, page, PAGE_SIZE, q), function(body, err)
            if job.cancelled then return end
            if not body then return cb(nil, err or _("下载失败")) end
            local parsed = Catalog.decodeFeedsPage(body)
            if not parsed then return cb(nil, _("无法解析订阅目录")) end
            for _idx, it in ipairs(parsed.items) do
                if #out >= FEED_LIMIT then break end
                if type(it) == "table" then
                    local url = Text.trim(tostring(it.feedUrl or ""))
                    if url:match("^https?://") then
                        local title = Text.trim(tostring(it.title or ""))
                        local desc = Text.trim(tostring(it.description or it.desc or it.summary or ""))
                        out[#out + 1] = {
                            title = title ~= "" and title or url,
                            url = url,
                            description = desc ~= "" and desc or nil,
                        }
                    end
                end
            end
            if #out >= FEED_LIMIT or #out >= parsed.total or #parsed.items == 0 then
                return cb(out)
            end
            page = page + 1
            step()
        end, true)
        job.inner = inner
    end
    function job:cancel()
        self.cancelled = true
        if self.inner and self.inner.cancel then self.inner:cancel() end
    end
    step()
    return job
end

return Catalog
