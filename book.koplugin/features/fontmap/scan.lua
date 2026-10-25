--[[--
书籍字体扫描：只读 EPUB 的 CSS / XHTML，以及 HTML、FB2 的内联样式和本地样式表。
不联网、不加载正文到 UI 线程；book() 在 Job 子进程中执行。

@module koplugin.book.features.fontmap.scan
--]]

local Text = require("utils.text")
local Scan = {}

local GENERIC = {}
for name in ("serif sans-serif monospace cursive fantasy system-ui emoji math fangsong "
    .. "ui-serif ui-sans-serif ui-monospace ui-rounded inherit initial unset revert revert-layer"):gmatch("%S+") do
    GENERIC[name] = true
end

local function escape(text, pos)
    local hex, after = text:match("^(%x%x?%x?%x?%x?%x?)()", pos)
    if hex then
        if text:sub(after, after):match("%s") then after = after + 1 end
        return Text.xmlDecode("&#x" .. hex .. ";"), after
    end
    return text:sub(pos, pos), pos + 1
end

--- CSS token 化只处理字体声明需要的引号、转义、注释与分隔符。
local function tokens(css)
    local out, pos = {}, 1
    while pos <= #css do
        local ch = css:sub(pos, pos)
        if ch:match("%s") then
            pos = pos + 1
        elseif css:sub(pos, pos + 1) == "/*" then
            local close = css:find("*/", pos + 2, true)
            pos = close and close + 2 or #css + 1
        elseif ch == '"' or ch == "'" then
            local quote, value = ch, {}
            pos = pos + 1
            while pos <= #css and css:sub(pos, pos) ~= quote do
                ch = css:sub(pos, pos)
                if ch == "\\" then
                    ch, pos = escape(css, pos + 1)
                else
                    pos = pos + 1
                end
                value[#value + 1] = ch
            end
            pos = pos + 1
            out[#out + 1] = { value = table.concat(value), quoted = true }
        elseif ch:find("[:,;{}()/!]", 1) then
            out[#out + 1] = { value = ch }
            pos = pos + 1
        else
            local value = {}
            while pos <= #css do
                ch = css:sub(pos, pos)
                if ch:match("[%s:,;{}()/!'\"]") then break end
                if ch == "\\" then ch, pos = escape(css, pos + 1)
                else pos = pos + 1 end
                value[#value + 1] = ch
            end
            out[#out + 1] = { value = table.concat(value) }
        end
    end
    return out
end

local function families(list, first, last, found)
    local name = {}
    local function add()
        local face = Text.trim(table.concat(name, " "))
        if face ~= "" and not GENERIC[face:lower()] then found[face] = true end
        name = {}
    end
    for idx = first, last do
        local token = list[idx]
        local value = token.value
        if not token.quoted and value == "!" then break end
        if not token.quoted and value == "(" then return end -- var() / env() 不是字体名。
        if not token.quoted and value == "," then add()
        else name[#name + 1] = value end
    end
    add()
end

---@param css string
---@param found table<string, boolean>|nil
---@return table<string, boolean>
---@return string[] imports
function Scan.css(css, found)
    found = found or {}
    local imports = {}
    local list = tokens(css)
    local idx = 1
    while idx <= #list do
        local token = list[idx]
        local property = token.value:lower()
        if not token.quoted and property == "@import" then
            local target = list[idx + 1]
            if target and target.value:lower() == "url" and list[idx + 2] and list[idx + 2].value == "(" then
                local parts, at = {}, idx + 3
                while list[at] and list[at].value ~= ")" do
                    parts[#parts + 1] = list[at].value
                    at = at + 1
                end
                imports[#imports + 1] = table.concat(parts)
            elseif target then
                imports[#imports + 1] = target.value
            end
            idx = idx + 1
        elseif not token.quoted and (property == "font-family" or property == "font")
            and (idx == 1 or list[idx - 1].value == "{" or list[idx - 1].value == ";")
            and list[idx + 1] and list[idx + 1].value == ":" then
            local first, last = idx + 2, idx + 2
            while list[last] and list[last].value ~= ";" and list[last].value ~= "}" do last = last + 1 end
            if property == "font" then
                while first < last and not list[first].value:match("^%d*%.?%d+[%a%%]+$") do first = first + 1 end
                first = first + 1
                if list[first] and list[first].value == "/" then first = first + 2 end
            end
            families(list, first, last - 1, found)
            idx = last
        else
            idx = idx + 1
        end
    end
    return found, imports
end

local function attributes(tag)
    local attrs = {}
    for name, quote, value in tag:gmatch("([%w%-]+)%s*=%s*(['\"])(.-)%2") do
        attrs[name:lower()] = Text.xmlDecode(value)
    end
    for name, value in tag:gmatch("([%w%-]+)%s*=%s*([^%s>'\"]+)") do
        name = name:lower()
        if attrs[name] == nil then attrs[name] = Text.xmlDecode(value) end
    end
    return attrs
end

---@param html string
---@param found table<string, boolean>
---@return string[] links
function Scan.markup(html, found)
    html = html:gsub("<!%-%-.-%-%->", "")
    html = html:gsub("<[sS][cC][rR][iI][pP][tT][^>]*>.-</[sS][cC][rR][iI][pP][tT]%s*>", "")
    local links = {}
    for _name, css in html:gmatch("<([sS][tT][yY][lL][eE][%w]*)[^>]*>(.-)</[sS][tT][yY][lL][eE][%w]*%s*>") do
        local _fonts, imports = Scan.css(css, found)
        for _idx, href in ipairs(imports) do links[#links + 1] = href end
    end
    for name, tag in html:gmatch("<([%a][%w:]*)%s+([^>]+)>") do
        local attrs = attributes(tag)
        if attrs.style then Scan.css(attrs.style, found) end
        if name:lower() == "font" and attrs.face then Scan.css("font-family:" .. attrs.face, found) end
        if name:lower() == "link" and attrs.href and (attrs.rel or ""):lower():find("stylesheet", 1, true) then
            links[#links + 1] = attrs.href
        end
    end
    return links
end

local function read(path)
    local file, err = io.open(path, "rb")
    if not file then error(err) end
    local content, read_err = file:read("*a")
    file:close()
    if not content then error(read_err) end
    return content
end

---@param path string
---@return string[]
function Scan.book(path)
    local found, visited = {}, {}
    local localCss
    local function follow(origin, href)
        if not href:match("^%a[%w+.-]*:") and not href:match("^//") then
            local dir = origin:match("^(.*)/") or "."
            href = Text.urlDecode(href:gsub("[?#].*$", ""))
            localCss(href:sub(1, 1) == "/" and href or dir .. "/" .. href)
        end
    end
    localCss = function(file)
        local canonical = assert(require("ffi/util").realpath(file), "cannot resolve stylesheet: " .. file)
        if visited[canonical] then return end
        visited[canonical] = true
        local _fonts, imports = Scan.css(read(canonical), found)
        for _idx, href in ipairs(imports) do follow(canonical, href) end
    end
    local ext = path:lower():match("%.([%w]+)$")
    if ext == "epub" or ext == "zip" then
        local reader = require("ffi/archiver").Reader:new()
        assert(reader:open(path), reader.err)
        local failure
        for entry in reader:iterate() do
            local suffix = entry.path:lower():match("%.([%w]+)$")
            if entry.mode == "file" and (suffix == "css" or suffix == "html" or suffix == "htm" or suffix == "xhtml") then
                local content = reader:extractToMemory(entry.path)
                if not content then failure = reader.err or ("cannot read " .. entry.path); break end
                if suffix == "css" then Scan.css(content, found) else Scan.markup(content, found) end
            end
        end
        failure = failure or reader.err
        reader:close()
        if failure then error(failure) end
    elseif ext == "html" or ext == "htm" or ext == "xhtml" or ext == "fb2" then
        local links = Scan.markup(read(path), found)
        for _idx, href in ipairs(links) do follow(path, href) end
    else
        error("unsupported stylesheet document: " .. path)
    end
    local names = {}
    for name in pairs(found) do names[#names + 1] = name end
    table.sort(names)
    return names
end

return Scan
