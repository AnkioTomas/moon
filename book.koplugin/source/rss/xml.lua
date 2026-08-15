--[[--
RSS 用的最小非验证 XML 解析器。

保留元素、属性、文本与 CDATA；不加载外部实体。

@module koplugin.book.source.rss.xml
--]]

local Xml = {}

local function utf8char(cp)
    if cp < 0x80 then
        return string.char(cp)
    elseif cp < 0x800 then
        return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
    elseif cp < 0x10000 then
        return string.char(
            0xE0 + math.floor(cp / 0x1000),
            0x80 + math.floor(cp / 0x40) % 0x40,
            0x80 + cp % 0x40)
    elseif cp < 0x110000 then
        return string.char(
            0xF0 + math.floor(cp / 0x40000),
            0x80 + math.floor(cp / 0x1000) % 0x40,
            0x80 + math.floor(cp / 0x40) % 0x40,
            0x80 + cp % 0x40)
    end
    return ""
end

function Xml.decode(s)
    s = tostring(s or "")
    s = s:gsub("&#(%d+);", function(n)
        return utf8char(tonumber(n) or 0)
    end)
    s = s:gsub("&#[xX](%x+);", function(n)
        return utf8char(tonumber(n, 16) or 0)
    end)
    return s:gsub("&lt;", "<")
        :gsub("&gt;", ">")
        :gsub("&quot;", '"')
        :gsub("&apos;", "'")
        :gsub("&amp;", "&")
end

local function parseAttrs(raw)
    local attrs = {}
    raw:gsub("([%w_:%.%-]+)%s*=%s*([\"'])(.-)%2", function(name, _, value)
        attrs[string.lower(name)] = Xml.decode(value)
    end)
    return attrs
end

--- 解析 XML 为 { name, attr, children } 树。
---@param raw string
---@return table|nil, string|nil
function Xml.parse(raw)
    if type(raw) ~= "string" or raw == "" then
        return nil, "empty XML"
    end
    raw = raw:gsub("^\239\187\191", "")
    local root = { name = "#document", attr = {}, children = {} }
    local stack = { root }
    local pos = 1

    local function appendText(text, decode)
        if text ~= "" then
            local node = stack[#stack]
            node.children[#node.children + 1] = decode and Xml.decode(text) or text
        end
    end

    while pos <= #raw do
        local lt = raw:find("<", pos, true)
        if not lt then
            appendText(raw:sub(pos), true)
            break
        end
        appendText(raw:sub(pos, lt - 1), true)

        if raw:sub(lt, lt + 8) == "<![CDATA[" then
            local close = raw:find("]]>", lt + 9, true)
            if not close then return nil, "unterminated CDATA" end
            appendText(raw:sub(lt + 9, close - 1), false)
            pos = close + 3
        elseif raw:sub(lt, lt + 3) == "<!--" then
            local close = raw:find("-->", lt + 4, true)
            if not close then return nil, "unterminated comment" end
            pos = close + 3
        elseif raw:sub(lt, lt + 1) == "<?" then
            local close = raw:find("?>", lt + 2, true)
            if not close then return nil, "unterminated processing instruction" end
            pos = close + 2
        elseif raw:sub(lt, lt + 8):upper():find("<!DOCTYPE", 1, true) == 1 then
            local close = raw:find(">", lt + 9, true)
            if not close then return nil, "unterminated doctype" end
            pos = close + 1
        else
            -- 找标签结束符：引号包裹的属性值内的 > 不算（如 <a title="x>y">）
            local close
            local quote
            local i = lt + 1
            while i <= #raw do
                local ch = raw:sub(i, i)
                if quote then
                    if ch == quote then
                        quote = nil
                    end
                elseif ch == '"' or ch == "'" then
                    quote = ch
                elseif ch == ">" then
                    close = i
                    break
                end
                i = i + 1
            end
            if not close then return nil, "unterminated tag" end
            local tag = raw:sub(lt + 1, close - 1)
            if tag:sub(1, 1) == "/" then
                local name = string.lower(tag:match("^/%s*([^%s>]+)") or "")
                local node = stack[#stack]
                if #stack == 1 or node.name ~= name then
                    return nil, "unbalanced tag: " .. name
                end
                table.remove(stack)
            elseif tag:sub(1, 1) ~= "!" then
                local self_closing = tag:match("/%s*$") ~= nil
                local name = tag:match("^%s*([^%s/>]+)")
                if name then
                    name = string.lower(name)
                    local node = {
                        name = name,
                        attr = parseAttrs(tag),
                        children = {},
                    }
                    local parent = stack[#stack]
                    parent.children[#parent.children + 1] = node
                    if not self_closing then
                        stack[#stack + 1] = node
                    end
                end
            end
            pos = close + 1
        end
    end

    if #stack ~= 1 then
        return nil, "incomplete XML"
    end
    return root
end

return Xml
