-- Cache immutable, already scaled pixel payloads, never live widget buffers.
-- Every reader owns its own Blitbuffer, so evictions cannot free visible images.
local lfs = require("libs/libkoreader-lfs")
local Paths = require("utils.paths")
local md5 = require("ffi/sha2").md5
local Cache = {}
local MEMORY_LIMIT, DISK_LIMIT, ENTRY_LIMIT = 4*1024*1024, 24*1024*1024, 128
local ITEM_LIMIT = 2*1024*1024
local memory, size, clock, writes = {}, 0, 0, 0

local function directory() return Paths.cacheDir() .. "/image-thumbnails-v1" end
local function drop(key)
    if memory[key] then size=size-#memory[key].data; memory[key]=nil end
end
local function remember(key, data)
    drop(key)
    clock=clock+1
    memory[key]={data=data,used=clock}; size=size+#data
    while size>MEMORY_LIMIT do
        local oldest
        for k,v in pairs(memory) do
            if not oldest or v.used<memory[oldest].used then oldest=k end
        end
        drop(oldest)
    end
end
function Cache.key(path,w,h)
    local attr=lfs.attributes(path)
    if not attr or attr.mode~="file" then return nil end
    return md5(table.concat({path,tostring(attr.size),tostring(attr.modification),tostring(w),tostring(h)},"\31"))
end
function Cache.get(key)
    if not key then return nil end
    local entry=memory[key]
    if entry then clock=clock+1; entry.used=clock; return entry.data end
    local path=directory() .. "/" .. key .. ".bin"
    local attr=lfs.attributes(path)
    if not attr or not attr.size or attr.size<1 or attr.size>ITEM_LIMIT then return nil end
    local f=io.open(path,"rb")
    if not f then return nil end
    local data=f:read("*a"); f:close()
    if data and #data>0 then remember(key,data); return data end
end
function Cache.remove(key)
    if not key then return end
    drop(key); os.remove(directory() .. "/" .. key .. ".bin")
end
local function trimDisk()
    local entries,total={},0
    for name in lfs.dir(directory()) do
        if name:match("^[%da-f]+%.bin$") then
            local path=directory() .. "/" .. name
            local attr=lfs.attributes(path)
            if attr and attr.mode=="file" then
                total=total+attr.size
                entries[#entries+1]={path=path,size=attr.size,time=attr.modification or 0}
            end
        end
    end
    table.sort(entries,function(a,b) return a.time<b.time end)
    local count=#entries
    for _,entry in ipairs(entries) do
        if total<=DISK_LIMIT and count<=ENTRY_LIMIT then break end
        if os.remove(entry.path) then total=total-entry.size; count=count-1 end
    end
end
function Cache.put(key,data)
    if not key or type(data)~="string" or #data==0 or #data>ITEM_LIMIT then return end
    remember(key,data)
    Paths.ensureCacheRoot(); lfs.mkdir(directory())
    local path=directory() .. "/" .. key .. ".bin"
    local f=io.open(path .. ".part","wb")
    if not f then return end
    local ok=f:write(data); local closed=f:close()
    if not ok or not closed or not os.rename(path .. ".part",path) then os.remove(path .. ".part"); return end
    writes=writes+1
    -- Prune on first write and periodically; excess is bounded by 7 small entries.
    if writes%8==1 then pcall(trimDisk) end
end
return Cache
