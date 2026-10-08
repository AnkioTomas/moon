--[[--
AI 接口的配置声明（settings/ai.lua，经 `utils.settings.get("ai")` 读写）。

@module koplugin.book.ai.setting
--]]

return {
    defaults = { ai_endpoint = "", ai_api_key = "", ai_model = "" },
}
