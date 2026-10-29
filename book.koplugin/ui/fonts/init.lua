--[[--
月读插件字体：id → 文件 → CRE 字体名的解析，以及 UI 字体设置。

  set(id, name)       写 ui.ui_font / ui_font_name；非空 id 须 FreeType 能打开，否则拒绝
  applyCurrent()      唯一改 Font.fontmap 的入口；坏字体/污染的 settings.fontmap 回退 SAFE_UI
  canOpen(path)       FreeType 实开探测（选字体与 apply 共用）
  faceForId / faceNameForId  解析字体名（前者顺带注册进 CRE）；pathForId 只给文件路径

字源：
  id == ""                         恢复首次备份的 fontmap（配置空值；选择器不提供此项）
  .moon/fonts/<id>.ttf             微信读书已下载（旧版 <id>.woff 解析时就地转换）
  $DATA/fonts/<basename>           KOReader 设置目录字库
  FontList 其余路径                 系统字库（basename == id）

列表与下载在 `ui.fonts.catalog`，应用到阅读文档在 `ui.fonts.reader`。

@module koplugin.book.ui.fonts
--]]

local DataStorage = require("datastorage")
local Font = require("ui/font")
local FontList = require("fontlist")
local lfs = require("libs/libkoreader-lfs")
local logger = require("utils.log")
local util = require("util")
local Paths = require("utils.paths")
local MoonSettings = require("utils.settings")
local Text = require("utils.text")
local Woff = require("ui.fonts.woff")
local _ = require("gettext")

local Fonts = {}

local UI_FACES = {
    "cfont", "tfont", "smalltfont", "x_smalltfont",
    "ffont", "smallffont", "largeffont",
    "rifont", "pgfont", "hfont",
    "infofont", "smallinfofont", "smallinfofontbold",
    "x_smallinfofont", "xx_smallinfofont",
}

-- KOReader frontend/ui/font.lua 默认值；settings.reader.lua 里的 fontmap 若已是坏字体，
-- 进程里 Font.fontmap 在插件 init 前就被污染，不能当「恢复默认」的备份源。
local SAFE_UI = {
    cfont = "NotoSans-Regular.ttf",
    tfont = "NotoSans-Bold.ttf",
    smalltfont = "NotoSans-Bold.ttf",
    x_smalltfont = "NotoSans-Bold.ttf",
    ffont = "NotoSans-Regular.ttf",
    smallffont = "NotoSans-Regular.ttf",
    largeffont = "NotoSans-Regular.ttf",
    rifont = "NotoSans-Regular.ttf",
    pgfont = "NotoSans-Regular.ttf",
    hfont = "NotoSans-Regular.ttf",
    infofont = "NotoSans-Regular.ttf",
    smallinfofont = "NotoSans-Regular.ttf",
    smallinfofontbold = "NotoSans-Bold.ttf",
    x_smallinfofont = "NotoSans-Regular.ttf",
    xx_smallinfofont = "NotoSans-Regular.ttf",
}

local _defaults = nil
local _bold_patched = false
local _registered_fonts = {}
-- 只缓存已解析的字体路径；命中后检查目标文件，避免每次开书遍历整个字库。
local _resolved_paths = {}

--- 微信读书字体在 .moon/fonts 下的落盘路径（sfnt）。
--- id 去空白后非 [%w._-] 一律换成下划线，才能安全拼进文件名。
---@param id string
---@return string|nil nil 表示 id 规范化后为空
function Fonts.wereadPath(id)
    id = Text.stripWhitespace(id):gsub("[^%w%._%-]", "_")
    if id == "" then return nil end
    return Paths.fontsDir() .. "/" .. id .. ".ttf"
end

---@param path string|nil
---@return boolean
function Fonts.isFile(path)
    return path ~= nil and lfs.attributes(path, "mode") == "file"
end

--- 已下载的微信读书字体文件：.ttf，或旧版直接落盘、尚未迁移的 .woff；未下载返回 nil。
---@param id string
---@return string|nil
function Fonts.downloadedPath(id)
    local path = Fonts.wereadPath(id)
    if not path then return nil end
    if Fonts.isFile(path) then return path end
    local woff = path:gsub("%.ttf$", ".woff")
    return Fonts.isFile(woff) and woff or nil
