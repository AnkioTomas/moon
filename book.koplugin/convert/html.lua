--[[--
章节 HTML：正文归一化与原子落盘。

@module koplugin.book.convert.html
--]]

local _ = require("gettext")
local Text = require("utils.text")

local Html = {}

--- 确保得到可嵌入 body 的 HTML。
---@param payload { title: string|nil, html: string|nil, text: string|nil }|string|nil
---@return string body, string title
function Html.normalizeBody(payload)
    local title = _("章节")
    local body = ""
    if type(payload) == "string" then
        body = payload
    elseif type(payload) == "table" then
        if type(payload.title) == "string" and payload.title ~= "" then
            title = payload.title
        end
        if type(payload.html) == "string" and payload.html ~= "" then
            body = payload.html
        elseif type(payload.text) == "string" and payload.text ~= "" then
            body = Text.textToBody(payload.text)
        end
    end
    if body ~= "" and not Text.looksLikeHtml(body) then
        body = Text.textToBody(body)
    end
    return body, title
end

--- 包成完整 HTML 文档（CREngine 可直接打开）。
---@param title string
---@param body string
---@return string
function Html.wrapDocument(title, body)
    return string.format([[
<!DOCTYPE html>
<html lang="zh">
<head>
<meta charset="utf-8"/>
<title>%s</title>
<style type="text/css">
body{margin:5%%;line-height:1.8;text-align:justify;}
h1{font-size:1.4em;text-align:center;margin:1.2em 0 1em;page-break-after:avoid;}
p{text-indent:2em;margin:0.45em 0;orphans:2;widows:2;}
img{max-width:100%%;}
</style>
</head>
<body>
<h1>%s</h1>
%s
</body>
</html>
]], Text.xmlEscape(title), Text.xmlEscape(title), body)
end

--- 章节文件是否可用（非空 HTML）。
---@param path string
---@return boolean
function Html.isValid(path)
    if type(path) ~= "string" or path == "" then
        return false
    end
    local f = io.open(path, "rb")
    if not f then
        return false
    end
    local head = f:read(64) or ""
    f:close()
    if #head < 16 then
        return false
    end
    local lower = head:lower()
    return lower:find("<!doctype", 1, true)
        or lower:find("<html", 1, true)
        or lower:find("<p", 1, true)
        or lower:find("<body", 1, true)
end

--- 原子写入章节 HTML。
---@param dest_path string
---@param payload { title: string|nil, html: string|nil, text: string|nil }|string
---@return boolean|nil, string|nil
function Html.write(dest_path, payload)
    if type(dest_path) ~= "string" or dest_path == "" then
        return nil, _("无效路径")
    end
    local body, title = Html.normalizeBody(payload)
    if body == "" then
        return nil, _("章节内容为空")
    end
    local doc = Html.wrapDocument(title, body)
    local tmp = dest_path .. ".part"
    pcall(os.remove, tmp)
    local f, err = io.open(tmp, "wb")
    if not f then
        return nil, err or _("无法写入章节")
    end
    f:write(doc)
    f:close()
    os.remove(dest_path)
    if not os.rename(tmp, dest_path) then
        pcall(os.remove, tmp)
        return nil, _("无法保存章节文件")
    end
    if not Html.isValid(dest_path) then
        return nil, _("章节文件未生成")
    end
    return true
end

return Html
