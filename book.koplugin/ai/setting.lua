--[[--
AI 接口与阅读助手的配置声明（settings/ai.lua，经 `utils.settings.get("ai")` 读写）。

阅读助手（features/ai）的开关也放这里：`features.ai` 的末段同样是 ai，分区文件只能有一个拥有者。

@module koplugin.book.ai.setting
--]]

return {
    defaults = {
        ai_endpoint = "", ai_api_key = "", ai_model = "",
        -- AI 请求超时（秒）：各 AI 功能按倍率 × 它；120 = 原先的缺省，见 http/timeout.lua。
        ai_timeout = 120,
        -- 读完一章自动让 AI 写摘要（花 API 费用，默认关）。
        ai_chapter_summary = false,
        -- 隔几天再开书时弹前情提要（只读本地摘要，不调 AI）。
        ai_recap = true,
    },
}
