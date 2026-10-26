--[[--
订阅的远程管理接口（远程管理 /api/subscribe/* 经 handler 调用，不依赖 server）。

  GET  list                     订阅 + 分组（含计数 / 未读）+ 开关状态
  GET  items?id=&page=          某订阅的文章（分页，含已读）
  GET  text                     纯文本批量编辑的当前文本
  GET  opml                     导出 OPML（Remote.download，路由层直接回附件）
  POST article {id, guid}       文章正文（离线缓存优先，会抓取并写缓存，所以走 POST），外链资源去掉，图片只留 https / data:image
  POST add / preview（OPML 地址回 {opml=true,count}）/ update / remove / refresh / move / reorder / group / import / catalog（在线订阅源清单）/ pick（订阅勾选项）/ read / batch
  GET  catalog                  在线订阅源目录（catalog.lua，POST catalog 按 id 取清单）

GET 只读；有副作用（抓取、写库、写缓存）的一律 POST。网页发起的抓取只许公网地址（Subscribe.privateHost）。

结果统一 cb(status, table)：2xx 是数据，4xx/5xx 是 { error = 文案 }。
分组是订阅的 grp 字段；空分组（新建还没放订阅）记在设置 groups 里，顺序也按它。

@module koplugin.book.features.subscribe.remote
--]]

local SubDB = require("features.subscribe.db")
local Text = require("utils.text")
local _ = require("gettext")

local Remote = {}

local PAGE = 30
local PREVIEW_ITEMS = 5
local PREVIEW_TEXT = 1200

local function S() return require("features.subscribe") end

local function settings() return S().settings() end
local function save() require("utils.settings").save("features.subscribe") end

--- 分组列表：设置里登记的顺序在前，订阅里出现的其余分组按名字补上；未分组（""）不进列表。
---@param feeds table[]
---@return { name: string, count: integer, unread: integer }[]
function Remote.groups(feeds)
    local by, out = {}, {}
    local function ensure(name)
        if name == "" or by[name] then return end
        by[name] = { name = name, count = 0, unread = 0 }
        out[#out + 1] = by[name]
    end
    for _idx, name in ipairs(settings().groups or {}) do ensure(name) end
    local extra = {}
    for _idx, f in ipairs(feeds) do
        if f.grp ~= "" and by[f.grp] == nil then extra[#extra + 1] = f.grp; by[f.grp] = false end
    end
    table.sort(extra)
    for _idx, name in ipairs(extra) do by[name] = nil; ensure(name) end
    for _idx, f in ipairs(feeds) do
        local g = by[f.grp]
        if g then g.count, g.unread = g.count + 1, g.unread + (f.unread or 0) end
    end
    return out
end

--- 列表。
---@return table
function Remote.list()
    local s = settings()
    local Setting = require("features.subscribe.setting")
    local rows, feeds = SubDB.feeds(), {}
    for _idx, f in ipairs(rows) do
        feeds[#feeds + 1] = { id = f.id, kind = f.kind, url = f.url, title = f.title, group = f.grp,
            unread = f.unread or 0, updated_at = f.updated_at or 0, sort = f.sort or 0, error = f.error or "" }
    end
    return { enabled = Setting.on(s, "enabled"), feeds = feeds,
        groups = Remote.groups(rows) }
end

--- 导出 OPML（RSS / 网页；公众号只能在设备上读，不导出）。
---@return string
function Remote.opml()
    local out = { '<?xml version="1.0" encoding="UTF-8"?>', '<opml version="2.0"><head><title>Moon</title></head><body>' }
    local groups, order = {}, {}
    for _idx, f in ipairs(SubDB.feeds()) do
        if f.kind ~= "mp" then
            if not groups[f.grp] then groups[f.grp] = {}; order[#order + 1] = f.grp end
            local list = groups[f.grp]
            list[#list + 1] = string.format('<outline type="%s" text="%s" title="%s" xmlUrl="%s"/>',
                f.kind, Text.xmlEscape(f.title), Text.xmlEscape(f.title), Text.xmlEscape(f.url))
        end
    end
    for _idx, grp in ipairs(order) do
        if grp ~= "" then out[#out + 1] = string.format('<outline text="%s">', Text.xmlEscape(grp)) end
        for _i, line in ipairs(groups[grp]) do out[#out + 1] = line end
        if grp ~= "" then out[#out + 1] = "</outline>" end
    end
    out[#out + 1] = "</body></opml>"
    return table.concat(out, "\n")
end

--- 解析 OPML：带 xmlUrl 的 outline 是订阅，外层不带 xmlUrl 的 outline 是分组。
---@param text string
---@return { kind: string, url: string, title: string, grp: string }[]
function Remote.parseOpml(text)
    text = tostring(text or ""):gsub("^\239\187\191", "")
    -- 注释 / CDATA 里的 <outline> 不算。
    text = text:gsub("<!%-%-.-%-%->", ""):gsub("<!%[CDATA%[.-%]%]>", "")
    local feeds, stack, seen = {}, {}, {}
    --- 属性：名字不分大小写（xmlUrl / xmlurl / XMLURL），单双引号都认，顺序随意。
    local function attrs(raw)
        local out = {}
        for name, q, value in raw:gmatch("([%w_:%-]+)%s*=%s*([\"'])(.-)%2") do
            out[name:lower()] = Text.xmlDecode(value)
        end
        return out
    end
    local i, n = 1, #text
    while i <= n do
        local s0, e0, close = text:find("<(/?)[oO][uU][tT][lL][iI][nN][eE]%f[%s/>]", i)
        if not s0 then break end
        -- 找标签结尾：跳过引号里的 >（标题里常见）。
        local j, quote = e0 + 1, nil
        while j <= n do
            local c = text:sub(j, j)
            if quote then
                if c == quote then quote = nil end
            elseif c == '"' or c == "'" then
                quote = c
            elseif c == ">" then
                break
            end
            j = j + 1
        end
        local raw = text:sub(e0 + 1, j - 1)
        local self_close = raw:match("/%s*$") ~= nil
        i = j + 1
        if close == "/" then
            stack[#stack] = nil
        else
            local a = attrs(raw)
            local url = Text.trim(a.xmlurl or "")
            local type_ = (a.type or ""):lower()
            local kind = (type_ == "site" or type_ == "page") and type_ or "rss"
            if url ~= "" and url:match("^https?://") and not seen[url] then
                seen[url] = true
                local title = Text.trim(a.title or a.text or "")
                feeds[#feeds + 1] = { kind = kind, url = url, title = title ~= "" and title or url,
                    grp = stack[#stack] or "" }
            end
            if not self_close then
                -- 分类 outline 的名字就是分组；订阅 outline 里嵌套的子项沿用外层分组。
                local name = url == "" and Text.trim(a.text or a.title or "") or nil
                stack[#stack + 1] = name ~= nil and name ~= "" and name or stack[#stack] or ""
            end
        end
    end
    return feeds
end

--- 网页预览正文：严格白名单清洗（直接插进页面渲染，不再套 iframe）。
--- 只留排版标签；脚本 / 样式 / 表单 / 内嵌框 / 媒体连内容一起删；属性只留 a 的 http(s) href、表格跨行列、
--- img 的 https / data:image 地址（设备本地路径浏览器打不开，去掉；不带 Referer 以免公众号图片防盗链）。
--- 浏览器端还会再按同一份白名单过一遍。
local ALLOW = {}
for t in ("p br hr h1 h2 h3 h4 h5 h6 div span section article header footer blockquote pre code "
    .. "ul ol li dl dt dd strong b em i u s del ins sub sup small mark a table thead tbody tfoot tr th td "
    .. "caption figure figcaption img"):gmatch("%S+") do ALLOW[t] = true end
local DROP = {}
for t in ("script style iframe object embed video audio noscript template svg math textarea select "
    .. "button form canvas frameset frame title head"):gmatch("%S+") do DROP[t] = true end
local VOID = { br = true, hr = true, img = true }

local function esc(v)
    return (v:gsub("&", "&amp;"):gsub('"', "&quot;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

local function attr(raw, name)
    raw = " " .. raw
    return raw:match("%s" .. name .. '%s*=%s*"([^"]*)"') or raw:match("%s" .. name .. "%s*=%s*'([^']*)'")
        or raw:match("%s" .. name .. "%s*=%s*([^%s\"'>]+)")
end

local function attrs(tag, raw)
    local out = {}
    if tag == "a" then
        local v = attr(raw, "[hH][rR][eE][fF]")
        if v and v:gsub("&#?%w+;", ""):gsub("[%c%s]", ""):lower():match("^https?://") then
            out[#out + 1] = ' href="' .. esc(v) .. '" rel="noopener noreferrer" target="_blank"'
        end
    elseif tag == "img" then
        local v = attr(raw, "[sS][rR][cC]")
        local plain = v and v:gsub("[%c%s]", ""):lower() or ""
        if not (plain:match("^https://") or plain:match("^data:image/[%w.+-]+;base64,")) or plain:match("^data:image/svg") then
            return nil
        end
        out[#out + 1] = ' src="' .. esc(v:gsub("&amp;", "&")) .. '" referrerpolicy="no-referrer" loading="lazy" alt=""'
    elseif tag == "td" or tag == "th" then
        for _idx, k in ipairs({ "colspan", "rowspan" }) do
            local v = attr(raw:lower(), k)
            if v and v:match("^%d+$") then out[#out + 1] = " " .. k .. '="' .. v .. '"' end
        end
    end
    return table.concat(out)
end

---@param html string
---@return string
function Remote.clean(html)
    html = tostring(html or ""):gsub("<!%-%-.-%-%->", ""):gsub("<!%[CDATA%[.-%]%]>", "")
    local out, pos, skip = {}, 1, nil
    while true do
        local s, e, close, tag, raw = html:find("<(/?)([%a][%w%-]*)(.-)>", pos)
        local text = html:sub(pos, (s or #html + 1) - 1)
        if not skip then out[#out + 1] = (text:gsub("<", "&lt;")) end
        if not s then break end
        tag = tag:lower()
        if skip then
            if close == "/" and tag == skip then skip = nil end
        elseif DROP[tag] then
            if close == "" and not raw:match("/%s*$") then skip = tag end
        elseif ALLOW[tag] then
            if close == "/" then
                if not VOID[tag] then out[#out + 1] = "</" .. tag .. ">" end
            else
                local a = attrs(tag, raw)
                if a then out[#out + 1] = "<" .. tag .. a .. ">" end
            end
        end
        pos = e + 1
    end
    return table.concat(out)
end

local function num(v) return tonumber(v) end

--- 设置里登记的分组补上 names 中还没有的（保持出现顺序，未分组 "" 不登记）。
---@param names string[]
local function addGroups(names)
    local s, known = settings(), {}
    s.groups = s.groups or {}
    for _idx, g in ipairs(s.groups) do known[g] = true end
    for _idx, g in ipairs(names) do
        if g ~= "" and not known[g] then s.groups[#s.groups + 1] = g; known[g] = true end
    end
end

--- 某分组的订阅 id（按当前顺序）。
---@param grp string
---@return integer[]
local function groupIds(grp)
    local ids = {}
    for _idx, f in ipairs(SubDB.feeds()) do
        if f.grp == grp then ids[#ids + 1] = f.id end
    end
    return ids
end

--- 网页给的地址：补协议并拒绝局域网 / 本机地址。返回规整后的地址或 nil, 错误。
---@param url any
---@return string|nil, string|nil
local function publicUrl(url)
    url = Text.trim(tostring(url or ""))
    if url == "" then return nil, _("请填写订阅地址") end
    if not url:match("^https?://") then url = "https://" .. url end
    if S().privateHost(url) then return nil, _("不允许访问局域网或本机地址") end
    return url
end

local function feedOr404(id, cb)
    local feed = SubDB.feed(num(id))
    if not feed then cb(404, { error = _("订阅不存在") }) end
    return feed
end

local function idList(v)
    local out = {}
    for _idx, id in ipairs(type(v) == "table" and v or {}) do
        if num(id) then out[#out + 1] = num(id) end
    end
    return out
end

local GET, POST = {}, {}

function GET.list(_q, cb) cb(200, Remote.list()) end

function GET.items(q, cb)
    local feed = feedOr404(q.id, cb)
    if not feed then return end
    local page = math.max(1, num(q.page) or 1)
    -- read：缺省全部，"1" 只要已读，"0" 只要未读
    local read = nil
    if q.read == "1" or q.read == 1 then read = true elseif q.read == "0" or q.read == 0 then read = false end
    local items, total = SubDB.items(feed.id, page, PAGE, read)
    cb(200, { items = items, total = total, page = page, size = PAGE })
end

function POST.article(q, cb)
    local feed = feedOr404(q.id, cb)
    if not feed then return end
    local item
    for _idx, it in ipairs((SubDB.items(feed.id, 1, SubDB.KEEP))) do
        if it.guid == q.guid then item = it; break end
    end
    if not item then return cb(404, { error = _("文章不存在") }) end
    if feed.kind ~= "mp" then feed.public = true end
    S().content(feed, item, function(html, err)
        if not html then return cb(502, { error = tostring(err or _("正文获取失败")) }) end
        local out = Remote.clean(html)
        -- 图已落到设备本地，clean 会把本地路径去掉：整篇没图可看时，改用订阅自带的远端图（没有就当链接本身是图）。
        if not out:find("<img", 1, true) and html:find("<img", 1, true) then
            local raw = SubDB.summary(feed.id, item.guid) or ""
            local imgs = Remote.clean(raw):gmatch("<img[^>]*>")
            local first = imgs()
            out = out .. (first or Remote.clean('<img src="' .. tostring(item.link) .. '">'))
        end
        cb(200, { title = item.title, link = item.link, html = out })
    end)
end

function POST.preview(b, cb)
    if b.kind ~= "rss" and b.kind ~= "site" and b.kind ~= "page" then return cb(400, { error = _("不支持的订阅类型") }) end
    local url, uerr = publicUrl(b.url)
    if not url then return cb(400, { error = uerr }) end
    local Subscribe = S()
    Subscribe.probe(b.kind, url, b.filter, function(feed, err)
        if not feed then
            -- 粘进来的是 OPML 订阅列表：告诉网页改走导入，而不是报「不是有效的 RSS」。
            return Subscribe.fetchText(url, function(body)
                local list = body and Remote.parseOpml(body) or {}
                if #list > 0 then return cb(200, { opml = true, url = url, count = #list }) end
                cb(422, { error = tostring(err or _("无法解析该地址")) })
            end, true)
        end
        feed.public = true
        Subscribe.providers[feed.kind].fetch(feed, nil, function(items)
            local out = { kind = feed.kind, url = feed.url, title = feed.title, items = {} }
            for i = 1, math.min(PREVIEW_ITEMS, #(items or {})) do
                out.items[i] = { title = items[i].title, link = items[i].link, time = items[i].time }
            end
            local first = items and items[1]
            if not first or not first.link or first.link == "" then return cb(200, out) end
            Subscribe.providers[feed.kind].content(feed, first, nil, function(html, cerr)
                feed.public = nil
                if html then
                    out.excerpt = Text.truncateUtf8(Text.trim(Text.stripHtml(html)), PREVIEW_TEXT)
                else
                    out.excerpt_error = tostring(cerr or "")
                end
                cb(200, out)
            end)
        end)
    end)
end

function POST.add(b, cb)
    if b.kind ~= "rss" and b.kind ~= "site" and b.kind ~= "page" then return cb(400, { error = _("不支持的订阅类型") }) end
    local url, uerr = publicUrl(b.url)
    if not url then return cb(400, { error = uerr }) end
    local function insert(feed)
        feed.grp = Text.trim(b.group or "")
        local title = Text.trim(b.title or "")
        if title ~= "" then feed.title = title end
        local id = SubDB.add(feed)
        if not id then return cb(409, { error = _("已经订阅过了") }) end
        cb(201, { id = id })
    end
    -- 预览过的直接用预览拿到的地址 / 标题，省一次请求。
    if b.checked and Text.trim(b.title or "") ~= "" then
        return insert({ kind = b.kind, url = url, title = b.title, filter = b.filter })
    end
    S().probe(b.kind, url, b.filter, function(feed, err)
        if not feed then return cb(422, { error = tostring(err or _("无法解析该地址")) }) end
        insert(feed)
    end, true)
end

function POST.update(b, cb)
    local feed = feedOr404(b.id, cb)
    if not feed then return end
    local title = b.title and Text.trim(b.title) or nil
    if title == "" then return cb(400, { error = _("名称不能为空") }) end
    SubDB.update(feed.id, { title = title, grp = b.group and Text.trim(b.group) or nil })
    cb(200, { ok = true })
end

function POST.remove(b, cb)
    local n = 0
    for _idx, id in ipairs(idList(b.ids)) do
        local feed = SubDB.feed(id)
        if feed then S().remove(feed); n = n + 1 end
    end
    cb(200, { removed = n })
end

--- 刷新单个订阅（批量由网页逐个调用，好显示进度）。并进设备上的后台刷新任务，不与它并发。
function POST.refresh(b, cb)
    local feed = feedOr404(b.id, cb)
    if not feed then return end
    require("features.subscribe.refresh").start({ feed }, { on_feed = function(_feed, added, err)
        if not added then return cb(502, { error = tostring(err or _("刷新失败")) }) end
        cb(200, { added = added })
    end })
end

--- 批量移到分组（追加到组尾）。
function POST.move(b, cb)
    local grp = Text.trim(b.group or "")
    local ids, keep = idList(b.ids), groupIds(grp)
    local seen = {}
    for _idx, id in ipairs(keep) do seen[id] = true end
    for _idx, id in ipairs(ids) do
        if not seen[id] then keep[#keep + 1] = id; seen[id] = true end
    end
    SubDB.order(grp, keep)
    cb(200, { moved = #ids })
end

--- 组内手动排序：ids 为该组的完整新顺序。
function POST.reorder(b, cb)
    SubDB.order(Text.trim(b.group or ""), idList(b.ids))
    cb(200, { ok = true })
end

--- 分组管理：create / rename / delete（删组 = 组内订阅移到未分组）。
function POST.group(b, cb)
    local s = settings()
    s.groups = s.groups or {}
    local name, to = Text.trim(b.name or ""), Text.trim(b.to or "")
    local function index(n) for i, g in ipairs(s.groups) do if g == n then return i end end end
    local function exists(n) return index(n) ~= nil or #groupIds(n) > 0 end
    if b.op == "create" then
        if name == "" then return cb(400, { error = _("分组名不能为空") }) end
        if exists(name) then return cb(409, { error = _("分组已存在") }) end
        s.groups[#s.groups + 1] = name
    elseif b.op == "rename" then
        if to == "" then return cb(400, { error = _("分组名不能为空") }) end
        if not exists(name) then return cb(404, { error = _("分组不存在") }) end
        if to == name then return cb(200, { ok = true }) end
        -- 改成已有的组名 = 并入该组：订阅追加到目标组尾，设置里只留目标组。
        local merged = exists(to)
        if merged then
            local ids = groupIds(to)
            for _idx, id in ipairs(groupIds(name)) do ids[#ids + 1] = id end
            SubDB.order(to, ids)
        else
            SubDB.renameGroup(name, to)
        end
        local i = index(name)
        if merged then
            if i then table.remove(s.groups, i) end
            if not index(to) then s.groups[#s.groups + 1] = to end
        elseif i then
            s.groups[i] = to
        else
            s.groups[#s.groups + 1] = to
        end
    elseif b.op == "delete" then
        SubDB.renameGroup(name, "")
        local i = index(name)
        if i then table.remove(s.groups, i) end
    else
        return cb(400, { error = _("不支持的操作") })
    end
    save()
    cb(200, { ok = true })
end

--- 导入 OPML：返回新增 / 已存在 / 无效条数。
function POST.import(b, cb)
    local function run(text)
        local parsed = Remote.parseOpml(text)
        if #parsed == 0 then return cb(422, { error = _("不是有效的 OPML，或文件里没有找到订阅") }) end
        local added, skipped = SubDB.addMany(parsed)
        local names = {}
        for _idx, feed in ipairs(parsed) do names[#names + 1] = feed.grp end
        addGroups(names)
        save()
        cb(200, { added = added, skipped = skipped, total = #parsed })
    end
    if Text.trim(b.url or "") == "" then return run(b.opml) end
    local url, uerr = publicUrl(b.url)
    if not url then return cb(400, { error = uerr }) end
    S().fetchText(url, function(body, err)
        if not body then return cb(502, { error = tostring(err or _("下载失败")) }) end
        run(body)
    end, true)
end

--- 在线订阅源：GET catalog 列出目录；POST catalog 取某个源的订阅清单（带「已订阅」标记）。
--- 只认目录里的 id，地址由设备端决定。
function GET.catalog(_q, cb)
    local out = {}
    for _idx, src in ipairs(require("features.subscribe.catalog").sources) do
        out[#out + 1] = { id = src.id, group = src.group, name = src.name }
    end
    cb(200, { sources = out })
end

function POST.catalog(b, cb)
    local src = require("features.subscribe.catalog").find(tostring(b.id))
    if not src then return cb(404, { error = _("订阅源不存在") }) end
    S().fetchText(src.url, function(body, err)
        if not body then return cb(502, { error = tostring(err or _("下载失败")) }) end
        local have = {}
        for _idx, f in ipairs(SubDB.feeds()) do have[f.url] = true end
        local feeds = {}
        for _idx, f in ipairs(Remote.parseOpml(body)) do
            feeds[#feeds + 1] = { title = f.title, url = f.url, subscribed = have[f.url] == true }
        end
        if #feeds == 0 then return cb(422, { error = _("这个订阅源里没有找到订阅") }) end
        cb(200, { name = src.name, feeds = feeds })
    end, true)
end

--- 订阅在线源里勾选的条目：feeds = [{ url, title }]，统一放进 group（可空）。已订阅的算 skipped。
function POST.pick(b, cb)
    local group = Text.trim(b.group or "")
    local list = {}
    for _idx, f in ipairs(type(b.feeds) == "table" and b.feeds or {}) do
        local url = Text.trim(tostring(f.url or ""))
        if url:match("^https?://") then
            local title = Text.trim(tostring(f.title or ""))
            list[#list + 1] = { kind = "rss", url = url, title = title ~= "" and title or url, grp = group }
        end
    end
    if #list == 0 then return cb(400, { error = _("没有选中订阅") }) end
    local added, skipped = SubDB.addMany(list)
    addGroups({ group })
    save()
    cb(200, { added = added, skipped = skipped })
end

--- 标已读：给 guid 标单篇，不给标整个订阅。
function POST.read(b, cb)
    local feed = feedOr404(b.id, cb)
    if not feed then return end
    SubDB.markRead(feed.id, b.guid)
    cb(200, { ok = true })
end

-- ── 纯文本批量编辑 ──
-- 每行一个订阅：「URL」「标题 | URL」「URL | 分组」「标题 | URL | 分组」；「# 分组名」开始一个分组（之后的行默认归它）。
-- 公众号行用 MP_WXS_ 号当地址，只能删除 / 移组 / 排序，改名忽略。没写标题的新地址自动识别类型和标题。

--- 当前订阅序列化成文本（未分组在前，再按分组顺序）。
---@return string
function Remote.serialize()
    local feeds = SubDB.feeds()
    local by, out = {}, {}
    for _idx, f in ipairs(feeds) do
        by[f.grp] = by[f.grp] or {}
        table.insert(by[f.grp], f)
    end
    local function lines(list)
        for _idx, f in ipairs(list or {}) do out[#out + 1] = f.title .. " | " .. f.url end
    end
    lines(by[""])
    for _idx, g in ipairs(Remote.groups(feeds)) do
        if #out > 0 then out[#out + 1] = "" end
        out[#out + 1] = "# " .. g.name
        lines(by[g.name])
    end
    return table.concat(out, "\n") .. "\n"
end

local function isUrl(part)
    return part:match("^https?://%S+$") or part:match("^MP_WXS_%w+$") or part:match("^[%w%-]+%.[%w%.%-]+[/%S]*$")
end

--- 解析文本：返回订阅行（按出现顺序）与无效行。
---@param text string
---@return { url: string, title: string|nil, group: string, line: integer, id?: integer }[] rows
---@return { line: integer, text: string }[] invalid
function Remote.parseText(text)
    local rows, invalid, group = {}, {}, ""
    local n = 0
    for raw in ((text or "") .. "\n"):gmatch("(.-)\r?\n") do
        n = n + 1
        local line = Text.trim(raw)
        local header = line:match("^#%s*(.-)%s*$")
        if header then
            group = header
        elseif line ~= "" then
            local parts = {}
            for part in (line .. "|"):gmatch("(.-)|") do parts[#parts + 1] = Text.trim(part) end
            if #parts == 1 then
                -- 没有竖线：URL 前面的文字当标题（「标题 URL」）
                local title, url = line:match("^(.-)%s+(%S+)$")
                parts = title and isUrl(url) and { title, url } or { line }
            end
            -- 取最右边像地址的一段：标题本身可能像域名（「Surmon.me | https://…」）或含竖线
            local at
            for i = #parts, 1, -1 do
                if isUrl(parts[i]) then at = i; break end
            end
            if not at then
                invalid[#invalid + 1] = { line = n, text = line }
            else
                local url = parts[at]
                if not url:match("^https?://") and not url:match("^MP_WXS_") then url = "https://" .. url end
                local title = at > 1 and table.concat(parts, " | ", 1, at - 1) or nil
                local grp = parts[at + 1]
                rows[#rows + 1] = { url = url, title = title ~= "" and title or nil,
                    group = grp and grp ~= "" and grp or group, line = n }
            end
        end
    end
    return rows, invalid
end

--- 对比当前订阅得出变更计划。
---@param text string
---@return table plan { add, remove, rename, move, invalid, rows }
function Remote.plan(text)
    local rows, invalid = Remote.parseText(text)
    local feeds = SubDB.feeds()
    local by_url = {}
    for _idx, f in ipairs(feeds) do by_url[f.url] = f end
    local plan = { add = {}, remove = {}, rename = {}, move = {}, invalid = invalid, rows = rows, duplicate = {} }
    local seen = {}
    for _idx, r in ipairs(rows) do
        if seen[r.url] then
            plan.duplicate[#plan.duplicate + 1] = { line = r.line, url = r.url }
        else
            seen[r.url] = true
            local f = by_url[r.url]
            if not f then
                if r.url:match("^MP_WXS_") then
                    plan.invalid[#plan.invalid + 1] = { line = r.line, text = r.url }
                else
                    plan.add[#plan.add + 1] = { url = r.url, title = r.title, group = r.group }
                end
            else
                r.id = f.id
                if f.kind ~= "mp" and r.title and r.title ~= f.title then
                    plan.rename[#plan.rename + 1] = { id = f.id, from = f.title, to = r.title }
                end
                if r.group ~= f.grp then
                    plan.move[#plan.move + 1] = { id = f.id, title = f.title, from = f.grp, to = r.group }
                end
            end
        end
    end
    for _idx, f in ipairs(feeds) do
        if not seen[f.url] then plan.remove[#plan.remove + 1] = { id = f.id, title = f.title, kind = f.kind } end
    end
    return plan
end

--- 新地址识别：先按 RSS（含网页里的 alternate 订阅源），不行再当任意网站。
local function detect(url, cb)
    local Subscribe = S()
    if Subscribe.privateHost(url) then return cb(nil, _("不允许访问局域网或本机地址")) end
    Subscribe.probe("rss", url, nil, function(feed)
        if feed then return cb(feed) end
        Subscribe.probe("site", url, nil, cb, true)
    end, true)
end

--- 预览（apply 为假）或执行批量编辑。执行时逐个识别新地址，最后按文本顺序重排各组。
function POST.batch(b, cb)
    local plan = Remote.plan(b.text)
    local summary = { add = plan.add, remove = plan.remove, rename = plan.rename, move = plan.move,
        invalid = plan.invalid, duplicate = plan.duplicate }
    if not b.apply then return cb(200, summary) end
    for _idx, r in ipairs(plan.remove) do
        local feed = SubDB.feed(r.id)
        if feed then S().remove(feed) end
    end
    for _idx, r in ipairs(plan.rename) do SubDB.update(r.id, { title = r.to }) end
    local failed, added, i = {}, 0, 0
    local new_ids = {}
    local function finish()
        local orders, names = {}, {}
        for _idx, r in ipairs(plan.rows) do
            local id = r.id or new_ids[r.url]
            if id then
                if not orders[r.group] then orders[r.group] = {}; names[#names + 1] = r.group end
                table.insert(orders[r.group], id)
            end
        end
        for _idx, g in ipairs(names) do SubDB.order(g, orders[g]) end
        addGroups(names)
        save()
        cb(200, { added = added, removed = #plan.remove, renamed = #plan.rename, moved = #plan.move, failed = failed })
    end
    local function step()
        i = i + 1
        local a = plan.add[i]
        if not a then return finish() end
        detect(a.url, function(feed, err)
            if not feed then
                failed[#failed + 1] = { url = a.url, error = tostring(err or _("无法解析该地址")) }
                return step()
            end
            if a.title then feed.title = a.title end
            feed.grp = a.group
            local id = SubDB.add(feed)
            if id then
                added = added + 1
                new_ids[a.url] = id
            else
                failed[#failed + 1] = { url = a.url, error = _("已经订阅过了") }
            end
            step()
        end)
    end
    step()
end

function GET.text(_q, cb) cb(200, { text = Remote.serialize() }) end

--- 分发；回调只回一次由调用方（remote/ext_route）保证。
---@param method "GET"|"POST"
---@param action string
---@param params table query（GET）或 JSON body（POST）
---@param cb fun(status: integer, result: table)
function Remote.handle(method, action, params, cb)
    local fn = (method == "GET" and GET or POST)[action]
    if not fn then return cb(404, { error = _("接口不存在") }) end
    local ok, err = pcall(fn, params or {}, cb)
    if not ok then
        require("utils.log").warn("subscribe remote failed", action, err)
        cb(500, { error = tostring(err) })
    end
end

--- 附件下载（GET opml）；其余动作返回 nil 交给 handle。
---@param action string
---@return { ctype: string, filename: string, body: string }|nil
function Remote.download(action)
    if action ~= "opml" then return nil end
    return { ctype = "text/x-opml; charset=utf-8", filename = "moon-subscriptions.opml", body = Remote.opml() }
end

return Remote
