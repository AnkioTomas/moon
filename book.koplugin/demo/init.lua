--[[--
主题组件演示（开发用，tools/package.sh 打包时剔除整个 demo/）。
main.lua 检测到 demo/ 目录存在才转发 addToMainMenu。

  首页（主题 List，点项不关）
    ├─ 切换主题            居中单选 List → 写 display.ui_theme，重开首页
    ├─ 控件：文字 / 按钮 / 进度条 / 卡片   全屏展示页，可交互
    ├─ 控件：行 / 翻页条 / 底栏            全屏展示页，可交互
    ├─ 控件：图片 / 锚点弹出 / 多按钮行    全屏展示页，可交互
    └─ 提示、确认框、动作表、列表×4、进度弹窗、数值×2、输入×2、文本查看、二维码

@module koplugin.book.demo
--]]

local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Theme = require("ui.themes.init")
local Box = require("ui.themes.widgets.box")
local Button = require("ui.themes.widgets.button")
local Confirm = require("ui.themes.widgets.confirm")
local IconPicker = require("ui.themes.widgets.icon_picker")
local Image = require("ui.themes.widgets.image")
local Input = require("ui.themes.widgets.input")
local List = require("ui.themes.widgets.list")
local Modal = require("ui.themes.widgets.modal")
local Pager = require("ui.themes.widgets.pager")
local Progress = require("ui.themes.widgets.progress")
local ProgressDialog = require("ui.themes.widgets.progress_dialog")
local QR = require("ui.themes.widgets.qr")
local Row = require("ui.themes.widgets.row")
local Sheet = require("ui.themes.widgets.sheet")
local Spin = require("ui.themes.widgets.spin")
local Tabbar = require("ui.themes.widgets.tabbar")
local Text = require("ui.themes.widgets.text")
local TextViewer = require("ui.themes.widgets.text_viewer")
local TitleBar = require("ui.themes.widgets.titlebar")
local Toast = require("ui.themes.widgets.toast")

local NAMES = { paper = "纸本", bold = "高对比", soft = "柔和" }

local Demo = {}

--- 演示结果统一用提示框回报。
---@param text string
local function say(text)
    Toast:new{ text = text, timeout = 2 }:show()
end

