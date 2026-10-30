--[[--
行间标注：阅读页在生僻字 / 生词上方画拼音、音标或 WordWise 短释义。
注音（rare_ruby）与释义（rare_wordwise）独立开关，可同时开；按文字类型分流。
开启任一类时若当前行距过小，抬到 rare_min_spacing（默认 140%），否则行间塞不下标注。

@module koplugin.book.features.rare.init
--]]

local Rare = {}

--- 开启标注时保证的最小行距默认值（CRE line_spacing，百分比）；设置项 rare_min_spacing 可改。
Rare.MIN_LINE_SPACING = 140

--- 当前生效的最小行距（设置优先）。0 = 关闭自动抬行距；否则夹在 100–200。
---@param s table|nil
---@return number
function Rare.minLineSpacing(s)
    s = Rare.migrate(s)
    local n = tonumber(s.rare_min_spacing)
    if n == nil then n = Rare.MIN_LINE_SPACING end
    if n <= 0 then return 0 end
    if n < 100 then return 100 end
    if n > 200 then return 200 end
    return n
end

---@param plugin BookPlugin
function Rare.onReaderReady(plugin)
    require("features.rare.overlay").install(plugin.ui)
end

--- 旧版只有 rare_enabled：迁成 rare_ruby（历史注音）。释义需用户再开。
---@param s table|nil
---@return table
function Rare.migrate(s)
    local MoonSettings = require("utils.settings")
    s = s or MoonSettings.get("features.rare")
    if s.rare_split_migrated then return s end
    if s.rare_enabled and not s.rare_ruby and not s.rare_wordwise then
        s.rare_ruby = true
    end
    s.rare_split_migrated = true
    s.rare_enabled = s.rare_ruby or s.rare_wordwise or false
    -- 测试桩可能没有 save；生产路径必有。
    if type(MoonSettings.save) == "function" then
        MoonSettings.save("features.rare", s)
    end
    return s
end

---@param s table|nil
---@return boolean
function Rare.anyOn(s)
    s = Rare.migrate(s)
    return s.rare_ruby == true or s.rare_wordwise == true
end

---@param kind "ruby"|"wordwise"
---@param s table|nil
---@return boolean
function Rare.kindOn(kind, s)
    s = Rare.migrate(s)
    if kind == "wordwise" then return s.rare_wordwise == true end
    return s.rare_ruby == true
end

--- 行距低于下限则抬高（只升不降）；返回是否改过。
---@param ui table|nil ReaderUI
---@return boolean
function Rare.ensureLineSpacing(ui)
    if not (ui and ui.document and ui.document.configurable and ui.document.setInterlineSpacePercent) then
        return false
    end
    local min = Rare.minLineSpacing()
    if min <= 0 then return false end
    local cur = tonumber(ui.document.configurable.line_spacing) or 0
    if cur >= min then return false end
    ui.document.configurable.line_spacing = min
    ui.document:setInterlineSpacePercent(min)
    ui:handleEvent(require("ui/event"):new("UpdatePos"))
    require("ui.themes.widgets.toast"):new{
        text = require("ffi/util").template(
            require("gettext")("行距过小，已调至 %1%% 以便放下标注"),
            min),
        timeout = 3,
    }:show()
    return true
end

--- 切换注音或释义（快捷面板 / 设置页）。没有该类型已启用词库时提示、不打开。
---@param kind "ruby"|"wordwise"
---@param ui table|nil ReaderUI（有则在开启时检查行距）
---@return boolean 切换后该类是否开着
function Rare.toggleKind(kind, ui)
    local MoonSettings = require("utils.settings")
    local s = Rare.migrate()
    local key = kind == "wordwise" and "rare_wordwise" or "rare_ruby"
    local turning_on = not s[key]
    if turning_on then
        local ok = false
        for id, on in pairs(s.rare_lexicons or {}) do
            if on and require("features.rare.catalog").kind(id) == kind
                and require("features.rare.catalog").installed(id) then
                ok = true
                break
            end
        end
        if not ok then
            local tip = kind == "wordwise"
                and require("gettext")("请先在设置里下载并启用释义词库")
                or require("gettext")("请先在设置里下载并启用注音词库")
            require("ui.themes.widgets.toast"):new{ text = tip, timeout = 2 }:show()
            return false
        end
    end
    s[key] = turning_on or nil
    s.rare_enabled = s.rare_ruby or s.rare_wordwise or false
    MoonSettings.save("features.rare", s)
    if turning_on then Rare.ensureLineSpacing(ui) end
    require("features.rare.overlay").invalidate()
    return turning_on
end

--- 切换标注范围；两类都关着时顺带打开注音（有词库才开）。
---@param level string rarest / rare / all
---@param ui table|nil
function Rare.setLevel(level, ui)
    local MoonSettings = require("utils.settings")
    local s = Rare.migrate()
    s.rare_level = level
    MoonSettings.save("features.rare", s)
    require("features.rare.overlay").invalidate()
    if not Rare.anyOn(s) then Rare.toggleKind("ruby", ui) end
end

return Rare
