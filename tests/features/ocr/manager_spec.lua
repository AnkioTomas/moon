--[[-- features.ocr.manager：清单校验、下载校验原子安装、只删自己装且未被替换的模型、语言列表原地刷新。 --]]

local Assert = require("support.assert")

-- 没有 KOReader 源码时退回系统 sha256 命令。
if not pcall(require, "ffi/sha2") then
    package.preload["ffi/sha2"] = function()
        return { sha256 = function()
            local chunks = {}
            return function(data)
                if data then chunks[#chunks + 1] = data; return end
                local tmp = os.tmpname()
                local f = assert(io.open(tmp, "wb")); f:write(table.concat(chunks)); f:close()
                local p = io.popen("(sha256sum " .. tmp .. " || shasum -a 256 " .. tmp .. ") 2>/dev/null")
                local out = p:read("*l"); p:close(); os.remove(tmp)
                return out:match("^(%x+)")
            end
        end }
    end
end
local sha256 = function(text)
    local h = require("ffi/sha2").sha256(); h(text); return h()
end

local store = {}
package.preload["json"] = function()
    return {
        decode = function(s) return store[s] or error("bad json") end,
        encode = function(t) local key = "json#" .. tostring(t); store[key] = t; return key end,
    }
end
local downloads = {}
package.preload["http.request"] = function()
    return { download = function(opts, dest, cb)
        downloads[#downloads + 1] = { opts = opts, dest = dest, cb = cb }
        return { cancel = function() end }
    end }
end
package.preload["workers.job"] = function()
    return { run = function(fn, opts)
        local ok, err = pcall(fn)
        if ok then opts.on_done() else opts.on_failed(err) end
    end }
end
package.preload["util"] = function()
    return { makePath = function(p) os.execute("mkdir -p '" .. p .. "'"); return true end }
end

local Manager = require("features.ocr.manager")

-- 清单校验：id 只放行 [%w_]，file 必须是 <id>.traineddata，sha256 64 位。
local hash = string.rep("a", 64)
local good = { id = "chi_sim", name = "简体中文", file = "chi_sim.traineddata", size = 5, sha256 = hash }
Assert.len(assert(Manager.validateManifest({ models = { good } })), 1)
local function bad(patch)
    local item = {}
    for k, v in pairs(good) do item[k] = v end
    for k, v in pairs(patch) do item[k] = v end
    return Manager.validateManifest({ models = { item } })
end
Assert.is_nil(bad({ id = "../x", file = "../x.traineddata" }), "路径穿越")
Assert.is_nil(bad({ file = "other.traineddata" }), "文件名必须对应 id")
Assert.is_nil(bad({ sha256 = "xyz" }))
Assert.is_nil(bad({ size = 0 }))
Assert.is_nil(Manager.validateManifest({ models = { good, good } }), "重复 id")
Assert.is_nil(Manager.validateManifest({ models = {} }))

-- 安装：下载到 .part → 校验 → 原子改名 → 记所有权 → 加入 Document Language。
local dir = os.tmpname()
os.remove(dir)
os.execute("mkdir -p '" .. dir .. "'")
local option = { name = "doc_language", values = { "eng" }, toggle = { "English" } }
option.args = option.values
package.loaded["ui/data/koptoptions"] = { { options = { option } } }
package.loaded["ui/data/isolanguage"] = { getLocalizedLanguage = function(_, code) return "L:" .. code end }

local body = "model"
local item = { id = "chi_sim", name = "简体中文", file = "chi_sim.traineddata", size = #body, sha256 = sha256(body) }
local result
Manager.install(item, dir, function(ok, err) result = { ok = ok, err = err } end)
Assert.len(downloads, 1)
Assert.eq(downloads[1].dest, dir .. "/chi_sim.traineddata.part")
Assert.eq(downloads[1].opts.url, require("http.mirror").url(Manager.BASE_PATH .. "/chi_sim.traineddata"))
local f = assert(io.open(downloads[1].dest, "wb")); f:write(body); f:close()
downloads[1].cb(true)
Assert.is_true(result.ok)
Assert.is_true(Manager.isInstalled(dir, "chi_sim"))
Assert.is_nil(io.open(dir .. "/chi_sim.traineddata.part", "rb"), ".part 已改名")
Assert.is_true(Manager.isOwned(dir, "chi_sim"))
Assert.eq(table.concat(option.values, ","), "eng,chi_sim", "原地追加，不用重启")
Assert.eq(option.toggle[2], "L:chi_sim")

-- 校验失败：不落地，.part 删除。
local tampered = { id = "jpn", name = "日语", file = "jpn.traineddata", size = 5, sha256 = hash }
Manager.install(tampered, dir, function(ok, err) result = { ok = ok, err = err } end)
f = assert(io.open(downloads[2].dest, "wb")); f:write("bogus"); f:close()
downloads[2].cb(true)
Assert.is_false(result.ok)
Assert.is_false(Manager.isInstalled(dir, "jpn"))
Assert.is_nil(io.open(dir .. "/jpn.traineddata.part", "rb"))

-- 下载失败（所有镜像都失败）：清掉半截 .part。
result = nil
Manager.install(tampered, dir, function(ok, err) result = { ok = ok, err = err } end)
f = assert(io.open(downloads[3].dest, "wb")); f:write("half"); f:close()
while not result do downloads[#downloads].cb(false, "timeout") end
Assert.eq(result.err, "timeout")
Assert.is_nil(io.open(dir .. "/jpn.traineddata.part", "rb"))

-- 用户自装的模型：列出但拒绝删除。
f = assert(io.open(dir .. "/eng.traineddata", "wb")); f:write("user"); f:close()
Assert.eq(table.concat(Manager.installed(dir), ","), "chi_sim,eng")
local ok, err = Manager.remove(dir, "eng")
Assert.is_false(ok)
Assert.eq(err, "not installed by this plugin")
Assert.is_true(Manager.isInstalled(dir, "eng"))

-- 自己装的但文件被替换（sha 不一致）：同样拒绝。
f = assert(io.open(dir .. "/chi_sim.traineddata", "wb")); f:write("replaced"); f:close()
Assert.is_false((Manager.remove(dir, "chi_sim")))
Assert.is_true(Manager.isInstalled(dir, "chi_sim"))

-- 恢复原文件后可删；所有权与语言列表同步移除。
f = assert(io.open(dir .. "/chi_sim.traineddata", "wb")); f:write(body); f:close()
Assert.is_true((Manager.remove(dir, "chi_sim")))
Assert.is_false(Manager.isInstalled(dir, "chi_sim"))
Assert.is_nil(Manager.owned(dir).chi_sim)
Assert.eq(table.concat(option.values, ","), "eng")
Assert.len(option.toggle, 1)
Assert.is_false((Manager.remove(dir, "../etc")))

-- 默认识别语言写 KOReader kopt 默认值；当前扫描书立即切换。
local saved = {}
local old_g = _G.G_reader_settings
_G.G_reader_settings = {
    readSetting = function(_, k) return saved[k] end,
    saveSetting = function(_, k, v) saved[k] = v end,
}
Manager.setDefaultLanguage("chi_tra")
Assert.eq(Manager.defaultLanguage(), "chi_tra")
Assert.eq(saved.kopt_doc_language, "chi_tra")
local events = {}
package.loaded["ui/event"] = { new = function(_, name, arg) return { name = name, arg = arg } end }
package.loaded["apps/reader/readerui"] = { instance = {
    document = { configurable = { doc_language = "eng" }, koptinterface = {} },
    handleEvent = function(_, ev) events[#events + 1] = ev end,
} }
-- Forced OCR：开着扫描书读这本书的值；写入同时改全局默认与当前书。
Assert.is_false(Manager.forcedOcr())
Manager.setForcedOcr(true)
Assert.eq(saved.kopt_forced_ocr, 1)
Assert.eq(package.loaded["apps/reader/readerui"].instance.document.configurable.forced_ocr, 1)
Assert.is_true(Manager.forcedOcr())
Manager.setForcedOcr(false)
Assert.eq(saved.kopt_forced_ocr, 0)
Assert.is_true(Manager.applyToOpenDocument("chi_sim"))
Assert.eq(Manager.currentLanguage(), "chi_sim")
Assert.eq(events[1].name, "DocLangUpdate")
package.loaded["apps/reader/readerui"] = { instance = { document = { configurable = {} } } }
Assert.is_false(Manager.applyToOpenDocument("chi_sim"), "重排文档不切")
package.loaded["apps/reader/readerui"] = { instance = nil }
saved.kopt_forced_ocr = 1
Assert.is_true(Manager.forcedOcr(), "没开书读全局默认")
package.loaded["apps/reader/readerui"] = nil
_G.G_reader_settings = old_g

os.execute("rm -rf '" .. dir .. "'")
return true