end

--- 删除已下载的微信读书字体文件（.ttf 与旧版 .woff）。
---@param id string
---@return boolean removed 至少删掉一个文件
function Fonts.removeDownloaded(id)
    _resolved_paths[id] = nil
    local path = Fonts.wereadPath(id)
    if not path then return false end
    local removed = false
    for _idx, file in ipairs({ path, (path:gsub("%.ttf$", ".woff")) }) do
        if Fonts.isFile(file) then
            removed = os.remove(file) == true or removed
            _registered_fonts[file] = nil
        end
    end
    return removed
end

--- WOFF 落成 path 处的 sfnt；WOFF2 或损坏时原样改名（FreeType 按内容识别），不再重复尝试。
---@param woff string
---@param path string
---@return boolean
function Fonts.finalizeWoff(woff, path)
    local ok, err = Woff.toSfnt(woff, path)
    if ok then
        os.remove(woff)
        return true
    end
    logger.warn("book.font woff convert failed", woff, err)
    return os.rename(woff, path) == true
end

--- KOReader 设置目录 fonts（$DATA/fonts）
---@return string
function Fonts.settingsFontsDir()
    return DataStorage:getDataDir() .. "/fonts"
end

--- 已装的微信读书字体路径；旧版 .woff 在这里就地迁移。
---@param id string
---@return string|nil
local function installedWereadPath(id)
    local found = Fonts.downloadedPath(id)
    if not found or not found:match("%.woff$") then return found end
    local path = found:gsub("%.woff$", ".ttf")
    return Fonts.finalizeWoff(found, path) and path or found
end

--- 把字体文件路径插到 FontList 队首，让 KOReader 能解析到它。
--- 已在列表里就不重复插；插队首是为了同名 basename 时优先命中本插件指定的文件。
---@param path string
local function registerFontPath(path)
    FontList:getFontList()
    for _idx, p in ipairs(FontList.fontlist) do
        if p == path then return end
    end
    table.insert(FontList.fontlist, 1, path)
end

--- 在目录树里按 basename 找字体文件。
---@param dir string
---@param id string
---@return string|nil
local function findInDir(dir, id)
    local found
    if lfs.attributes(dir, "mode") ~= "directory" then
        return nil
    end
    util.findFiles(dir, function(path, file)
        if not found and file == id then
            found = path
        end
    end)
    return found
end

--- 设置目录或 FontList 里按 basename 找字体。
---@param id string
---@return string|nil
local function findInstalledFont(id)
    local path = findInDir(Fonts.settingsFontsDir(), id)
    if path then return path end
    FontList:getFontList()
    for _idx, p in ipairs(FontList.fontlist or {}) do
        if Text.basename(p) == id and Fonts.isFile(p) then return p end
    end
    return nil
end

---@param path string
---@return table|nil
local function ensureFontInfo(path)
    FontList:getFontList()
    if FontList.fontinfo[path] then
        return FontList.fontinfo[path]
    end
    -- 只读这一个文件：_readList 会把整个目录的字体逐个打开（几十个大 CJK 字体在 Kindle 上要十几秒）。
    -- collectFaceInfo 是 fontlist 的局部函数，从 _readList 的上值里取；取不到退回整目录读。
    local collect
    for i = 1, math.huge do
        local name, value = debug.getupvalue(FontList._readList, i)
        if not name then break end
        if name == "collectFaceInfo" then collect = value break end
    end
    if collect then
        local fi = collect(path)
        if fi and next(fi) then
            fi.change = lfs.attributes(path, "change")
            FontList.fontinfo[path] = fi
        end
        return FontList.fontinfo[path]
    end
    local dir = path:match("^(.*)/[^/]+$")
    if not dir then
        return nil
    end
    -- _readList 会把整个目录追加进 fontlist；path 已由 registerFontPath 登记，追加的全部截掉。
    local n = #FontList.fontlist
    FontList:_readList(dir, { cache_dirty = false })
    for i = #FontList.fontlist, n + 1, -1 do
        FontList.fontlist[i] = nil
    end
    return FontList.fontinfo[path]
