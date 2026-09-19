-- Isolated virtual filesystem: no user images, settings, or network access.
local files, stats, reads, stamp = {}, {}, 0, 1
local old_io = io
local function file(path, mode)
    if mode == 'rb' then
        if not files[path] then return nil end
        reads=reads+1
        return {read=function() return files[path] end,close=function() return true end}
    end
    local data=''
    return {write=function(_,s) data=data..s;return true end,close=function()
        files[path]=data;stats[path]={mode='file',size=#data,modification=stamp};stamp=stamp+1;return true
    end}
end
io={open=file}
os.remove=function(path) files[path]=nil;stats[path]=nil;return true end
os.rename=function(a,b) files[b]=files[a];stats[b]=stats[a];files[a]=nil;stats[a]=nil;return true end
package.loaded['libs/libkoreader-lfs']=nil
package.preload['libs/libkoreader-lfs']=function() return {
    attributes=function(p) return stats[p] end,mkdir=function() return true end,
    dir=function(dir)
        local names={}
        for p in pairs(files) do if p:sub(1,#dir+1)==dir..'/' then names[#names+1]=p:sub(#dir+2) end end
        local n=0;return function() n=n+1;return names[n] end
    end,
} end
package.loaded['utils.paths']=nil
package.preload['utils.paths']=function() return {cacheDir=function() return 'cache' end,ensureCacheRoot=function() end} end
local keys,n={},0
package.loaded['ffi/sha2']=nil
package.preload['ffi/sha2']=function() return {md5=function(s)
    if not keys[s] then n=n+1;keys[s]=string.format('%032x',n) end
    return keys[s]
end} end
package.loaded['ui.components.image_cache']=nil
local cache=require('ui.components.image_cache')
stats['cover']={mode='file',size=10,modification=1}
local key=cache.key('cover',80,120)
assert(cache.get(key)==nil)
cache.put(key,'scaled pixels')
local before=reads
assert(cache.get(key)=='scaled pixels' and reads==before,'warm hit must not read disk')
assert(cache.key('cover',81,120)~=key,'resize must invalidate thumbnail')
stats.cover.modification=2
assert(cache.key('cover',80,120)~=key,'source replacement must invalidate thumbnail')
package.loaded['ui.components.image_cache']=nil
cache=require('ui.components.image_cache')
assert(cache.get(key)=='scaled pixels' and reads==before+1,'restart should reuse disk thumbnail')
cache.remove(key);assert(cache.get(key)==nil)
-- Force memory eviction, then recover the evicted entry from persistent storage.
for i=1,6 do cache.put(string.format('%032x',100+i),string.rep('p',1024*1024)) end
before=reads
assert(#cache.get(string.format('%032x',101))==1024*1024 and reads==before+1)
-- Disk retention is bounded even while browsing a large library.
for i=1,150 do cache.put(string.format('%032x',1000+i),'small') end
local count=0
for p in pairs(files) do if p:match('%.bin$') then count=count+1 end end
assert(count<=135,'persistent thumbnail count must be bounded')
io=old_io
return true
