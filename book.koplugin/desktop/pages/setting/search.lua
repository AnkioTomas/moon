--[[--
设置搜索：把设置树里每个页面的行建一遍，取标题 / 副标题做索引，按关键词列出命中的行，点开所在页面。

索引只含「页面 → 分节 → 行」这三层的静态文字（Row.widget 把 title / subtitle 记在返回控件上）；
由行再打开的二级页面不往下钻，命中的是它所在的那一页。索引在每个设置根页实例上缓存一份。

@module koplugin.book.desktop.pages.setting.search
--]]

local Guard = require("ui.guard")
local Row = require("ui.themes.widgets.row")
local _ = require("gettext")

local Search = {}

--- 建行只为取文字，宽度随便给一个。
local PROBE_WIDTH = 400

---@class BookSettingHit
---@field title string
---@field subtitle string|nil
---@field trail string 面包屑：页面 › 分节
---@field page BookSettingsOverlaySpec
---@field text string 小写后的可匹配文字

---@param hits BookSettingHit[]
---@param page BookSettingsOverlaySpec
---@param section_title string|nil
---@param title string
---@param subtitle string|nil
local function add(hits, page, section_title, title, subtitle)
    local trail = section_title and section_title ~= page.title and (page.title .. " › " .. section_title) or page.title
    hits[#hits + 1] = {
        title = title,
        subtitle = subtitle,
        trail = trail,
        page = page,
        text = (title .. " " .. (subtitle or "") .. " " .. trail):lower(),
    }
end

--- 遍历设置根页分组里所有带页面的条目，收集可搜索的行。
---@param groups { entries: BookSettingNode[] }[]
---@return BookSettingHit[]
function Search.build(groups)
    local hits = {}
    for _idx, group in ipairs(groups) do
        for _i, entry in ipairs(group.entries) do
            local page = entry.page
            if page then
                add(hits, page, nil, entry.title, entry.subtitle)
                local sections = Guard.call("settings search " .. tostring(page.id), page.sections) or {}
                for _j, section in ipairs(sections) do
                    for _k, build in ipairs(section.rows) do
                        local widget = build(PROBE_WIDTH)
                        if widget.row_title then
                            add(hits, page, section.title, widget.row_title, widget.row_subtitle)
                        end
                    end
                end
            end
        end
    end
    return hits
end

--- 空白分词，每个词都得出现在行文字里。
---@param hits BookSettingHit[]
---@param query string
---@return BookSettingHit[]
function Search.match(hits, query)
    local words = {}
    for word in query:lower():gmatch("%S+") do words[#words + 1] = word end
    local out = {}
    if #words == 0 then return out end
    for _idx, hit in ipairs(hits) do
        local ok = true
        for _i, word in ipairs(words) do
            if not hit.text:find(word, 1, true) then ok = false break end
        end
        if ok then out[#out + 1] = hit end
    end
    return out
end

--- 结果页规格：点结果在其上再叠一层所在页面，返回时回到结果。
---@param desktop BookDesktop
---@param hits BookSettingHit[]
---@param query string
---@return BookSettingsOverlaySpec
function Search.spec(desktop, hits, query)
    local Overlay = require("desktop.pages.setting.overlay")
    return {
        id = "settings_search",
        title = _("搜索设置"),
        right_icon = "search",
        right_callback = function() Search.prompt(desktop, hits, query) end,
        sections = function()
            local rows = {}
            for _idx, hit in ipairs(Search.match(hits, query)) do
                rows[#rows + 1] = function(iw)
                    return Row.widget({
                        width = iw, title = hit.title, subtitle = hit.trail,
                        callback = function() Overlay.push(desktop, hit.page) end,
                    })
                end
            end
            if #rows == 0 then
                rows[1] = function(iw) return Row.widget({ width = iw, title = _("没有匹配的设置") }) end
            end
            return { { title = "“" .. query .. "”", rows = rows } }
        end,
    }
end

--- 弹出关键词输入框，确认后打开结果页。
---@param desktop BookDesktop
---@param hits BookSettingHit[]
---@param query string|nil
function Search.prompt(desktop, hits, query)
    require("ui.themes.widgets.input"):new{
        title = _("搜索设置"),
        fields = { { text = query or "", hint = _("设置名称或说明") } },
        ok_text = _("搜索"),
        callback = function(value)
            if value:find("%S") then
                require("desktop.pages.setting.overlay").open(desktop, Search.spec(desktop, hits, value))
            end
        end,
    }:show()
end

return Search
