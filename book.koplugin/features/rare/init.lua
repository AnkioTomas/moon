--[[--
生僻字注音：阅读页在生僻字 / 生词上方画拼音或音标。数据是可下载的注音词库（格式见 lexicon）。

只画不改书，挂在 reader/page_marks 的 paint 图层，仅 CRE 滚动排版生效。
lexicon 解析与匹配（纯函数）；overlay 取屏上文字 → 匹配 → findText 取框 → 绘制，按视口缓存，单屏取框预算 250ms；
catalog 词库清单与下载（复用 features.ime.download.install，assets/rare/<id>/ manifest + 分片，落 .moon/rare/<id>.tsv）。
只有点到注音或被注音的字才开查词窗口，点普通文字不拦截。下载失败不影响阅读，只是没有注音。

@module koplugin.book.features.rare.init
--]]

local Rare = {}

---@param plugin BookPlugin
function Rare.onReaderReady(plugin)
    require("features.rare.overlay").install(plugin.ui)
end

return Rare
