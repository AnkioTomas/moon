local Base = require('source.base')
local Settings = require('source.fanqie.settings')
local Client = require('source.fanqie.client')
local Async = require('source.fanqie.async')
local Content = require('source.fanqie.content')
local Toc = require('source.fanqie.toc')
local M = {}
local Source = setmetatable({}, {__index=Base})
Source.__index = Source
function M.meta() return {id='fanqie', name='番茄小说', type='chapter'} end
function M.new()
    local settings = Settings:new()
    return setmetatable({id='fanqie', name='番茄小说', type='chapter',
        settings=settings, client=Client:new(settings)}, Source)
end
function Source:configured()
    self.settings=Settings:new(); self.client.settings=self.settings
    return self.settings:is_cookie_configured()
end
function Source:capabilities() return {refresh=true, insight=true} end
local function run(work, done)
    local cancelled=false
    local job=Async.run(work, function(ok, value, err)
        if not cancelled then done(ok and value or nil, ok and nil or tostring(err or '番茄请求失败')) end
    end)
    return {cancel=function() cancelled=true; if job and job.cancel then job.cancel() end end}
end
function Source:syncBooksAsync(opts, cb)
    -- Reload shared settings after QR login.
    self.settings=Settings:new(); self.client=Client:new(self.settings)
    if not self:configured() then cb(nil, '请在数据源设置中扫码登录番茄小说'); return end
    return run(function()
        local wire=self.client:fetch_shelf_detail(opts and opts.force)
        local rows=wire and wire.data and wire.data.detail_list
        if type(rows)~='table' then error('番茄书架响应不完整，保留本地书架') end
        require('source.fanqie.helper').make_dir(require('utils.paths').imageDir('fanqie'))
        local books={}
        for _,row in ipairs(rows) do
            local id=row.book_id or row.bookId or row.id
            if id then
                local title=row.book_name or row.title or row.name or '未知'
                local old_cover=self.settings.cache_dir .. '/covers/' .. title:gsub('[/\\:%*%?"<>|]', '_') .. '.jpg'
                local target=require('utils.paths').coverPath(tostring(id),'fanqie')
                if not require('libs/libkoreader-lfs').attributes(target,'size') then
                    local input=io.open(old_cover,'rb')
                    if input then
                        local bytes=input:read('*a'); input:close()
                        local output=io.open(target,'wb')
                        if output then output:write(bytes); output:close() end
                    end
                end
                books[#books+1]={source_id='fanqie', stable_id=tostring(id),
                    title=title,
                    authors=row.author_name or row.author or '',
                    intro=row.description or row.desc or row.abstract or '',
                    cover=row.thumb_url or row.coverUrl or row.cover or row.cover_url}
            end
        end
        return books
    end, function(books,err)
        if not books then cb(nil,err); return end
        local result,reason=require('book.store').reconcile(self.id,books)
        cb(result,reason)
    end)
end
function Source:coverRequest(identity)
    local book=identity.book or require('db.book').get(self.id,identity.stable_id)
    if book and type(book.cover)=='string' and book.cover:match('^https?://') then return {url=book.cover} end
    return nil,'暂无封面'
end
function Source:getDetailAsync(identity,cb)
    local cancelled=false
    require('ui/uimanager'):nextTick(function()
        if not cancelled then cb(identity.book or require('db.book').get(self.id,identity.stable_id)) end
    end)
    return {cancel=function() cancelled=true end}
