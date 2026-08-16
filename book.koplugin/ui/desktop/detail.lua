--[[--
书籍详情：Material 返回顶栏 + 书籍信息（hero，点按开始阅读）+ 阅读情况 + 底部动作行
  单页，禁止 ScrollableContainer；「最近几天」用 Pager 分页，不做高度裁剪。
  书城书（zlib）未入库：无编辑/统计，hero 不显示简介摘要与进度，完整简介直下，
  底部只留「加入书库」。

布局：
  +-----------------------------------------------+
  | ← 返回                                        | 自绘顶栏 + 通栏底线
  |-----------------------------------------------|
  | +----+  书名                                  |
  | |封面|  作者          ← 点按开始阅读           | BookInfo.hero（正常展示：
  | +----+  分类 · 系列 / 简介摘要 / 进度条        |   详情都在这张卡里）
  |-----------------------------------------------|
  | +---------+ +---------+ +---------+           |
  | | 累计时长 | | 已读页数 | | 上次阅读 |           | KPI 卡片
  | +---------+ +---------+ +---------+           |
  | 最近几天（平铺，无卡片）                        |
  | 08-15  ========····  42分钟                    |
  | 08-14  ====········  25分钟                    |
  |           |«  ‹  1/3  ›  »|                   | Pager（>1 页才出现）
  |-----------------------------------------------|
  | [✏ 编辑]  [🔍 刮削]  [▶ 继续阅读]              | 等宽图标 chip（不加粗）
  +-----------------------------------------------+

@module koplugin.book.ui.detail
--]]

