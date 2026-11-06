--[[--
盐选正文：移除备案号，保留原文节点顺序，在末尾留出章评区。

@module source.zhihu.content
--]]

local Content = {}

Content.ANCHOR = "moon-chapter-reviews"
Content.FOOTER = '<div id="' .. Content.ANCHOR .. '" style="height:4em;page-break-inside:avoid"></div>'

---@param html string
---@return string
function Content.prepare(html)
    html = html:gsub("<span%s[^>]-id%s*=%s*([\"'])vipyxcode%1[^>]*>.-</span>", "")
    if html:find('id="' .. Content.ANCHOR .. '"', 1, true) then return html end
    local ending = html:find("</body>", 1, true)
    if ending then return html:sub(1, ending - 1) .. Content.FOOTER .. html:sub(ending) end
    return html .. Content.FOOTER
end

--- 原地升级章节缓存，不改原文节点的序号；失败不覆盖旧文件。
---@param path string
---@return boolean
function Content.reuse(path)
    local file = assert(io.open(path, "rb"))
    local raw, read_err = file:read("*a")
    file:close()
    assert(raw, read_err)
    local html = Content.prepare(raw)
    if html == raw then return true end
    local temp = path .. ".part"
    file = assert(io.open(temp, "wb"))
    local written, write_err = file:write(html)
    local closed, close_err = file:close()
    if not written or not closed then
        os.remove(temp)
        error(write_err or close_err)
    end
    local renamed, rename_err = os.rename(temp, path)
    if not renamed then os.remove(temp); error(rename_err) end
    return true
end

--- 仅升级本源由 text2epub 生成的短篇：不重新排版，不动既有正文节点。
---@param path string
---@param original string 旧章节 HTML，用来精确识别转换前的备案号文字
---@return boolean|nil, string|nil
function Content.upgradeStory(path, original)
    local Archiver = require("ffi/archiver")
    local Text = require("utils.text")
    local reader = Archiver.Reader:new()
    if not reader:open(path) then return nil, reader.err end
    local entries, last, last_idx = {}, nil, 0
    for entry in reader:iterate() do
        if entry.mode == "file" then
            local raw = reader:extractToMemory(entry.path)
            if not raw then
                local err = reader.err
                reader:close()
                return nil, err
            end
            entries[#entries + 1] = { path = entry.path, data = raw }
            local idx = tonumber(entry.path:match("^OEBPS/chapter_(%d+)%.xhtml$"))
            if idx and idx > last_idx then last, last_idx = entries[#entries], idx end
        end
    end
    local read_err = reader.err
    reader:close()
    if read_err then return nil, read_err end
    if not last then return nil, require("gettext")("无文本内容") end
    local updated = Content.prepare(last.data)
    local _quote, watermark = original:match("<span%s[^>]-id%s*=%s*([\"'])vipyxcode%1[^>]*>(.-)</span>")
    if watermark then
        watermark = Text.stripHtml(watermark)
        updated = updated:gsub("(<p[^>]*>)(.-)</p>", function(open, inner)
            return open .. (Text.stripHtml(inner) == watermark and "" or inner) .. "</p>"
        end)
    end
    if updated == last.data then return true end
    last.data = updated
    local temp = path .. ".part"
    local writer = Archiver.Writer:new()
    if not writer:open(temp, "epub") then return nil, writer.err end
    for _idx, entry in ipairs(entries) do
        writer:setZipCompression(entry.path == "mimetype" and "store" or "deflate")
        if not writer:addFileFromMemory(entry.path, entry.data, os.time()) then
            local err = writer.err
            writer:close()
            os.remove(temp)
            return nil, err
        end
    end
    writer:close()
    local renamed, err = os.rename(temp, path)
    if not renamed then os.remove(temp); return nil, err end
    return true
end

return Content
