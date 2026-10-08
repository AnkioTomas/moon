--[[--
KOReader 标注 → Kavita 注解锚点（离线计算）。

输入 KOReader 注解（`text`/`pos0`）+ 本地 epub 路径，输出
`{ pageNumber, xPath, endingXPath }`：

- `pageNumber` = 0-based spine 序号（`DocFragment[D] = spine D-1`，真机 6/6 标定）。
- `xPath` = `//body` + 相对 `<body>` 的同名兄弟下标完整路径（嵌套书不能只写 `p[N]`）。
- 段落匹配失败 → 返回 nil（调用方降级为空 xPath 或跳过）。

epub 经 `ffi/archiver` 读取；测试用 preload 桩替换为内存条目。

@module koplugin.book.source.kavita.anchor
--]]

local Text = require("utils.text")

local Anchor = {}

local VOID = {
    br = true, img = true, hr = true, meta = true, link = true, input = true,
    area = true, base = true, col = true, embed = true, source = true,
    track = true, wbr = true,
}

--- OPF 目录 + href 归一化成 zip 内路径。
---@param base string
---@param href string
---@return string
local function joinPath(base, href)
    local path = base ~= "" and (base .. "/" .. href) or href
    local parts = {}
    for seg in path:gmatch("[^/]+") do
        if seg == ".." then
            if #parts > 0 then table.remove(parts) end
        elseif seg ~= "." then
            parts[#parts + 1] = seg
        end
    end
    return table.concat(parts, "/")
end

---@param path string
---@return string
local function dirname(path)
    return path:match("^(.*)/[^/]*$") or ""
end

--- `META-INF/container.xml` → OPF 路径。
---@param xml string|nil
---@return string|nil
local function parseContainer(xml)
    if type(xml) ~= "string" then return nil end
    return xml:match('rootfile[^>]-full%-path="([^"]+)"')
        or xml:match("rootfile[^>]-full%-path='([^']+)'")
end

--- OPF → manifest(id→href) 与 spine(href 顺序)。
---@param xml string|nil
---@return { manifest: table<string,string>, spine: string[] }|nil
local function parseOpf(xml)
    if type(xml) ~= "string" then return nil end
    local manifest = {}
    for id, href in xml:gmatch('<item[^>]-id="([^"]-)"[^>]-href="([^"]-)"') do
        manifest[id] = href
    end
    for href, id in xml:gmatch('<item[^>]-href="([^"]-)"[^>]-id="([^"]-)"') do
        manifest[id] = manifest[id] or href
    end
    local spine = {}
    local spine_xml = xml:match("<spine[^>]*>(.-)</spine>")
    if spine_xml then
        for idref in spine_xml:gmatch('<itemref[^>]-idref="([^"]-)"') do
            local href = manifest[idref]
            if href then spine[#spine + 1] = href end
        end
    end
    return { manifest = manifest, spine = spine }
end

--- `/body/DocFragment[8]/...` → 8；取不到返回 nil。
---@param pos0 string|nil
---@return integer|nil
local function docFragmentIndex(pos0)
    if type(pos0) ~= "string" then return nil end
    local d = pos0:match("DocFragment%[(%d+)%]")
    return d and tonumber(d)
end

--- 归一化用于段落匹配的文本：解实体、去脚注标记（unicode 上标与 [N]）、去空白。
---@param s string|nil
---@return string
local function normalizeText(s)
    if type(s) ~= "string" then return "" end
    s = Text.xmlDecode(s)
    s = s:gsub("%[%d+%]", "")
    s = s:gsub("\194\185", ""):gsub("\194\178", ""):gsub("\194\179", "")
    s = s:gsub("\226\129[\176-\185]", "")
    s = s:gsub("%s+", "")
    return s
end

---@param stack table[]
---@param i integer
---@return string
local function pathOf(stack, i)
    local parts = {}
    for j = 2, i do
        parts[#parts + 1] = "/" .. stack[j].name .. "[" .. stack[j].index .. "]"
    end
    return table.concat(parts)
end

--- 扫描 `<body>` 内元素，按文档序收集 `<p>`：`{ path, text }`（path 相对 body）。
---@param html string|nil
---@return { path: string, text: string }[]
local function enumerateParagraphs(html)
    if type(html) ~= "string" then return {} end
    local body = html:match("<body[^>]*>(.-)</body>") or html
    local paras = {}
    local stack = { { name = "#root", index = 0, counts = {}, text = {} } }
    local pos = 1
    local n = #body
    while pos <= n do
        local lt = body:find("<", pos, true)
        if not lt then
            local frame = stack[#stack]
            if frame.name == "p" then frame.text[#frame.text + 1] = body:sub(pos) end
            break
        end
        if lt > pos then
            local text = body:sub(pos, lt - 1)
            for i = #stack, 1, -1 do
                if stack[i].name == "p" then
                    stack[i].text[#stack[i].text + 1] = text
                    break
                end
            end
        end
        local gt = body:find(">", lt, true)
        if not gt then break end
        local tag = body:sub(lt + 1, gt - 1)
        pos = gt + 1
        if tag:sub(1, 1) == "/" then
            local name = tag:match("^/%s*([%w:_%-]+)")
            if name then
                for i = #stack, 1, -1 do
                    if stack[i].name == name then
                        if name == "p" then
                            paras[#paras + 1] = {
                                path = pathOf(stack, i),
                                text = normalizeText(table.concat(stack[i].text)),
                            }
                        end
                        for _ = #stack, i, -1 do table.remove(stack) end
                        break
                    end
                end
            end
        elseif tag:sub(1, 1) ~= "!" and tag:sub(1, 1) ~= "?" then
            local name = tag:match("^([%w:_%-]+)")
            if name then
                local parent = stack[#stack]
                local idx = (parent.counts[name] or 0) + 1
                parent.counts[name] = idx
                if not VOID[name] and tag:sub(-1) ~= "/" then
                    stack[#stack + 1] = { name = name, index = idx, counts = {}, text = {} }
                end
            end
        end
    end
    return paras
end

--- 在 `<body>` 内查 `id="X"` 元素，返回其 body 相对完整路径（口径同 `pathOf`：
--- 无名段补 `[1]`）。找不到返回 nil。
---@param html string|nil
---@param id string
---@return string|nil
local function idPath(html, id)
    if type(html) ~= "string" or type(id) ~= "string" or id == "" then return nil end
    local body = html:match("<body[^>]*>(.-)</body>") or html
    local stack = { { name = "#root", index = 0, counts = {} } }
    local pos = 1
    local n = #body
    while pos <= n do
        local lt = body:find("<", pos, true)
        if not lt then break end
        local gt = body:find(">", lt, true)
        if not gt then break end
        local tag = body:sub(lt + 1, gt - 1)
        pos = gt + 1
        local first = tag:sub(1, 1)
        if first == "/" then
            local name = tag:match("^/%s*([%w:_%-]+)")
            if name then
                for i = #stack, 1, -1 do
                    if stack[i].name == name then
                        for _ = #stack, i, -1 do table.remove(stack) end
                        break
                    end
                end
            end
        elseif first ~= "!" and first ~= "?" then
            local name = tag:match("^([%w:_%-]+)")
            if name then
                local parent = stack[#stack]
                local idx = (parent.counts[name] or 0) + 1
                parent.counts[name] = idx
                local attr_id = tag:match('id%s*=%s*"([^"]*)"') or tag:match("id%s*=%s*'([^']*)'")
                if attr_id == id then
                    local parts = {}
                    for j = 2, #stack do
                        parts[#parts + 1] = stack[j].name .. "[" .. stack[j].index .. "]"
                    end
                    parts[#parts + 1] = name .. "[" .. idx .. "]"
                    return table.concat(parts, "/")
                end
                if not VOID[name] and tag:sub(-1) ~= "/" then
                    stack[#stack + 1] = { name = name, index = idx, counts = {} }
                end
            end
        end
    end
    return nil
end

--- 在段落里定位选中文本区间（跨段时 end 向后找尾部探针）。
---@param paras { path: string, text: string }[]
---@param needle string
---@return integer|nil start
---@return integer|nil finish
local function findRange(paras, needle)
    if #paras == 0 or #needle < 2 then return nil end
    -- 探针由长到短：整段选择 → 逐级缩短的头部，跨段选择也能命中。
    local candidates = { needle }
    if #needle > 32 then candidates[#candidates + 1] = needle:sub(1, 32) end
    if #needle > 16 then candidates[#candidates + 1] = needle:sub(1, 16) end
    for _, candidate in ipairs(candidates) do
        local start
        for i, para in ipairs(paras) do
            if para.text:find(candidate, 1, true) then start = i; break end
        end
        if start then
            local tail = needle:sub(-math.min(24, #needle))
            local finish = start
            for i = start, #paras do
                if paras[i].text:find(tail, 1, true) then finish = i; break end
            end
            return start, finish
        end
    end
    return nil
end

---@return table
local function newReader()
    return require("ffi/archiver").Reader:new()
end

---@param opf table
---@param base string
---@param s integer 0-based spine 序号
---@param needle string
---@param arc table
---@return table|nil
local function anchorInSpine(opf, base, s, needle, arc)
    if s < 0 or s >= #opf.spine then return nil end
    local html = arc:extractToMemory(joinPath(base, opf.spine[s + 1]))
    if not html then return nil end
    local paras = enumerateParagraphs(html)
    local start_idx, end_idx = findRange(paras, needle)
    if not start_idx then return nil end
    return {
        pageNumber = s,
        xPath = "//body" .. paras[start_idx].path,
        endingXPath = "//body" .. paras[end_idx].path,
    }
end

--- 计算注解锚点；解析/匹配失败返回 nil（调用方降级）。
---@param annotation table
---@param epub_path string
---@return { pageNumber: integer, xPath: string, endingXPath: string }|nil
function Anchor.compute(annotation, epub_path)
    if type(annotation) ~= "table" or type(epub_path) ~= "string" then return nil end
    local needle = normalizeText(annotation.text)
    if #needle < 2 then return nil end
    local arc = newReader()
    if not arc:open(epub_path) then return nil end
    local ok, result = pcall(function()
        -- archiver 的 entries 表要先扫描一遍，extractToMemory→seek 才找得到条目；
        -- 否则首次 extract 一律返回 nil，锚点全空（Kavita 端可见但无法定位）。
        for _ in arc:iterate() do end
        local opf_path = parseContainer(arc:extractToMemory("META-INF/container.xml"))
        if not opf_path then return nil end
        local opf = parseOpf(arc:extractToMemory(opf_path))
        if not opf or #opf.spine == 0 then return nil end
        local base = dirname(opf_path)
        local fragment_index = docFragmentIndex(annotation.pos0)
        local primary = fragment_index and (fragment_index - 1) or 0
        local hit = anchorInSpine(opf, base, primary, needle, arc)
        if hit then return hit end
        -- 兜底：全 spine 搜索，取离 primary 最近的命中。
        local best
        for s = 0, #opf.spine - 1 do
            if s ~= primary then
                local cand = anchorInSpine(opf, base, s, needle, arc)
                if cand and (not best
                        or math.abs(s - primary) < math.abs(best.pageNumber - primary)) then
                    best = cand
                end
            end
        end
        return best
    end)
    arc:close()
    if ok then return result end
    return nil
end

--- pos0 直接推 pageNumber（0-based spine）；取不到返回 nil。
---@param pos0 string|nil
---@return integer|nil
function Anchor.pageNumber(pos0)
    local fragment_index = docFragmentIndex(pos0)
    if not fragment_index then return nil end
    return fragment_index - 1
end

--- 解析 xpointer 里 `DocFragment[D]/body` 之后的段落路径，输出 Kavita 语义的
--- 完整同名兄弟下标（无下标补 `[1]`，丢弃 `text().N` / `a.0` 文本偏移）。
--- 例：`/body/DocFragment[8]/body/section/p[3]/text().0` → `section[1]/p[3]`。
--- body 内无元素或非 xpointer 返回 nil。
---@param xpointer string|nil
---@return string|nil
local function bodyPath(xpointer)
    if type(xpointer) ~= "string" then return nil end
    -- 两种 xpointer 形态都要认：原始 `/body/DocFragment[N]/body/...`，以及 crengine
    -- 归一化后的 `/body[1]/DocFragment[N]/body[1]/...`。只认前者会让 bookScrollId 恒为
    -- nil（Kavita 看不到章内位置，且相同 pageNum 的上报会被服务端当作无变化）。
    local rest = xpointer:match("^/body%[%d+%]/DocFragment%[%d+%]/body%[%d+%](.*)$")
        or xpointer:match("^/body%[%d+%]/DocFragment/body%[%d+%](.*)$")
        or xpointer:match("^/body/DocFragment%[%d+%]/body(.*)$")
        or xpointer:match("^/body/DocFragment/body(.*)$")
    if not rest or rest == "" then return nil end
    local parts = {}
    for seg in rest:gmatch("([^/]+)") do
        -- 跳掉文本偏移段：既有 `text().0`，也有归一化的 `text()[1].0`。
        if not seg:match("^text%(") then
            local name, index = seg:match("^([%w:_%-]+)%[(%d+)%]$")
            if not name then
                name = seg:match("^([%w:_%-]+)")
                index = nil
            end
            if name then
                parts[#parts + 1] = name .. "[" .. (index or "1") .. "]"
            end
        end
    end
    if #parts == 0 then return nil end
    return table.concat(parts, "/")
end

--- KOReader xpointer → Kavita `bookScrollId`（`//body/...`）；无页内元素返回 nil。
---@param locator string|nil
---@return string|nil
function Anchor.toScrollId(locator)
    local path = bodyPath(locator)
    if not path then return nil end
    return "//body/" .. path
end

--- `[N]` 段还原成 crengine 规范：`[1]` 省略。
---@param seg string
---@return string
local function creSegment(seg)
    local name, index = seg:match("^([%w:_%-]+)%[(%d+)%]$")
    if not name then return seg end
    if tonumber(index) == 1 then return name end
    return name .. "[" .. index .. "]"
end

--- 0-based spine + Kavita `bookScrollId` → KOReader xpointer。
--- 页级源（Kavita）用 spine 定位到章节文档、bookScrollId 提供页内精度；
--- `pages == 1` 时 crengine 的单文档形态是 `DocFragment/body`（无下标）。
---@param spine integer|nil 0-based spine 序号
---@param scroll_id string|nil Kavita bookScrollId
---@param pages integer|nil spine 数，用于区分单文档 xpointer 形态
---@return string|nil
function Anchor.toXPointer(spine, scroll_id, pages)
    local n = tonumber(spine)
    if not n or n < 0 then return nil end
    local total = tonumber(pages)
    -- Kavita 用 pageNum == pages 表示已读完：定位要落回最后一个 spine。
    if total and total > 0 and n > total - 1 then n = total - 1 end
    local fragment = (total == 1) and "DocFragment"
        or ("DocFragment[" .. (n + 1) .. "]")
    local tail = ""
    if type(scroll_id) == "string" then
        local path = scroll_id:match("^//body/?(.*)$")
        if path and path ~= "" then
            local parts = {}
            for seg in path:gmatch("([^/]+)") do
                parts[#parts + 1] = creSegment(seg)
            end
            if #parts > 0 then tail = "/" .. table.concat(parts, "/") end
        end
    end
    return "/body/" .. fragment .. "/body" .. tail
end

--- Kavita `bookScrollId` → `//body/...`（供 `toXPointer` 补页内锚点）。两种形态：
--- - `//body/...`：moon 自己上报的，原样返回；
--- - `id("X")`：Kavita 网页端上报的「元素 id」，用本地 epub 的 spine 文档定位成路径。
--- 无本地文件、id 不在该 spine、或形态不认识时返回 nil（调用方退回只看 spine）。
---@param epub_path string|nil
---@param spine integer|nil 0-based spine 序号（= Kavita pageNum）
---@param scroll_id string|nil
---@return string|nil
function Anchor.resolveScrollId(epub_path, spine, scroll_id)
    if type(scroll_id) ~= "string" or scroll_id == "" then return nil end
    if scroll_id:match("^//body") then return scroll_id end
    local id = scroll_id:match('^id%("(.-)"%)$') or scroll_id:match("^id%('(.-)'%)$")
    if not id or id == "" then return nil end
    if type(epub_path) ~= "string" or epub_path == "" then return nil end
    -- 整体 pcall：读 epub 在 UI 线程同步执行，任何解析异常都只退化成「只看 spine」。
    local ok, path = pcall(function()
        local arc = newReader()
        if not arc:open(epub_path) then return nil end
        local inner_ok, inner = pcall(function()
            for _ in arc:iterate() do end
            local opf_path = parseContainer(arc:extractToMemory("META-INF/container.xml"))
            if not opf_path then return nil end
            local opf = parseOpf(arc:extractToMemory(opf_path))
            if not opf or #opf.spine == 0 then return nil end
            local s = tonumber(spine)
            if not s or s < 0 or s >= #opf.spine then return nil end
            local html = arc:extractToMemory(joinPath(dirname(opf_path), opf.spine[s + 1]))
            if not html then return nil end
            return idPath(html, id)
        end)
        arc:close()
        return inner_ok and inner or nil
    end)
    if ok and path then return "//body/" .. path end
    return nil
end

return Anchor
