--[[--
RSS XML 树查询与序列化。

@module koplugin.book.source.rss.xml_handler
--]]

local Text = require("utils.text")

local Handler = {}

local function localName(name)
    return tostring(name or ""):match("([^:]+)$")
end

function Handler.children(node, name)
    local out = {}
    name = name and string.lower(name) or nil
    for _, child in ipairs(node and node.children or {}) do
        if type(child) == "table"
            and (not name or child.name == name or localName(child.name) == name) then
            out[#out + 1] = child
        end
    end
    return out
end

function Handler.child(node, name)
    return Handler.children(node, name)[1]
end

function Handler.text(node)
    local out = {}
    local function walk(current)
        for _, child in ipairs(current and current.children or {}) do
            if type(child) == "string" then
                out[#out + 1] = child
            elseif type(child) == "table" then
                walk(child)
            end
        end
    end
    walk(node)
    return Text.trim(table.concat(out))
end

local function serialize(node)
    if type(node) == "string" then return node end
    local attrs = {}
    for name, value in pairs(node.attr or {}) do
        attrs[#attrs + 1] = string.format(' %s="%s"', name, Text.xmlEscape(value))
    end
    table.sort(attrs)
    local body = {}
    for _, child in ipairs(node.children or {}) do
        body[#body + 1] = serialize(child)
    end
    return "<" .. node.name .. table.concat(attrs) .. ">"
        .. table.concat(body) .. "</" .. node.name .. ">"
end

function Handler.innerXml(node)
    local out = {}
    for _, child in ipairs(node and node.children or {}) do
        out[#out + 1] = serialize(child)
    end
    return table.concat(out)
end

return Handler
