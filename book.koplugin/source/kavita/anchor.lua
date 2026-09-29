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

return Anchor
