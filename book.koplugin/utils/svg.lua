--[[--
给阅读器展开 SVG 的根级 CSS 主题变量与透明绘制，保留矢量图。

只接收根元素的简单选择器和内联变量；有局部变量、未知条件规则时原样保留，
不把不同作用域的同名变量混在一起。颜色主题固定为默认 / light。
纯 Lua，不调用浏览器、图片服务或阅读器渲染器。

@module koplugin.book.utils.svg
--]]

local Text = require("utils.text")
local Svg = {}

--- 找 CSS 顶层分隔符，跳过字符串、注释和函数参数。
---@param text string
---@param pos integer
---@param stops string
---@return integer
---@return string
local function delimiter(text, pos, stops)
    local depth, quote = 0, nil
    while pos <= #text do
        local c = text:sub(pos, pos)
        if quote then
            if c == "\\" then pos = pos + 1 elseif c == quote then quote = nil end
        elseif text:sub(pos, pos + 1) == "/*" then
            pos = (text:find("*/", pos + 2, true) or #text - 1) + 1
        elseif c == '"' or c == "'" then
            quote = c
        elseif c == "(" then depth = depth + 1
        elseif c == ")" then depth = depth - 1
        elseif depth == 0 and stops:find(c, 1, true) then return pos, c end
        pos = pos + 1
    end
    return pos, ""
end

--- 简单根选择器的优先级；不能匹配根时返回 nil。
---@param selector string
---@param attrs table<string, string>
---@return integer|nil
local function rootSpecificity(selector, attrs)
    selector = Text.trim(selector)
    local score = 0
    if selector:sub(1, 3) == "svg" then selector, score = selector:sub(4), 1
    elseif selector:sub(1, 1) == "*" then selector = selector:sub(2) end
    while selector ~= "" do
        if selector:sub(1, 5) == ":root" then
            selector, score = selector:sub(6), score + 10
        else
            local kind, name, rest = selector:match("^([.#])([%w_-]+)(.*)$")
            if not kind then return nil end
            if kind == "#" then
                if attrs.id ~= name then return nil end
                score = score + 100
            else
                if not (" " .. (attrs.class or ""):gsub("%s+", " ") .. " "):find(" " .. name .. " ", 1, true) then return nil end
                score = score + 10
            end
            selector = rest
        end
    end
    return score
end

--- 将根级 CSS 变量展开为静态值。无法确定作用域 / 值时不改图。
---@param data string 已识别的 SVG 字节
---@return string
local function expandVariables(data)
    if not data:find("var%s*%(") then return data end
    local root = data:match("<svg%s*(.-)>")
    if not root then return data end
    local attrs = {}
    for key, _quote, value in root:gmatch("([%w_:.-]+)%s*=%s*(['\"])(.-)%2") do
        attrs[key] = Text.xmlDecode(value)
    end
    local values, priorities = {}, {}
    local scoped = false
    --- 收集声明；无根选择器优先级的变量意味着局部作用域，整图不处理。
    local function declarations(body, specificity)
        local pos = 1
        while pos <= #body do
            local last = delimiter(body, pos, ";")
            local key, value = body:sub(pos, last - 1):gsub("/%*.-%*/", " "):match("^%s*(%-%-[%w_-]+)%s*:%s*(.-)%s*$")
            if key then
                if not specificity then scoped = true; return end
                local important = value:match("%s*!important%s*$")
                value = value:gsub("%s*!important%s*$", "")
                local priority = specificity + (important and 10000 or 0)
                if not priorities[key] or priority >= priorities[key] then
                    values[key], priorities[key] = value, priority
                end
            end
            pos = last + 1
        end
    end
    --- 按 CSS 块读取，仅展开明确的浅 / 深主题媒体规则。
    local function stylesheet(css)
        local out, pos = {}, 1
        while pos <= #css do
            local open, kind = delimiter(css, pos, "{;")
            if kind ~= "{" then
                out[#out + 1] = css:sub(pos, open)
                pos = open + 1
            else
                local close, depth = open + 1, 1
                while depth > 0 and close <= #css do
                    local brace
                    close, brace = delimiter(css, close, "{}")
                    if brace == "" then scoped = true; return css end
                    depth = depth + (brace == "{" and 1 or -1)
                    if depth > 0 then close = close + 1 end
                end
                local selector = css:sub(pos, open - 1):gsub("/%*.-%*/", " ")
                local body = css:sub(open + 1, close - 1)
                local theme = selector:match("^%s*@media%s*%(%s*prefers%-color%-scheme%s*:%s*(%a+)%s*%)%s*$")
                if theme == "dark" then
                    -- 默认浅色：深色变量和样式均不参与级联。
                elseif theme == "light" then
                    out[#out + 1] = stylesheet(body)
                else
                    if selector:find("@", 1, true) then
                        scoped = true
                    else
                        local specificity
                        for part in selector:gmatch("[^,]+") do
                            local score = rootSpecificity(part, attrs)
                            if score and (not specificity or score > specificity) then specificity = score end
                        end
                        declarations(body, specificity)
                    end
                    out[#out + 1] = css:sub(pos, close)
                end
                pos = close + 1
            end
        end
        return table.concat(out)
    end
    local prepared = data:gsub("(<style[^>]*>)(.-)(</style%s*>)", function(start, css, finish)
        return start .. stylesheet(css) .. finish
    end)
    -- 内联根变量最高优先；后代元素的内联变量不能提升到根。
    local first = true
    for tag, attributes in data:gmatch("<([%w_:]+)%s*([^>]-)>") do
        local is_root = first and tag == "svg"
        first = false
        for key, _quote, value in attributes:gmatch("([%w_:.-]+)%s*=%s*(['\"])(.-)%2") do
            if key == "style" then declarations(Text.xmlDecode(value), is_root and 1000 or nil) end
        end
    end
    if scoped then return data end

    -- 按括号读取 var，备用值可以包含逗号或另一个 var；依赖环按无效值处理。
    local resolving, cyclic = {}, false
    local expand
    expand = function(text)
        local out, pos = {}, 1
        while true do
            local start, open = text:find("var%s*%(", pos)
            if not start then out[#out + 1] = text:sub(pos); break end
            out[#out + 1] = text:sub(pos, start - 1)
            local close, depth = open + 1, 1
            while depth > 0 and close <= #text do
                local c = text:sub(close, close)
                if c == "(" then depth = depth + 1 elseif c == ")" then depth = depth - 1 end
                if depth > 0 then close = close + 1 end
            end
            if depth ~= 0 then return nil end
            local args = text:sub(open + 1, close - 1)
            local comma = delimiter(args, 1, ",")
            local key = Text.trim(args:sub(1, comma - 1))
            local value
            if resolving[key] then cyclic = true end
            if values[key] and not resolving[key] then
                resolving[key] = true
                value = expand(values[key])
                resolving[key] = nil
            end
            if not value and comma <= #args then value = expand(args:sub(comma + 1)) end
            if not value then return nil end
            out[#out + 1], pos = value, close + 1
        end
        return table.concat(out)
    end
    local failed = false
    prepared = prepared:gsub("(<style[^>]*>)(.-)(</style%s*>)", function(start, css, finish)
        local expanded = expand(css)
        if not expanded then failed = true end
        return start .. (expanded or css) .. finish
    end)
    -- 只改 CSS 与属性中的 var，不替换标题、图注等文本内容。
    prepared = prepared:gsub("<[%a][^>]*>", function(tag)
        return (tag:gsub("([%w_:.-]+)(%s*=%s*)(['\"])(.-)%3", function(key, equals, quote, value)
            if value:find("var%s*%(") then
                local expanded = expand(Text.xmlDecode(value))
                if not expanded then failed = true end
                if expanded then value = Text.xmlEscape(expanded) end
            end
            return key .. equals .. quote .. value .. quote
        end))
    end)
    return (failed or cyclic) and data or prepared
end

---@param css string
---@return string
local function normalizePaint(css)
    local declarations, opacity, pos = {}, {}, 1
    while pos <= #css do
        local last = delimiter(css, pos, ";")
        local declaration = css:sub(pos, last - 1)
        local key, value = declaration:match("^%s*([%w-]+)%s*:%s*(.-)%s*$")
        declarations[#declarations + 1] = { raw = declaration, key = key, value = value }
        if key == "fill-opacity" or key == "stroke-opacity" then opacity[key] = value end
        pos = last + 1
    end
    local out, changed = {}, false
    for _, declaration in ipairs(declarations) do
        local key, value = declaration.key, declaration.value
        local raw = declaration.raw
        if key == "fill" or key == "stroke" then
            if value:lower() == "transparent" then
                raw = key .. ": none"
                changed = true
            else
                -- SVG 1.1 的 rgb + 独立透明度等价于 rgba；原图的半透明箱线区域用到它。
                local rgb, alpha = value:match("^rgba%(%s*([^,]+,%s*[^,]+,%s*[^,]+),%s*([%d.]+)%s*%)$")
                local inherited = opacity[key .. "-opacity"]
                local factor = 1
                if inherited then factor = tonumber(inherited) end
                if rgb and alpha and factor then
                    changed = true
                    raw = key .. ": rgb(" .. rgb .. ")"
                    opacity[key .. "-opacity"] = nil
                    -- 放在原透明度声明之后，仍保留整体 opacity 对整个元素的作用。
                    out[#out + 1] = raw
                    raw = key .. "-opacity: " .. tostring(tonumber(alpha) * factor)
                end
            end
        end
        if not (key == "fill-opacity" or key == "stroke-opacity") then out[#out + 1] = raw end
    end
    for _, key in ipairs({ "fill-opacity", "stroke-opacity" }) do
        if opacity[key] then out[#out + 1] = key .. ": " .. opacity[key] end
    end
    return changed and table.concat(out, ";") or css
end

--- 旧版 SVG 引擎把 transparent 画成黑色；fill / stroke 用 none 表达不绘制。
--- 只处理绘制属性，不改文本或其它属性里的 transparent 字样。
---@param data string
---@return string
function Svg.normalize(data)
    data = expandVariables(data)
    local lower = data:lower()
    if not lower:find("transparent", 1, true) and not lower:find("rgba(", 1, true) then return data end
    data = data:gsub("(<style[^>]*>)(.-)(</style%s*>)", function(start, css, finish)
        css = css:gsub("([^{}]+){([^{}]*)}", function(selector, declarations)
            return selector .. "{" .. normalizePaint(declarations) .. "}"
        end)
        return start .. css .. finish
    end)
    return (data:gsub("<[%a][^>]*>", function(tag)
        return (tag:gsub("([%w_:.-]+)(%s*=%s*)(['\"])(.-)%3", function(key, equals, quote, value)
            if (key == "fill" or key == "stroke") and Text.trim(value):lower() == "transparent" then
                value = "none"
            elseif key == "fill" or key == "stroke" then
                local rgb, alpha = value:match("^rgba%(%s*([^,]+,%s*[^,]+,%s*[^,]+),%s*([%d.]+)%s*%)$")
                -- 有独立透明度的属性留给同一条 style 处理，避免改变级联关系。
                if rgb and alpha and not tag:find(key .. "-opacity", 1, true) and not tag:find("style%s*=") then
                    return key .. equals .. quote .. "rgb(" .. rgb .. ")" .. quote .. " " .. key .. "-opacity=" .. quote .. alpha .. quote
                end
            elseif key == "style" then
                value = normalizePaint(value)
            end
            return key .. equals .. quote .. value .. quote
        end))
    end))
end

return Svg
