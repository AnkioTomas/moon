--[[--
开书检测缺失字体并提示映射；阅读快捷面板修改映射后自动重载当前书籍。
扫描在子进程只读书籍，别名只加在当前文档用户样式中，不改原书或下载缓存。

@module koplugin.book.features.fontmap
--]]

require("l10n").apply()
local _ = require("gettext")
local T = require("ffi/util").template

---@class BookFontMap
---@field ui table
---@field names string[]|nil
---@field active table<string, string>
---@field alias_css string
---@field job BookJob|nil
---@field dialog table|nil
---@field closed boolean
---@field requested boolean
---@field prepared boolean|nil
---@field setStyleSheet function
---@field setFontFamilyFontFaces function|nil
local FontMap = {}
FontMap.__index = FontMap

function FontMap:prepare()
    if self.prepared then return end
    self.prepared = true
    local faces = {}
    for name, mapping in pairs(require("utils.settings").get("features.fontmap").mappings) do
        if faces[mapping.id] == nil then
            local face, err = require("ui.fonts").faceForId(mapping.id)
            faces[mapping.id] = face or false
            if not face then require("utils.log").warn("fontmap target unavailable", name, err) end
        end
        if faces[mapping.id] then self.active[name] = faces[mapping.id] end
    end
    self.alias_css = FontMap.css(self.active)
end

--- KOReader a72790090 首次更新了支持用户样式表 @font-face 的 CRE。
function FontMap.supported()
    local version = require("version"):getNormalizedCurrentVersion()
    return version ~= nil and version >= 202607020046
end

---@param ui table|nil
---@return boolean
function FontMap.available(ui)
    if not FontMap.supported() or not ui or not ui.rolling or type(ui.document.setStyleSheet) ~= "function"
        or type(ui.document.getEmbeddedFontList) ~= "function" then return false end
    local ext = ui.document.file:lower():match("%.([%w]+)$")
    if ext ~= "epub" and ext ~= "html" and ext ~= "htm" and ext ~= "xhtml" and ext ~= "fb2" and ext ~= "zip" then
        return false
    end
    local identity = require("book.store").identityFor(ui.document.file)
    return not identity or identity.source_id ~= "subscribe"
end

local function quote(name)
    return '"' .. name:gsub("\\", "\\\\"):gsub('"', '\\"')
        :gsub("\r", "\\d "):gsub("\n", "\\a "):gsub("\f", "\\c ") .. '"'
end

