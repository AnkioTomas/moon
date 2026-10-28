--[[--
拷贝漫画数据源门面。

书架是收藏列表：删除 = 查 comic_id 再取消收藏，交给 Shelf.pushDeletes；没有加架上行。进度双向（章粒度），无笔记、统计。
一章是一组图片 URL，章节 CBZ 按章节 uuid 命名（分组拼接后章号会整体后移）。重登后用最新 token。

@module koplugin.book.source.copymanga
--]]

local Browse = require("source.browse")
local Client = require("source.copymanga.client")
local Mapper = require("source.copymanga.mapper")
local SourceBase = require("source.base")
local Shelf = require("source.shelf")
local Toc = require("source.toc")
local logger = require("utils.log")
local _ = require("gettext")
local T = require("ffi/util").template

local Copymanga = {}

---@return BookSourceMeta
function Copymanga.meta()
    return { id = "copymanga", name = _("拷贝漫画"), type = "chapter" }
end

---@class CopymangaSource : SourceBase
---@field _client CopymangaClient
local Source = setmetatable({}, { __index = SourceBase })
Source.__index = Source

---@return CopymangaSource
function Copymanga.new()
    local cfg = require("utils.settings").getSource("copymanga")
    local meta = Copymanga.meta()
    return setmetatable({
        id = meta.id,
        name = meta.name,
        type = meta.type,
        _client = Client:new(cfg),
    }, Source)
end

---@return boolean
function Source:configured()
    return self._client:configured()
end

--- 云端取消收藏一本：先查 comic_id 再 setCollect(false)。
---@param self CopymangaSource
---@param stable_id string
---@param done fun(ok: any)
---@return { cancel: fun() }
local function removeCollect(self, stable_id, done)
    local job
    job = self._client:detailAsync(stable_id, function(wire)
        local comic_id = wire and Mapper.comicId(wire)
        if not comic_id then
            done(false)
            return
        end
        job = self._client:setCollectAsync(comic_id, false, done)
    end)
    return { cancel = function() job.cancel() end }
end

