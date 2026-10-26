--[[--
查词面板：所有划词 / 查词入口共用的一个标准居中弹窗（主题 Modal，带遮罩，点遮罩关闭）。

底部四个图标 Tab：词典、翻译、AI、百科，点 Tab 原地切换正文。词典 Tab 卡头可选词典（列出有结果的词典，记住选择）；
AI、百科首次切到才请求（结果缓存，可取消，AI 可追问）。正文固定高度，超长时上下滑滚动；各 Tab 卡片几何一致，
切换时重画整个窗口栈，遮罩下不留旧卡残影。记住上次用的 Tab；同一时刻只留一个面板。
入口：长按查词、划词「查词」「翻译」「AI 解释」。

  +-------------------------------+
  |            彘             [×] |
  |            zhì                |
  |-------------------------------|
  | [现代汉语 ▼]                  |   词典 Tab（翻译 Tab 为语言按钮）
  | 正文……（HTML 词典按 HTML 排版）|
  | [复制] [存为笔记] [追问]      |
  |-------------------------------|
  |  词典   翻译    AI    百科    |   图标 Tab
  +-------------------------------+

@module koplugin.book.features.rare.lookup
--]]

require("l10n").apply()

local Device = require("device")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Theme = require("ui.themes")
local Box = require("ui.themes.widgets.box")
local Modal = require("ui.themes.widgets.modal")
local Icon = require("ui.themes.widgets.icon")
local Html = require("ui.themes.widgets.html")
local Pager = require("ui.themes.widgets.pager")
local Tabbar = require("ui.themes.widgets.tabbar")
local Text = require("ui.themes.widgets.text")
local TitleBar = require("ui.themes.widgets.titlebar")
local GestureRange = require("ui/gesturerange")
local HorizontalSpan = require("ui/widget/horizontalspan")
local _ = require("gettext")
local T = require("ffi/util").template

local Screen = Device.screen

--- 选中文字超过这么多字节不查词典（长句只翻译 / AI）。
local DICT_MAX = 64
--- AI 释义缓存条数上限（进程内）。
local CACHE_MAX = 50
local ai_cache, ai_cache_n = {}, 0

---@class BookLookupPanel : BookThemeModal
---@field translator table|nil 翻译器替身或原生翻译器
---@field source string|nil 初始来源
---@field source_lang string|nil 源语言
---@field target_lang string|nil 目标语言
---@field from_highlight boolean|nil 是否由划词打开
---@field full_page boolean|nil 是否使用较高正文区域
---@field note_index integer|nil 要编辑的笔记序号
---@field ui table|nil ReaderUI
---@field text string 查的词 / 选中文字
---@field reading string|nil 读音
---@field context { text?: string, sentence: string, paragraph: string }|nil
---@field dicts { name: string, text: string, html: string|nil, css: string|nil, dir: string|nil, empty?: boolean }[]
---@field active string 当前来源 id：dict:<名> / translate / ai
---@field content table<string, string> 各来源已就绪的正文
---@field status table<string, string> 各来源未就绪时的状态
---@field jobs table<string, { cancel: fun() }>
local Lookup = Modal:extend{
    name = "book_lookup_panel",
}

--- 词典释义转纯文字（复制 / 存笔记 / 非 HTML 回退）：列表项加「• 」，块级标签换行、去标签、解码实体。
---@param s string
---@return string
function Lookup.plainDef(s)
    return require("utils.text").stripHtml((s:gsub("<[Ll][Ii]([%s>])", "<li%1• ")))
end
local plainDef = Lookup.plainDef

--- 词典链接（bword://词 或裸词）→ 要查的词；外链 nil。
---@param uri string|nil
---@return string|nil
function Lookup.linkWord(uri)
    if not uri or uri == "" then return end
    local word = uri:match("^bword://(.*)$") or (not uri:find("://") and uri) or nil
    if word and word ~= "" then return word end
end

--- 释义像 HTML（含 p/b/i/ol/ul/li/br/div/span/hr/font/a… 标签）。
---@param s string|nil
---@return boolean
function Lookup.looksHtml(s)
    if not s then return false end
    for tag in s:gmatch("<%s*/?%s*(%a+)[^<>]*>") do
        local t = tag:lower()
        if t == "p" or t == "b" or t == "i" or t == "u" or t == "ol" or t == "ul" or t == "li" or t == "br"
            or t == "div" or t == "span" or t == "hr" or t == "font" or t == "a" or t == "em" or t == "strong"
            or t == "sup" or t == "sub" or t == "dl" or t == "dt" or t == "dd" or t == "table" or t == "img" then
            return true
        end
    end
    return false
