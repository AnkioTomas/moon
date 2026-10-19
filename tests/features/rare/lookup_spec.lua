--[[-- features.rare.lookup：多来源查词面板——词典分栏、翻译、AI 释义（按需请求、缓存、取消）、记住来源、无词典提示。 --]]
---@diagnostic disable: undefined-field, missing-fields, inject-field

local Assert = require("support.assert")
local Kit = require("support.widget_stubs")
Kit.install("paper")
require("support.theme_stubs").install()

local settings = { rare_lookup_source = "" }
Kit.sections.rare = settings
local dict_settings = { dictionary_load_all = false }
Kit.sections.dictionary = dict_settings
require("utils.settings").save = function() end
require("device").hasClipboard = function() return true end
require("device").input = { setClipboardText = function() end }
local lex = { entries = { ["彘"] = { "zhì", 7000 } } }
package.preload["features.rare.catalog"] = function() return { active = function() return { lex } end } end
local translate_cb, translate_cancelled
package.preload["features.translate.edge"] = function()
    return { translateAsync = function(_t, _to, _from, cb)
        translate_cb = cb
        return { cancel = function() translate_cancelled = true end }
    end }
end
package.preload["features.translate.languages"] = function()
    return { displayName = function(_, code) return code or "自动" end }
end
local translator = { getSourceLanguage = function() return "auto" end, getTargetLanguage = function() return "zh" end }
package.preload["ui/translator"] = function() return translator end
local configured, connected = true, true
local ai_calls, ai_cb, ai_cancelled, ai_prompt = 0, nil, false, nil
package.preload["ai"] = function()
    return {
        isConfigured = function() return configured end,
        chat = function(messages, _opts, cb)
            ai_calls = ai_calls + 1
            ai_cb = cb
            ai_prompt = messages[2].content
            return { cancel = function() ai_cancelled = true end }
        end,
    }
end
local baike_calls, baike_cb, baike_cancelled = 0, nil, false
package.preload["features.baike.client"] = function()
    return { lookupAsync = function(_w, cb)
        baike_calls, baike_cb = baike_calls + 1, cb
        return { cancel = function() baike_cancelled = true end }
    end }
end
package.preload["ui/network/manager"] = function() return { isConnected = function() return connected end } end
package.preload["http.timeout"] = function() return { ai = function() return 60 end } end
package.preload["features.ai.explain"] = function()
    return {
        messages = function(_ui, sel) return { {}, { content = "句子:" .. sel.sentence } } end,
        plain = function(s) return (s:gsub("%*", "")) end,
    }
end

