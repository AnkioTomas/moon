--[[--
正文抽取：Mozilla Readability.js（github.com/mozilla/readability）的 Lua 移植，函数与原版一一对应（_grabArticle 等去掉下划线）。

parse 流程同原版：unwrapNoscriptImages → JSON-LD → removeScripts → prepDocument（style、br 串成段、font）→ 元数据 →
grabArticle（隐藏 / 署名 / 重复标题 / unlikelyCandidates / role，div 里的行内内容包 p，打分加给 5 层祖先，前 5 名
共同祖先、父链上溯、兄弟合并）→ prepArticle（样式属性、数据表、懒加载图、表单 / embed / 分享 / 标题 / 条件清理、
h1→h2、空段落、单格表格）→ 正文太短按 FLAG_STRIP_UNLIKELYS → WEIGHT_CLASSES → CLEAN_CONDITIONALLY 依次放宽重试，
都不够取最长一次 → postProcess（相对地址、嵌套 div 化简、class 只留 page）。

与原版的差异（都为中文与 KOReader）：
  - 没有 DOM：自带宽容解析器（隐式闭合 p / li / td / tr / option，script / style / textarea / title 按原文），
    元素超过 MAX_ELEMS 不解析（原版 maxElemsToParse）；重试时重新解析原文，而不是缓存 innerHTML。
  - 长度按 UTF-8 字符数，charThreshold 取 200（中文）；textSimilarity 把非 ASCII 字符当词字符（原版 \W 会把汉字全切掉）；
    cleanConditionally 的逗号数也算全角「，」。
  - 序列化只留阅读器用得上的属性（href / src / alt / title / colspan / rowspan / class=page），
    img 没有 src 时取 srcset 第一个地址。
  - 抽到的正文不足 MIN_CHARS 返回 nil（调用方退回整页抽取 / RSS 摘要）。

@module koplugin.book.features.subscribe.readability
--]]

local Text = require("utils.text")

local R = {}

local FLAG_STRIP_UNLIKELYS, FLAG_WEIGHT_CLASSES, FLAG_CLEAN_CONDITIONALLY = 1, 2, 4
local N_TOP_CANDIDATES = 5
--- 原版 500 字符按英文定；同样篇幅的中文约 1/3，取 200。
local CHAR_THRESHOLD = 200
local MIN_CHARS = 100
R.MAX_ELEMS = 20000

local function set(list)
    local s = {}
    for _idx, v in ipairs(list) do s[v] = true end
    return s
end

local VOID = set({ "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source",
    "track", "wbr" })
local RAW = set({ "script", "style", "textarea", "title" })
local P_CLOSERS = set({ "address", "article", "aside", "blockquote", "div", "dl", "fieldset", "figure", "footer",
    "form", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hr", "main", "nav", "ol", "p", "pre", "section", "table",
    "ul", "figcaption", "details" })
local UNLIKELY_ROLES = set({ "menu", "menubar", "complementary", "navigation", "alert", "alertdialog", "dialog" })
local DIV_TO_P_ELEMS = set({ "blockquote", "dl", "div", "img", "ol", "p", "pre", "table", "ul" })
local ALTER_TO_DIV_EXCEPTIONS = set({ "div", "article", "section", "p", "ol", "ul" })
local PRESENTATIONAL_ATTRIBUTES = { "align", "background", "bgcolor", "border", "cellpadding", "cellspacing",
    "frame", "hspace", "rules", "style", "valign", "vspace" }
local DEPRECATED_SIZE_ATTRIBUTE_ELEMS = set({ "table", "th", "td", "hr", "pre" })
local PHRASING_ELEMS = set({ "abbr", "audio", "b", "bdo", "br", "button", "cite", "code", "data", "datalist", "dfn",
    "em", "embed", "i", "img", "input", "kbd", "label", "mark", "math", "meter", "noscript", "object", "output",
    "progress", "q", "ruby", "samp", "script", "select", "small", "span", "strong", "sub", "sup", "textarea", "time",
    "var", "wbr" })
local TAGS_TO_SCORE = set({ "section", "h2", "h3", "h4", "h5", "h6", "p", "td", "pre" })
local KEEP_ATTR = set({ "href", "src", "alt", "title", "colspan", "rowspan" })

-- REGEXPS：原版是正则，这里是小写子串清单（i 标志）。
local UNLIKELY = { "-ad-", "ai2html", "banner", "breadcrumbs", "combx", "comment", "community", "cover-wrap", "disqus",
    "extra", "footer", "gdpr", "header", "legends", "menu", "related", "remark", "replies", "rss", "shoutbox",
    "sidebar", "skyscraper", "social", "sponsor", "supplemental", "ad-break", "agegate", "pagination", "pager",
    "popup", "yom-remote" }
local OK_MAYBE = { "and", "article", "body", "column", "content", "main", "mathjax", "shadow" }
local POSITIVE = { "article", "body", "content", "entry", "hentry", "h-entry", "main", "page", "pagination", "post",
    "text", "blog", "story" }
local NEGATIVE = { "-ad-", "hidden", "banner", "combx", "comment", "com-", "contact", "footer", "gdpr", "masthead",
    "media", "meta", "outbrain", "promo", "related", "scroll", "share", "shoutbox", "sidebar", "skyscraper", "sponsor",
    "shopping", "tags", "widget" }
local BYLINE = { "byline", "author", "dateline", "writtenby", "p-author" }
local VIDEO_HOSTS = { "dailymotion.com", "youtube.com", "youtube-nocookie.com", "player.vimeo.com", "v.qq.com",
    "bilibili.com", "live.bilibili.com", "archive.org", "upload.wikimedia.org", "player.twitch.tv" }
local COMMAS = { ",", "،", "﹐", "︐", "︑", "⹁", "⸴", "⸲", "，" }
local AD_WORDS = set({ "ad", "advertising", "advertisement", "pub", "publicité", "werb", "werbung", "广告", "реклама",
    "anuncio" })
local LOADING_WORDS = set({ "loading", "正在加载", "загрузка", "chargement", "cargando" })
local TITLE_SEPS = { "|", "-", "–", "—", "\\", "/", ">", "»" }
local JSONLD_TYPES = set({ "Article", "AdvertiserContentArticle", "NewsArticle", "AnalysisNewsArticle",
    "AskPublicNewsArticle", "BackgroundNewsArticle", "OpinionNewsArticle", "ReportageNewsArticle", "ReviewNewsArticle",
    "Report", "SatiricalArticle", "ScholarlyArticle", "MedicalScholarlyArticle", "SocialMediaPosting", "BlogPosting",
    "LiveBlogPosting", "DiscussionForumPosting", "TechArticle", "APIReference" })

local function any(s, list)
    s = s:lower()
    for _idx, w in ipairs(list) do
        if s:find(w, 1, true) then return true end
    end
    return false
end

local function negative(s)
    if any(s, NEGATIVE) then return true end
    return (" " .. s:lower() .. " "):find(" hid ", 1, true) ~= nil
end