end

local ifo_cache = {}
--- 词典目录下各 .ifo：bookname → { html = sametypesequence 含 h/x/g, css = 同名 .css 内容 }（按目录缓存）。
---@param data_dir string|nil
---@return table<string, { html: boolean, css: string|nil }>
function Lookup.ifoInfo(data_dir)
    if not data_dir then return {} end
    if ifo_cache[data_dir] then return ifo_cache[data_dir] end
    local lfs = require("libs/libkoreader-lfs")
    local map = {}
    local function walk(dir, depth)
        local ok, iter, obj = pcall(lfs.dir, dir)
        if not ok then return end
        for name in iter, obj do
            if name ~= "." and name ~= ".." then
                local path = dir .. "/" .. name
                local mode = lfs.attributes(path, "mode")
                if mode == "directory" and depth < 4 then
                    walk(path, depth + 1)
                elseif mode == "file" and name:lower():match("%.ifo$") then
                    local f = io.open(path, "r")
                    local c = f and f:read("*a") or ""
                    if f then f:close() end
                    local book = c:match("\nbookname=(.-)\r?\n")
                    if book then
                        local seq = c:match("\nsametypesequence=(%w+)") or ""
                        local cf = io.open((path:gsub("%.[Ii][Ff][Oo]$", ".css")), "r")
                        map[book] = { html = seq:find("[hxg]") ~= nil, css = cf and cf:read("*a") or nil }
                        if cf then cf:close() end
                    end
                end
            end
        end
    end
    walk(data_dir, 0)
    ifo_cache[data_dir] = map
    return map
end

