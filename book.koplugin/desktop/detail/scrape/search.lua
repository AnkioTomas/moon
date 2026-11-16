--[[--
多源图书搜索：按用户选的来源查（豆瓣自带解析，其余全走数据源 searchAsync）

@module koplugin.book.desktop.detail.scrape.search
--]]

local Douban = require("desktop.detail.scrape.douban")
local Novel = require("desktop.detail.scrape.novel")
local Text = require("utils.text")
local _ = require("gettext")

local Search = {}

local BASE = {
    { id = "douban", name = _("豆瓣"), run = Douban.searchAsync },
}

-- 内置的平台元数据搜索：匿名接口，只取书名 / 作者 / 简介 / 封面等，不依赖任何书源插件。
-- 每个平台一个模块 desktop.detail.scrape.platform.<id>，导出 searchAsync(query, cb)，cb 收统一行（见 novel.fromBooks）。
local PLATFORMS = {
    { id = "weread", name = _("微信读书") },
    { id = "qimao", name = _("七猫小说") },
    { id = "jjwxc", name = _("晋江文学城") },
    { id = "qidian", name = _("起点中文网") },
    { id = "fanqie", name = _("番茄小说") },
    { id = "changpei", name = _("长佩文学") },
    { id = "xiaoxiang", name = _("潇湘书院") },
}

--- 可单独指定的数据来源（顺序即选择列表顺序）：内置的豆瓣与平台搜索 + 已启用的第三方书源（id 去掉可能的 ext. 前缀，与内置重名的不重复列出）。
---@return { id: string, name: string, run: fun(query: string, cb: function): table|nil }[]
function Search.sources()
    local out, seen = { BASE[1] }, { [BASE[1].id] = true }
    for _idx, platform in ipairs(PLATFORMS) do
        seen[platform.id] = true
        out[#out + 1] = { id = platform.id, name = platform.name, run = function(q, cb)
            return require("desktop.detail.scrape.platform." .. platform.id).searchAsync(q, cb)
        end }
    end
    for _idx, meta in ipairs(require("source.registry").listEnabled()) do
        local short = tostring(meta.id):gsub("^ext%.", "")
        if require("source.registry").external(meta.id) and short ~= "demo" and not seen[short] then
            seen[short] = true
            out[#out + 1] = { id = short, name = meta.name or short,
                run = function(q, cb) return Novel.viaSource(meta.id, q, cb, short) end }
        end
    end
    return out
end

---@param id string
---@return string
function Search.name(id)
    for _idx, list in ipairs({ BASE, PLATFORMS }) do
        for _jdx, src in ipairs(list) do
            if src.id == id then return src.name end
        end
    end
    for _idx, src in ipairs(Search.sources()) do
        if src.id == id then return src.name end
    end
    return id
end

--- 只查指定来源；无结果按错误回调。
---@param query string
---@param source_id string
---@param cb fun(results: table[]|nil, err: string|nil, source: string|nil)
---@return { cancel: fun() }|nil
function Search.searchAsync(query, source_id, cb)
    query = Text.trim(query)
    if query == "" then
        cb(nil, _("搜索关键词为空"))
        return nil
    end
    for _idx, src in ipairs(Search.sources()) do
        if src.id == source_id then
            return src.run(query, function(results, err)
                if results and #results > 0 then
                    cb(results, nil, source_id)
                else
                    cb(nil, err or _("无搜索结果"), nil)
                end
            end)
        end
    end
    cb(nil, _("未知数据源"))
    return nil
end

return Search