end

--- 字体 id → 字体文件路径，并登记进 FontList。
---@param id string
---@return string|nil path, string|nil err
local function resolvePath(id)
    local path = _resolved_paths[id]
    if path and Fonts.isFile(path) then return path end
    _resolved_paths[id] = nil
    path = installedWereadPath(id) or findInstalledFont(id)
    if not path then return nil, _("字体文件不存在") end
    registerFontPath(path)
    _resolved_paths[id] = path
    return path
end

--- 字体 id → 字体文件路径（登记进 FontList）；不读字体信息，自绘只要文件时用这个。
---@type fun(id: string): string|nil, string|nil
Fonts.pathForId = resolvePath

--- 字体 id → CRE 字体名与字体文件路径；不触发 CRE 注册，用于偏好比较和保存。
---@param id string
---@return string|nil face, string|nil err, string|nil path
function Fonts.faceNameForId(id)
    local path, err = resolvePath(id)
    if not path then return nil, err end
    local info = ensureFontInfo(path)
    if not info or not info[1] or not info[1].name then
        local f = io.open(path, "rb")
        local magic = f and f:read(4) or ""
        if f then f:close() end
        logger.warn("book font unreadable", path, "magic=" .. string.format("%q", magic))
        -- 已下载的微信读书字体读不出就是坏文件：删掉，下次选择时重新下载，不再永远卡在「已下载」。
        if path == Fonts.wereadPath(id) then os.remove(path) end
        return nil, _("应用字体失败")
    end
    return info[1].name, nil, path
end

---@param id string
---@return string|nil, string|nil
function Fonts.faceForId(id)
    local face, err, path = Fonts.faceNameForId(id)
    if not face or _registered_fonts[path] then
        return face, err
    end
    local cre = require("document/credocument"):engineInit()
    local registered, register_err = pcall(cre.registerFont, path)
    logger.dbg(
        "book font register",
        "id=" .. tostring(id),
        "path=" .. path,
        "face=" .. face,
        "registered=" .. tostring(registered),
        "error=" .. tostring(register_err)
    )
    -- engineInit 已注册 FontList 里的全部字体，crengine 拒绝同一路径重复注册；
    -- 所以注册失败时只要该字体名已可用就算成功。
    if not registered and not util.arrayContains(cre.getFontFaces(), face) then
        return nil, _("应用字体失败")
    end
    _registered_fonts[path] = true
    return face
end

--- FreeType 能否真正打开该文件。文件在盘上 ≠ 可用：坏 ttf / 假后缀 / 截断下载
--- 会让 KOReader 冷启动建 FileManager 时 face 为 nil 直接崩（见 KPW5 crash.log）。
---@param path string
---@return boolean
function Fonts.canOpen(path)
    if not Fonts.isFile(path) then return false end
    local ok, size = pcall(function()
        return require("ffi/freetype").newFaceSize(path, 16)
    end)
    if not ok or not size then return false end
    -- newFaceSize 的 face 进弱缓存；size 用完立刻释放，避免无意义占坑。
    if type(size) == "table" or type(size) == "cdata" then
        pcall(function() size:done() end)
    end
    return true
end

--- fontmap 里的 basename（如 xwwk.ttf）能否被 FreeType 打开（内置目录或 FontList）。
---@param basename string|nil
---@return boolean
local function canOpenMapped(basename)
    if type(basename) ~= "string" or basename == "" then return false end
    local dir = FontList.fontdir
    if dir and Fonts.canOpen(dir .. "/" .. basename) then return true end
    FontList:getFontList()
    local escaped = basename:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
    for _idx, path in ipairs(FontList.fontlist or {}) do
        if path:find(escaped, 1) and Fonts.canOpen(path) then return true end
    end
    return false
end

--- 清掉 KOReader 持久化的 fontmap（reader.lua 启动时会灌进 Font.fontmap，早于插件）。
local function clearPersistedFontmap()
    local settings = rawget(_G, "G_reader_settings")
    if settings and settings.has and settings:has("fontmap") then
        settings:delSetting("fontmap")
        logger.warn("book.font cleared persisted fontmap")
    end