--- sdcv 结果按词典分组（保持词典顺序），去掉「无结果」「未安装词典」占位。
--- 词条名与查的词相同时不再重复一行（标题栏已显示）。
---@param results table[] ReaderDictionary:startSdcv 的返回
---@param word string|nil 查的词
--- HTML 词典另留 html（按 HTML 排版）与词典 css / 资源目录；text 恒为纯文字（复制、存笔记）。
---@return { name: string, text: string, html: string|nil, css: string|nil, dir: string|nil }[]
---@param ifos table|nil Lookup.ifoInfo 的结果
function Lookup.groupResults(results, word, ifos)
    local out, by = {}, {}
    for _idx, r in ipairs(results or {}) do
        if not r.no_result and r.dict and r.dict ~= "" then
            local raw = r.definition or ""
            -- startSdcv 不经 KOReader 的 tidyMarkup，is_html / css 要自己补：ifo 类型或释义像 HTML。
            local ifo = ifos and ifos[r.dict]
            if not r.is_html and ((ifo and ifo.html) or Lookup.looksHtml(raw)) then
                r = setmetatable({ is_html = true, css = r.css or (ifo and ifo.css) }, { __index = r })
            end
            local head = r.word and r.word ~= "" and r.word ~= word and r.word or nil
            local entry = by[r.dict]
            if not entry then
                entry = { name = r.dict, parts = {}, html = r.is_html and {} or nil, css = r.css, dir = r.dictionary_resource_directory }
                by[r.dict] = entry
                out[#out + 1] = entry
            end
            entry.parts[#entry.parts + 1] = (head and (head .. "\n") or "") .. (r.is_html and plainDef(raw) or raw)
            if entry.html then
                entry.html[#entry.html + 1] = (head and ("<p><b>" .. require("utils.text").xmlEscape(head) .. "</b></p>") or "") .. raw
            end
        end
    end
    for i, e in ipairs(out) do
        out[i] = { name = e.name, text = table.concat(e.parts, "\n\n"), css = e.css, dir = e.dir,
            html = e.html and table.concat(e.html, "<hr/>") or nil }
    end
    return out
end

--- 已启用词库里这个词的读音；没有时 nil。
---@param word string
---@return string|nil
function Lookup.readingOf(word)
    for _idx, lex in ipairs(require("features.rare.catalog").active()) do
        local e = lex.entries[word] or lex.entries[word:lower()]
        if e then return e[1] end
    end
end

--- 在 ui 的词典里查（同步，sdcv 自带进度提示）；文字太长或没词典时空表。
--- 「加载所有词典」开着时查全部已安装词典（含已停用），无结果的也占一项（empty = true，排在有结果的后面）。
---@param ui table|nil
---@param word string
---@return { name: string, text: string, empty: boolean|nil }[]
function Lookup.queryDicts(ui, word)
    local dict = ui and ui.dictionary
    if not (dict and dict.startSdcv and dict.enabled_dict_names) or #word > DICT_MAX or word:find("\n") then
        return {}
    end
    local names = dict.enabled_dict_names
    local load_all = require("utils.settings").get("features.dictionary").dictionary_load_all
    if load_all then
        ifo_cache[dict.data_dir] = nil
        names = {}
        for name in pairs(Lookup.ifoInfo(dict.data_dir)) do names[#names + 1] = name end
        table.sort(names)
    end
    if #names == 0 then return {} end
    local out = Lookup.groupResults(dict:startSdcv(word, names, false), word, Lookup.ifoInfo(dict.data_dir))
    if load_all then
        local hit = {}
        for _idx, d in ipairs(out) do hit[d.name] = true end
        for _idx, name in ipairs(names) do
            if not hit[name] then out[#out + 1] = { name = name, text = _("该词典没有查到这个词。"), empty = true } end
        end
    end
    return out
end

--- 底部 Tab（固定四个）。
---@return table[]
function Lookup:tabs()
    return {
        { id = "dict", text = _("词典"), icon = "dictionary" },
        { id = "translate", text = _("翻译"), icon = "translate" },
        { id = "ai", text = _("AI"), icon = "auto_awesome" },
        { id = "baike", text = _("百科"), icon = "travel_explore" },
    }
end

--- 能否查词典 / 百科（长句、多行不查）。
---@return boolean
function Lookup:isWord()
    return #self.text <= DICT_MAX and not self.text:find("\n")
end

--- 滑动翻正文页；全部吞掉，不漏到阅读页翻页。
---@param _arg any
---@param ges table
---@return boolean
function Lookup:onSwipe(_arg, ges)
    local d = ges.direction
    if d == "north" or d == "west" then self:turn(1) elseif d == "south" or d == "east" then self:turn(-1) end
    return true
end

--- 正文翻页。
---@param delta integer
function Lookup:turn(delta)
    local page = (self.body_page or 1) + delta
    if page < 1 or page > (self.body_pages or 1) then return end
    self.body_page = page
    self:refreshView()
end

--- 翻页键 / 音量键：翻正文页；词典 Tab 翻到头 / 尾自动换到下一 / 上一本词典（上一本落在末页）。
---@param delta integer 1 下一页，-1 上一页
---@return boolean
function Lookup:step(delta)
    local page = (self.body_page or 1) + delta
    if page >= 1 and page <= (self.body_pages or 1) then
        self:turn(delta)
        return true
    end
    if self.active == "dict" and self:isWord() then
        local cur = self:currentDict()
        for idx, d in ipairs(self.dicts) do
            if d == cur then
                -- 翻页键跳过没结果的词典。
                local j = idx + delta
                while self.dicts[j] and self.dicts[j].empty do j = j + delta end
                local nxt = self.dicts[j]
                if nxt then
                    self.dict_name = nxt.name
                    self.body_page = delta > 0 and 1 or math.huge
                    self:refreshView()
                end
                break
            end
        end
    end
    return true
end

function Lookup:onReadNextResult() return self:step(1) end
function Lookup:onReadPrevResult() return self:step(-1) end

--- 当前词典 Tab 显示的词典。
---@return { name: string, text: string, html?: string, css?: string, dir?: string, empty?: boolean }|nil
function Lookup:currentDict()
    for _idx, d in ipairs(self.dicts) do
        if d.name == self.dict_name then return d end
    end
    return self.dicts[1]
end

--- 初始 Tab：指定的 → 上次用的 → 有词典给词典，否则 AI。
---@param wanted string|nil
---@return string
function Lookup:initialSource(wanted)
    local ids = { dict = true, translate = true, ai = true, baike = true }
    local last = require("utils.settings").get("features.rare").rare_lookup_source
    if wanted and ids[wanted] then return wanted end
    if last and ids[last] then return last end
    return self.dicts[1] and not self.dicts[1].empty and "dict" or "ai"
end

--- 切 Tab：记住它，没内容就按需请求，重画整个窗口栈。
---@param id string
function Lookup:select(id)
    self.active = id
    self.body_page = 1
    local MoonSettings = require("utils.settings")
    local s = MoonSettings.get("features.rare")
    if s.rare_lookup_source ~= id then
        s.rare_lookup_source = id
        MoonSettings.save("features.rare", s)
    end
    if not self.content[id] and not self.jobs[id] then
        if id == "translate" then self:requestTranslate()
        elseif id == "baike" and self:isWord() then self:requestBaike()
        elseif id == "ai" then self:requestAi() end
    end
    self:refreshView()
end

--- 词典 Tab 换词典：弹出有结果的词典列表，记住选择。
---@param anchor table|nil 按钮矩形
function Lookup:pickDict(anchor)
    local items = {}
    local current = self:currentDict().name
    for _idx, d in ipairs(self.dicts) do
        items[#items + 1] = { text = d.name .. (d.empty and _("（无结果）") or ""), checked = d.name == current, callback = function()
            self.dict_name = d.name
            self.body_page = 1
            local MoonSettings = require("utils.settings")
            local s = MoonSettings.get("features.rare")
            s.rare_lookup_dict = d.name
            MoonSettings.save("features.rare", s)
            if not self._gone then self:refreshView() end
        end }
    end
    require("ui.themes.widgets.list"):new{ title = _("选择词典"), centered = true, anchor = anchor, items = items }:show()
end

--- 某来源结果回来：存下，正看着就刷新。
---@param id string
---@param text string|nil
---@param status string|nil
function Lookup:deliver(id, text, status)
    self.jobs[id] = nil
    self.content[id], self.status[id] = text, status
    if self.active == id and not self._gone then self:refreshView() end
end

function Lookup:requestTranslate()
    local translator = self.translator or require("ui/translator")
    self.source_lang = self.source_lang or translator:getSourceLanguage() --[[@as string|nil]]
    self.target_lang = self.target_lang or translator:getTargetLanguage() --[[@as string|nil]]
    if self.jobs.translate then self.jobs.translate.cancel() end
    self.content.translate, self.status.translate = nil, _("正在翻译…")
    self.jobs.translate = require("features.translate.edge").translateAsync(self.text, self.target_lang, self.source_lang,
        function(translated, detected, err)
            self.detected_lang = detected or self.detected_lang
            self:deliver("translate", translated, not translated and T(_("翻译失败：%1"), tostring(err)) or nil)
        end)
end

--- 百科：百度百科词条摘要；未收录、断网都写在卡里。
function Lookup:requestBaike()
    if not require("ui/network/manager"):isConnected() then
        self.status.baike = _("网络不可用，请先连接 Wi-Fi")
        return
    end
    self.content.baike, self.status.baike = nil, _("正在查询百科…")
    self.jobs.baike = require("features.baike.client").lookupAsync(self.text, function(entry, err)
        if not entry then
            self:deliver("baike", nil, err == "not found" and T(_("百科未收录「%1」"), self.text)
                or T(_("百科查询失败：%1"), tostring(err)))
            return
        end
        local title = entry.title ~= self.text and (entry.title .. "\n") or ""
        self:deliver("baike", title .. entry.definition)
    end)
end

---@return string
function Lookup:aiKey()
    return self.text .. "\0" .. (self.context and self.context.sentence or "")
end

---@param chain table[]|nil 追问时带上的整条对话
function Lookup:requestAi(chain)
    local key = self:aiKey()
    if not chain and ai_cache[key] then
        self.content.ai = ai_cache[key]
        return
    end
    if not require("ai").isConfigured() then
        self.status.ai = _("请先在月读设置中配置 AI 服务")
        return
    end
    if not require("ui/network/manager"):isConnected() then
        self.status.ai = _("网络不可用，请先连接 Wi-Fi")
        return
    end
    local Explain = require("features.ai.explain")
    local selection = self.context or { text = self.text, sentence = self.text, paragraph = "" }
    ---@cast selection { text: string, sentence: string, paragraph: string }
    selection.text = self.text
    self.ai_messages = chain or Explain.messages(self.ui, selection)
    self.content.ai, self.status.ai = nil, _("AI 解释中…")
    self.jobs.ai = require("ai").chat(self.ai_messages,
        { max_tokens = 1000, timeout = require("http.timeout").ai(0.5) }, function(content, err)
            local answer = content and Explain.plain(content) or ""
            if answer == "" then
                self:deliver("ai", nil, T(_("AI 解释失败：%1"), tostring(err or _("未知错误"))))
                return
            end
            if not chain then
                if ai_cache_n >= CACHE_MAX then ai_cache, ai_cache_n = {}, 0 end
                ai_cache[key], ai_cache_n = answer, ai_cache_n + 1
            end
            self:deliver("ai", answer)
        end)
end

--- 当前 Tab 的正文（未就绪给状态）。
---@return string
function Lookup:body()
    local id = self.active
    if id == "dict" then
        if not self:isWord() then return _("选中文字较长，不查词典，可看翻译或 AI。") end
        local d = self:currentDict()
        if d then return d.text end
        return _("未安装词典或词典无结果，可在「词典」设置中下载。")
    end
    if id == "baike" and not self:isWord() then return _("选中文字较长，不查百科。") end
    return self.content[id] or self.status[id] or ""
end

--- 重画整个窗口栈：遮罩是叠在旧像素上的网点，只重画本窗会把上一张卡留在遮罩下。
function Lookup:refreshView()
    self:rebuild()
    UIManager:setDirty("all", "ui")
end

--- 复制 / 存为笔记（划词进来的才有）。
---@return table[]
function Lookup:actions()
    local row = {}
    if Device:hasClipboard() then
        row[#row + 1] = { text = _("复制"), callback = function()
            local text = self.content[self.active] or (self.active == "dict" and self:currentDict() and self:body())
            if text then Device.input.setClipboardText(text) end
        end }
    end
    if self.from_highlight then
        row[#row + 1] = { text = _("存为笔记"), callback = function()
            local text = self.content[self.active] or (self.active == "dict" and self:currentDict() and self:body())
            local ui = self.ui
            if not (text and ui and ui.highlight) then return end
            self.handed_off = true
            self:close()
            if self.note_index then ui.highlight:editNote(self.note_index, false, text)
            else ui.highlight:addNote(text) end
        end }
    end
    -- 原生生词本（vocabbuilder 插件）装着才有；手动添加不看它的「自动添加」开关，已有的词由它弹详情。
    if self.ui and self.ui.vocabbuilder and self:isWord() then
        row[#row + 1] = { text = _("加入生词本"), callback = function()
            local props = self.ui.doc_props
            local book = props and props.display_title or _("查词")
            self.ui:handleEvent(require("ui/event"):new("WordLookedUp", self.text, book, true))
        end }
    end
    if self.active == "ai" and self.content.ai then
        row[#row + 1] = { text = _("追问"), callback = function() self:followUp() end }
    end
    return row
end

function Lookup:init()
    Modal.init(self)
    self.dicts = self.dicts or {}
    self.content, self.status, self.jobs = {}, {}, {}
    local t = self.theme
    self.frame = Theme.px(t.dialog.border or 0)
    self.content_w = Modal.dialogWidth() - self.frame * 2
    -- 正文区固定高度：左右切卡时卡片不跳动。
    self.body_h = math.floor(Screen:getHeight() * (self.full_page and 0.45 or 0.3))
    if Device:hasKeys() then
        self.key_events.ReadPrevResult = { { Device.input.group.PgBack } }
        self.key_events.ReadNextResult = { { Device.input.group.PgFwd } }
    end
    self.ges_events.Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } }
    local last_dict = require("utils.settings").get("features.rare").rare_lookup_dict
    self.dict_name = self.dict_name or last_dict
    -- 记住的词典这次没查到时，改显示第一本有结果的（不改记忆）。
    local remembered = self:currentDict()
    if remembered and remembered.empty then
        for _idx, d in ipairs(self.dicts) do
            if not d.empty then self.dict_name = d.name; break end
        end
    end
    self.active = self:initialSource(self.source)
    self:rebuild()
end

--- 点词典里的词条链接：在同一个面板位置重开查这个词（外链忽略）。
---@param link { uri: string|nil }
function Lookup:followLink(link)
    local word = Lookup.linkWord(link and link.uri)
    if not word or self._gone then return end
    UIManager:nextTick(function()
        Lookup.open{ ui = self.ui, text = word, source = "dict", context = self.context }
    end)
end

--- 追问：带上整条对话再问 AI（只在 AI 卡）。
function Lookup:followUp()
    require("ui.themes.widgets.input"):new{
        title = _("追问"),
        fields = { { text = "", hint = _("想进一步了解什么？") } },
        ok_text = _("发送"),
        callback = function(question)
            question = require("utils.text").trim(question or "")
            local answer = self.content.ai
            if question == "" or not answer or self._gone then return end
            local chain = { unpack(self.ai_messages or {}) }
            chain[#chain + 1] = { role = "assistant", content = answer }
            chain[#chain + 1] = { role = "user", content = question }
            self:requestAi(chain)
            self:refreshView()
        end,
    }:show()
end

--- 标准居中卡片：标题栏（词 + 读音，关闭）→ 卡头（词典选择 / 翻译语言 / 空位）→ 正文（固定高，可滚动）
--- → 出处 → 操作按钮行 → 图标 Tab。各 Tab 占位一致，卡片高度不随 Tab 变化。
function Lookup:rebuild()
    local t = self.theme
    local w = self.content_w
    local pad = Theme.px(t.space.lg)
    local gap = Theme.px(t.space.sm)
    local row_h = Theme.px(t.control.height)
    local inner = w - pad * 2
    local title = self.text:gsub("\n", " ")
    if #title > 60 then title = require("utils.text").truncateUtf8(title, 60) .. "…" end
    local bar = TitleBar.widget({
        width = w, title = title, subtitle = self.reading, subtitle_face = Lookup.readingFace(),
        right_icon = "close", right_callback = function() self:dismiss() end,
    })
    local group = VerticalGroup:new{ align = "left", HorizontalSpan:new{ width = inner } }
    local header
    if self.active == "translate" then
        local Languages = require("features.translate.languages")
        local translator = self.translator or require("ui/translator")
        local function pick(label, is_source)
            return {
                text = T(_("%1：%2 ▼"), label, Languages.displayName(translator,
                    is_source and self.source_lang or self.target_lang, is_source and self.detected_lang or nil)),
                callback = function()
                    Languages.pick(translator, label, is_source, is_source and self.source_lang or self.target_lang, function(code)
                        if is_source then self.source_lang = code; Languages.applySource(code)
                        else self.target_lang = code; Languages.applyTarget(code) end
                        self:requestTranslate()
                        self:refreshView()
                    end)
                end,
            }
        end
        header = self:buttonRow({ pick(_("源语言"), true), pick(_("目标语言"), false) }, inner)
    elseif self.active == "dict" and self:isWord() and #self.dicts > 1 then
        local row
        row = self:buttonRow({ { text = T(_("%1 ▼"), self:currentDict().name),
            callback = function() self:pickDict(row and row.dimen) end } }, inner)
        header = row
    end
    -- 总高固定：卡头行、操作行缺席时，空出的高度全给正文，不留空白占位。
    local actions = self:actions()
    local action_row = #actions > 0 and self:buttonRow(actions, inner) or nil
    -- 原「来源」行的高度也归正文。
    local body_h = self.body_h + (row_h + gap) * 2 + gap + Theme.px(t.font.caption) * 2
    if header then
        group[#group + 1] = header
        group[#group + 1] = VerticalSpan:new{ width = gap }
        body_h = body_h - header:getSize().h - gap
    end
    if action_row then body_h = body_h - action_row:getSize().h - gap end
    self.body_area_h = body_h
    local pager_h = Theme.px(t.control.height)
    if self.html_box then self.html_box:free(); self.html_box = nil end
    self.text_box = nil
    local body
    local dict = self.active == "dict" and self:isWord() and self:currentDict()
    if dict and dict.html then
        -- HTML 词典：MuPDF 按正文高分页；多页时让出翻页条高度重排一次，页码交给 Pager。
        local function layout(h)
            return Html.widget({ width = inner, height = h, html = dict.html, css = dict.css, dir = dict.dir,
                on_link = function(link) self:followLink(link) end })
        end
        body = layout(body_h)
        if body.page_count > 1 then
            body:free()
            body = layout(body_h - pager_h - gap)
        end
        self.body_pages = math.max(1, body.page_count)
        self.body_page = math.min(math.max(1, self.body_page or 1), self.body_pages)
        body:setPageNumber(self.body_page)
        self.html_box = body
    else
        -- 自动分页：正文只放整行，放不下就在下方加翻页条（流式 AI 每次刷新都重算页数）。
        local opts = { bg = t.dialog.bg, face = Lookup.bodyFace() }
        local probe = Text.box("body", self:body(), inner, opts)
        local lh, total = probe:getLineHeight(), probe:getAllLineCount()
        probe:free()
        local per = math.max(1, math.floor(body_h / lh))
        if total > per then per = math.max(1, math.floor((body_h - pager_h - gap) / lh)) end
        self.body_pages = math.max(1, math.ceil(total / per))
        self.body_page = math.min(math.max(1, self.body_page or 1), self.body_pages)
        opts.height = per * lh
        body = Text.box("body", self:body(), inner, opts)
        for _i = 2, self.body_page do body:scrollDown() end
        self.text_box = body
    end
    group[#group + 1] = body
    local used = body:getSize().h
    if self.body_pages > 1 then
        group[#group + 1] = VerticalSpan:new{ width = gap }
        self.pager = Pager.widget({ width = inner, page = self.body_page, pages = self.body_pages,
            on_prev = function() self:turn(-1) end, on_next = function() self:turn(1) end })
        group[#group + 1] = self.pager
        used = used + gap + self.pager:getSize().h
    else
        self.pager = nil
    end
    group[#group + 1] = VerticalSpan:new{ width = math.max(0, body_h - used) }
    local kids = { align = "center", bar, Box:new{ style = {}, padding = pad, group } }
    if action_row then
        kids[#kids + 1] = action_row
        kids[#kids + 1] = VerticalSpan:new{ width = gap }
    end
    -- Tab 高度按图标 + 间距 + 标签实测，再加分隔线和选中标记，标签不再被截。
    local label = Icon.label{ name = "close", text = "词典", direction = "column", size = t.control.icon,
        face = "cfont", font_size = t.font.caption + 2, gap = Theme.px(t.space.xs) }
    local tab_h = math.max(Tabbar.height(), label:getSize().h + Theme.px(t.space.sm) * 2
        + math.max(1, Theme.px(t.row.divider)) + Theme.px(t.selected.mark))
    self.tabbar = Tabbar.widget({ width = w, height = tab_h, tabs = self:tabs(), active = self.active,
        on_tab = function(id) self:select(id) end })
    kids[#kids + 1] = self.tabbar
    -- 圆角主题底部留出圆角高度，Tab 栏不压边框；内边距 = 边框宽，边框四周完整。
    local radius = Theme.px(t.dialog.radius or 0)
    if radius > 0 then kids[#kids + 1] = VerticalSpan:new{ width = math.floor(radius / 2) } end
    self:setPanel(Box:new{ style = t.dialog, padding = self.frame, VerticalGroup:new(kids) })
end

--- 读音用与注音层相同的 NotoSans（界面字体缺拼音字形会回退成带空隙的「y ú」）。
---@return table face
function Lookup.readingFace()
    return Theme.face("NotoSans-Regular.ttf", Theme.current().font.caption)
end

--- 正文同理用 NotoSans（汉字走 KOReader 字体回退），词典正文里的拼音不再拆成「y ú」。
---@return table face
function Lookup.bodyFace()
    return Theme.face("NotoSans-Regular.ttf", Theme.current().font.body)
end

--- 关窗取消在途请求；划词进来且没交给存笔记的，清掉选区。
function Lookup:onCloseWidget()
    self._gone = true
    if self.html_box then self.html_box:free(); self.html_box = nil end
    for id, job in pairs(self.jobs) do job.cancel(); self.jobs[id] = nil end
    if self.from_highlight and not self.handed_off and self.ui and self.ui.highlight then self.ui.highlight:clear() end
    if Lookup.current == self then Lookup.current = nil end
    Modal.onCloseWidget(self)
end

--- 打开查词面板。
---@param opts { ui: table|nil, text: string, reading: string|nil, context: table|nil, source: string|nil, from_highlight: boolean|nil, index: number|nil, translator: table|nil, source_lang: string|nil, target_lang: string|nil, full_page: boolean|nil }
---@return BookLookupPanel
function Lookup.open(opts)
    local text = opts.text
    -- 同一时刻只留一个面板：长按查词等重复入口不再叠层。
    if Lookup.current then Lookup.current:close() end
    local panel = Lookup:new{
        ui = opts.ui,
        text = text,
        reading = opts.reading or Lookup.readingOf(text),
        context = opts.context,
        dicts = Lookup.queryDicts(opts.ui, text),
        source = opts.source,
        from_highlight = opts.from_highlight,
        note_index = opts.index,
        translator = opts.translator,
        source_lang = opts.source_lang,
        target_lang = opts.target_lang,
        full_page = opts.full_page,
    }
    Lookup.current = panel
    panel:show()
    panel:select(panel.active)
    return panel
end

return Lookup
