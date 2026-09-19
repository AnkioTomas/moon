
local queue={}
package.preload['ui/uimanager']=function() return {nextTick=function(_,f) queue[#queue+1]=f end} end
function drain() while #queue>0 do table.remove(queue,1)() end end
package.preload['source.base']=function() return {} end
package.preload['source.fanqie.settings']=function() return {new=function() return {cache_dir='missing',is_cookie_configured=function() return true end} end} end
package.preload['source.fanqie.client']=function() return {new=function() return {
 fetch_shelf_detail=function() return {data={detail_list={{book_id='1234567890123456789',book_name='测试',author='作者'}}}} end,
 fetch_chapter_directory=function() return {data={chapterList={{itemId='9876543210987654321',title='第一章'}}}} end,
 official_get_content=function() return {title='第一章',content='<p>测试正文</p>'} end,
 fetch_read_progress=function() return {data={}} end,
 } end} end
package.preload['source.fanqie.async']=function() return {run=function(work,done)
 require('ui/uimanager'):nextTick(function() local ok,r=pcall(work); done(ok,ok and r or nil,not ok and r or nil) end)
 return {cancel=function() end}
end} end
package.preload['source.fanqie.helper']=function() return {make_dir=function() end} end
package.preload['libs/libkoreader-lfs']=function() return {attributes=function() return nil end} end
package.preload['utils.paths']=function() return {imageDir=function() return 'missing' end,coverPath=function() return 'missing/cover.jpg' end} end
local stored
package.preload['book.store']=function() return {reconcile=function(id,books) assert(id=='fanqie');stored=books; return {pulled=#books} end} end
local toc
package.preload['source.fanqie.toc']=function() return {read=function() return toc end,put=function(_,_,v) toc=v end} end
package.preload['source.chapter']=function() return {
 openAsync=function(_,id,book,opts,ops,cb) ops.loadToc(id,function(chapters) assert(chapters[1].uid=='9876543210987654321');cb('ready.html') end) end,
 openWithUi=function() error('chapter transition must not open a progress dialog') end,
 prefetchAsync=function(_,_,_,_,count,ops,cb) assert(count==3);assert(ops.interval_seconds==6);cb() end
} end
local src=require('source.fanqie').new()
assert(src:configured())
local count=0
src:syncBooksAsync({},function(r,e) assert(r and not e);count=r.pulled end)
drain();assert(count==1);assert(stored[1].stable_id=='1234567890123456789')
local ref={source_id='fanqie',stable_id='1234567890123456789'}
src:openBookAsync(ref,{chapter_idx=1},function(path) assert(path=='ready.html');count=count+1 end)
drain();assert(count==2)
local cancelled=src:syncBooksAsync({},function() error('cancelled callback delivered') end)
cancelled.cancel();drain()
src:prefetchChaptersAsync(ref,{},1,3,function() count=count+1 end);assert(count==3)

return true