---@param mappings table<string, string> 源字体名 → 已注册的目标字体族名
---@return string
function FontMap.css(mappings)
    local names, css = {}, {}
    for name in pairs(mappings) do names[#names + 1] = name end
    table.sort(names)
    for _idx, name in ipairs(names) do
        if name ~= mappings[name] then
            css[#css + 1] = "@font-face{font-family:" .. quote(name) .. ";src:local(" .. quote(mappings[name]) .. ");}"
        end
    end
    return table.concat(css, "\n")
end

---@param ui table
---@return BookFontMap
function FontMap.new(ui)
    local self = setmetatable({ ui = ui, active = {}, alias_css = "", closed = false, requested = false }, FontMap)
    local document = ui.document
    self.setStyleSheet = document.setStyleSheet
    document.setStyleSheet = function(doc, file, appended)
        if self:stylesEnabled() then
            -- CRE 在解析书籍时登记别名；等 sidecar 设置就绪再准备，关闭样式的书不注册字体。
            self:prepare()
            if self.alias_css ~= "" then appended = self.alias_css .. "\n" .. (appended or "") end
        end
        return self.setStyleSheet(doc, file, appended)
    end
    -- 映射明确要求采用本书字体名；仅覆盖当前文档，不改全局「忽略出版方字体名」设置。
    self.setFontFamilyFontFaces = document.setFontFamilyFontFaces
    if self.setFontFamilyFontFaces then
        document.setFontFamilyFontFaces = function(doc, families, ignore)
            if self.names and next(self.active) and self:stylesEnabled() then ignore = false end
            return self.setFontFamilyFontFaces(doc, families, ignore)
        end
    end
    return self
end

---@return boolean
function FontMap:stylesEnabled()
    return self.ui.document.configurable.embedded_css ~= 0
end

--- 仅应用当前书用到的映射；不存在的目标字体重新列为缺失，不拖累其它书。
function FontMap:refresh()
    self:prepare()
    local active = {}
    for _idx, name in ipairs(self.names or {}) do
        if self.active[name] then active[name] = self.active[name] end
    end
    self.active = active
    self.alias_css = FontMap.css(active)
    if next(active) then
        self.ui.document.configurable.embedded_fonts = 1
        self.ui.doc_settings:saveSetting("copt_embedded_fonts", 1)
        self.ui.document:setEmbeddedFonts(1)
        if self.ui.font then self.ui.font:updateFontFamilyFonts() end
        self.ui:handleEvent(require("ui/event"):new("ApplyStyleSheet"))
    end
end

---@return table<string, boolean>
function FontMap:installed()
    local installed = {}
    for _idx, name in ipairs(self.ui.document:engineInit().getFontFaces()) do installed[name:lower()] = true end
    for name in pairs(self.ui.document:getEmbeddedFontList()) do installed[name:lower()] = true end
    return installed
end

---@return string[]
function FontMap:missing()
    local installed, missing = self:installed(), {}
    for _idx, name in ipairs(self.names or {}) do
        if not installed[name:lower()] and not self.active[name] then missing[#missing + 1] = name end
    end
    return missing
end

---@param name string
function FontMap:pick(name)
    local settings = require("utils.settings")
    local mappings = settings.get("features.fontmap").mappings
    require("ui.widgets.fontpicker").open{
        title = T(_("映射字体：%1"), name),
        current_id = function() return mappings[name] and mappings[name].id or "" end,
        on_select = function(_item, id, label)
            if self.closed then return end
            local face, err = require("ui.fonts").faceForId(id)
            if not face then
                require("ui.themes.widgets.toast"):new{ text = err }:show()
                return
            end
            mappings[name] = { id = id, name = label }
            settings.save("features.fontmap")
            self.ui.document.configurable.embedded_fonts = 1
            self.ui.doc_settings:saveSetting("copt_embedded_fonts", 1)
            self.ui:reloadDocument(nil, true)
        end,
    }
end

---@param names string[]
---@return table[]
function FontMap:items(names)
    local mappings = require("utils.settings").get("features.fontmap").mappings
    local installed, items = self:installed(), {}
    for _idx, name in ipairs(names) do
        items[#items + 1] = {
            text = name,
            mandatory = self.active[name] and mappings[name].name
                or (installed[name:lower()] and _("本机已有") or _("缺失字体")),
            keep_open = true, chevron = true,
            callback = function()
                if not mappings[name] then self:pick(name); return end
                require("ui.themes.widgets.sheet"):new{
                    title = name,
                    items = {
                        { text = _("更换映射字体"), callback = function() self:pick(name) end },
                        { text = _("清除映射"), callback = function()
                            mappings[name] = nil
                            require("utils.settings").save("features.fontmap")
                            -- CRE 没有删除文档字体别名的 Lua API；重载才能真正恢复原字体。
                            self.ui:reloadDocument(nil, true)
                        end },
                    },
                }:show()
            end,
        }
    end
    return items
end

---@param names string[]
function FontMap:show(names)
    if self.closed or self.dialog then return end
    if #names == 0 then
        require("ui.themes.widgets.toast"):new{ text = _("未检测到书内指定的字体") }:show()
        return
    end
    self.dialog = require("ui.themes.widgets.list"):new{
        title = _("书内字体映射"),
        subtitle = _("选择后自动重载本书生效，映射可供其它书复用"),
        items = self:items(names),
        close_callback = function() self.dialog = nil end,
    }
    self.dialog.font_names = names
    self.dialog:show()
end

---@param requested boolean 从快捷面板主动打开时展示全部字体，否则只提示缺失字体。
function FontMap:start(requested)
    if not FontMap.supported() or self.closed then return end
    if not self:stylesEnabled() then
        if requested then require("ui.themes.widgets.toast"):new{ text = _("请先开启本书的内嵌样式") }:show() end
        return
    end
    self.requested = self.requested or requested
    if self.names then
        if requested then self:show(self.names) end
        return
    end
    if self.job then return end
    local path = self.ui.document.file
    self.job = require("workers.job").run(function()
        return require("features.fontmap.scan").book(path)
    end, {
        name = "fontmap.scan", kind = "light",
        on_done = require("ui.guard").wrap("fontmap.scan", function(names)
            self.job = nil
            if self.closed or not self:stylesEnabled() then return end
            self.names = names
            if #names > 0 then self:refresh() end
            local show = self.requested and names or self:missing()
            if #show > 0 or self.requested then self:show(show) end
        end),
        on_failed = function(err)
            self.job = nil
            if self.closed then return end
            require("utils.log").warn("fontmap scan failed", path, err)
            require("ui.themes.widgets.toast"):new{ text = T(_("检测书内字体失败：%1"), err) }:show()
        end,
    })
end

function FontMap:close()
    self.closed = true
    if self.job then self.job:cancel(); self.job = nil end
    if self.dialog then self.dialog:close() end
    self.ui.document.setStyleSheet = self.setStyleSheet
    if self.setFontFamilyFontFaces then self.ui.document.setFontFamilyFontFaces = self.setFontFamilyFontFaces end
end

---@param plugin BookPlugin
function FontMap.onReaderReady(plugin)
    local ui = plugin.ui
    if ui._book_fontmap then ui._book_fontmap:start(false) end
end

---@param plugin BookPlugin
function FontMap.onCreate(plugin)
    local ui = plugin.ui
    if not FontMap.available(ui) or ui._book_fontmap then return end
    ui._book_fontmap = FontMap.new(ui)
end

---@param plugin BookPlugin
function FontMap.onExit(plugin)
    local state = plugin.ui and plugin.ui._book_fontmap
    if state then state:close(); plugin.ui._book_fontmap = nil end
end

FontMap.events = { CloseDocument = FontMap.onExit }

return FontMap