end

--- 当前配置的 UI 字体 id；空串表示用系统默认 fontmap。
---@return string
function Fonts.currentId()
    return MoonSettings.get("ui").ui_font or ""
end

--- 当前 UI 字体的显示名：优先用配置里记的中文名，退回 id，都没有显示「系统默认」。
---@return string
function Fonts.currentName()
    local s = MoonSettings.get("ui")
    if s.ui_font_name and s.ui_font_name ~= "" then return s.ui_font_name end
    if s.ui_font and s.ui_font ~= "" then return s.ui_font end
    return _("系统默认")
end

--- 写 ui.ui_font；非空 id 必须能被 FreeType 打开，否则拒绝落盘（避免一键砖机）。
---@param id string 空=恢复默认 fontmap
---@param name string|nil
---@return boolean|nil ok, string|nil err
function Fonts.set(id, name)
    if id ~= "" then
        local path, err = resolvePath(id)
        if not path then return nil, err or _("字体文件不存在") end
        if not Fonts.canOpen(path) then
            -- 微信读书下载的坏包清掉，下次可选「重新下载」。
            if path == Fonts.wereadPath(id) then Fonts.removeDownloaded(id) end
            return nil, _("字体文件损坏，无法用作界面字体")
        end
    end
    local s = MoonSettings.get("ui")
    s.ui_font = id
    s.ui_font_name = id ~= "" and name or ""
    MoonSettings.save("ui")
    logger.info("book.font set", id, s.ui_font_name)
    return true
end

--- 清掉已落盘的坏界面字体配置（不经 set 校验，避免循环）。
local function clearUiFont()
    local s = MoonSettings.get("ui")
    s.ui_font = ""
    s.ui_font_name = ""
    MoonSettings.save("ui")
end

--- 把配置里的字体真正写进 Font.fontmap（唯一改 fontmap 的入口）。
--- 文件缺失或 FreeType 打不开时退回系统默认并清配置，不让 KO 因坏字体起不来。
--- 在 FileManager:setupLayout 之前由插件 init 调用，正好挡在冷启动崩点前。
function Fonts.applyCurrent()
    -- 只备份一次。settings 里已污染的 fontmap 不能当备份，改用 SAFE_UI。
    if not _defaults then
        _defaults = {}
        local healed = false
        for _idx, key in ipairs(UI_FACES) do
            local cur = Font.fontmap[key]
            if canOpenMapped(cur) then
                _defaults[key] = cur
            else
                _defaults[key] = SAFE_UI[key] or "NotoSans-Regular.ttf"
                Font.fontmap[key] = _defaults[key]
                healed = true
            end
        end
        if healed then clearPersistedFontmap() end
    end
    -- 界面字体加粗：TextWidget / TextBoxWidget 创建时都经 getAdjustedFace 决定是否加粗，在这里统一打开。
    if not _bold_patched then
        _bold_patched = true
        local adjusted = Font.getAdjustedFace
        Font.getAdjustedFace = function(self, face, bold)
            return adjusted(self, face, bold or MoonSettings.get("ui").font_bold or nil)
        end
    end
    local id = Fonts.currentId()
    local path = id ~= "" and select(1, resolvePath(id)) or nil
    if path and Fonts.canOpen(path) then
        local base = Text.basename(path)
        for _idx, key in ipairs(UI_FACES) do
            Font.fontmap[key] = base
        end
        return
    end
    if id ~= "" then
        logger.warn("book.font unusable, fallback default", id, path and "bad file" or "missing")
        if path and path == Fonts.wereadPath(id) then Fonts.removeDownloaded(id) end
        clearUiFont()
    end
    for key, val in pairs(_defaults) do
        Font.fontmap[key] = val
    end
    clearPersistedFontmap()
end

--- 插件 init：UI fontmap 每进程应用一次，阅读字体组合按文档安装。
function Fonts.onCreate(ui)
    if not _defaults then Fonts.applyCurrent() end
    if ui and ui.document then require("ui.fonts.mixed").install(ui.document) end
end

return Fonts
