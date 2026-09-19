-- Exercise Image.widget's warm path, not just the cache container.
local saved, jobs, dirty, buffers = {}, {}, 0, 0
local function widget()
    return {new=function(_,opts) opts.free=function(self) if self[1] then self[1]:free() end end; return opts end,
        free=function(self) if self[1] then self[1]:free() end end,paintTo=function() end}
end
for _,name in ipairs({'ui/widget/container/centercontainer','ui/widget/container/framecontainer',
    'ui/widget/container/widgetcontainer','ui/widget/widget','ui/widget/textwidget','ui/widget/imagewidget'}) do
    package.preload[name]=widget
end
package.preload['ffi/blitbuffer']=function() return {COLOR_WHITE=0,fromstring=function()
    buffers=buffers+1;return {id=buffers}
end} end
package.preload['ui/geometry']=function() return {new=function(_,v) return v end} end
package.preload['ui/uimanager']=function() return {setDirty=function() dirty=dirty+1 end} end
package.preload['ffi/sha2']=function() return {md5=function(v) return v end} end
package.preload['libs/libkoreader-lfs']=function() return {attributes=function(_,field)
    local attr={mode='file',size=20,modification=1};return field and attr[field] or attr
end} end
package.preload['utils.log']=function() return {warn=function() end} end
package.preload['ui.components.bookui']=function() return {pluginRoot=function() return '' end} end
package.preload['utils.paths']=function() return {cacheDir=function() return 'cache' end,ensureCacheRoot=function() end} end
package.preload['http.request']=function() error('cached local image must not use network') end
-- The module imports Request eagerly, so install a throwing download method instead.
package.preload['http.request']=function() return {download=function() error('unexpected network') end} end
package.preload['json']=function() return {decode=function(s)
    assert(s=='header');return {w=40,h=60,stride=40,fmt=1}
end} end
package.preload['workers.job']=function() return {run=function(_,opts)
    jobs[#jobs+1]=opts;return {abort=function() end}
end} end
package.preload['ui.components.image_cache']=function() return {
    key=function(p,w,h) return p..w..':'..h end,get=function(k) return saved[k] end,
    put=function(k,data) saved[k]=data end,remove=function(k) saved[k]=nil end,
} end
local real_open, real_remove=io.open,os.remove
io.open=function(path)
    assert(path=='decoded')
    return {read=function() return 'header\n'..string.rep('p',2400) end,close=function() end}
end
os.remove=function() return true end
local Image=require('ui.components.image')
local first=Image.widget{src='cover',width=40,height=60}
assert(#jobs==1)
jobs[1].on_done('decoded')
assert(buffers==1)
first:free()
local second=Image.widget{src='cover',width=40,height=60}
assert(#jobs==1,'warm page must not launch another decoder')
assert(buffers==2,'each widget must own a fresh pixel buffer')
assert(dirty==0,'warm construction must not schedule an extra screen refresh')
second:free()
saved['cover40:60']='bad\npixels'
local third=Image.widget{src='cover',width=40,height=60}
assert(#jobs==2,'corrupt thumbnail must fall back to background decode')
third:free()
io.open,os.remove=real_open,real_remove
return true