end
function Source:loadTocAsync(identity,cb)
    local cached=Toc.read(self.id,identity.stable_id)
    if cached and #cached>0 then
        require('ui/uimanager'):nextTick(function() cb(cached) end)
        return
    end
    return run(function()
        local rows=Content.readable_chapters(Content.normalize_chapters(
            self.client:fetch_chapter_directory(identity.stable_id),identity.stable_id))
        local toc={}
        for _,row in ipairs(rows) do
            local uid=row.itemId or row.item_id
            if uid then toc[#toc+1]={idx=#toc+1,uid=tostring(uid),title=row.title or row.item_title or ('第'..(#toc+1)..'章')} end
        end
        if #toc==0 then error('番茄目录为空') end
        return toc
    end,function(toc,err)
        if toc then Toc.put(self.id,identity.stable_id,toc) end
        cb(toc,err)
    end)
end
local function fetch(self,identity,chapter,cb)
    return run(function()
        local index=Content.load_cache_index(self.settings,identity.stable_id)
        local path=index and index[chapter.uid]
        if path then
            local file=io.open(path,'rb')
            if file then
                local html=file:read('*a'); file:close()
                local body=html:match('<body[^>]*>(.-)</body>')
                if body and body:match('%S') then return {title=chapter.title,html=body} end
            end
        end
        local result=self.client:official_get_content(identity.stable_id,chapter.uid)
        local html=Content.decode_pua_content(result.content)
        return {title=result.title~='' and result.title or chapter.title, html=html}
    end,cb)
end
function Source:openBookAsync(identity,opts,cb)
    local Chapter=require('source.chapter')
    local open=opts and opts.chapter_idx and Chapter.openAsync or Chapter.openWithUi
    return open(self,identity,identity.book,opts,{
        loadToc=function(ref,done) return self:loadTocAsync(ref,done) end,
        fetchContent=function(ref,ch,done) return fetch(self,ref,ch,done) end,
    },cb)
end
function Source:prefetchChaptersAsync(identity,toc,from_idx,count,cb)
    return require('source.chapter').prefetchAsync(identity,identity.book,toc,from_idx,count,{
        fetchContent=function(ref,ch,done) return fetch(self,ref,ch,done) end,
        interval_seconds=6,
    },cb)
end
function Source:getProgressAsync(identity,cb)
    local cancelled,request,toc_job=false,nil,nil
    request=run(function()
        local wire=self.client:fetch_read_progress()
        for _,row in ipairs(wire and wire.data or {}) do
            if tostring(row.book_id)==identity.stable_id then return row end
        end
        return {}
    end,function(row,err)
        if cancelled then return end
        if not row then cb(nil,err); return end
        if not row.item_id then cb(nil,nil,{empty=true}); return end
        toc_job=self:loadTocAsync(identity,function(toc,reason)
            if cancelled then return end
            if not toc then cb(nil,reason); return end
            local idx=Toc.index(self.id,identity.stable_id,row.item_id)
            if not idx then cb(nil,nil,{empty=true}); return end
            local within=tonumber(row.read_progress) or 0
            if within>1 then within=within/10000 end
            within=math.max(0,math.min(1,within))
            cb({chapter_idx=idx, chapter_fraction=within, fraction=(idx-1+within)/#toc,
                extra={chapter_uid=tostring(row.item_id),chapter_idx=idx}})
        end)
    end)
    return {cancel=function()
        cancelled=true
        if request then request.cancel() end
        if toc_job then toc_job.cancel() end
    end}
end
function Source:putProgressAsync(identity,pos,cb)
    local cancelled,request,toc_job=false,nil,nil
    toc_job=self:loadTocAsync(identity,function(toc,err)
        if cancelled then return end
        if not toc then cb(nil,err); return end
        local idx=tonumber(pos.chapter_idx) or tonumber(identity.chapter_idx)
        local chapter=idx and toc[idx]
        if not chapter then cb(nil,'缺少番茄章节位置'); return end
        request=run(function()
            local wire=self.client:update_read_progress(identity.stable_id,chapter.uid,idx-1,
                math.max(0,math.min(1,tonumber(pos.chapter_fraction) or 0)))
            if not wire or tonumber(wire.code or 0)~=0 then error('番茄进度上传失败') end
            return true
        end,function(ok,reason) if not cancelled then cb(ok,reason) end end)
    end)
    return {cancel=function()
        cancelled=true
        if request then request.cancel() end
        if toc_job then toc_job.cancel() end
    end}
end
return M