local function shareMatch(s)
    s = s:lower()
    return s:find("%f[%w]share%f[^%w]") ~= nil or s:find("%f[%w]sharedaddy%f[^%w]") ~= nil
end

local function isVideo(s)
    s = s:lower()
    for _idx, h in ipairs(VIDEO_HOSTS) do
        if s:find("//" .. h, 1, true) or s:find("//www." .. h, 1, true) then return true end
    end
    return false
end

--- UTF-8 字符数。
local function len(s)
    local _n, count = s:gsub("[^\128-\191]", "")
    return count
end

local function trim(s) return (s:match("^%s*(.-)%s*$")) end

-- ── 迷你 DOM ──────────────────────────────────────────────────────────────
-- 元素 { tag, attrs = {}, parent, children = {} }；文本 { text, parent }；文档 tag = "#document"。
-- textContent 按全局版本号缓存：任何改动都让缓存失效，打分阶段（不改树）反复取文本不必重算。

local version = 0
local count -- 解析中的元素数

local function el(tag, attrs)
    return { tag = tag, attrs = attrs or {}, children = {} }
end

local function append(parent, node)
    if node.parent then
        local siblings = node.parent.children
        for i = 1, #siblings do
            if siblings[i] == node then table.remove(siblings, i) break end
        end
    end
    node.parent = parent
    parent.children[#parent.children + 1] = node
    version = version + 1
end

local function indexOf(node)
    local siblings = node.parent and node.parent.children
    for i = 1, siblings and #siblings or 0 do
        if siblings[i] == node then return i end
    end
end

local function remove(node)
    local i = indexOf(node)
    if i then table.remove(node.parent.children, i) end
    node.parent = nil
    version = version + 1
end

local function insertBefore(parent, node, ref)
    if node.parent then remove(node) end
    local i = ref and indexOf(ref) or #parent.children + 1
    table.insert(parent.children, i, node)
    node.parent = parent
    version = version + 1
end

local function replaceChild(new, old)
    local parent = old.parent
    insertBefore(parent, new, old)
    remove(old)
end

local function nextSibling(node)
    local i = indexOf(node)
    return i and node.parent.children[i + 1]
end

local function elementChildren(node)
    local out = {}
    for _idx, c in ipairs(node.children or {}) do
        if c.tag then out[#out + 1] = c end
    end
    return out
end

local function firstElementChild(node)
    for _idx, c in ipairs(node.children or {}) do
        if c.tag then return c end
    end
end

local function nextElementSibling(node)
    local siblings = node.parent and node.parent.children
    local i = indexOf(node)
    if not i then return nil end
    for j = i + 1, #siblings do
        if siblings[j].tag then return siblings[j] end
    end
end

local function textContent(node)
    if node.text then return node.text end
    if node._tcv == version then return node._tc end
    local out = {}
    for i, c in ipairs(node.children) do out[i] = textContent(c) end
    node._tc, node._tcv = table.concat(out), version
    return node._tc
end

--- 署名用的文本：相邻元素之间补空格（LWN 的「作者」「日期」是并排的元素，直接拼会粘在一起），再压空白。
local function spacedText(node)
    local out = {}
    local function walk(n)
        if n.text then out[#out + 1] = n.text return end
        out[#out + 1] = " "
        for _idx, c in ipairs(n.children) do walk(c) end
        out[#out + 1] = " "
    end
    walk(node)
    return (table.concat(out):gsub("%s+", " "))
end

--- 后代中这些标签的元素，文档序，不含自己。
local function byTags(node, tags)
    local out = {}
    local function walk(n)
        for _idx, c in ipairs(n.children) do
            if c.tag then
                if tags[c.tag] then out[#out + 1] = c end
                walk(c)
            end
        end
    end
    walk(node)
    return out
end

local function byTag(node, tag) return byTags(node, { [tag] = true }) end

local function attr(node, name) return node.attrs and node.attrs[name] end
local function className(node) return attr(node, "class") or "" end
local function idOf(node) return attr(node, "id") or "" end

local function parseAttrs(s)
    local attrs = {}
    local rest = s:gsub('([%a_:][%w_:%.%-]*)%s*=%s*(["\'])(.-)%2', function(name, _q, v)
        name = name:lower()
        if attrs[name] == nil then attrs[name] = Text.xmlDecode(v) end
        return " "
    end):gsub("([%a_:][%w_:%.%-]*)%s*=%s*([^%s>]+)", function(name, v)
        name = name:lower()
        if attrs[name] == nil then attrs[name] = Text.xmlDecode(v) end
        return " "
    end)
    -- 无值属性（hidden 等）
    for name in rest:gmatch("[%a_:][%w_:%.%-]*") do
        local key = name:lower()
        if attrs[key] == nil then attrs[key] = "" end
    end
    return attrs
end

--- HTML → 文档树；元素数超过 MAX_ELEMS 返回 nil。
---@param html string
---@return table|nil doc
function R.parse(html)
    html = html:gsub("<!%-%-.-%-%->", ""):gsub("<!%[CDATA%[(.-)%]%]>", "%1"):gsub("<![^>]*>", ""):gsub("<%?[^>]*>", "")
    local doc = el("#document")
    local cur, pos = doc, 1
    count = 0
    local function close(name)
        local n = cur
        while n and n.tag ~= name and n ~= doc do n = n.parent end
        if n and n ~= doc then cur = n.parent end
    end
    local function within(names, stop)
        local n = cur
        while n and n ~= doc and not stop[n.tag] do
            if names[n.tag] then return n end
            n = n.parent
        end
    end
    local function text(s)
        if s ~= "" then
            local node = { text = Text.xmlDecode(s), parent = cur }
            cur.children[#cur.children + 1] = node
        end
    end
    while true do
        local s, e, slash, tag, attrs = html:find("<(/?)([%a][%w:%-]*)(.-)>", pos)
        text(html:sub(pos, (s or #html + 1) - 1))
        if not s then break end
        pos = e + 1
        local name = tag:lower()
        if slash == "/" then
            if name == "p" and not within({ p = true }, { div = true, td = true, li = true }) then
                -- 孤立 </p> 按浏览器补一个空段落：忽略即可
            else
                close(name)
            end
        else
            count = count + 1
            if count > R.MAX_ELEMS then return nil end
            if P_CLOSERS[name] and cur.tag == "p" then cur = cur.parent end
            if name == "li" then
                local li = within({ li = true }, { ul = true, ol = true })
                if li then cur = li.parent end
            elseif name == "dt" or name == "dd" then
                local d = within({ dt = true, dd = true }, { dl = true })
                if d then cur = d.parent end
            elseif name == "td" or name == "th" then
                local c = within({ td = true, th = true }, { tr = true, table = true })
                if c then cur = c.parent end
            elseif name == "tr" then
                local r = within({ tr = true }, { table = true, tbody = true, thead = true, tfoot = true })
                if r then cur = r.parent end
            elseif name == "option" and cur.tag == "option" then
                cur = cur.parent
            end
            local node = el(name, parseAttrs(attrs))
            node.parent = cur
            cur.children[#cur.children + 1] = node
            if RAW[name] then
                local cs, ce = html:find("</" .. name .. "%s*>", pos)
                local body = html:sub(pos, (cs or #html + 1) - 1)
                if body ~= "" then
                    node.children[1] = { text = name == "title" and Text.xmlDecode(body) or body, parent = node }
                end
                pos = (ce or #html) + 1
            elseif not VOID[name] and not attrs:find("/%s*$") then
                cur = node
            end
        end
    end
    version = version + 1
    -- 补齐 html / body：所有正文都在 body 下。
    local html_el = firstElementChild(doc)
    if not html_el or html_el.tag ~= "html" then
        html_el = el("html")
        for _idx, c in ipairs(doc.children) do c.parent = html_el end
        html_el.children, doc.children = doc.children, {}
        append(doc, html_el)
    end
    if not byTag(html_el, "body")[1] then
        local body = el("body")
        for _idx, c in ipairs(elementChildren(html_el)) do
            if c.tag ~= "head" then append(body, c) end
        end
        for i = #html_el.children, 1, -1 do
            if html_el.children[i].text then append(body, html_el.children[i]) end
        end
        append(html_el, body)
    end
    return doc
end

local function serialize(node, out)
    for _idx, c in ipairs(node.children) do
        if c.text then
            out[#out + 1] = (c.text:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
        else
            local parts = { "<", c.tag }
            local names = {}
            for k in pairs(c.attrs) do
                if KEEP_ATTR[k] or (k == "class" and c.attrs[k] ~= "") then names[#names + 1] = k end
            end
            if c.tag == "img" and not c.attrs.src and c.attrs.srcset then
                c.attrs.src = c.attrs.srcset:match("^%s*([^%s,]+)")
                if c.attrs.src then names[#names + 1] = "src" end
            end
            table.sort(names)
            for _i, k in ipairs(names) do
                parts[#parts + 1] = " " .. k .. '="' .. c.attrs[k]:gsub("&", "&amp;"):gsub('"', "&quot;") .. '"'
            end
            if VOID[c.tag] then
                parts[#parts + 1] = "/>"
                out[#out + 1] = table.concat(parts)
            else
                parts[#parts + 1] = ">"
                out[#out + 1] = table.concat(parts)
                serialize(c, out)
                out[#out + 1] = "</" .. c.tag .. ">"
            end
        end
    end
    return out
end

local function innerHTML(node) return table.concat(serialize(node, {})) end

-- ── Readability ───────────────────────────────────────────────────────────

local Reader = {}
Reader.__index = Reader

function Reader:flagIsActive(flag) return self.flags % (flag * 2) >= flag end
function Reader:removeFlag(flag) if self:flagIsActive(flag) then self.flags = self.flags - flag end end

local function getInnerText(e, normalize)
    local s = trim(textContent(e))
    if normalize ~= false then s = s:gsub("%s%s+", " ") end
    return s
end

local function getNextNode(node, ignoreSelfAndKids)
    if not ignoreSelfAndKids then
        local first = firstElementChild(node)
        if first then return first end
    end
    local sib = nextElementSibling(node)
    if sib then return sib end
    repeat
        node = node.parent
    until not node or nextElementSibling(node)
    return node and nextElementSibling(node)
end

local function removeAndGetNext(node)
    local nextNode = getNextNode(node, true)
    remove(node)
    return nextNode
end

local function setNodeTag(node, tag)
    node.tag = tag
    return node
end

local function tokens(s)
    local out = {}
    for t in s:lower():gmatch("[%w\128-\255]+") do out[#out + 1] = t end
    return out
end

local function textSimilarity(a, b)
    local ta, tb = tokens(a), tokens(b)
    if #ta == 0 or #tb == 0 then return 0 end
    local inA = set(ta)
    local uniq = {}
    for _idx, t in ipairs(tb) do
        if not inA[t] then uniq[#uniq + 1] = t end
    end
    return 1 - len(table.concat(uniq, " ")) / len(table.concat(tb, " "))
end

local function hasAncestorTag(node, tag, maxDepth, filter)
    maxDepth = maxDepth or 3
    local depth = 0
    while node.parent do
        if maxDepth > 0 and depth > maxDepth then return false end
        if node.parent.tag == tag and (not filter or filter(node.parent)) then return true end
        node = node.parent
        depth = depth + 1
    end
    return false
end

local function getNodeAncestors(node, maxDepth)
    local out = {}
    while node.parent do
        out[#out + 1] = node.parent
        if maxDepth and #out == maxDepth then break end
        node = node.parent
    end
    return out
end

local function isPhrasingContent(node)
    if node.text then return true end
    if PHRASING_ELEMS[node.tag] then return true end
    if node.tag == "a" or node.tag == "del" or node.tag == "ins" then
        for _idx, c in ipairs(node.children) do
            if not isPhrasingContent(c) then return false end
        end
        return true
    end
    return false
end

local function isWhitespace(node)
    return (node.text and trim(node.text) == "") or node.tag == "br"
end

local function hasSingleTagInsideElement(e, tag)
    local kids = elementChildren(e)
    if #kids ~= 1 or kids[1].tag ~= tag then return false end
    for _idx, c in ipairs(e.children) do
        if c.text and c.text:find("%S$") then return false end
    end
    return true
end

local function isElementWithoutContent(node)
    if not node.tag or trim(textContent(node)) ~= "" then return false end
    local kids = #elementChildren(node)
    return kids == 0 or kids == #byTag(node, "br") + #byTag(node, "hr")
end

local function hasChildBlockElement(e)
    for _idx, c in ipairs(e.children or {}) do
        if c.tag and (DIV_TO_P_ELEMS[c.tag] or hasChildBlockElement(c)) then return true end
    end
    return false
end

local function getLinkDensity(e)
    local total = len(getInnerText(e))
    if total == 0 then return 0 end
    local links = 0
    for _idx, a in ipairs(byTag(e, "a")) do
        local href = attr(a, "href")
        links = links + len(getInnerText(a)) * ((href and href:match("^#.")) and 0.3 or 1)
    end
    return links / total
end

function Reader:getClassWeight(e)
    if not self:flagIsActive(FLAG_WEIGHT_CLASSES) then return 0 end
    local w = 0
    for _idx, v in ipairs({ className(e), idOf(e) }) do
        if v ~= "" then
            if negative(v) then w = w - 25 end
            if any(v, POSITIVE) then w = w + 25 end
        end
    end
    return w
end

local INIT_SCORE = { div = 5, pre = 3, td = 3, blockquote = 3, address = -3, ol = -3, ul = -3, dl = -3, dd = -3,
    dt = -3, li = -3, form = -3, h1 = -5, h2 = -5, h3 = -5, h4 = -5, h5 = -5, h6 = -5, th = -5 }

function Reader:initializeNode(node)
    node.score = (INIT_SCORE[node.tag] or 0) + self:getClassWeight(node)
end

local function isProbablyVisible(node)
    local style = (attr(node, "style") or ""):lower()
    if style:find("display%s*:%s*none") or style:find("visibility%s*:%s*hidden") then return false end
    if attr(node, "hidden") then return false end
    if attr(node, "aria-hidden") == "true" and not className(node):find("fallback-image", 1, true) then
        return false
    end
    return true
end

local function isValidByline(node, matchString)
    local itemprop = attr(node, "itemprop")
    local n = len(trim(textContent(node)))
    return (attr(node, "rel") == "author" or (itemprop and itemprop:find("author", 1, true)) or any(matchString, BYLINE))
        and n > 0 and n < 100
end

function Reader:headerDuplicatesTitle(node)
    if node.tag ~= "h1" and node.tag ~= "h2" then return false end
    return textSimilarity(self.title or "", getInnerText(node, false)) > 0.75
end

local function wordCount(s)
    local _s, n = s:gsub("%s+", "")
    return n + 1
end

--- 原版 _getArticleTitle：去掉「 | 站名」之类的层级后缀。
local function getArticleTitle(doc)
    local t = byTag(doc, "title")[1]
    local orig = t and trim(textContent(t)) or ""
    local cur = orig
    local hierarchical = false
    local last
    for _idx, sep in ipairs(TITLE_SEPS) do
        local pat = "%s" .. sep:gsub("%p", "%%%0") .. "%s"
        local init = 1
        while true do
            local s = orig:find(pat, init)
            if not s then break end
            if not last or s > last then last = s end
            if sep == "\\" or sep == "/" or sep == ">" or sep == "»" then hierarchical = true end
            init = s + 1
        end
    end
    if last then
        cur = orig:sub(1, last - 1)
        if wordCount(cur) < 3 then
            local first
            for _idx, sep in ipairs(TITLE_SEPS) do
                local s = orig:find(sep, 1, true)
                if s and (not first or s < first[1]) then first = { s, #sep } end
            end
            cur = first and orig:sub(first[1] + first[2]) or orig
        end
    elseif cur:find(": ", 1, true) then
        local match = false
        for _idx, h in ipairs(byTags(doc, { h1 = true, h2 = true })) do
            if trim(textContent(h)) == trim(cur) then match = true break end
        end
        if not match then
            local lastColon = orig:match(".*():")
            cur = orig:sub(lastColon + 1)
            local firstColon = orig:find(":", 1, true)
            if wordCount(cur) < 3 then
                cur = orig:sub(firstColon + 1)
            elseif wordCount(orig:sub(1, firstColon - 1)) > 5 then
                cur = orig
            end
        end
    elseif len(cur) > 150 or len(cur) < 15 then
        local h1s = byTag(doc, "h1")
        if #h1s == 1 then cur = getInnerText(h1s[1]) end
    end
    cur = trim(cur):gsub("%s%s+", " ")
    local n = wordCount(cur)
    if n <= 4 then
        local stripped = orig
        for _idx, sep in ipairs(TITLE_SEPS) do stripped = stripped:gsub("%s" .. sep:gsub("%p", "%%%0") .. "%s", "") end
        if not hierarchical or n ~= wordCount(stripped) - 1 then cur = orig end
    end
    return cur
end

local function getJSONLD(doc, titleFn)
    local json = require("utils.json")
    for _idx, s in ipairs(byTag(doc, "script")) do
        if attr(s, "type") == "application/ld+json" then
            local ok, parsed = pcall(json.decode, (textContent(s):gsub("^%s*<!%[CDATA%[", ""):gsub("%]%]>%s*$", "")))
            local function isArticle(it)
                return type(it) == "table" and type(it["@type"]) == "string" and JSONLD_TYPES[it["@type"]]
            end
            if ok and type(parsed) == "table" then
                if parsed[1] then
                    local found
                    for _i, it in ipairs(parsed) do if isArticle(it) then found = it break end end
                    parsed = found
                end
                local ctx = parsed and parsed["@context"]
                local schema = function(v) return type(v) == "string" and v:match("^https?://schema%.org/?$") end
                if parsed and (schema(ctx) or (type(ctx) == "table" and schema(ctx["@vocab"]))) then
                    if not parsed["@type"] and type(parsed["@graph"]) == "table" then
                        local found
                        for _i, it in ipairs(parsed["@graph"]) do if isArticle(it) then found = it break end end
                        parsed = found
                    end
                    if isArticle(parsed) then
                        local m = {}
                        if type(parsed.name) == "string" and type(parsed.headline) == "string"
                            and parsed.name ~= parsed.headline then
                            local title = titleFn()
                            local nameMatches = textSimilarity(parsed.name, title) > 0.75
                            local headlineMatches = textSimilarity(parsed.headline, title) > 0.75
                            m.title = (headlineMatches and not nameMatches) and parsed.headline or parsed.name
                        elseif type(parsed.name) == "string" then
                            m.title = trim(parsed.name)
                        elseif type(parsed.headline) == "string" then
                            m.title = trim(parsed.headline)
                        end
                        local author = parsed.author
                        if type(author) == "table" then
                            if type(author.name) == "string" then
                                m.byline = trim(author.name)
                            elseif type(author[1]) == "table" and type(author[1].name) == "string" then
                                local names = {}
                                for _i, a in ipairs(author) do
                                    if type(a) == "table" and type(a.name) == "string" then names[#names + 1] = trim(a.name) end
                                end
                                m.byline = table.concat(names, ", ")
                            end
                        end
                        if type(parsed.description) == "string" then m.excerpt = trim(parsed.description) end
                        if type(parsed.publisher) == "table" and type(parsed.publisher.name) == "string" then
                            m.siteName = trim(parsed.publisher.name)
                        end
                        if type(parsed.datePublished) == "string" then m.publishedTime = trim(parsed.datePublished) end
                        return m
                    end
                end
            end
        end
    end
    return {}
end

local META_PREFIX = { "dc", "dcterm", "og", "twitter", "parsely", "weibo:article", "weibo:webpage" }
local META_NAME = set({ "author", "creator", "pub-date", "description", "title", "site_name" })
local META_PROP_NS = set({ "article", "dc", "dcterm", "og", "twitter" })
local META_PROP = set({ "author", "creator", "description", "published_time", "title", "site_name" })

local function metaName(name)
    local n = name:lower():gsub("%s", "")
    if META_NAME[n] then return n end
    for _idx, p in ipairs(META_PREFIX) do
        if n:sub(1, #p) == p then
            local sep, base = n:sub(#p + 1, #p + 1), n:sub(#p + 2)
            if (sep == "-" or sep == "." or sep == ":") and META_NAME[base] then return (n:gsub("%.", ":")) end
        end
    end
end

local function getArticleMetadata(doc, jsonld)
    local values = {}
    for _idx, m in ipairs(byTag(doc, "meta")) do
        local content = attr(m, "content")
        if content and content ~= "" then
            local matched = false
            local prop = attr(m, "property")
            if prop then
                for ns, key in prop:lower():gmatch("(%a+)%s*:%s*([%a_]+)") do
                    if META_PROP_NS[ns] and META_PROP[key] then
                        values[ns .. ":" .. key] = trim(content)
                        matched = true
                        break
                    end
                end
            end
            local name = not matched and attr(m, "name")
            local key = name and metaName(name)
            if key then values[key] = trim(content) end
        end
    end
    local function first(...)
        for i = 1, select("#", ...) do
            local v = select(i, ...)
            if v and v ~= "" then return v end
        end
    end
    local articleAuthor = values["article:author"]
    if articleAuthor and articleAuthor:match("^%a[%w+.-]*://") then articleAuthor = nil end
    return {
        title = first(jsonld.title, values["dc:title"], values["dcterm:title"], values["og:title"],
            values["weibo:article:title"], values["weibo:webpage:title"], values.title, values["twitter:title"],
            values["parsely-title"]) or getArticleTitle(doc),
        byline = first(jsonld.byline, values["dc:creator"], values["dcterm:creator"], values.author,
            values["parsely-author"], articleAuthor),
        excerpt = first(jsonld.excerpt, values["dc:description"], values["dcterm:description"],
            values["og:description"], values["weibo:article:description"], values["weibo:webpage:description"],
            values.description, values["twitter:description"]),
        siteName = first(jsonld.siteName, values["og:site_name"]),
        publishedTime = first(jsonld.publishedTime, values["article:published_time"], values["parsely-pub-date"]),
    }
end

local function hasImageExt(v)
    v = v:lower()
    return v:find("%.jpe?g") or v:find("%.png") or v:find("%.webp")
end

local function isSingleImage(node)
    while node do
        if node.tag == "img" then return true end
        local kids = elementChildren(node)
        if #kids ~= 1 or trim(textContent(node)) ~= "" then return false end
        node = kids[1]
    end
    return false
end

local function unwrapNoscriptImages(doc)
    for _idx, img in ipairs(byTag(doc, "img")) do
        local keep = false
        for k, v in pairs(img.attrs) do
            if k == "src" or k == "srcset" or k == "data-src" or k == "data-srcset" or hasImageExt(v) then
                keep = true
                break
            end
        end
        if not keep then remove(img) end
    end
    for _idx, noscript in ipairs(byTag(doc, "noscript")) do
        if noscript.parent and isSingleImage(noscript) then
            local i = indexOf(noscript)
            local prev
            for j = i - 1, 1, -1 do
                if noscript.parent.children[j].tag then prev = noscript.parent.children[j] break end
            end
            if prev and isSingleImage(prev) then
                local prevImg = prev.tag == "img" and prev or byTag(prev, "img")[1]
                local fresh = firstElementChild(noscript)
                local newImg = fresh.tag == "img" and fresh or byTag(fresh, "img")[1]
                for k, v in pairs(prevImg.attrs) do
                    if v ~= "" and (k == "src" or k == "srcset" or hasImageExt(v)) and newImg.attrs[k] ~= v then
                        newImg.attrs[newImg.attrs[k] and ("data-old-" .. k) or k] = v
                    end
                end
                replaceChild(fresh, prev)
            end
        end
    end
end

local function nextNode(node)
    local n = node
    while n and not n.tag and trim(n.text) == "" do n = nextSibling(n) end
    return n
end

local function replaceBrs(body)
    for _idx, br in ipairs(byTag(body, "br")) do
        if br.parent then
            local nxt = nextSibling(br)
            local replaced = false
            while true do
                nxt = nxt and nextNode(nxt)
                if not nxt or nxt.tag ~= "br" then break end
                replaced = true
                local sib = nextSibling(nxt)
                remove(nxt)
                nxt = sib
            end
            if replaced then
                local p = el("p")
                replaceChild(p, br)
                nxt = nextSibling(p)
                while nxt do
                    if nxt.tag == "br" then
                        local after = nextSibling(nxt)
                        local ne = after and nextNode(after)
                        if ne and ne.tag == "br" then break end
                    end
                    if not isPhrasingContent(nxt) then break end
                    local sib = nextSibling(nxt)
                    append(p, nxt)
                    nxt = sib
                end
                while #p.children > 0 and isWhitespace(p.children[#p.children]) do remove(p.children[#p.children]) end
                if p.parent.tag == "p" then setNodeTag(p.parent, "div") end
            end
        end
    end
end

local function prepDocument(doc)
    for _idx, s in ipairs(byTag(doc, "style")) do remove(s) end
    replaceBrs(byTag(doc, "body")[1])
    for _idx, f in ipairs(byTag(doc, "font")) do setNodeTag(f, "span") end
end

local function removeNodes(list, filter)
    for i = #list, 1, -1 do
        local n = list[i]
        if n.parent and (not filter or filter(n)) then remove(n) end
    end
end

local function anyVideoAttr(node)
    for _k, v in pairs(node.attrs) do
        if isVideo(v) then return true end
    end
    return node.tag == "object" and isVideo(innerHTML(node))
end

function Reader:clean(e, tag)
    local isEmbed = tag == "object" or tag == "embed" or tag == "iframe"
    removeNodes(byTag(e, tag), function(node) return not (isEmbed and anyVideoAttr(node)) end)
end

local function getRowAndColumnCount(tbl)
    local rows, columns = 0, 0
    for _idx, tr in ipairs(byTag(tbl, "tr")) do
        rows = rows + (tonumber(attr(tr, "rowspan")) or 1)
        local cols = 0
        for _i, td in ipairs(byTag(tr, "td")) do cols = cols + (tonumber(attr(td, "colspan")) or 1) end
        columns = math.max(columns, cols)
    end
    return rows, columns
end

local function markDataTables(root)
    for _idx, t in ipairs(byTag(root, "table")) do
        local caption = byTag(t, "caption")[1]
        if attr(t, "role") == "presentation" or attr(t, "datatable") == "0" then
            t.datatable = false
        elseif (attr(t, "summary") or "") ~= "" or (caption and #caption.children > 0) then
            t.datatable = true
        elseif #byTags(t, set({ "col", "colgroup", "tfoot", "thead", "th" })) > 0 then
            t.datatable = true
        elseif byTag(t, "table")[1] then
            t.datatable = false
        else
            local rows, cols = getRowAndColumnCount(t)
            if cols == 1 or rows == 1 then
                t.datatable = false
            elseif rows >= 10 or cols > 4 then
                t.datatable = true
            else
                t.datatable = rows * cols > 10
            end
        end
    end
end

local function fixLazyImages(root)
    for _idx, e in ipairs(byTags(root, set({ "img", "picture", "figure" }))) do
        local src = e.tag == "img" and attr(e, "src") or nil
        local mime = src and src:match("^data:%s*([^%s;,]+)%s*;%s*base64%s*,")
        if mime and mime ~= "image/svg+xml" then
            local could = false
            for k, v in pairs(e.attrs) do
                if k ~= "src" and hasImageExt(v) then could = true break end
            end
            local b64 = #src - #src:match("^data:[^,]*,")
            if could and b64 < 133 then e.attrs.src, src = nil, nil end
        end
        local srcset = e.tag == "img" and attr(e, "srcset") or nil
        local skip = mime == "image/svg+xml"
            or (((src and src ~= "") or (srcset and srcset ~= "" and srcset ~= "null"))
                and not className(e):lower():find("lazy", 1, true))
        if not skip then
            for k, v in pairs(e.attrs) do
                if k ~= "src" and k ~= "srcset" and k ~= "alt" then
                    local copyTo
                    local lv = v:lower()
                    if lv:find("%.jpe?g%s+%d") or lv:find("%.png%s+%d") or lv:find("%.webp%s+%d") then
                        copyTo = "srcset"
                    elseif lv:match("^%s*%S+%.jpe?g%S*%s*$") or lv:match("^%s*%S+%.png%S*%s*$")
                        or lv:match("^%s*%S+%.webp%S*%s*$") then
                        copyTo = "src"
                    end
                    if copyTo then
                        if e.tag == "img" or e.tag == "picture" then
                            e.attrs[copyTo] = v
                        elseif e.tag == "figure" and #byTags(e, set({ "img", "picture" })) == 0 then
                            local img = el("img", { [copyTo] = v })
                            append(e, img)
                        end
                    end
                end
            end
        end
    end
end

local function getTextDensity(e, tags)
    local total = len(getInnerText(e))
    if total == 0 then return 0 end
    local n = 0
    for _idx, c in ipairs(byTags(e, tags)) do n = n + len(getInnerText(c)) end
    return n / total
end

local function charCount(e)
    local s, n = getInnerText(e), 0
    for _idx, c in ipairs({ ",", "，" }) do
        local _r, k = s:gsub(c, "")
        n = n + k
    end
    return n
end

local HEADINGS = set({ "h1", "h2", "h3", "h4", "h5", "h6" })
local TEXTISH = set({ "span", "li", "td", "blockquote", "dl", "div", "img", "ol", "p", "pre", "table", "ul" })
local EMBEDS = set({ "object", "embed", "iframe" })

function Reader:cleanConditionally(e, tag)
    if not self:flagIsActive(FLAG_CLEAN_CONDITIONALLY) then return end
    local isDataTable = function(t) return t.datatable end
    removeNodes(byTag(e, tag), function(node)
        local isList = tag == "ul" or tag == "ol"
        if not isList then
            local listLength = 0
            for _idx, l in ipairs(byTags(node, set({ "ul", "ol" }))) do listLength = listLength + len(getInnerText(l)) end
            local total = len(getInnerText(node))
            isList = total > 0 and listLength / total > 0.9
        end
        if tag == "table" and node.datatable then return false end
        if hasAncestorTag(node, "table", -1, isDataTable) then return false end
        if hasAncestorTag(node, "code") then return false end
        for _idx, t in ipairs(byTag(node, "table")) do
            if t.datatable then return false end
        end
        local weight = self:getClassWeight(node)
        if weight < 0 then return true end
        if charCount(node) >= 10 then return false end
        local p = #byTag(node, "p")
        local img = #byTag(node, "img")
        local li = #byTag(node, "li") - 100
        local input = #byTag(node, "input")
        local headingDensity = getTextDensity(node, HEADINGS)
        local embedCount = 0
        for _idx, em in ipairs(byTags(node, EMBEDS)) do
            if anyVideoAttr(em) then return false end
            embedCount = embedCount + 1
        end
        local innerText = getInnerText(node)
        local lower = innerText:lower()
        if AD_WORDS[lower] or LOADING_WORDS[lower] or LOADING_WORDS[(lower:gsub("…$", ""):gsub("%.%.%.$", ""))] then
            return true
        end
        local contentLength = len(innerText)
        local linkDensity = getLinkDensity(node)
        local textDensity = getTextDensity(node, TEXTISH)
        local isFigureChild = hasAncestorTag(node, "figure")
        local remove_it = (not isFigureChild and img > 1 and p / img < 0.5)
            or (not isList and li > p)
            or (input > math.floor(p / 3))
            or (not isList and not isFigureChild and headingDensity < 0.9 and contentLength < 25
                and (img == 0 or img > 2) and linkDensity > 0)
            or (not isList and weight < 25 and linkDensity > 0.2)
            or (weight >= 25 and linkDensity > 0.5)
            or ((embedCount == 1 and contentLength < 75) or embedCount > 1)
            or (img == 0 and textDensity == 0)
        if isList and remove_it then
            for _idx, c in ipairs(elementChildren(node)) do
                if #elementChildren(c) > 1 then return true end
            end
            if img == #byTag(node, "li") then return false end
        end
        return remove_it and true or false
    end)
end

local function cleanMatchedNodes(e, filter)
    local stop = getNextNode(e, true)
    local n = getNextNode(e)
    while n and n ~= stop do
        if filter(n, className(n) .. " " .. idOf(n)) then n = removeAndGetNext(n) else n = getNextNode(n) end
    end
end

local function cleanStyles(e)
    if e.tag == "svg" then return end
    for _idx, a in ipairs(PRESENTATIONAL_ATTRIBUTES) do e.attrs[a] = nil end
    if DEPRECATED_SIZE_ATTRIBUTE_ELEMS[e.tag] then e.attrs.width, e.attrs.height = nil, nil end
    for _idx, c in ipairs(elementChildren(e)) do cleanStyles(c) end
end

function Reader:prepArticle(article)
    cleanStyles(article)
    markDataTables(article)
    fixLazyImages(article)
    self:cleanConditionally(article, "form")
    self:cleanConditionally(article, "fieldset")
    for _idx, t in ipairs({ "object", "embed", "footer", "link", "aside" }) do self:clean(article, t) end
    for _idx, top in ipairs(elementChildren(article)) do
        cleanMatchedNodes(top, function(node, match)
            return shareMatch(match) and len(textContent(node)) < CHAR_THRESHOLD
        end)
    end
    for _idx, t in ipairs({ "iframe", "input", "textarea", "select", "button" }) do self:clean(article, t) end
    removeNodes(byTags(article, set({ "h1", "h2" })), function(n) return self:getClassWeight(n) < 0 end)
    self:cleanConditionally(article, "table")
    self:cleanConditionally(article, "ul")
    self:cleanConditionally(article, "div")
    for _idx, h in ipairs(byTag(article, "h1")) do setNodeTag(h, "h2") end
    removeNodes(byTag(article, "p"), function(p)
        return #byTags(p, set({ "img", "embed", "object", "iframe" })) == 0 and getInnerText(p, false) == ""
    end)
    for _idx, br in ipairs(byTag(article, "br")) do
        local sib = nextSibling(br)
        local n = sib and nextNode(sib)
        if n and n.tag == "p" then remove(br) end
    end
    for _idx, t in ipairs(byTag(article, "table")) do
        if t.parent then
            local tbody = hasSingleTagInsideElement(t, "tbody") and firstElementChild(t) or t
            if hasSingleTagInsideElement(tbody, "tr") then
                local row = firstElementChild(tbody)
                if hasSingleTagInsideElement(row, "td") then
                    local cell = firstElementChild(row)
                    local phrasing = true
                    for _i, c in ipairs(cell.children) do
                        if not isPhrasingContent(c) then phrasing = false break end
                    end
                    setNodeTag(cell, phrasing and "p" or "div")
                    replaceChild(cell, t)
                end
            end
        end
    end
end

--- 原版 _grabArticle；doc 每次尝试新解析。返回 article 节点或 nil（正文太短，需放宽重试）。
function Reader:grabArticle(doc)
    local body = byTag(doc, "body")[1]
    local strip = self:flagIsActive(FLAG_STRIP_UNLIKELYS)
    local elementsToScore = {}
    local shouldRemoveTitleHeader = true
    local node = firstElementChild(doc)
    while node do
        if node.tag == "html" then self.lang = attr(node, "lang") end
        local matchString = className(node) .. " " .. idOf(node)
        if not isProbablyVisible(node) then
            node = removeAndGetNext(node)
        elseif attr(node, "aria-modal") == "true" and attr(node, "role") == "dialog" then
            node = removeAndGetNext(node)
        elseif not self.byline and not self.meta.byline and isValidByline(node, matchString) then
            local stop, n, nameNode = getNextNode(node, true), getNextNode(node), nil
            while n and n ~= stop do
                local ip = attr(n, "itemprop")
                if ip and ip:find("name", 1, true) then nameNode = n break end
                n = getNextNode(n)
            end
            self.byline = trim(spacedText(nameNode or node))
            node = removeAndGetNext(node)
        elseif shouldRemoveTitleHeader and self:headerDuplicatesTitle(node) then
            shouldRemoveTitleHeader = false
            node = removeAndGetNext(node)
        elseif strip and any(matchString, UNLIKELY) and not any(matchString, OK_MAYBE)
            and not hasAncestorTag(node, "table") and not hasAncestorTag(node, "code")
            and node.tag ~= "body" and node.tag ~= "a" then
            node = removeAndGetNext(node)
        elseif strip and UNLIKELY_ROLES[attr(node, "role") or ""] then
            node = removeAndGetNext(node)
        elseif (node.tag == "div" or node.tag == "section" or node.tag == "header" or HEADINGS[node.tag])
            and isElementWithoutContent(node) then
            node = removeAndGetNext(node)
        else
            if TAGS_TO_SCORE[node.tag] then elementsToScore[#elementsToScore + 1] = node end
            if node.tag == "div" then
                -- 行内内容包成 p
                local i = 1
                while i <= #node.children do
                    local child = node.children[i]
                    if isPhrasingContent(child) then
                        local run = {}
                        while node.children[i] and isPhrasingContent(node.children[i]) do
                            run[#run + 1] = table.remove(node.children, i)
                        end
                        while run[1] and isWhitespace(run[1]) do table.remove(run, 1) end
                        while run[#run] and isWhitespace(run[#run]) do table.remove(run) end
                        if #run > 0 then
                            local p = el("p")
                            for _idx, c in ipairs(run) do
                                c.parent = p
                                p.children[#p.children + 1] = c
                            end
                            p.parent = node
                            table.insert(node.children, i, p)
                            i = i + 1
                        end
                        version = version + 1
                    else
                        i = i + 1
                    end
                end
                if hasSingleTagInsideElement(node, "p") and getLinkDensity(node) < 0.25 then
                    local newNode = elementChildren(node)[1]
                    replaceChild(newNode, node)
                    node = newNode
                    elementsToScore[#elementsToScore + 1] = node
                elseif not hasChildBlockElement(node) then
                    setNodeTag(node, "p")
                    elementsToScore[#elementsToScore + 1] = node
                end
            end
            node = getNextNode(node)
        end
    end

    local candidates = {}
    for _idx, e in ipairs(elementsToScore) do
        if e.parent and e.parent.tag ~= "#document" then
            local innerText = getInnerText(e)
            local n = len(innerText)
            if n >= 25 then
                local ancestors = getNodeAncestors(e, 5)
                if #ancestors > 0 then
                    local commas = 0
                    for _i, c in ipairs(COMMAS) do
                        local _r, k = innerText:gsub(c, "")
                        commas = commas + k
                    end
                    local score = 1 + (commas + 1) + math.min(math.floor(n / 100), 3)
                    for level, a in ipairs(ancestors) do
                        if a.tag and a.parent and a.parent.tag ~= "#document" then
                            if a.score == nil then
                                self:initializeNode(a)
                                candidates[#candidates + 1] = a
                            end
                            local lv = level - 1
                            a.score = a.score + score / (lv == 0 and 1 or lv == 1 and 2 or lv * 3)
                        end
                    end
                end
            end
        end
    end

    local top = {}
    for _idx, c in ipairs(candidates) do
        c.score = c.score * (1 - getLinkDensity(c))
        for t = 1, N_TOP_CANDIDATES do
            if not top[t] or c.score > top[t].score then
                table.insert(top, t, c)
                if #top > N_TOP_CANDIDATES then table.remove(top) end
                break
            end
        end
    end

    local topCandidate = top[1]
    local created = false
    local parentOfTop
    if not topCandidate or topCandidate.tag == "body" then
        topCandidate = el("div")
        created = true
        while body.children[1] do append(topCandidate, body.children[1]) end
        append(body, topCandidate)
        self:initializeNode(topCandidate)
    else
        local alternatives = {}
        for i = 2, #top do
            if top[i].score / topCandidate.score >= 0.75 then
                alternatives[#alternatives + 1] = set(getNodeAncestors(top[i]))
            end
        end
        if #alternatives >= 3 then
            parentOfTop = topCandidate.parent
            while parentOfTop.tag ~= "body" do
                local lists = 0
                for _i, anc in ipairs(alternatives) do
                    if anc[parentOfTop] then lists = lists + 1 end
                    if lists >= 3 then break end
                end
                if lists >= 3 then
                    topCandidate = parentOfTop
                    break
                end
                parentOfTop = parentOfTop.parent
            end
        end
        if not topCandidate.score then self:initializeNode(topCandidate) end
        parentOfTop = topCandidate.parent
        local lastScore = topCandidate.score
        local threshold = lastScore / 3
        while parentOfTop.tag ~= "body" do
            if parentOfTop.score then
                if parentOfTop.score < threshold then break end
                if parentOfTop.score > lastScore then
                    topCandidate = parentOfTop
                    break
                end
                lastScore = parentOfTop.score
            end
            parentOfTop = parentOfTop.parent
        end
        parentOfTop = topCandidate.parent
        while parentOfTop.tag ~= "body" and #elementChildren(parentOfTop) == 1 do
            topCandidate = parentOfTop
            parentOfTop = topCandidate.parent
        end
        if not topCandidate.score then self:initializeNode(topCandidate) end
    end

    local article = el("div")
    local siblingThreshold = math.max(10, topCandidate.score * 0.2)
    parentOfTop = topCandidate.parent
    for _idx, sib in ipairs(elementChildren(parentOfTop)) do
        local keep = sib == topCandidate
        if not keep then
            local bonus = (className(sib) == className(topCandidate) and className(topCandidate) ~= "")
                and topCandidate.score * 0.2 or 0
            if sib.score and sib.score + bonus >= siblingThreshold then
                keep = true
            elseif sib.tag == "p" then
                local density, content = getLinkDensity(sib), getInnerText(sib)
                local n = len(content)
                keep = (n > 80 and density < 0.25)
                    or (n < 80 and n > 0 and density == 0 and (content:find("%.%s") or content:find("%.$")
                        or content:find("。", 1, true)) ~= nil)
            end
        end
        if keep then
            if not ALTER_TO_DIV_EXCEPTIONS[sib.tag] then setNodeTag(sib, "div") end
            append(article, sib)
        end
    end
    self:prepArticle(article)
    if created then
        topCandidate.attrs.id, topCandidate.attrs.class = "readability-page-1", "page"
    else
        local div = el("div", { id = "readability-page-1", class = "page" })
        while article.children[1] do append(div, article.children[1]) end
        append(article, div)
    end
    local dirChain = getNodeAncestors(parentOfTop)
    table.insert(dirChain, 1, topCandidate)
    table.insert(dirChain, 1, parentOfTop)
    for _idx, a in ipairs(dirChain) do
        if a.tag and attr(a, "dir") then self.dir = attr(a, "dir") break end
    end
    return article, len(getInnerText(article))
end

local function fixRelativeUris(article, base)
    local function abs(uri)
        if uri:sub(1, 1) == "#" then return uri end
        return Text.absoluteUrl(base, uri) or uri
    end
    for _idx, a in ipairs(byTag(article, "a")) do
        local href = attr(a, "href")
        if href then
            if href:find("^javascript:") then
                if #a.children == 1 and a.children[1].text then
                    replaceChild({ text = textContent(a) }, a)
                else
                    setNodeTag(a, "span")
                    a.attrs = {}
                end
            else
                a.attrs.href = abs(href)
            end
        end
    end
    for _idx, m in ipairs(byTags(article, set({ "img", "picture", "figure", "video", "audio", "source" }))) do
        if m.attrs.src then m.attrs.src = abs(m.attrs.src) end
        if m.attrs.poster then m.attrs.poster = abs(m.attrs.poster) end
        if m.attrs.srcset then
            local parts = {}
            for item in m.attrs.srcset:gmatch("[^,]+") do
                local url, rest = item:match("^%s*(%S+)(.-)%s*$")
                if url then parts[#parts + 1] = abs(url) .. rest end
            end
            m.attrs.srcset = table.concat(parts, ", ")
        end
    end
end

local function simplifyNestedElements(article)
    local node = article
    while node do
        local removable = node.parent and (node.tag == "div" or node.tag == "section")
            and not idOf(node):find("^readability")
        if removable and isElementWithoutContent(node) then
            node = removeAndGetNext(node)
        elseif removable and (hasSingleTagInsideElement(node, "div") or hasSingleTagInsideElement(node, "section")) then
            local child = elementChildren(node)[1]
            for k, v in pairs(node.attrs) do child.attrs[k] = v end
            replaceChild(child, node)
            node = child
        else
            node = getNextNode(node)
        end
    end
end

local function cleanClasses(node)
    node.attrs.class = (" " .. className(node) .. " "):find(" page ", 1, true) and "page" or nil
    for _idx, c in ipairs(elementChildren(node)) do cleanClasses(c) end
end

--- 原版 parse()。
---@param html string 网页源码（调用方已按大小上限截断）
---@param url string|nil 页面地址：补全相对链接（页面里有 <base href> 时以它为准）
---@return table|nil { title, byline, excerpt, siteName, publishedTime, lang, dir, content, textContent, length }
function R.parse_article(html, url)
    local function prepared()
        local doc = R.parse(html)
        if not doc then return nil end
        unwrapNoscriptImages(doc)
        return doc
    end
    local doc = prepared()
    if not doc then return nil end
    local jsonld = getJSONLD(doc, function() return getArticleTitle(doc) end)
    local base = url
    local base_el = byTag(doc, "base")[1]
    if base_el and attr(base_el, "href") then base = Text.absoluteUrl(url or "", attr(base_el, "href")) or base end
    local self = setmetatable({ flags = FLAG_STRIP_UNLIKELYS + FLAG_WEIGHT_CLASSES + FLAG_CLEAN_CONDITIONALLY },
        Reader)
    local function finish(d)
        for _idx, s in ipairs(byTags(d, set({ "script", "noscript" }))) do remove(s) end
        prepDocument(d)
        return d
    end
    finish(doc)
    self.meta = getArticleMetadata(doc, jsonld)
    self.title = self.meta.title
    local attempts = {}
    local article
    while true do
        local textLength
        article, textLength = self:grabArticle(doc)
        if textLength >= CHAR_THRESHOLD then break end
        attempts[#attempts + 1] = { article = article, length = textLength }
        if self:flagIsActive(FLAG_STRIP_UNLIKELYS) then
            self:removeFlag(FLAG_STRIP_UNLIKELYS)
        elseif self:flagIsActive(FLAG_WEIGHT_CLASSES) then
            self:removeFlag(FLAG_WEIGHT_CLASSES)
        elseif self:flagIsActive(FLAG_CLEAN_CONDITIONALLY) then
            self:removeFlag(FLAG_CLEAN_CONDITIONALLY)
        else
            table.sort(attempts, function(a, b) return a.length > b.length end)
            if attempts[1].length == 0 then return nil end
            article = attempts[1].article
            break
        end
        -- 失败的尝试只留文章节点（几 KB），整棵树丢掉重新解析。
        doc = finish(prepared())
        self.byline = nil
    end
    if base then fixRelativeUris(article, base) end
    simplifyNestedElements(article)
    cleanClasses(article)
    local excerpt = self.meta.excerpt
    if not excerpt then
        local p = byTag(article, "p")[1]
        excerpt = p and trim(textContent(p)) or nil
    end
    local text = textContent(article)
    return {
        title = self.title, byline = self.meta.byline or self.byline, dir = self.dir, lang = self.lang,
        content = innerHTML(article), textContent = text, length = len(text), excerpt = excerpt,
        siteName = self.meta.siteName, publishedTime = self.meta.publishedTime,
    }
end

--- 网页 HTML → 正文片段与元数据；正文不足 MIN_CHARS 返回 nil（调用方退回整页抽取）。
---@param html string
---@param url string|nil
---@return string|nil content
---@return table|nil meta parse_article 的结果
function R.extract(html, url)
    local ok, result = pcall(R.parse_article, html, url)
    if not ok then
        require("utils.log").warn("readability failed", result)
        return nil
    end
    if not result or len(trim(result.textContent)) < MIN_CHARS then return nil end
    return Text.trim(result.content), result
end

return R