local html_made = {}
package.preload["ui/widget/htmlboxwidget"] = function()
    local W = {}
    function W:new(o)
        o = setmetatable(o or {}, { __index = W })
        html_made[#html_made + 1] = o
        return o
    end
    function W:setContent(body, css, size, _x, _n, dir)
        self.body, self.css, self.size, self.dir = body, css, size, dir
        self.page_count = math.max(1, math.ceil(#body / 2000 * 100 / self.dimen.h))
        self.page_number = 1
    end
    function W:setPageNumber(n) self.page_number = n end
    function W:getSize() return self.dimen end
    function W:free() self.freed = true end
    function W:paintTo() end
    return W
end

local Lookup = require("features.rare.lookup")

-- 词典结果按词典分组，去掉无结果占位，HTML 去标签
local groups = Lookup.groupResults({
    { dict = "现代汉语", word = "彘", definition = "<b>猪</b><br>古称" , is_html = true },
    { dict = "古汉语", word = "彘", definition = "大猪" },
    { dict = "现代汉语", word = "彘肩", definition = "猪腿" },
    { dict = "Not available", word = "彘", definition = "No results.", no_result = true },
}, "彘")
Assert.len(groups, 2)
Assert.eq(groups[1].name, "现代汉语")
Assert.eq(groups[1].text, "猪\n古称\n\n彘肩\n猪腿", "与查的词相同的词条名不重复")

-- 加载所有词典：查全部已安装词典（含已停用），无结果的排在后面并标 empty
do
    local dir = os.tmpname()
    os.remove(dir)
    os.execute("mkdir -p " .. dir .. "/a")
    local f = io.open(dir .. "/a/a.ifo", "w")
    f:write("StarDict's dict ifo file\nbookname=甲\nsametypesequence=m\n")
    f:close()
    f = io.open(dir .. "/a/b.ifo", "w")
    f:write("StarDict's dict ifo file\nbookname=乙\nsametypesequence=m\n")
    f:close()
    local asked
    local ui = { dictionary = { enabled_dict_names = { "甲" }, data_dir = dir,
        startSdcv = function(_s, _word, names) asked = names; return { { dict = "乙", word = "彘", definition = "猪" } } end } }
    dict_settings.dictionary_load_all = true
    local all = Lookup.queryDicts(ui, "彘")
    Assert.eq(table.concat(asked, ","), "乙,甲", "不看启用状态，查全部")
    Assert.eq(all[1].name, "乙")
    Assert.is_nil(all[1].empty)
    Assert.eq(all[2].name, "甲")
    Assert.is_true(all[2].empty, "无结果的也留一项")
    dict_settings.dictionary_load_all = false
    Assert.len(Lookup.queryDicts(ui, "彘"), 1, "关闭时只查已启用的")
    os.execute("rm -rf " .. dir)
end

-- 一个居中窗口，底部四个图标 Tab；默认词典 Tab；标题带读音
local sdcv_word
local ui = { dictionary = {
    enabled_dict_names = { "现代汉语", "古汉语" },
    startSdcv = function(_self, word) sdcv_word = word; return {
        { dict = "现代汉语", word = word, definition = "猪" }, { dict = "古汉语", word = word, definition = "大猪" } } end,
} }
local panel = Lookup.open{ ui = ui, text = "彘", context = { sentence = "杀彘", paragraph = "" } }
Assert.eq(sdcv_word, "彘")
Assert.eq(panel.reading, "zhì")
local ids = {}
for _idx, tab in ipairs(panel:tabs()) do ids[#ids + 1] = tab.id .. ":" .. tab.text .. ":" .. tab.icon end
Assert.eq(table.concat(ids, ","), "dict:词典:dictionary,translate:翻译:translate,ai:AI:auto_awesome,baike:百科:travel_explore")
Assert.eq(panel.active, "dict")
Assert.eq(panel.text_box.text, "猪")
Assert.eq(settings.rare_lookup_source, "dict", "记住 Tab")
Assert.eq(panel.panel_x, math.floor((panel.dimen.w - panel[1]:getSize().w) / 2), "水平居中")
Assert.eq(panel.panel_y, math.floor((panel.dimen.h - panel[1]:getSize().h) / 2), "垂直居中，不贴底")
Assert.is_nil(panel.footer, "不再有「来源」行")
Assert.is_nil(panel.move, "不再左右滑切来源")
Assert.is_nil(panel.dots, "不再有圆点")
-- 词典 Tab 卡头换词典：列出有结果的词典，选中后显示并记住
local picker
for _idx, b in ipairs(Kit.buttons(panel[1])) do if b.text == "现代汉语 ▼" then picker = b end end
Assert.not_nil(picker, "词典选择按钮")
picker.callback()
local sheet = require("support.theme_stubs").last("list")
Assert.len(sheet.items, 2)
sheet.items[2].callback()
Assert.eq(panel.text_box.text, "大猪")
Assert.eq(settings.rare_lookup_dict, "古汉语")
-- 短正文一页：无翻页条，滑动吞掉不切 Tab
Assert.is_nil(panel.pager)
Assert.is_true(panel:onSwipe(nil, { direction = "north" }))
panel:onSwipe(nil, { direction = "west" })
Assert.eq(panel.active, "dict")
-- 布局：没有卡头行的 Tab 正文紧贴顶部内边距；Tab 栏在边框之内
local function inner_group() return panel[1][1][2][1] end
panel:select("baike")
Assert.eq(inner_group()[2], panel.text_box, "百科正文上方无占位")
local frame = panel.frame
local tb = panel.tabbar:getSize()
Assert.is_true(frame >= 1, "有边框")
Assert.is_true(panel[1].padding >= frame, "内边距容下边框")
Assert.is_true(tb.w + frame * 2 <= panel[1].box_w, "Tab 栏宽在边框内")
Assert.is_true(panel[1][1]:getSize().h + frame * 2 <= panel[1].box_h, "Tab 栏高在边框内")
panel:select("dict")
-- 点 Tab 原地切换：几何不变，重画整个窗口栈（遮罩下不留旧卡）
local h0, y0 = panel[1]:getSize().h, panel.panel_y
for _idx, id in ipairs({ "baike", "translate", "ai", "dict" }) do
    Kit.dirty = {}
    panel:select(id)
    Assert.eq(Kit.dirty[#Kit.dirty].widget, "all", id .. " 重画整个窗口栈")
    Assert.eq(panel[1]:getSize().h, h0, id .. " 高度不变")
    Assert.eq(panel.panel_y, y0, id .. " 位置不变")
end
Assert.eq(#Kit.taps(panel[1]) >= 4, true, "四个 Tab 可点")

-- 百科：首次切到才请求一次；成功显示摘要，出处百度百科
Assert.eq(baike_calls, 1)
panel:select("baike")
Assert.eq(baike_calls, 1, "在途不重复请求")
Assert.eq(panel.text_box.text, "正在查询百科…")
baike_cb({ title = "彘", definition = "古书中指猪" })
Assert.eq(panel.text_box.text, "古书中指猪")

-- 切到翻译：按需请求，成功显示译文
panel:select("translate")
Assert.eq(panel.text_box.text, "正在翻译…")
translate_cb("pig", "zh")
Assert.eq(panel.text_box.text, "pig")
Assert.eq(settings.rare_lookup_source, "translate")

-- 切到 AI：按需请求一次；结果去 Markdown；再切回不重复请求
panel:select("ai")
Assert.eq(ai_calls, 1)
Assert.eq(ai_prompt, "句子:杀彘", "AI 带所在句子")
Assert.eq(panel.text_box.text, "AI 解释中…")
ai_cb("**猪**，此处指祭品")
Assert.eq(panel.text_box.text, "猪，此处指祭品")
-- 长文自动分页：整行高度、翻页条、滑动翻页；流式变长重算页数
local h_before = panel[1]:getSize().h
ai_cb(string.rep("长", 2000))
Assert.is_true(panel.body_pages > 1, "多页")
Assert.is_true(panel.pager ~= nil, "有翻页条")
Assert.eq(panel.text_box.height % panel.text_box:getLineHeight(), 0, "无半行")
Assert.eq(panel[1]:getSize().h, h_before, "分页不改总高")
local pages = panel.body_pages
panel:onSwipe(nil, { direction = "north" })
Assert.eq(panel.body_page, 2)
Assert.eq(panel.text_box.scrolled, 1)
ai_cb(string.rep("长", 4000))
Assert.is_true(panel.body_pages > pages, "流式变长重算页数")
Assert.eq(panel.body_page, 2, "保持当前页")
ai_cb("**猪**，此处指祭品")
Assert.is_nil(panel.pager)
panel:select("dict:现代汉语")
panel:select("ai")
Assert.eq(ai_calls, 1)
panel:close()

-- 再开同一词同一句：AI 走缓存；上次来源（AI）被记住
local again = Lookup.open{ ui = ui, text = "彘", context = { sentence = "杀彘", paragraph = "" } }
Assert.eq(again.active, "ai")
Assert.eq(ai_calls, 1)
Assert.eq(again.text_box.text, "猪，此处指祭品")
again:close()

-- 百科未收录 / 断网 / 关窗取消；长句没有百科卡
local nb = Lookup.open{ ui = {}, text = "龘龘", source = "baike" }
baike_cb(nil, "not found")
Assert.eq(nb.text_box.text, "百科未收录「龘龘」")
nb:close()
nb = Lookup.open{ ui = {}, text = "龘", source = "baike" }
baike_cancelled = false
nb:close()
Assert.is_true(baike_cancelled, "关窗取消百科请求")
connected = false
nb = Lookup.open{ ui = {}, text = "龘", source = "baike" }
Assert.eq(nb.text_box.text, "网络不可用，请先连接 Wi-Fi")
nb:close()
connected = true
Assert.matches(Lookup.open{ ui = {}, text = string.rep("长", 40), source = "baike" }.text_box.text, "不查百科", "长句不查百科")
Lookup.current:close()

-- 关窗取消在途请求
settings.rare_lookup_source = "translate"
local inflight = Lookup.open{ ui = ui, text = "龘" }
translate_cancelled = false
inflight:close()
Assert.is_true(translate_cancelled)

-- 指定来源优先（划词「翻译」）
local t = Lookup.open{ ui = ui, text = "彘", source = "translate", translator = translator }
Assert.eq(t.active, "translate")
t:close()

-- 没装词典：只有翻译和 AI，落在 AI 并提示；未配置 AI 给出原因
settings.rare_lookup_source = ""
configured = false
local bare = Lookup.open{ ui = {}, text = "生字", context = { sentence = "杀彘", paragraph = "" } }
Assert.eq(bare.active, "ai")
Assert.matches(bare.text_box.text, "请先在月读设置中配置 AI 服务")
bare:select("dict")
Assert.matches(bare.text_box.text, "未安装词典")
bare:close()
configured = true

-- 长句不查词典
sdcv_word = nil
local long = Lookup.open{ ui = ui, text = string.rep("长", 40) }
Assert.is_nil(sdcv_word)
long:close()

-- 划词进来：关窗清选区；存为笔记交给 addNote，不清
local clears, noted = 0, nil
local hl_ui = { dictionary = ui.dictionary, highlight = { clear = function() clears = clears + 1 end, addNote = function(_, s) noted = s end } }
local p = Lookup.open{ ui = hl_ui, text = "彘", from_highlight = true, source = "dict" }
p:close()
Assert.eq(clears, 1)
p = Lookup.open{ ui = hl_ui, text = "彘", from_highlight = true, source = "dict" }
for _idx, b in ipairs(Kit.buttons(p[1])) do
    if b.text == "存为笔记" then b.callback() end
end
Assert.eq(noted, "大猪", "存当前（上次选的）词典释义")
Assert.eq(clears, 1)

-- 加入生词本：装了原生生词本插件才有按钮，发 WordLookedUp（手动，不看自动开关）
do
    local sent
    local vb_ui = { dictionary = ui.dictionary, vocabbuilder = {}, doc_props = { display_title = "书名" },
        handleEvent = function(_, ev) sent = ev end }
    local vp = Lookup.open{ ui = vb_ui, text = "彘", source = "dict" }
    for _idx, b in ipairs(Kit.buttons(vp[1])) do
        if b.text == "加入生词本" then b.callback() end
    end
    Assert.eq(sent.name, "WordLookedUp")
    Assert.eq(sent.args[1], "彘")
    Assert.eq(sent.args[2], "书名")
    Assert.eq(sent.args[3], true)
    vp:close()
    local plain = Lookup.open{ ui = ui, text = "彘", source = "dict" }
    for _idx, b in ipairs(Kit.buttons(plain[1])) do Assert.is_true(b.text ~= "加入生词本") end
    plain:close()
end

-- 同一时刻只留一个面板：再次打开先关掉旧的
local first = Lookup.open{ ui = ui, text = "彘" }
local closed_before = #Kit.closed
local second = Lookup.open{ ui = ui, text = "彘" }
Assert.eq(Kit.closed[closed_before + 1], first, "旧面板被关闭")
Assert.eq(Lookup.current, second)
second:close()
Assert.is_nil(Lookup.current)

-- 标题读音用 NotoSans（与注音层同字体），不用界面字体
local native_face = Lookup.readingFace
Assert.matches(debug.getinfo(native_face, "S").source, "lookup")
local mark = {}
Lookup.readingFace = function() return mark end
local rp = Lookup.open{ ui = ui, text = "彘" }
local found = false
local function walk(node, depth)
    if type(node) ~= "table" or depth > 30 then return end
    if node.face == mark and tostring(node.text):find("zhì") then found = true end
    for _k, v in pairs(node) do if type(v) == "table" and _k ~= "face" and _k ~= "ui" and _k ~= "parent" then walk(v, depth + 1) end end
end
walk(rp[1], 0)
Assert.is_true(found, "读音用 readingFace 渲染")
rp:close()
Lookup.readingFace = native_face


-- HTML 词典：纯文字版去标签（列表加圆点）；面板用 HtmlBoxWidget 排版，带词典 css / 资源目录，链接在同窗查词
do
    local raw = "<p><b>釋義</b></p><ol><li>僅用於人名。</li></ol><p>劉龑&amp;</p>"
    local g = Lookup.groupResults({
        { dict = "reader.dict ZH", word = "龑", definition = raw, is_html = true, css = "b{color:red}",
          dictionary_resource_directory = "/res" },
        { dict = "reader.dict ZH", word = "龑2", definition = "<p>二</p>", is_html = true },
    }, "龑")
    Assert.eq(g[1].text, "釋義\n• 僅用於人名。\n劉龑&\n\n龑2\n二")
    Assert.eq(g[1].html, raw .. "<hr/><p><b>龑2</b></p><p>二</p>")
    Assert.eq(g[1].css, "b{color:red}")
    Assert.eq(Lookup.linkWord("bword://龑"), "龑")
    Assert.eq(Lookup.linkWord("龑"), "龑")
    Assert.is_nil(Lookup.linkWord("https://x.org"))
    local hui = { dictionary = { enabled_dict_names = { "reader.dict ZH" }, startSdcv = function(_s, word)
        return { { dict = "reader.dict ZH", word = word, definition = word == "龑" and raw or string.rep("<p>长</p>", 3000),
            is_html = true, css = "b{color:red}", dictionary_resource_directory = "/res" } } end } }
    settings.rare_lookup_source = "dict"
    local p = Lookup.open{ ui = hui, text = "龑", source = "dict" }
    local box = p.html_box
    Assert.not_nil(box, "HTML 词典走 HtmlBoxWidget")
    Assert.is_nil(p.text_box)
    Assert.eq(box.body, raw)
    Assert.eq(box.dir, "/res")
    Assert.is_true(box.css:find("Noto Sans", 1, true) ~= nil and box.css:find("b{color:red}", 1, true) ~= nil, "基础 css + 词典 css")
    Assert.is_nil(p.pager, "一页无翻页条")
    -- 长释义多页：让出翻页条高度重排，Pager 翻 HTML 页，旧盒子被释放
    local long = Lookup.open{ ui = hui, text = "长词", source = "dict" }
    Assert.not_nil(long.pager)
    Assert.is_true(long.body_pages > 1)
    local first = long.html_box
    long:turn(1)
    Assert.eq(long.html_box.page_number, 2)
    Assert.is_true(first.freed, "重建时释放旧 HTML 盒子")
    -- 点链接：下一拍在同一面板位置查新词
    long.html_box.html_link_tapped_callback({ uri = "bword://龑" })
    Assert.eq(Lookup.current.text, "龑")
    Lookup.current:close()
end

-- startSdcv 原始结果不带 is_html（KOReader 只在 tidyMarkup 里补）：按 ifo 类型或标签启发式判 HTML
do
    Assert.is_true(Lookup.looksHtml("<p><b>釋義</b></p><ol><li>x</li></ol>"))
    Assert.is_true(Lookup.looksHtml("a<br/>b"))
    Assert.is_false(Lookup.looksHtml("1 < 2 > 0"))
    Assert.is_false(Lookup.looksHtml("纯文字 <龑>"))
    local g = Lookup.groupResults({ { dict = "Z", word = "龑", definition = "<p><b>釋義</b></p><ol><li>人名</li></ol>" } }, "龑")
    Assert.eq(g[1].html, "<p><b>釋義</b></p><ol><li>人名</li></ol>")
    Assert.eq(g[1].text, "釋義\n• 人名")
    g = Lookup.groupResults({ { dict = "H", word = "x", definition = "plain" } }, "x", { H = { html = true, css = "p{}" } })
    Assert.eq(g[1].html, "plain")
    Assert.eq(g[1].css, "p{}")
    g = Lookup.groupResults({ { dict = "M", word = "x", definition = "plain" } }, "x", { M = { html = false } })
    Assert.is_nil(g[1].html)
    local dir = os.tmpname(); os.remove(dir); os.execute("mkdir -p '" .. dir .. "/a'")
    local f = io.open(dir .. "/a/d.ifo", "w"); f:write("StarDict's dict ifo file\nbookname=reader.dict ZH\nsametypesequence=h\n"); f:close()
    f = io.open(dir .. "/a/d.css", "w"); f:write("b{}"); f:close()
    local info = Lookup.ifoInfo(dir)
    Assert.is_true(info["reader.dict ZH"].html)
    Assert.eq(info["reader.dict ZH"].css, "b{}")
    os.execute("rm -rf '" .. dir .. "'")
end

return true
