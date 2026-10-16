--[[--
生僻字注音：阅读页在生僻字 / 生词上方画拼音或音标。数据是可下载的注音词库（格式见 lexicon）。

只画不改书，挂在 reader/page_marks 的 paint 图层，仅 CRE 滚动排版生效。
lexicon 解析与匹配（纯函数）；overlay 逐字走本屏 → 匹配（vocab：KOReader 生字本可当个人生僻字）→ 按字位置取框 → 绘制，按视口缓存；
panel 阅读快捷面板开关；
catalog 词库清单与下载（复用 features.ime.download.install，assets/rare/<id>/ manifest + 分片，落 .moon/rare/<id>.tsv）。
只有点到注音或被注音的字才开查词窗口，点普通文字不拦截。下载失败不影响阅读，只是没有注音。

@module koplugin.book.features.rare.init
--]]

local Rare = {}

---@param plugin BookPlugin
function Rare.onReaderReady(plugin)
    require("features.rare.overlay").install(plugin.ui)
end

--- 开关注音（快捷面板用）；没有已启用词库时提示先下载、不打开。
---@return boolean 切换后是否开着
function Rare.toggle()
    local MoonSettings = require("utils.settings")
    local s = MoonSettings.get("features.rare")
    if not s.rare_enabled and #require("features.rare.catalog").active() == 0 then
        require("ui.themes.widgets.toast"):new{ text = require("gettext")("请先在设置里下载注音词库"), timeout = 2 }:show()
        return false
    end
    s.rare_enabled = not s.rare_enabled
    MoonSettings.save("features.rare", s)
    require("features.rare.overlay").invalidate()
    return s.rare_enabled
end

return Rare
