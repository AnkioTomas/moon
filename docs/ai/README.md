# ai/ — OpenAI 兼容门面

路径：[`ai.lua`](../../book.koplugin/ai.lua) + [`ai/`](../../book.koplugin/ai/)。

其它模块统一 `require("ai")`，不要直连 `ai.client`。

## 设计

- 传输：`ai/client.lua` 走 `http.request` 的非流式 POST；当前不支持流式输出
- `ai/json.lua` 从模型输出里抽 JSON
- 密钥/端点/模型在设置里；**禁止写进日志**
- X-Ray 等上层只调门面，不关心 provider 细节

## 用法

```lua
local AI = require("ai")

if not AI.isConfigured() then return end

AI.chat({
    { role = "system", content = "…" },
    { role = "user", content = "…" },
}, { temperature = 0.2, max_tokens = 1024 }, function(content, err)
    …
end)

-- 让模型吐结构化 JSON 再解析；opts 可省略（第二参直接传 cb）
AI.jsonExtract(messages, opts, function(obj, err) end)
```

配置项在 reader/AI 设置页；未配置齐全时 `isConfigured()` 为 false，调用方应隐藏入口或提示去设置。