--- 书架是收藏列表，没有加架上行：先推本地删除，再拉收藏对账。
---@param opts { dirty_only?: boolean, force?: boolean, on_progress?: fun(text: string|nil, done: integer|nil, total: integer|nil) }|nil
---@param cb fun(result: SyncResult|nil, err: any)
---@return { cancel: fun() }
function Source:syncBooksAsync(opts, cb)
    opts = opts or {}
    if not require("source.copymanga.auth").hasSession() then
        return SourceBase.syncBooksAsync(self, opts, cb)
    end
    local report = opts.on_progress or function(...) end
    local function removeOne(stable_id, done) return removeCollect(self, stable_id, done) end
    if opts.dirty_only then
        return Shelf.pushDeletes(self.id, removeOne, report, function(pushed)
            cb({ pulled = 0, pushed = pushed, hidden = 0, conflicts = 0, skipped = false })
        end)
    end
    local cancelled, job, delete_job = false, nil, nil
    delete_job = Shelf.pushDeletes(self.id, removeOne, report, function(pushed)
        if cancelled then return end
        report(_("正在拉取书架…"))
        job = self._client:collectAllAsync(function(rows, err)
            if cancelled then return end
            if not rows then
                cb(nil, err)
                return
            end
            local books = Mapper.collect(rows)
            report(T(_("正在写入书架（%1 本）"), #books))
            local result, rerr = Shelf.reconcile(self.id, books)
            if result then result.pushed = pushed end
            cb(result, rerr)
        end)
    end)
    return { cancel = function()
        cancelled = true
        delete_job.cancel()
        if job then job.cancel() end
    end }
end

---@param client CopymangaClient
---@param stable_id string
---@param groups { path_word: string, name: string }[]
---@param cb fun(chapters: BookChapter[]|nil, err: string|nil)
---@return { cancel: fun() }
local function loadChapters(client, stable_id, groups, cb)
    return client:chaptersAsync(stable_id, groups, function(rows, err)
        if not rows then cb(nil, err); return end
        local chapters = Mapper.chapters(rows)
        if not chapters then cb(nil, _("漫画目录为空")); return end
        cb(chapters)
    end)
end

--- 绕过缓存拉目录并写回。
---@param self CopymangaSource
---@param identity BookIdentity
---@param cb fun(toc: BookChapter[]|nil, err: string|nil)
---@return { cancel: fun() }
local function fetchTocAsync(self, identity, cb)
    local cancelled, job = false, nil
    job = self._client:detailAsync(identity.stable_id, function(wire, err)
        if cancelled then return end
        if not wire then cb(nil, err); return end
        job = loadChapters(self._client, identity.stable_id, Mapper.groups(wire), function(chapters, chapter_err)
            if cancelled then return end
            if not chapters then cb(nil, chapter_err); return end
            if not Toc.put(identity.source_id, identity.stable_id, chapters) then
                cb(nil, _("漫画目录保存失败"))
                return
            end
            cb(chapters)
        end)
    end)
    return { cancel = function()
            cancelled = true
            job.cancel()
        end }
end

--- 书城搜索：回包形状同 listStoreAsync。
---@param keyword string
---@param cb fun(res: { data: Book[] }|nil, err: string|nil)
---@return { cancel: fun() }|nil
function Source:searchAsync(keyword, cb)
    return self._client:searchAsync(keyword, function(wire, err)
        if not wire then
            cb(nil, err)
            return
        end
        cb({ data = Mapper.search(wire) })
    end)
end


-- 官网「查看全部分類」的题材（接口 filter/comic/tags 只回前 20 个，其余题材同样可查）；漫展场次标签不收。
local THEMES = {
    { "aiqing", "愛情" }, { "huanlexiang", "歡樂向" }, { "maoxian", "冒險" }, { "qihuan", "奇幻" },
    { "baihe", "百合" }, { "xiaoyuan", "校园" }, { "kehuan", "科幻" }, { "dongfang", "東方" },
    { "danmei", "耽美" }, { "gedou", "格鬥" }, { "teenslove", "TL" }, { "shenghuo", "生活" },
    { "qingxiaoshuo", "轻小说" }, { "xuanyi", "悬疑" }, { "mengxi", "萌系" }, { "shengui", "神鬼" },
    { "zhichang", "职场" }, { "zhiyu", "治愈" }, { "jiecao", "节操" }, { "sige", "四格" },
    { "gaoxiao", "搞笑" }, { "changtiao", "長條" }, { "jingji", "竞技" }, { "mohuan", "魔幻" },
    { "jianniang", "舰娘" }, { "weiniang", "伪娘" }, { "rexue", "热血" }, { "jingsong", "惊悚" },
    { "meishi", "美食" }, { "xingzhuanhuan", "性转换" }, { "lizhi", "励志" }, { "hougong", "後宮" },
    { "yinyuewudao", "音乐舞蹈" }, { "zhentan", "侦探" }, { "COLOR", "彩色" }, { "aa", "AA" },
    { "yishijie", "异世界" }, { "lishi", "历史" }, { "chuanyue", "穿越" }, { "jizhan", "机战" },
    { "zhanzheng", "战争" }, { "dushi", "都市" }, { "chongsheng", "重生" }, { "kongbu", "恐怖" },
    { "shengcun", "生存" }, { "wuxia", "武侠" }, { "zhaixi", "宅系" }, { "zhuansheng", "转生" },
    { "fate", "FATE" }, { "Uncensored", "無修正" }, { "xianxia", "仙侠" }, { "loveLive", "LoveLive" },
    { "zazhifuzengxiezhenji", "雜誌附贈寫真集" }, { "qita", "其他" },
}

local PERIODS = { { "day", _("日榜") }, { "week", _("周榜") }, { "month", _("月榜") }, { "total", _("总榜") } }
local AUDIENCES = { { "all", _("全部") }, { "male", _("男频") }, { "female", _("女频") } }

--- 书城浏览：节点 `周期:受众`（缺省 day:all，每页 20 部）或 `theme:<题材>`（按人气）。
--- 书城 chip 最多两行：第一行周期，第二行受众 + 题材（放不下的折进「更多」）；选题材后周期 / 受众不高亮，点回去就是榜单。
---@param opts { node?: string, limit?: integer }
---@param cb fun(res: { data: Book[], groups: StoreChipGroup[] }|nil, err: string|nil)
---@return { cancel: fun() }
function Source:browseAsync(opts, cb)
    local node = opts.node or "day:all"
    local theme = node:match("^theme:(.+)$")
    local period, audience = node:match("^(%a+):(%a+)$")
    if theme then period, audience = "day", "all" end
    local periods, filters = {}, {}
    for _idx, row in ipairs(PERIODS) do periods[#periods + 1] = { id = row[1] .. ":" .. audience, title = row[2] } end
    for _idx, row in ipairs(AUDIENCES) do filters[#filters + 1] = { id = period .. ":" .. row[1], title = row[2] } end
    for _idx, row in ipairs(THEMES) do filters[#filters + 1] = { id = "theme:" .. row[1], title = row[2] } end
    local groups = { Browse.group(periods, node), Browse.group(filters, node) }
    return Browse.pages(function(page, done)
        local function finish(wire, err)
            if not wire then
                done(nil, err)
                return
            end
            done(Mapper.search(wire))
        end
        local offset = (page - 1) * 20
        if theme then
            return self._client:themeAsync(theme, offset, finish)
        end
        return self._client:rankAsync(period, audience ~= "all" and audience or nil, offset, finish)
    end, opts.limit or 60, groups, cb)
end

function Source:getDetailAsync(identity, cb)
    local cancelled, job = false, nil
    job = self._client:detailAsync(identity.stable_id, function(wire, err)
        if cancelled then return end
        if not wire then cb(nil, err); return end
        local book = Mapper.detail(wire)
        if not book then cb(nil, _("漫画详情解析失败")); return end
        local existing = require("book.books_db").get(self.id, identity.stable_id)
        if existing then
            book.deleted = existing.deleted
        end
        local progress = require("book.progress_db").get(self.id, identity.stable_id)
        if progress then
            book.percent = require("book.progress").clampPercent(progress.fraction, false, true)
        end
        local function finish()
            require("book.store").rememberMany({ book })
            cb(book)
        end
        if Toc.read(self.id, identity.stable_id) then
            finish()
            return
        end
        -- 顺手预热目录：详情回包里已有分组，省一次 comic2。
        job = loadChapters(self._client, identity.stable_id, Mapper.groups(wire), function(chapters)
            if cancelled then return end
            if chapters and not Toc.put(self.id, identity.stable_id, chapters) then
                logger.warn("copymanga toc persist failed", identity.stable_id)
            end
            finish()
        end)
    end)
    return { cancel = function()
            cancelled = true
            job.cancel()
        end }
end

function Source:loadTocAsync(identity, cb)
    local cached = Toc.read(identity.source_id, identity.stable_id)
    if cached and #cached > 0 then
        return SourceBase.defer(cb, cached)
    end
    return fetchTocAsync(self, identity, cb)
end

--- 不看 TTL 的目录：离线打开已下载章节用，过期目录也能把章号换成 uuid。
---@param identity BookIdentity
---@return BookChapter[]|nil
local function anyToc(identity)
    local toc = Toc.read(identity.source_id, identity.stable_id)
    if toc then return toc end
    local payload = require("book.books_db").getToc(identity.source_id, identity.stable_id)
    -- 坏 JSON 等同没有目录，走联网重拉。
    local ok, list = pcall(require("json").decode, payload or "")
    return ok and type(list) == "table" and #list > 0 and list or nil
end

--- 起始章：显式章号 > 本地进度章号 > 本地进度全书比例 > 第一章。
---@param identity BookIdentity
---@param opts table
---@param toc BookChapter[]
---@return integer
local function startIndex(identity, opts, toc)
    local idx = opts.chapter_idx
    if not idx then
        local pending = require("book.progress_db").get(identity.source_id, identity.stable_id)
        idx = pending and (pending.chapter_idx or math.floor(pending.fraction * #toc) + 1)
    end
    return math.max(1, math.min(#toc, idx or 1))
end

---@param identity BookIdentity
---@param opts table|nil
---@param cb fun(path: string|nil, err: string|nil)
---@return { cancel: fun() }
function Source:openBookAsync(identity, opts, cb)
    opts = opts or {}
    local Chapter = require("source.copymanga.chapter")
    local function finish(path, idx)
        local ok, err = require("book.store").touch(path, identity, {
            chapter_idx = idx,
            book = identity.book,
        })
        cb(ok and path or nil, err)
    end

    -- 已下载章节直接交给阅读器；这条路径不能先经过联网门控。
    local toc = anyToc(identity)
    if toc then
        local idx = startIndex(identity, opts, toc)
        local path = Chapter.existing(identity, toc[idx])
        if path then return SourceBase.defer(finish, path, idx) end
    end
    if not require("ui/network/manager"):isConnected() then
        return SourceBase.defer(cb, nil, _("网络不可用，请先连接 Wi-Fi"))
    end

    local cancelled, active, dialog = false, nil, nil
    local function closeDialog()
        if dialog then dialog:close(); dialog = nil end
    end
    require("ui/uimanager"):nextTick(function()
        if cancelled then return end
        dialog = require("ui.themes.widgets.progress_dialog"):new{
            title = identity.book and identity.book.title or identity.stable_id,
            dismissable = false,
        }
        dialog:show()
        dialog:set(_("正在准备漫画…"))
        active = self:loadTocAsync(identity, function(fresh, err)
            active = nil
            if cancelled then return end
            if not fresh then closeDialog(); cb(nil, err); return end
            local idx = startIndex(identity, opts, fresh)
            active = Chapter.materializeAsync(self._client, identity, fresh[idx],
                function(done, total)
                    if dialog and total > 0 then dialog:update(_("正在准备漫画…"), done, total) end
                end,
                function(path, materialize_err)
                    active = nil
                    closeDialog()
                    if cancelled then return end
                    if not path then cb(nil, materialize_err); return end
                    finish(path, idx)
                end
            )
        end)
    end)

    return { cancel = function()
            cancelled = true
            if active then active.cancel() end
            closeDialog()
        end }
end

--- 阅读中后台预取后续章节 CBZ。会话侧固定预取后面 3 章。
---@param identity BookIdentity
---@param toc BookChapter[]
---@param from_idx integer
---@param count integer
---@param cb fun()|nil
---@return { cancel: fun() }
function Source:prefetchChaptersAsync(identity, toc, from_idx, count, cb)
    return require("source.copymanga.chapter").prefetchAsync(
        self._client, identity, toc, from_idx, count, nil, cb
    )
end

--- 拉取云端浏览记录，用目录把 chapter_uuid 换成本地章序号。
--- 官方只有章粒度，没有页内坐标。
---@param identity BookIdentity
---@param cb fun(pos: ProgressPosition|nil, err: string|nil, meta: table|nil)
---@return { cancel: fun() }
function Source:getProgressAsync(identity, cb)
    if not require("source.copymanga.auth").hasSession() then
        return SourceBase.defer(cb, nil, nil, { empty = true })
    end
    local cancelled, toc_job = false, nil
    local request = self._client:getProgressAsync(identity.stable_id, function(wire, err)
        if cancelled then return end
        if not wire then cb(nil, err); return end
        local pos, uid = Mapper.progress(wire)
        if not pos or not uid then cb(nil, nil, { empty = true }); return end

        local function finish(idx)
            if not idx then cb(nil, nil, { empty = true }); return end
            pos.chapter_idx = idx
            pos.fraction = Toc.wholeFraction(
                identity.source_id, identity.stable_id, idx, pos.chapter_fraction
            ) or pos.fraction
            pos.extra = { chapter_uid = uid, chapter_idx = idx }
            cb(pos)
        end

        local idx = Toc.index(identity.source_id, identity.stable_id, uid)
        if idx then
            finish(idx)
            return
        end
        -- 缓存目录里没有这一话：多半是别的设备读了新更新的章节，缓存还没过期也得重拉。
        toc_job = fetchTocAsync(self, identity, function(toc, toc_err)
            if cancelled then return end
            if not toc then cb(nil, toc_err); return end
            finish(Toc.index(identity.source_id, identity.stable_id, uid))
        end)
    end)
    return { cancel = function()
            cancelled = true
            request.cancel()
            if toc_job then toc_job.cancel() end
        end }
end

--- 推送当前章到云端。官方没有独立浏览写入接口；
--- 带 Token 的 chapter2 GET 就是打开章节时写入浏览记录的副作用。
---@param identity BookIdentity
---@param pos ProgressPosition
---@param cb fun(ok: boolean|nil, err: string|nil)
---@return { cancel: fun() }
function Source:putProgressAsync(identity, pos, cb)
    if not require("source.copymanga.auth").hasSession() then
        return SourceBase.defer(cb, nil, _("请先登录拷贝漫画账号"))
    end
    local chapter_idx = pos.chapter_idx or identity.chapter_idx
    if not chapter_idx then
        return SourceBase.defer(cb, nil, _("缺少章节信息"))
    end
    local cancelled, toc_job, push_job = false, nil, nil

    local function push(uid)
        if not uid then
            cb(nil, _("缺少章节信息"))
            return
        end
        push_job = self._client:chapterAsync(identity.stable_id, uid, function(wire, err)
            if cancelled then return end
            cb(wire and true or nil, err)
        end)
    end

    local extra = pos.extra
    local uid = extra and extra.chapter_idx == chapter_idx and extra.chapter_uid
        or Toc.uid(identity.source_id, identity.stable_id, chapter_idx)
    if uid then
        push(uid)
    else
        toc_job = self:loadTocAsync(identity, function(toc, err)
            if cancelled then return end
            if not toc then cb(nil, err); return end
            push(Toc.uid(identity.source_id, identity.stable_id, chapter_idx))
        end)
    end
    return { cancel = function()
            cancelled = true
            if toc_job then toc_job.cancel() end
            if push_job then push_job.cancel() end
        end }
end

--- 缓存漫画章节（全本或 range 指定的一段）；已落盘章节自动跳过，章与章之间留间隔以免打爆接口。
---@param identity BookIdentity
---@param on_progress fun(done: integer, total: integer)|nil
---@param cb fun(ok: boolean, cached: integer, err: string|nil, total: integer, failed: integer)
---@param range ChapterCacheRange|nil 缺省全本
---@return { cancel: fun() }
function Source:cacheAllChaptersAsync(identity, on_progress, cb, range)
    local cancelled, active = false, nil
    active = self:loadTocAsync(identity, function(toc, err)
        if cancelled then return end
        if not toc then cb(false, 0, err, 0, 0); return end
        local from_idx, count = require("source.chapter").cacheRange(toc, range)
        active = require("source.copymanga.chapter").prefetchAsync(
            self._client, identity, toc, from_idx, count,
            {
                progress = on_progress,
                interval_seconds = 1.5,
            },
            function(cached, total, failed, last_err)
                if not cancelled then
                    cb(failed == 0, cached, last_err, total, failed)
                end
            end
        )
    end)
    return { cancel = function()
            cancelled = true
            active.cancel()
        end }
end

return Copymanga
