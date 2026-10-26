--[[--
OCR 识别模型（Tesseract traineddata）管理：清单、下载校验、原子安装、受控删除、语言列表刷新。

模型装进 KOReader 的 tessdata 目录（文件名必须是 `<lang>.traineddata`，不能像词典那样加前缀），
所有权记在同目录 `.book-ocr.json`：只有记录在案且 sha256 仍一致的文件允许删除，用户自己放的模型只显示。

@module koplugin.book.features.ocr.manager
--]]

local JSON = require("json")
local Mirror = require("http.mirror")
local Job = require("workers.job")
local lfs = require("libs/libkoreader-lfs")

local Manager = {}
Manager.BASE_PATH = "assets/ocr"
local OWNED_FILE = ".book-ocr.json"
local SUFFIX = ".traineddata"

--- 语言码：清单来自网络，会拼进文件名，只放行 `[%w_]`。
---@return string|nil
local function safeId(value)
    return type(value) == "string" and value:match("^[%w_]+$") and value or nil
end

---@return boolean
local function validHash(value)
    return type(value) == "string" and #value == 64 and value:match("^%x+$") ~= nil
end

--- 校验远程清单；返回规范化模型列表。
---@param manifest table
---@return table[]|nil, string|nil
function Manager.validateManifest(manifest)
    if type(manifest) ~= "table" or type(manifest.models) ~= "table" then
        return nil, "bad manifest"
    end
    local out, seen = {}, {}
    for _idx, item in ipairs(manifest.models) do
        if type(item) ~= "table" or not safeId(item.id) or seen[item.id]
            or type(item.name) ~= "string" or item.name == ""
            or item.file ~= (type(item.id) == "string" and item.id .. SUFFIX or nil)
            or tonumber(item.size) == nil or tonumber(item.size) <= 0
            or not validHash(item.sha256) then
            return nil, "bad ocr manifest"
        end
        seen[item.id] = true
        out[#out + 1] = item
    end
    if #out == 0 then return nil, "empty manifest" end
    return out
end

--- 拉取并校验远程模型目录。
---@param cb fun(items: table[]|nil, err: any)
---@return table
function Manager.catalog(cb)
    return Mirror.get(Manager.BASE_PATH .. "/manifest.json", { timeout = require("http.timeout").net(1) }, function(body, err)
        if not body then cb(nil, err); return end
        local ok, manifest = pcall(JSON.decode, body)
        if not ok then cb(nil, manifest); return end
        cb(Manager.validateManifest(manifest))
    end)
end

--- KOReader 实际读取模型的目录：默认 `<数据目录>/data/tessdata`；
--- 设了 `$TESSDATA_PREFIX` 时 koptinterface 不传目录，交给 libk2pdfopt 找 `$TESSDATA_PREFIX[/tessdata]`。
--- 与 koptinterface.tessocr_data 同一规则；不 require koptinterface（会连带加载 mupdf，设置页没必要）。
---@return string
function Manager.dataDir()
    local env = os.getenv("TESSDATA_PREFIX")
    if not env then return require("datastorage"):getDataDir() .. "/data/tessdata" end
    if lfs.attributes(env .. "/tessdata", "mode") == "directory" then return env .. "/tessdata" end
    return env
end

--- 文件 sha256（流式）。
---@param path string
---@return string|nil hex, number|nil size
function Manager.digest(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local hash, size = require("ffi/sha2").sha256(), 0
    while true do
        local data = file:read(256 * 1024)
        if not data then break end
        hash(data)
        size = size + #data
    end
    file:close()
    return hash():lower(), size
end

--- 所有权记录：语言码 → { sha256, size }。文件损坏按空表处理（最多是删不了，不会误删）。
---@param dir string
---@return table<string, { sha256: string, size: number }>
function Manager.owned(dir)
    local file = io.open(dir .. "/" .. OWNED_FILE, "rb")
    if not file then return {} end
    local body = file:read("*a")
    file:close()
    local ok, data = pcall(JSON.decode, body)
    if not ok or type(data) ~= "table" then return {} end
    local out = {}
    for id, rec in pairs(data) do
        if safeId(id) and type(rec) == "table" and validHash(rec.sha256) then out[id] = rec end
    end
    return out
end

---@param dir string
---@param owned table
---@return boolean|nil, string|nil
local function saveOwned(dir, owned)
    local tmp = dir .. "/" .. OWNED_FILE .. ".part"
    local file, err = io.open(tmp, "wb")
    if not file then return nil, err end
    file:write(JSON.encode(owned))
    file:close()
    return os.rename(tmp, dir .. "/" .. OWNED_FILE)
end

--- 已安装的语言码（排序）。
---@param dir string
---@return string[]
function Manager.installed(dir)
    local out = {}
    local ok, iter, dir_obj = pcall(lfs.dir, dir)
    if not ok then return out end
    for name in iter, dir_obj do
        local code = name:sub(-#SUFFIX) == SUFFIX and safeId(name:sub(1, -#SUFFIX - 1))
        if code and lfs.attributes(dir .. "/" .. name, "mode") == "file" then out[#out + 1] = code end
    end
    table.sort(out)
    return out
end

---@param dir string
---@param id string
---@return boolean
function Manager.isInstalled(dir, id)
    return safeId(id) ~= nil and lfs.attributes(dir .. "/" .. id .. SUFFIX, "mode") == "file"
end

--- 是否本插件安装、且文件未被替换（sha256 一致）。
---@param dir string
---@param id string
---@return boolean
function Manager.isOwned(dir, id)
    local rec = safeId(id) and Manager.owned(dir)[id]
    if not rec then return false end
    return Manager.digest(dir .. "/" .. id .. SUFFIX) == rec.sha256:lower()
end

--- 校验下载好的 `.part` 并原子改名到位（跑在 Job 子进程里，失败即 error）。
--- 先校验再 rename：Tesseract 读到半个模型会直接识别失败甚至崩溃。
---@param item table 清单项
---@param part string 临时文件
---@param target string 最终文件
function Manager.verifyAndInstall(item, part, target)
    local hash, size = Manager.digest(part)
    if not hash then error("downloaded file missing") end
    if size ~= tonumber(item.size) or hash ~= item.sha256:lower() then
        os.remove(part)
        error("ocr model sha256 mismatch")
    end
    assert(os.rename(part, target))
end

--- 下载、校验并原子安装一个模型，成功后记入所有权。
---@param item table `Manager.catalog` 校验过的清单项
---@param dir string tessdata 目录
---@param cb fun(ok: boolean, err: any)
---@param on_progress fun(stage: string, done: number, total: number)|nil stage 为 "download"/"install"
---@return table|nil 下载句柄
function Manager.install(item, dir, cb, on_progress)
    cb = cb or function() end
    local report = on_progress or function() end
    if not safeId(item.id) then cb(false, "invalid model"); return end
    if Manager.isInstalled(dir, item.id) then cb(false, "ocr model already installed"); return end
    local made, make_err = require("util").makePath(dir)
    if not made then cb(false, make_err); return end
    local part = dir .. "/" .. item.id .. SUFFIX .. ".part"
    local target = dir .. "/" .. item.id .. SUFFIX
    return Mirror.download(Manager.BASE_PATH .. "/" .. item.file, {
        timeout = require("http.timeout").net(10),
        allow_redirects = true,
        on_progress = function(bytes) report("download", bytes, item.size) end,
    }, part, function(ok, err)
        if not ok then
            os.remove(part)
            cb(false, err)
            return
        end
        report("install", item.size, item.size)
        Job.run(function() Manager.verifyAndInstall(item, part, target) end, {
            name = "features.ocr.install",
            kind = "medium",
            timeout = 120,
            on_done = function()
                local owned = Manager.owned(dir)
                owned[item.id] = { sha256 = item.sha256:lower(), size = tonumber(item.size) }
                saveOwned(dir, owned)
                Manager.addLanguage(item.id)
                cb(true)
            end,
            on_failed = function(job_err)
                os.remove(part)
                cb(false, job_err)
            end,
        })
    end)
end

--- 删除本插件安装的模型：必须在所有权记录里且 sha256 一致；用户自装或已被替换的拒绝删除。
---@param dir string
---@param id string
---@return boolean, string|nil
function Manager.remove(dir, id)
    if not safeId(id) then return false, "invalid model" end
    if not Manager.isInstalled(dir, id) then return false, "ocr model not installed" end
    if not Manager.isOwned(dir, id) then return false, "not installed by this plugin" end
    local ok, err = os.remove(dir .. "/" .. id .. SUFFIX)
    if not ok then return false, err or "delete failed" end
    local owned = Manager.owned(dir)
    owned[id] = nil
    saveOwned(dir, owned)
    Manager.removeLanguage(id)
    return true
end

--- KOReader 底部菜单「Document Language」的选项：koptoptions 在模块加载时扫一次 tessdata，
--- values / args 指向同一张语言码表，toggle 是显示名表。原地增删即可，不用重启。
--- 还没加载过就不碰：首次加载时会重新扫目录，自然包含新模型。
---@return table|nil option
local function docLanguageOption()
    local options = package.loaded["ui/data/koptoptions"]
    if type(options) ~= "table" then return nil end
    for _idx, group in ipairs(options) do
        for _i, option in ipairs(group.options or {}) do
            if option.name == "doc_language" then return option end
        end
    end
end

---@param code string
---@return string
local function langName(code)
    local ok, Iso = pcall(require, "ui/data/isolanguage")
    local name = ok and Iso.getLocalizedLanguage and Iso:getLocalizedLanguage(code)
    return name or code
end

--- 把语言加进 Document Language 选项（已在则不动）。
---@param code string
function Manager.addLanguage(code)
    local option = docLanguageOption()
    if not option or type(option.values) ~= "table" then return end
    for _idx, value in ipairs(option.values) do
        if value == code then return end
    end
    table.insert(option.values, code)
    if type(option.toggle) == "table" then table.insert(option.toggle, langName(code)) end
    if type(option.args) == "table" and option.args ~= option.values then table.insert(option.args, code) end
end

--- 从 Document Language 选项里移除语言。
---@param code string
function Manager.removeLanguage(code)
    local option = docLanguageOption()
    if not option or type(option.values) ~= "table" then return end
    for index = #option.values, 1, -1 do
        if option.values[index] == code then
            table.remove(option.values, index)
            if type(option.toggle) == "table" then table.remove(option.toggle, index) end
            if type(option.args) == "table" and option.args ~= option.values then table.remove(option.args, index) end
        end
    end
end

--- 默认识别语言：KOReader 的 kopt 默认值（「设为默认」同一键），新开的扫描书用它。
---@return string|nil
function Manager.defaultLanguage()
    return (G_reader_settings and G_reader_settings:readSetting("kopt_doc_language") or nil) --[[@as string|nil]]
end

---@param code string
function Manager.setDefaultLanguage(code)
    if G_reader_settings then G_reader_settings:saveSetting("kopt_doc_language", code) end
end

--- KOReader 的「Forced OCR」（koptoptions.lua:637 `forced_ocr`，0/1，每本书一份，
--- 全局默认存 `kopt_forced_ocr`）。开启后 koptinterface.getTextBoxes 无视文字层、一律走识别；
--- 关闭时没有文字层的扫描页照样自动识别。开着扫描书读这本书的值，否则读全局默认。
---@return boolean
function Manager.forcedOcr()
    local ui = Manager.koptReader()
    if ui then return ui.document.configurable.forced_ocr == 1 end
    return G_reader_settings ~= nil and G_reader_settings:readSetting("kopt_forced_ocr") == 1
end

--- 同时写全局默认与当前扫描书（立即生效：选词时 getTextBoxes 现读 configurable）。
---@param on boolean
function Manager.setForcedOcr(on)
    local value = on and 1 or 0
    if G_reader_settings then G_reader_settings:saveSetting("kopt_forced_ocr", value) end
    local ui = Manager.koptReader()
    if ui then ui.document.configurable.forced_ocr = value end
end

--- 正在阅读的扫描版文档（kopt 系，有 doc_language 配置）。
---@return table|nil ui
function Manager.koptReader()
    -- 没加载过 ReaderUI 就不可能开着书；不在设置页里连带加载整个阅读器。
    local ReaderUI = package.loaded["apps/reader/readerui"]
    local ui = type(ReaderUI) == "table" and ReaderUI.instance
    local doc = ui and ui.document
    if doc and doc.configurable and doc.koptinterface then
        ---@cast ui table
        return ui
    end
end

--- 当前书的识别语言。
---@return string|nil
function Manager.currentLanguage()
    local ui = Manager.koptReader()
    return ui and ui.document.configurable.doc_language
end

--- 把当前打开的扫描书的识别语言设为 code。没开扫描书返回 false。
---@param code string
---@return boolean
function Manager.applyToOpenDocument(code)
    local ui = Manager.koptReader()
    if not ui then return false end
    ui.document.configurable.doc_language = code
    ui:handleEvent(require("ui/event"):new("DocLangUpdate", code))
    return true
end

return Manager