--- 横排控件，中间留 sm 间隔。
---@param t table 主题令牌
---@param kids table[]
---@return table
local function hrow(t, kids)
    local row = HorizontalGroup:new{ align = "center" }
    for i, kid in ipairs(kids) do
        if i > 1 then row[#row + 1] = HorizontalSpan:new{ width = Theme.px(t.space.sm) } end
        row[#row + 1] = kid
    end
    return row
end

--- 竖排控件，块与块之间留 md 间隔。
---@param t table 主题令牌
---@param kids table[]
---@return table
local function vstack(t, kids)
    local col = VerticalGroup:new{ align = "left" }
    for i, kid in ipairs(kids) do
        if i > 1 then col[#col + 1] = VerticalSpan:new{ width = Theme.px(t.space.md) } end
        col[#col + 1] = kid
    end
    return col
end

-- 全屏展示页：标题栏 + 内容，内容由 body(page, t, width) 构建，状态变化时 page:refresh() 重建。
local Gallery = Modal:extend{
    mask = false,
    title = nil,
    body = nil,
}

function Gallery:init()
    Modal.init(self)
    self:rebuild()
end

function Gallery:rebuild()
    local t = self.theme
    local w, h = self.dimen.w, self.dimen.h
    local pad = Theme.px(t.space.lg)
    local bar = TitleBar.widget({
        width = w, title = self.title, subtitle = NAMES[t.id],
        right_icon = "close", right_callback = function() self:dismiss() end,
    })
    local content = Box:new{ style = {}, padding = pad, self.body(self, t, w - pad * 2) }
    local used = bar:getSize().h + content:getSize().h
    self:setPanel(Box:new{
        style = { bg = t.color.page },
        width = w,
        height = h,
        VerticalGroup:new{
            align = "left",
            bar,
            content,
            VerticalSpan:new{ width = math.max(0, h - used) },
        },
    })
end

function Gallery:refresh()
    self:rebuild()
    UIManager:setDirty(self, "ui")
end

--- 控件页一：字号角色、按钮四种形态、筛选 chip、进度条、三级表面。
local function controls(page, t, width)
    page.pct = page.pct or 35
    page.chip = page.chip or "全部"
    local half = math.floor((width - Theme.px(t.space.sm)) / 2)
    local chips = {}
    for _idx, name in ipairs({ "全部", "在读", "读完" }) do
        chips[#chips + 1] = Button:new{
            text = name,
            variant = page.chip == name and "primary" or "normal",
            callback = function() page.chip = name; page:refresh() end,
        }
    end
    local bar = Progress:new{ width = width, percent = page.pct }
    local function card(style, label)
        return Box:new{
            style = style, width = half, height = Theme.px(56),
            VerticalGroup:new{
                align = "center",
                Text.line("title", label),
                Text.line("caption", "card / raised", { color = t.color.muted }),
            },
        }
    end
    return vstack(t, {
        Text.line("hero", "42%", { width = width }),
        Text.line("title", "标题 title", { width = width }),
        Text.line("body", "正文 body：月读插件的主题组件演示", { width = width }),
        Text.line("caption", "说明 caption · muted", { width = width, color = t.color.muted }),
        hrow(t, {
            Button:new{ text = "普通", callback = function() say("normal") end },
            Button:new{ text = "主要", variant = "primary", callback = function() say("primary") end },
            Button:new{ text = "禁用", enabled = false, callback = function() say("不会出现") end },
            Button:new{ icon = "favorite", variant = "ghost", callback = function() say("ghost") end },
            Button:new{ icon = "settings", callback = function() say("icon") end },
        }),
        hrow(t, {
            Button:new{ icon = "home", text = "图标+文字", callback = function() say("icon + text") end },
            chips[1], chips[2], chips[3],
        }),
        Text.line("caption", string.format("进度条 %d%%", page.pct), { color = t.color.muted }),
        bar,
        hrow(t, {
            Button:new{ text = "-10", callback = function() page.pct = math.max(0, page.pct - 10); page:refresh() end },
            Button:new{ text = "+10", callback = function() page.pct = math.min(100, page.pct + 10); page:refresh() end },
            Button:new{ text = "0%", variant = "ghost", callback = function() page.pct = 0; page:refresh() end },
            Button:new{ text = "100%", variant = "ghost", callback = function() page.pct = 100; page:refresh() end },
        }),
        hrow(t, { card(t.card, "普通卡片"), card(t.raised, "主角卡片") }),
    })
end

--- 控件页二：列表行各状态、翻页条两种中心、底栏。
local function rows(page, t, width)
    page.wifi = page.wifi ~= false
    page.at = page.at or 1
    page.dot = page.dot or 2
    page.tab = page.tab or "home"
    return vstack(t, {
        VerticalGroup:new{
            align = "left",
            Row.widget({ width = width, icon = "wifi", title = "无线网络",
                status = page.wifi and "开" or "关", status_on = page.wifi, chevron = false,
                callback = function() page.wifi = not page.wifi; page:refresh() end }),
            Row.widget({ width = width, icon = "text_fields", title = "字体",
                subtitle = "带副标题的导航行", status = "思源宋体",
                callback = function() say("进入字体设置") end }),
            Row.widget({ width = width, icon = "radio_button_checked", title = "选中行（selected）",
                selected = true, chevron = false }),
            Row.widget({ width = width, icon = "block", title = "禁用行", enabled = false,
                callback = function() say("不会出现") end }),
            Row.widget({ width = width, title = "无图标、无分割线", divider = false,
                callback = function() say("row") end }),
        },
        Pager.widget({ width = width, page = page.at, pages = 12,
            on_prev = function() page.at = page.at - 1; page:refresh() end,
            on_next = function() page.at = page.at + 1; page:refresh() end }),
        Pager.widget({ width = width, page = page.dot, pages = 4, dots = true,
            on_prev = function() page.dot = page.dot - 1; page:refresh() end,
            on_next = function() page.dot = page.dot + 1; page:refresh() end }),
        Tabbar.widget({
            width = width,
            active = page.tab,
            tabs = {
                { id = "home", text = "首页", icon = "home" },
                { id = "library", text = "图书馆", icon = "local_library" },
                { id = "store", text = "书城", icon = "storefront" },
                { id = "settings", text = "设置", icon = "settings" },
            },
            on_tab = function(id) page.tab = id; page:refresh() end,
        }),
    })
end

--- 贴着按钮弹出的菜单（按钮上屏后 dimen 带坐标）。
local function menuFrom(button)
    Sheet:new{ anchor = button.dimen, mask = false, items = {
        { text = "按书名", callback = function() say("按书名") end },
        { text = "按作者", callback = function() say("按作者") end },
        { text = "按最近阅读", callback = function() say("按最近阅读") end },
    } }:show()
end

--- 控件页三：图片三态、锚点弹出（左上 / 右下，验证翻转与夹边）、多按钮行动作表。
local function media(_page, t, width)
    local third = math.floor((width - Theme.px(t.space.sm) * 2) / 3)
    local h = math.floor(third * 4 / 3)
    local left, right
    left = Button:new{ icon = "sort", text = "排序", callback = function() menuFrom(left) end }
    right = Button:new{ icon = "more_horiz", text = "更多", callback = function() menuFrom(right) end }
    return vstack(t, {
        Text.line("caption", "图片：本地 / 缺失回落文案 / 卡片表面", { width = width, color = t.color.muted }),
        hrow(t, {
            Image.widget({ width = third, height = h, src = "logo.png" }),
            Image.widget({ width = third, height = h, src = "missing.png", fallback = "三体" }),
            Image.widget({ width = third, height = h, src = "logo.png", style = t.card }),
        }),
        Text.line("caption", "锚点弹出：贴按钮下方，放不下翻到上方", { width = width, color = t.color.muted }),
        hrow(t, { left, right }),
        Button:new{ text = "动作表：多按钮行", width = width, callback = function()
            Sheet:new{ title = "划词", items = {
                { buttons = {
                    { icon = "content_copy", callback = function() say("复制") end },
                    { icon = "border_color", callback = function() say("高亮") end },
                    { icon = "translate", callback = function() say("翻译") end },
                    { icon = "search", callback = function() say("查词") end },
                } },
                { buttons = {
                    { text = "笔记", callback = function() say("笔记") end },
                    { text = "分享", callback = function() say("分享") end },
                } },
                { separator = true },
                { text = "取消" },
            } }:show()
        end },
    })
end

--- 模拟一个 10 步的后台任务；收起弹窗后停止推进。
local function fakeProgress()
    local stopped = false
    local dialog = ProgressDialog:new{ title = "模拟导入", close_callback = function() stopped = true end }
    dialog:show()
    local step = 0
    local function tick()
        if stopped then return end
        step = step + 1
        dialog:update(string.format("第 %d 本.epub", step), step, 10)
        if step < 10 then
            UIManager:scheduleIn(0.5, tick)
        else
            UIManager:scheduleIn(0.8, function() if not stopped then dialog:close() end end)
        end
    end
    UIManager:scheduleIn(0.5, tick)
end

local function numbered(n, checked)
    local out = {}
    for i = 1, n do
        out[i] = { text = "第 " .. i .. " 项", value = i, checked = i == checked,
            mandatory = i % 5 == 0 and "状态" or nil, enabled = i ~= 3 }
    end
    return out
end

local LONG_TEXT = string.rep("月读把图书馆、阅读进度、统计与多源同步收进一个插件。"
    .. "这一段文字用来演示文本查看器的分页：正文按可见行数切页，底部翻页条前后翻。\n\n", 40)

-- 首页：点项执行演示，首页本身不关（List 单选默认点按即关）。
local Hub = List:extend{}

function Hub:choose(item)
    item.run(self)
end

--- 首页条目：text + run(hub)。
---@return table[]
local function entries()
    return {
        { text = "切换主题", mandatory = NAMES[Theme.current().id], run = function(hub)
            local cur = Theme.current().id
            local items = {}
            for _idx, id in ipairs(Theme.ids) do
                items[#items + 1] = { text = NAMES[id] .. "  " .. id, value = id, checked = id == cur }
            end
            List:new{ title = "切换主题", items = items, centered = true, on_select = function(id)
                Theme.set(id)
                hub:close()
                Demo.open()
            end }:show()
        end },
        { text = "控件：文字 / 按钮 / 进度条 / 卡片", run = function()
            Gallery:new{ title = "控件", body = controls }:show()
        end },
        { text = "控件：行 / 翻页条 / 底栏", run = function()
            Gallery:new{ title = "列表件", body = rows }:show()
        end },
        { text = "控件：图片 / 锚点弹出 / 多按钮行", run = function()
            Gallery:new{ title = "图片与弹出", body = media }:show()
        end },
        { text = "提示 Toast（点任意处收起）", run = function()
            Toast:new{ text = "已加入书架。点任意处收起。" }:show()
        end },
        { text = "提示 Toast（2 秒自动收起）", run = function() say("2 秒后自动收起") end },
        { text = "确认框 Confirm", run = function()
            Confirm:new{
                title = "删除书籍", text = "确定删除《三体》？本地文件一并删除。", ok_text = "删除",
                ok_callback = function() say("确认：删除") end,
                cancel_callback = function() say("取消") end,
            }:show()
        end },
        { text = "动作表 Sheet", run = function()
            Sheet:new{ title = "《三体》", items = {
                { text = "打开", icon = "menu_book", callback = function() say("打开") end },
                { text = "详情", icon = "info", callback = function() say("详情") end },
                { separator = true },
                { text = "不可用的动作", enabled = false },
                { text = "删除", variant = "primary", callback = function() say("删除") end },
            } }:show()
        end },
        { text = "列表：居中单选", run = function()
            List:new{ title = "排序方式", centered = true, items = {
                { text = "最近阅读", value = "recent", checked = true },
                { text = "书名", value = "title", checked = false },
                { text = "作者", value = "author", checked = false },
            }, on_select = function(v) say("选择：" .. v) end }:show()
        end },
        { text = "列表：全屏多选", run = function()
            local items = {}
            for i, name in ipairs({ "微信读书", "京东读书", "本地", "OPDS", "Z-Library" }) do
                items[i] = { text = name, value = name, checked = i <= 2 }
            end
            List:new{ title = "启用的书源", subtitle = "点按切换，关闭后汇总", items = items, multi = true,
                close_callback = function()
                    local on = {}
                    for _idx, it in ipairs(items) do if it.checked then on[#on + 1] = it.value end end
                    say("已启用：" .. (#on > 0 and table.concat(on, "、") or "无"))
                end }:show()
        end },
        { text = "列表：缩略图 + 右侧控件", run = function()
            local items = {}
            for i, name in ipairs({ "三体", "球状闪电", "流浪地球" }) do
                items[i] = { text = name, value = name, image = "logo.png", image_w = 28, image_h = 36,
                    widget = Text.line("caption", "预览 Aa") }
            end
            List:new{ title = "带缩略图", items = items, on_select = function(v) say("选择：" .. v) end }:show()
        end },
        { text = "列表：60 项分页（第 3 项禁用）", run = function()
            List:new{ title = "长列表", subtitle = "打开即翻到选中的第 33 项", items = numbered(60, 33),
                on_select = function(v) say("选择：第 " .. v .. " 项") end }:show()
        end },
        { text = "图标选择 IconPicker", run = function()
            IconPicker:new{ current = "menu_book", on_select = function(name) say("图标：" .. name) end }:show()
        end },
        { text = "进度弹窗 ProgressDialog", run = fakeProgress },
        { text = "数值选择：单列", run = function()
            Spin:new{ title = "每日阅读目标（分钟）",
                fields = { { value = 30, min = 5, max = 240, step = 5 } },
                callback = function(v) say("目标：" .. v .. " 分钟") end }:show()
        end },
        { text = "数值选择：时间（两列回绕）", run = function()
            local fmt2 = function(v) return string.format("%02d", v) end
            Spin:new{ title = "提醒时间", fields = {
                { value = 21, min = 0, max = 23, wrap = true, label = "时", format = fmt2 },
                { value = 30, min = 0, max = 55, step = 5, wrap = true, label = "分", format = fmt2 },
            }, callback = function(h, m) say(string.format("提醒：%02d:%02d", h, m)) end }:show()
        end },
        { text = "输入框：单字段", run = function()
            Input:new{ title = "重命名", fields = { { text = "三体", hint = "书名" } },
                callback = function(v) say("新书名：" .. v) end }:show()
        end },
        { text = "输入框：多字段（含密码、多行）", run = function()
            Input:new{ title = "登录", fields = {
                { label = "账号", hint = "邮箱或手机号" },
                { label = "密码", text_type = "password" },
                { label = "备注", height = 80 },
            }, ok_text = "登录", callback = function(account) say("账号：" .. account) end }:show()
        end },
        { text = "文本查看 TextViewer", run = function()
            TextViewer:new{ title = "关于月读", text = LONG_TEXT }:show()
        end },
        { text = "二维码 QR", run = function()
            QR:new{ title = "扫码打开", text = "https://github.com/", caption = "点任意处收起" }:show()
        end },
    }
end

--- 打开演示首页（按当前主题构建）。
function Demo.open()
    Hub:new{ title = "主题组件演示", subtitle = "当前：" .. NAMES[Theme.current().id], items = entries() }:show()
end

local MENU_ID = "book_theme_demo"

--- 挂主菜单项（由 BookPlugin:addToMainMenu 转发）：设置页紧跟「月读」（book_library）。
--- KOReader 先收集各插件菜单项再按 menu_order 排序，所以在这里改顺序表来得及。
---@param menu_items table KOReader 主菜单项表（就地写入）
function Demo.addToMainMenu(menu_items)
    menu_items[MENU_ID] = {
        text = "主题组件演示",
        sorting_hint = "setting",
        callback = Demo.open,
    }
    for _idx, modname in ipairs({ "ui/elements/filemanager_menu_order", "ui/elements/reader_menu_order" }) do
        local order = require(modname).setting
        local at
        for i, id in ipairs(order) do
            if id == MENU_ID then at = nil break end
            if id == "book_library" then at = i + 1 end
        end
        if at then table.insert(order, at, MENU_ID) end
    end
end

return Demo
