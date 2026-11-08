--[[-- 超长段评预览可点开全文，全文分页不改变评论列表当前位置。
@module tests.features.reviews.sheet_content_spec
--]]
local Assert = require("support.assert")
local Kit = require("support.widget_stubs")
Kit.install("paper")
Kit.sections.reviews = { font_scale = 100 }
Kit.sections.ai = { ai_endpoint = "", ai_api_key = "", ai_model = "" }
local Text = require("ui.themes.widgets.text")
local box = Text.box
local box_opts = {}
-- stub 的文字高度固定；按正文长度提供自然高度，限行后仍用原 stub。
Text.box = function(role, text, width, opts)
    box_opts[#box_opts + 1] = { text = text, opts = opts or {} }
    local widget = box(role, text, width, opts)
    if not opts or not opts.max_lines then
        function widget:getSize() return { w = width, h = math.ceil(#text / 10) * 10 } end
    end
    return widget
end
local Sheet = require("features.reviews.sheet")
local theme = require("ui.themes").current()
local long = ("review text "):rep(250) .. "END-OF-REVIEW"
local fake = setmetatable({
    theme = theme, inner_w = 500, body_h = 200, cards = {}, page = 2,
    items = {
        { author = "Long author", content = long, likes = 10, time = 1 },
        { author = "Short author", content = "short", likes = 1, time = 1 },
    },
}, { __index = Sheet })

local card = fake:card(1)
Assert.eq(fake:card(1), card, "卡片缓存保留点击入口")
Assert.is_true(card:getSize().h <= fake.body_h)
Assert.is_true(type(card.onTapThemeArea) == "function")
card:onTapThemeArea()
local viewer = Kit.shown[#Kit.shown]
Assert.eq(viewer.title, "段评 · Long author")
Assert.eq(viewer.text, long, "全文不使用被截断的预览")
Assert.is_true(viewer.pages > 1, "同一条长评论可独立分页")
viewer:turn(1)
Assert.eq(viewer.page, 2)
Assert.eq(fake.page, 2, "全文翻页不前进到另一人的段评")
viewer:close()
Assert.eq(fake.page, 2)
Assert.is_nil(fake:card(2).onTapThemeArea, "短评论不增加无用点击区")

-- avail 更小（第一页扣掉引用后）时截断更狠，而不是按整页高截完再整条搬走。
local function lastLines()
    for i = #box_opts, 1, -1 do
        if box_opts[i].text == long and box_opts[i].opts.max_lines then return box_opts[i].opts.max_lines end
    end
end
local full_lines = lastLines()
local first_page = setmetatable({
    theme = theme, inner_w = 500, body_h = 200, cards = {}, page = 1,
    items = { { author = "Long author", content = long, likes = 10, time = 1 } },
}, { __index = Sheet })
local first_card = first_page:card(1, 90)
Assert.is_true(lastLines() < full_lines, "首页首条按剩余高度截断")
Assert.is_true(first_card:getSize().h <= 90)
Assert.is_true(type(first_card.onTapThemeArea) == "function", "截断后仍可点开全文")

local inline_images = { ["[捂脸]"] = { url = "https://pic.test/emoticon.png" } }
local rich_page = setmetatable({
    theme = theme, inner_w = 500, body_h = 200, cards = {},
    items = { { author = "Emoji author", content = long, likes = 0, time = 1, inline_images = inline_images } },
}, { __index = Sheet })
local rich_card = rich_page:card(1)
Assert.eq(box_opts[#box_opts].opts.inline_images, inline_images, "段评预览交给主题文字渲染内联表情")
Assert.is_true(box_opts[#box_opts].opts.emoji, "预览显示 Unicode emoji，不要求用户安装字体")
rich_card:onTapThemeArea()
Assert.eq(Kit.shown[#Kit.shown].inline_images, inline_images, "打开全文也保留表情")
Assert.is_true(Kit.shown[#Kit.shown].emoji, "全文保持相同 emoji 渲染")

do -- 整书首批复用同一张卡片列表，本地翻页不请求段评或额外书评。
    local Ext = require("utils.extension")
    Ext.reset()
    require("features.reviews")
    Ext.call("desktop.comments", { title = "测试书" }, {
        items = {
            { author = "书评作者", text = long, time = "昨天", grade = 8 },
            { author = "另一位作者", text = "简短书评", time = "8月27日" },
        },
    })
    local snapshot = Kit.shown[#Kit.shown]
    Assert.eq(snapshot.title, "书评")
    Assert.eq(snapshot.spot.text, "测试书")
    Assert.eq(snapshot.items[1].content, long)
    Assert.is_true(snapshot.loaded)
    Assert.is_false(snapshot.more)
    Assert.is_nil(snapshot.identity, "整书评论不假造段落身份")
    Assert.len(Kit.find(snapshot, function(w) return w.text == "昨天" end), 1)
    Assert.len(Kit.find(snapshot, function(w) return w.text == "评分 8" end), 1)
    Assert.is_nil(snapshot.items[1].likes, "未知点赞数不伪造为零")
    snapshot:load()
    for _idx = 1, #snapshot.pages + 1 do snapshot:turn(1) end
    Assert.eq(snapshot.page, #snapshot.pages)
    Assert.is_nil(snapshot.job, "翻到末页也不发起网络请求")
    snapshot:card(1):onTapThemeArea()
    Assert.eq(Kit.shown[#Kit.shown].title, "书评 · 书评作者")
    Assert.eq(Kit.shown[#Kit.shown].text, long)
    Kit.shown[#Kit.shown]:close()
    snapshot:close()
    Ext.reset()
end

do -- 有回复数才出现入口；点开把评论 id 交给回复页。回复页本身不再往下开。
    local opened
    local openReplies = Sheet.openReplies
    function Sheet.openReplies(_identity, item) opened = item.id end
    local source = { paragraphReviewRepliesAsync = function() end }
    local reply_card = setmetatable({
        theme = theme, inner_w = 500, body_h = 200, cards = {},
        identity = { source = source },
        items = { { id = "c1", author = "甲", content = "hello", likes = 1, time = 1, replies = 3,
            reply_to = "乙" } },
    }, { __index = Sheet }):card(1)
    local taps = Kit.taps(reply_card)
    Assert.len(taps, 1)
    taps[1]:onTapThemeArea()
    Assert.eq(opened, "c1")
    local prefixed
    for _idx, call in ipairs(box_opts) do
        if call.text:find("hello", 1, true) then prefixed = call.text end
    end
    Assert.eq(prefixed, "回复 乙：hello")

    local nested = setmetatable({
        theme = theme, inner_w = 500, body_h = 200, cards = {}, reply_page = true,
        identity = { source = source },
        items = { { id = "c2", author = "甲", content = "more", likes = 0, time = 1, replies = 8 } },
    }, { __index = Sheet }):card(1)
    Assert.len(Kit.taps(nested), 0, "回复页不再给下一级入口")
    Sheet.openReplies = openReplies
end

do -- 内嵌预览是独立二级列表；不联网、不伪造完整数量或后续页。
    local preview = {
        { id = "r1", author = "乙", content = "第一条回复", likes = 0, time = 1, replies = 8 },
        { id = "r2", author = "丙", content = "第二条回复", likes = 1, time = 1 },
    }
    local item = { id = "parent", content = "主评论", replies = 65, reply_preview = preview,
        inline_images = inline_images }
    local source = { paragraphReviewPageAsync = function() error("预览不能请求主评论接口") end }
    local identity = { source = source }
    local parent = setmetatable({ theme = theme, identity = identity }, { __index = Sheet })
    local line = parent:replyLine(item)
    Assert.len(Kit.find(line, function(w) return w.text == "回复预览（2/65）" end), 1)
    Kit.taps(line)[1]:onTapThemeArea()
    local child = Kit.shown[#Kit.shown]
    Assert.is_true(child.reply_page)
    Assert.eq(child.items, preview)
    Assert.eq(child.spot.text, "主评论")
    Assert.eq(child.spot.inline_images, inline_images, "回复页引用保留主评论表情")
    Assert.eq(child.total, 65)
    Assert.is_true(child.loaded)
    Assert.is_false(child.more)
    Assert.is_nil(child.job)
    Assert.len(Kit.find(child, function(w) return w.text == "回复预览（2/65）" end), 1)
    Assert.is_nil(child:replyLine(preview[1]), "二级页面不再打开三级列表")
    child:load()
    for _idx = 1, #child.pages + 1 do child:turn(1) end
    Assert.eq(child.page, #child.pages, "翻到预览末页不能续拉不存在的内容")
    Assert.is_nil(parent:replyLine({ id = "empty", author = "", content = "", likes = 0, time = 1,
        replies = 65, reply_preview = {} }), "空预览不提供入口")
    child:close()

    local full_calls = 0
    source.paragraphReviewRepliesAsync = function(_self, _identity, review_id, _cursor, cb)
        full_calls = full_calls + 1
        Assert.eq(review_id, "parent")
        cb({ items = { preview[1] }, total = 65, max_idx = 1, more = false })
    end
    local full_line = parent:replyLine(item)
    Assert.len(Kit.find(full_line, function(w) return w.text == "65 条回复" end), 1)
    Kit.taps(full_line)[1]:onTapThemeArea()
    local full = Kit.shown[#Kit.shown]
    Assert.eq(full_calls, 1, "已有完整接口的源仍使用原回复接口")
    Assert.is_nil(full.reply_preview)
    Assert.len(full.items, 1)
    full:close()
end

local image_url = "https://example.test/review.jpg"
local image_card = setmetatable({
    theme = theme, inner_w = 500, body_h = 200, cards = {},
    items = { { author = "Reviewer", content = "Short review", likes = 1, time = 1,
        images = { { url = image_url } } } },
}, { __index = Sheet }):card(1)
local image_tap = Kit.taps(image_card)[1]
Assert.is_true(image_tap ~= nil, "配图有独立点击入口")
image_tap:onTapThemeArea()
-- 原句与正文直接落在面板上，不铺整块底色（真机上会显出一块矩形底）。
local quote_fake = setmetatable({
    theme = theme, inner_w = 500, spot = { text = "被引用的原句", total = 1 },
}, { __index = Sheet })
quote_fake:quote()
for _idx, call in ipairs(box_opts) do
    -- 带 height 的是全文查看器的正文框，不在段评弹窗范围内。
    if call.opts.height == nil
        and (call.text == long or call.text == "short" or call.text == "被引用的原句") then
        Assert.is_true(call.opts.transparent, "段评文字不铺底色: " .. call.text:sub(1, 12))
    end
end

local viewer = Kit.shown[#Kit.shown]
Assert.is_true(viewer.close_on_tap, "全屏图可点按关闭")
local displayed_image = Kit.find(viewer, function(widget) return widget.src == image_url end)[1]
Assert.is_true(displayed_image ~= nil, "预览使用点击的图片地址")
Assert.is_true(displayed_image.image_opts.stretch, "全屏预览按比例缩进，不拉满变形")
viewer.close_callback()
Assert.is_true(displayed_image.cancelled, "关闭预览取消图片下载")

local custom_headers = { Referer = "https://www.zhihu.com/" }
local custom_image = { url = "https://pic.test/zhihu.jpg", headers = custom_headers }
local thumbs = fake:thumbs({ custom_image })
local thumbnail = Kit.find(thumbs, function(widget) return widget.src == custom_image.url end)[1]
Assert.eq(thumbnail.image_opts.headers, custom_headers, "缩略图使用所属图片的请求头")
Kit.taps(thumbs)[1]:onTapThemeArea()
local custom_viewer = Kit.shown[#Kit.shown]
local full_image = Kit.find(custom_viewer, function(widget) return widget.src == custom_image.url end)[1]
Assert.eq(full_image.image_opts.headers, custom_headers, "展开图片不误发其它源的 Referer")