local Blitbuffer = require("ffi/blitbuffer")
local ButtonTable = require("ui/widget/buttontable")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TopContainer = require("ui/widget/container/topcontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local TextWidget = require("ui/widget/textwidget")
local BookInfo = require("ui.components.bookinfo")
local Icon = require("ui.components.icon")
local Pager = require("ui.components.pager")
local LocalMapper = require("source.local.mapper")
local UI = require("ui.components.bookui")
local Text = require("utils.text")
local _ = require("gettext")
local Screen = Device.screen

local Detail = InputContainer:extend{
    name = "book_detail",
    covers_fullscreen = true,
    book = nil,
    plugin = nil,
    source = nil,
    desktop = nil,
}

--- 小节标题（书城书的简介用）。
---@param text string
---@param width number
---@return table
local function sectionTitle(text, width)
    return LeftContainer:new{
        dimen = Geom:new{ w = width, h = UI.sz(30) },
        TextWidget:new{
            text = text,
            face = UI.face("cfont", 15),
            fgcolor = Blitbuffer.COLOR_BLACK,
        },
    }
end

--- 动作 chip：等宽描边按钮，Material 图标 + 文案（不加粗），整颗可点。
---@param w number
---@param h number
---@param icon string Material Icons 原名
---@param text string
---@param on_tap fun()
---@return table
local function actionChip(w, h, icon, text, on_tap)
    local border = UI.line()
    local tap = BookInfo.tappable(w, h, on_tap)
    tap[1] = FrameContainer:new{
        bordersize = border,
        color = UI.rule(),
        padding = 0,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        dimen = Geom:new{ w = w, h = h },
        CenterContainer:new{
            dimen = Geom:new{ w = w - border * 2, h = h - border * 2 },
            Icon.label{
                name = icon,
                text = text,
                direction = "row",
                size = 18,
                font_size = 14,
                gap = UI.sz(6),
                max_width = w - border * 2 - UI.sz(16),
            },
        },
    }
    return tap
end

--- KPI 卡片：描边白底，上值下标签。
---@param w number
---@param value string
---@param label string
---@return table, number 卡片 widget 与其高度
local function kpiCard(w, value, label)
    local pad = UI.sz(10)
    local border = UI.line()
    local inner_w = math.max(1, w - (pad + border) * 2)
    local value_w = TextWidget:new{
        text = value,
        face = UI.face("cfont", 16),
        max_width = inner_w,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    local label_w = TextWidget:new{
        text = label,
        face = UI.face("xx_smallinfofont", 11),
        max_width = inner_w,
        fgcolor = UI.muted(),
    }
    local h = pad * 2 + border * 2 + value_w:getSize().h + UI.sz(4) + label_w:getSize().h
    local card = FrameContainer:new{
        bordersize = border,
        color = UI.rule(),
        padding = pad,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        dimen = Geom:new{ w = w, h = h },
        CenterContainer:new{
            dimen = Geom:new{ w = inner_w, h = h - (pad + border) * 2 },
            VerticalGroup:new{
                align = "center",
                value_w,
                VerticalSpan:new{ width = UI.sz(4) },
                label_w,
            },
        },
    }
    return card, h
end

--- 初始化全屏尺寸、返回键，rebuild 并拉本机阅读统计。
function Detail:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    if Device:hasKeys() then
        self.key_events = {
            Close = { { Device.input.group.Back } },
        }
    end
    self:rebuild()
    self:fetchStats()
    if self.book and self.book.ref and self.book.ref.source_id == "zlib" then
        self._store_detail_job = require("zlib.init").getDetailAsync(self.book, function(detail)
            self._store_detail_job = nil
            if self._closed or not detail then return end
            self.book = detail
            self:rebuild()
            require("ui/uimanager"):setDirty(self, "full")
        end)
    end
end

--- 返回详情页尺寸。
---@return table
function Detail:getSize()
    return self.dimen
end

--- 顶栏：Material 返回箭头 +「返回」（贴左）+ 通栏底线。
--- TitleBar 只认 KOReader svg 图标，塞不进 Material 字体图标，故自绘。
--- 热区按内容实际宽度算：固定宽度 + CenterContainer 会让内容溢出
--- （图标越过左对齐线、文字右半在热区外点不到）。
---@param w number
---@return table, number 顶栏 widget 与其高度
function Detail:buildTopBar(w)
    local pad = UI.pagePad()
    local bar_h = UI.sz(48)
    local label = Icon.label{ name = "arrow_back", size = 24, text = _("返回") }
    local back_w = label:getSize().w + UI.sz(12)
    local back = BookInfo.tappable(back_w, bar_h, function()
        self:onClose()
    end)
    back[1] = LeftContainer:new{
        dimen = Geom:new{ w = back_w, h = bar_h },
        label,
    }
    local line_h = UI.line()
    local bar = FrameContainer:new{
        bordersize = 0,
        padding = 0,
        background = Blitbuffer.COLOR_WHITE,
        dimen = Geom:new{ w = w, h = bar_h + line_h },
        VerticalGroup:new{
            align = "left",
            HorizontalGroup:new{
                HorizontalSpan:new{ width = pad },
                back,
            },
            LineWidget:new{
                background = UI.rule(),
                dimen = Geom:new{ w = w, h = line_h },
            },
        },
    }
    return bar, bar_h + line_h
end

--- 异步拉本机阅读统计（汇总 + 最近 N 天），完成后重建阅读情况区。
--- 书城书（zlib）未读过，无本机数据可查，直接跳过。
---@return nil
function Detail:fetchStats()
    local ref = self.book and self.book.ref
    if type(ref) ~= "table" or type(ref.source_id) ~= "string" or type(ref.stable_id) ~= "string" then
        return
    end
    if ref.source_id == "zlib" then
        return
    end
    local stats, daily
    require("utils.db.queue").run(function()
        local StatsDB = require("utils.db.stats")
        stats = StatsDB.summaryByBook(ref.source_id, ref.stable_id)
        daily = StatsDB.dailyByBook(ref.source_id, ref.stable_id, 30)
    end, {
        on_done = function()
            if self._closed then
                return
            end
            self._stats = stats
            self._daily = daily
            self:rebuild()
            require("ui/uimanager"):setDirty(self, "full")
        end,
    })
end

--- 关闭详情并强制重绘下层桌面。
---@return boolean
function Detail:onClose()
    self._closed = true
    if self._store_detail_job and self._store_detail_job.cancel then self._store_detail_job.cancel() end
    if self._install_job and self._install_job.cancel then self._install_job.cancel() end
    self._store_detail_job, self._install_job = nil, nil
    local UIManager = require("ui/uimanager")
    local desk = self.desktop
    UIManager:close(self)
    -- 全屏详情盖住桌面，关掉后必须强制重绘下层，否则残影/白板
    UIManager:nextTick(function()
        if desk and not desk._closed then
            UIManager:setDirty(desk, "full")
        else
            UIManager:setDirty("all", "full")
        end
    end)
    return true
end

--- 刮削/编辑结束后重读 books 行并重绘：元数据与封面都只在 rebuild 时取，
--- 光 setDirty 只会把旧数据再画一遍。
--- 走到这说明底层数据已变，打脏标记，关闭详情时桌面要清缓存重建而不是纯重绘。
function Detail:reload()
    self._dirty = true
    local ref = self.book.ref
    local row
    require("utils.db.queue").run(function()
        row = require("utils.db.book").get(ref.source_id, ref.stable_id)
    end, {
        on_done = function()
            if self._closed then
                return
            end
            if row then
                row.ref = self.book.ref
                self.book = row
            end
            self:rebuild()
            require("ui/uimanager"):setDirty(self, "full")
        end,
    })
end

--- Widget 关闭时触发 close_callback。
function Detail:onCloseWidget()
    self._closed = true
    local cb = self.close_callback
    self.close_callback = nil
    if cb then
        cb()
    end
end

--- 点按书籍信息 / 底部「继续阅读」开始阅读。
---@return nil
function Detail:openBook()
    local plugin = self.plugin
    local b = self.book
    self:onClose()
    if plugin and plugin.openBook then plugin:openBook(b) end
end

--- 书城书「加入书库」：无凭据先开设置；否则弹进度条下载并导入当前源。
---@return nil
function Detail:installStoreBook()
    local book = self.book or {}
    if self._install_job then
        return
    end
    if not require("zlib.init").hasCredentials() then
        require("zlib.setting").open(self.plugin)
        return
    end
    local ProgressbarDialog = require("ui/widget/progressbardialog")
    local UIManager = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")
    local dialog = ProgressbarDialog:new{
        title = _("正在加入书库…"),
        subtitle = book.title,
        progress_max = tonumber(book.filesize),
        dismissable = false,
    }
    dialog:show()
    require("ui/network/manager"):runWhenOnline(function()
        if self._closed then dialog:close(); return end
        self._install_job = require("zlib.init").installAsync(self.source, book, function(bytes)
            dialog:reportProgress(bytes)
        end, function(ok, err, filename)
            self._install_job = nil
            dialog:close()
            if self._closed then return end
            if not ok then
                UIManager:show(InfoMessage:new{ text = err or _("下载失败") })
                return
            end
            local desk = self.desktop
            self:onClose()
            UIManager:show(InfoMessage:new{
                text = _("已加入书库：") .. tostring(filename or book.title),
                timeout = 3,
            })
            if desk and not desk._closed then
                desk._library_state = nil
                desk.page = 1
                desk:switchTab("library")
            end
        end)
    end)
end

--- 启动刮削（底部按钮入口，条件与原底部按钮一致）。
---@return nil
function Detail:startScrape()
    local ref = self.book and self.book.ref
    if type(ref) ~= "table" then
        return
    end
    require("scrape.ui").start(ref, self.book.title, function()
        self:reload()
    end)
end

--- 编辑元信息对话框（书名/作者/分类/系列）。
---@return nil
function Detail:openEditor()
    local book = self.book or {}
    if type(book.ref) ~= "table" then
        return
    end
    local UIManager = require("ui/uimanager")
    local MultiInputDialog = require("ui/widget/multiinputdialog")
    local dialog
    dialog = MultiInputDialog:new{
        title = _("编辑元信息"),
        fields = {
            { text = book.title or "", hint = _("书名") },
            { text = BookInfo.author(book), hint = _("作者") },
            { text = book.category or "", hint = _("分类") },
            { text = book.series or "", hint = _("系列") },
        },
        buttons = { {
            {
                text = _("取消"),
                id = "close",
                callback = function()
                    UIManager:close(dialog)
                end,
            },
            {
                text = _("保存"),
                is_enter_default = true,
                callback = function()
                    local fields = dialog:getFields()
                    UIManager:close(dialog)
                    self:saveMeta(fields)
                end,
            },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--- 保存编辑结果到 books 表（进度/收藏/简介/md5 保留），完成后 reload 重绘。
--- 本地源：分类/系列即目录层级，改动会移动文件、stable_id 跟着变
---（opens/reading_stats/pending_progress 由 moveBook 里的 renameStableId 迁移）。
---@param fields table 对话框字段值：书名/作者/分类/系列
---@return nil
function Detail:saveMeta(fields)
    local ref = self.book and self.book.ref
    if type(ref) ~= "table" or type(fields) ~= "table" then
        return
    end
    --- 空串归一为 nil：空标题才能回退 stable_id 显示
    ---@param s any
    ---@return string|nil
    local function nonempty(s)
        s = Text.trim(type(s) == "string" and s or "")
        return s ~= "" and s or nil
    end
    local title = nonempty(fields[1])
    local authors = nonempty(fields[2])
    local category = nonempty(fields[3])
    local series = nonempty(fields[4])
    local can_move = ref.source_id == "local"
        and self.source ~= nil and self.source.id == "local"
        and type(self.source.moveBook) == "function"
    if can_move and not category then
        series = nil -- 本地源系列必须挂在分类下，与扫盘派生语义一致
    end
    local move_err, new_stable_id
    require("utils.db.queue").run(function()
        if can_move then
            local moved, err = self.source:moveBook(ref.stable_id, category, series)
            if not moved then
                move_err = err
                return
            end
            new_stable_id = moved
        end
        local sid = new_stable_id or ref.stable_id
        local BookDB = require("utils.db.book")
        local existing = BookDB.get(ref.source_id, sid)
        BookDB.upsert({
            source_id = ref.source_id,
            stable_id = sid,
            title = title,
            authors = authors,
            category = category,
            series = series,
            intro = existing and existing.intro or nil,
            percent = existing and existing.percent or 0,
            favorite = existing and existing.favorite or nil,
            md5 = existing and existing.md5 or nil,
            fetched_at = os.time(),
        })
    end, {
        on_done = function()
            if self._closed then
                return
            end
            local UIManager = require("ui/uimanager")
            local InfoMessage = require("ui/widget/infomessage")
            if move_err then
                UIManager:show(InfoMessage:new{ text = move_err, timeout = 2 })
                return
            end
            if new_stable_id and new_stable_id ~= ref.stable_id and self.book then
                self.book.ref = { source_id = ref.source_id, stable_id = new_stable_id }
            end
            self:reload()
            UIManager:show(InfoMessage:new{
                text = _("元数据已更新"),
                timeout = 1.5,
            })
        end,
    })
end

--- 最近几天（平铺，无卡片壳）+ Pager：行高固定，按可用高度定每页行数，翻页只重建本区。
---@param w number
---@param avail_h number
---@return table|nil, number 区块 widget 与实占高度；放不下返回 nil, 0
function Detail:buildRecent(w, avail_h)
    local daily = self._daily or {}
    if #daily == 0 then
        return nil, 0
    end
    local row_h = UI.sz(22)
    local row_gap = UI.sz(8)
    local header = TextWidget:new{
        text = _("最近几天"),
        face = UI.face("xx_smallinfofont", 12),
        fgcolor = UI.muted(),
    }
    local fixed_h = header:getSize().h + row_gap
    local pager_h = UI.iconSz() + UI.sz(12)

    --- 预算内能放的行数。
    local function rowsFit(budget)
        return math.floor((budget - fixed_h) / (row_h + row_gap))
    end

    local per = rowsFit(avail_h)
    if per < 1 then
        return nil, 0
    end
    local show_pager = #daily > per
    if show_pager then
        per = math.max(1, rowsFit(avail_h - pager_h))
    end
    per = math.min(per, #daily)
    local page, pages = Pager.clamp(self._daily_page, math.ceil(#daily / per))
    self._daily_page = page

    -- 条形按全部天数里最大当天时长归一
    local max_s = 0
    for _, r in ipairs(daily) do
        if r.seconds > max_s then max_s = r.seconds end
    end
    local date_w = UI.sz(52)
    local dur_w = UI.sz(64)
    local bar_w = math.max(1, w - date_w - dur_w - row_gap * 2)
    local kids = VerticalGroup:new{ align = "left", header }
    for i = (page - 1) * per + 1, math.min(#daily, page * per) do
        local r = daily[i]
        local _y, m, d = tostring(r.ymd):match("^(%d+)%-(%d+)%-(%d+)$")
        table.insert(kids, VerticalSpan:new{ width = row_gap })
        table.insert(kids, HorizontalGroup:new{
            align = "center",
            LeftContainer:new{
                dimen = Geom:new{ w = date_w, h = row_h },
                TextWidget:new{
                    text = (m and d) and (m .. "-" .. d) or tostring(r.ymd),
                    face = UI.face("xx_smallinfofont", 12),
                    fgcolor = UI.muted(),
                },
            },
            HorizontalSpan:new{ width = row_gap },
            UI.progressBar(bar_w, UI.sz(6), max_s > 0 and (r.seconds / max_s * 100) or 0),
            HorizontalSpan:new{ width = row_gap },
            LeftContainer:new{
                dimen = Geom:new{ w = dur_w, h = row_h },
                TextWidget:new{
                    text = LocalMapper.formatDuration(r.seconds),
                    face = UI.face("xx_smallinfofont", 12),
                    fgcolor = Blitbuffer.COLOR_BLACK,
                },
            },
        })
    end

    local used = kids:getSize().h
    if show_pager then
        --- 翻页：改页码重建。
        ---@param p number
        local function goto2(p)
            self._daily_page = p
            self:rebuild()
            require("ui/uimanager"):setDirty(self, "ui")
        end
        local pager = Pager.widget(page, pages, {
            on_first = function() goto2(1) end,
            on_prev = function() goto2(page - 1) end,
            on_next = function() goto2(page + 1) end,
            on_last = function() goto2(pages) end,
        }, w)
        table.insert(kids, VerticalSpan:new{ width = UI.sz(4) })
        table.insert(kids, CenterContainer:new{
            dimen = Geom:new{ w = w, h = pager:getSize().h },
            pager,
        })
        used = used + UI.sz(4) + pager:getSize().h
    end
    return kids, used
end

--- 阅读情况区：KPI 卡片三列 + 最近几天（平铺分页）；无本机记录时单行占位。
---@param w number
---@param avail_h number
---@return table
function Detail:buildStatsArea(w, avail_h)
    local st = self._stats
    if not st or st.pages <= 0 then
        return TextWidget:new{
            text = _("暂无阅读记录"),
            face = UI.face("xx_smallinfofont", 13),
            max_width = w,
            fgcolor = UI.muted(),
        }
    end

    local gap = UI.sz(10)
    local items = {
        { LocalMapper.formatDuration(st.total_seconds), _("累计时长") },
        { tostring(st.pages), _("已读页数") },
        { st.last_read > 0 and os.date("%Y-%m-%d", st.last_read) or "—", _("上次阅读") },
    }
    local cell_w = math.floor((w - gap * 2) / 3)
    local kpi_row = HorizontalGroup:new{ align = "center" }
    local kpi_h = 0
    for i, item in ipairs(items) do
        if i > 1 then
            table.insert(kpi_row, HorizontalSpan:new{ width = gap })
        end
        local card, card_h = kpiCard(cell_w, item[1], item[2])
        kpi_h = math.max(kpi_h, card_h)
        table.insert(kpi_row, card)
    end
    local kids = VerticalGroup:new{ align = "left", kpi_row }

    local recent, _recent_h = self:buildRecent(w, avail_h - kpi_h - gap)
    if recent then
        table.insert(kids, VerticalSpan:new{ width = gap })
        table.insert(kids, recent)
    end
    return kids
end

--- 重建书籍信息、阅读情况卡片与底部动作行。
function Detail:rebuild()
    local book = self.book or {}
    local w = Screen:getWidth()
    local h = Screen:getHeight()
    local pad = UI.pagePad()
    local content_w = w - pad * 2

    local store_book = book.ref and book.ref.source_id == "zlib"
    local caps = self.source and self.source:capabilities() or {}
    local can_scrape = caps.scrape == true and type(book.ref) == "table"
        and type(book.ref.source_id) == "string" and type(book.ref.stable_id) == "string"
    local can_read = not store_book and self.source ~= nil
        and (self.source.type == "book"
            or self.source.type == "online"
            or self.source.type == "article")

    local title_bar, title_h = self:buildTopBar(w)

    -- 底部动作行：书城书只有「加入书库」（ButtonTable，有禁用态）；
    -- 库内书是等宽图标 chip：编辑 / 刮削? / 继续阅读
    local footer_pad_v = UI.sz(12)
    local footer, footer_h
    if store_book then
        footer = ButtonTable:new{
            width = content_w,
            buttons = { {
                {
                    text = _("加入书库"),
                    font_size = UI.buttonFontSize(),
                    enabled = type(self.source and self.source.importBookAsync) == "function",
                    callback = function()
                        self:installStoreBook()
                    end,
                },
            } },
            zero_sep = true,
            show_parent = self,
        }
        footer_h = footer:getSize().h + footer_pad_v * 2
    else
        local defs = {
            { icon = "edit", text = _("编辑"), fn = function()
                self:openEditor()
            end },
        }
        if can_scrape then
            table.insert(defs, { icon = "search", text = _("刮削"), fn = function()
                self:startScrape()
            end })
        end
        if can_read then
            local pct = BookInfo.pct(book)
            table.insert(defs, {
                icon = "play_arrow",
                text = pct > 0 and pct < 100 and _("继续阅读") or _("开始阅读"),
                fn = function()
                    self:openBook()
                end,
            })
        end
        local btn_h = UI.sz(44)
        local btn_gap = UI.sz(10)
        local cell_w = math.floor((content_w - btn_gap * (#defs - 1)) / #defs)
        local row = HorizontalGroup:new{ align = "center" }
        for i, def in ipairs(defs) do
            if i > 1 then
                table.insert(row, HorizontalSpan:new{ width = btn_gap })
            end
            table.insert(row, actionChip(cell_w, btn_h, def.icon, def.text, def.fn))
        end
        footer = row
        footer_h = btn_h + footer_pad_v * 2
    end

    local body_h = math.max(UI.sz(80), h - title_h - footer_h)
    local body_inner_h = math.max(UI.sz(60), body_h - pad - UI.sz(12))

    -- 顶部：书籍信息英雄卡（封面 / 书名 / 作者 / 分类·系列 / 简介摘要 / 进度条）
    local category = book.category
    if type(category) == "string" and category ~= "" then
        category = category:gsub("[,\n]+", " · ")
    else
        category = nil
    end
    local subtitle_parts = {}
    if category then
        subtitle_parts[#subtitle_parts + 1] = category
    end
    if type(book.series) == "string" and book.series ~= "" then
        subtitle_parts[#subtitle_parts + 1] = book.series
    end
    local hero_opts = {
        width = content_w,
        pad = 0,
        subtitle = #subtitle_parts > 0 and table.concat(subtitle_parts, " · ") or nil,
        on_tap = can_read and function()
            self:openBook()
        end or nil,
        show_parent = self,
    }
    if store_book then
        -- 书城书：0% 进度条无意义；简介摘要让位给下方完整简介
        hero_opts.show_progress = false
        hero_opts.show_desc = false
    end
    local hero, hero_h = BookInfo.hero(self.plugin, self.source, book, hero_opts)

    local gap = UI.sz(12)
    local body_kids = { align = "left", hero }

    if store_book then
        -- 书城书：完整简介吃剩余高度
        local desc = BookInfo.desc(book)
        if desc ~= "" then
            local avail = math.max(UI.sz(40), body_inner_h - hero_h - gap - UI.sz(30) - UI.sz(6))
            table.insert(body_kids, VerticalSpan:new{ width = gap })
            table.insert(body_kids, sectionTitle(_("简介"), content_w))
            table.insert(body_kids, VerticalSpan:new{ width = UI.sz(6) })
            table.insert(body_kids, TextBoxWidget:new{
                text = desc,
                face = UI.face("xx_smallinfofont", 14),
                width = content_w,
                height = avail,
                alignment = "left",
                fgcolor = UI.muted(),
            })
        end
    else
        table.insert(body_kids, VerticalSpan:new{ width = gap })
        table.insert(body_kids, self:buildStatsArea(content_w, body_inner_h - hero_h - gap))
    end

    local root_kids = {
        align = "left",
        title_bar,
        FrameContainer:new{
            bordersize = 0,
            padding = pad,
            padding_top = UI.sz(12),
            background = Blitbuffer.COLOR_WHITE,
            dimen = Geom:new{ w = w, h = body_h },
            -- 顶对齐：内容都是满宽的，水平居中无视觉效果；
            -- 用 LeftContainer 会在内容不足时垂直居中（残影式的“飘在��间”）
            TopContainer:new{
                dimen = Geom:new{ w = content_w, h = body_inner_h },
                VerticalGroup:new(body_kids),
            },
        },
        FrameContainer:new{
            bordersize = 0,
            padding = pad,
            padding_top = footer_pad_v,
            padding_bottom = footer_pad_v,
            background = Blitbuffer.COLOR_WHITE,
            dimen = Geom:new{ w = w, h = footer_h },
            footer,
        },
    }

    self[1] = FrameContainer:new{
        bordersize = 0,
        padding = 0,
        background = Blitbuffer.COLOR_WHITE,
        dimen = Geom:new{ w = w, h = h },
        VerticalGroup:new(root_kids),
    }
    self.dimen = Geom:new{ x = 0, y = 0, w = w, h = h }
end

return Detail
