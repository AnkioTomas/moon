--[[--
KOReader xpointer ↔ Kavita 书籍进度（pageNum + bookScrollId）。

Kavita 的 epub 进度以 spine 为单位：pageNum 是 0-based spine 序号（KOReader 的
`DocFragment[D]` = spine D-1），pageNum == pages 表示读完；bookScrollId 是章内锚点，
本插件上报 `//body/...` 路径，Kavita 网页端上报 `id("X")`，后者要读本地 epub 才能还原成路径。

@module moonsource_kavita.position
--]]

local Position = {}

local VOID = {
    br = true, img = true, hr = true, meta = true, link = true, input = true,
    area = true, base = true, col = true, embed = true, source = true, track = true, wbr = true,
}

--- xpointer 所在 spine（0-based）。单 spine 书 crengine 写 `DocFragment/body`（无下标）。
---@param locator string|nil
---@return integer|nil
function Position.spine(locator)
    if type(locator) ~= "string" then return nil end
    local d = locator:match("DocFragment%[(%d+)%]")
    if d then return tonumber(d) - 1 end
    if locator:match("/DocFragment/") then return 0 end
    return nil
end

--- xpointer → `//body/...`（同名兄弟下标补全为 [1]，丢弃文本偏移）。body 内无元素返回 nil。
---@param locator string|nil
---@return string|nil
function Position.toScrollId(locator)
    if type(locator) ~= "string" then return nil end
    -- crengine 两种写法都有：`/body/DocFragment[N]/body/...` 与归一化的 `/body[1]/DocFragment[N]/body[1]/...`。
    local rest = locator:match("^/body%[%d+%]/DocFragment%[?%d*%]?/body%[%d+%](.*)$")
        or locator:match("^/body/DocFragment%[?%d*%]?/body(.*)$")
    if not rest then return nil end
    local parts = {}
    for seg in rest:gmatch("[^/]+") do
        if not seg:match("^text%(") then
            local name, index = seg:match("^([%w:_%-]+)%[(%d+)%]$")
            name = name or seg:match("^([%w:_%-]+)")
            if name then parts[#parts + 1] = name .. "[" .. (index or "1") .. "]" end
        end
    end
    if #parts == 0 then return nil end
    return "//body/" .. table.concat(parts, "/")
end

--- spine + `//body/...` → xpointer。pageNum == pages（读完）落回最后一个 spine。
---@param spine integer
---@param scroll_id string|nil
---@param pages integer spine 总数
---@return string
function Position.toXPointer(spine, scroll_id, pages)
    local n = math.max(0, math.min(spine, pages - 1))
    local tail = ""
    local path = type(scroll_id) == "string" and scroll_id:match("^//body/(.+)$")
    if path then
        for seg in path:gmatch("[^/]+") do
            -- crengine 规范：[1] 省略。
            tail = tail .. "/" .. (seg:gsub("%[1%]$", ""))
        end
    end
    local fragment = pages == 1 and "DocFragment" or ("DocFragment[" .. (n + 1) .. "]")
    return "/body/" .. fragment .. "/body" .. tail
end

---@param base string
---@param href string
---@return string
local function joinPath(base, href)
    local parts = {}
    for seg in ((base ~= "" and base .. "/" or "") .. href):gmatch("[^/]+") do
        if seg == ".." then
            table.remove(parts)
        elseif seg ~= "." then
            parts[#parts + 1] = seg
        end
    end
    return table.concat(parts, "/")
end

--- 打开 epub 交给 fn({ count, html(spine) })。用户的 epub 什么样都有：
--- 打不开、解析抛错一律返回 nil，调用方降级（只按 spine 定位 / 不带锚点），不能让开书或同步失败。
---@param epub_path string|nil
---@param fn fun(doc: { count: integer, html: fun(spine: integer): string|nil }): any
---@return any
local function withEpub(epub_path, fn)
    if not epub_path then return nil end
    local arc = require("ffi/archiver").Reader:new()
    if not arc:open(epub_path) then return nil end
    local ok, result = pcall(function()
        -- archiver 要先扫一遍条目，extractToMemory 才找得到文件。
        for _entry in arc:iterate() do end
        local opf_path = (arc:extractToMemory("META-INF/container.xml") or ""):match('full%-path="([^"]+)"')
        local opf = opf_path and arc:extractToMemory(opf_path) or ""
        local manifest, hrefs = {}, {}
        for tag in opf:gmatch("<item%s[^>]*>") do
            local id, href = tag:match('%sid="([^"]*)"'), tag:match('%shref="([^"]*)"')
            if id and href then manifest[id] = href end
        end
        for idref in (opf:match("<spine[^>]*>(.-)</spine>") or ""):gmatch('idref="([^"]*)"') do
            hrefs[#hrefs + 1] = manifest[idref]
        end
        local base = opf_path and opf_path:match("^(.*)/") or ""
        return fn({
            count = #hrefs,
            html = function(spine)
                local href = hrefs[spine + 1]
                return href and arc:extractToMemory(joinPath(base, href))
            end,
        })
    end)
    arc:close()
    return ok and result or nil
end

---@class KavitaElement
---@field name string
---@field tag string 开标签原文（不含尖括号）
---@field path string 相对 body 的路径，同名兄弟下标补全：`section[1]/p[3]`
---@field text string[] 元素内（含后代）的文本片段

--- body 内元素按文档顺序展开，路径口径与 Kavita 的 `//body/...` 一致。
---@param html string
---@return KavitaElement[]
local function elements(html)
    local body = html:match("<body[^>]*>(.-)</body>") or html
    local out, stack = {}, { { path = "", counts = {} } }
    local pos = 1
    while true do
        local lt = body:find("<", pos, true)
        local text = body:sub(pos, (lt or 0) - 1)
        if text ~= "" then
            for i = 2, #stack do stack[i].text[#stack[i].text + 1] = text end
        end
        if not lt then break end
        local gt = body:find(">", lt, true)
        if not gt then break end
        local tag = body:sub(lt + 1, gt - 1)
        pos = gt + 1
        local close = tag:match("^/%s*([%w:_%-]+)")
        local name = not close and tag:match("^([%w:_%-]+)")
        if close then
            for i = #stack, 2, -1 do
                if stack[i].name == close then
                    for j = #stack, i, -1 do stack[j] = nil end
                    break
                end
            end
        elseif name then
            local parent = stack[#stack]
            local idx = (parent.counts[name] or 0) + 1
            parent.counts[name] = idx
            local el = {
                name = name, tag = tag, text = {}, counts = {},
                path = (parent.path == "" and "" or parent.path .. "/") .. name .. "[" .. idx .. "]",
            }
            out[#out + 1] = el
            if not VOID[name] and tag:sub(-1) ~= "/" then stack[#stack + 1] = el end
        end
    end
    return out
end

--- 远端 bookScrollId → `//body/...`。`id("X")` 需读本地 epub 第 spine 个文档定位；
--- 读不到 / 找不到返回 nil，调用方退回只按 spine 定位。
---@param epub_path string|nil
---@param spine integer
---@param scroll_id string|nil
---@return string|nil
function Position.resolveScrollId(epub_path, spine, scroll_id)
    if type(scroll_id) ~= "string" then return nil end
    if scroll_id:match("^//body/") then return scroll_id end
    local id = scroll_id:match('^id%("(.-)"%)$') or scroll_id:match("^id%('(.-)'%)$")
    if not id or id == "" then return nil end
    return withEpub(epub_path, function(doc)
        for _idx, el in ipairs(elements(doc.html(spine) or "")) do
            if (el.tag:match("%sid%s*=%s*\"([^\"]*)\"") or el.tag:match("%sid%s*=%s*'([^']*)'")) == id then
                return "//body/" .. el.path
            end
        end
    end)
end

--- 段落匹配用：解实体，去脚注标记（上标数字与 [N]）和全部空白。
---@param s string|nil
---@return string
local function normalizeText(s)
    s = require("utils.text").xmlDecode(s or "")
    s = s:gsub("%[%d+%]", ""):gsub("\194[\185\178\179]", ""):gsub("\226\129[\176-\185]", "")
    return (s:gsub("%s+", ""))
end

--- 选中文本落在哪几段：首行定起始段（探针由长到短：整行 → 前 32 / 16 字节，容忍段内差异），
--- 末行尾部定结束段。KOReader 跨段选区按段换行，所以首末行各自落在一段里。
---@param paras { path: string, text: string }[]
---@param head string 首行（已规范化）
---@param tail string 末行（已规范化）
---@return integer|nil first, integer|nil last
local function findRange(paras, head, tail)
    local probes = { head }
    if #head > 32 then probes[#probes + 1] = head:sub(1, 32) end
    if #head > 16 then probes[#probes + 1] = head:sub(1, 16) end
    tail = tail:sub(-math.min(24, #tail))
    for _pidx, probe in ipairs(probes) do
        for i, para in ipairs(paras) do
            if para.text:find(probe, 1, true) then
                for j = i, #paras do
                    if paras[j].text:find(tail, 1, true) then return i, j end
                end
                return i, i
            end
        end
    end
    return nil
end

--- KOReader 划线 → Kavita 注解锚点 { pageNumber, xPath, endingXPath }。
--- 先在 pos0 所在 spine 找，找不到由近及远搜其它 spine；都找不到返回 nil（调用方只带 spine）。
---@param text string|nil 划线原文
---@param pos0 string|nil 起点 xpointer
---@param epub_path string|nil
---@return { pageNumber: integer, xPath: string, endingXPath: string }|nil
function Position.anchor(text, pos0, epub_path)
    local lines = {}
    for line in (text or ""):gmatch("[^\n]+") do
        local clean = normalizeText(line)
        if clean ~= "" then lines[#lines + 1] = clean end
    end
    if #table.concat(lines) < 2 then return nil end
    local primary = Position.spine(pos0) or 0
    return withEpub(epub_path, function(doc)
        local function try(spine)
            local html = doc.html(spine)
            if not html then return nil end
            local paras = {}
            for _idx, el in ipairs(elements(html)) do
                if el.name == "p" then
                    paras[#paras + 1] = { path = el.path, text = normalizeText(table.concat(el.text)) }
                end
            end
            local first, last = findRange(paras, lines[1], lines[#lines])
            return first and {
                pageNumber = spine,
                xPath = "//body/" .. paras[first].path,
                endingXPath = "//body/" .. paras[last].path,
            }
        end
        local hit = try(primary)
        for distance = 1, doc.count do
            hit = hit or try(primary - distance) or try(primary + distance)
        end
        return hit
    end)
end

return Position
