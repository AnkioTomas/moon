# online/ — ankio.net

路径：[`book.koplugin/online/`](../../book.koplugin/online/)。**不是** BookSource。首页 / 锁屏消费这里的数据。

## 设计

子类填 `url` / `parse`；TTL 原样交给 `Request.get(cache_ttl)`。要离线兜底再覆盖 `store` / `load`。日更用 `Online.untilMidnight()`，别写死 24h。

| 模块 | 用途 |
|---|---|
| `weather` | 天气；图标 URL 走 jsDelivr（`assets/weather/`，不进插件包） |
| `hitokoto` | 一言（可落设置）；**无图片接口** |
| `bing` / `myrl` | 壁纸 URL；落盘在 lockscreen.background |

## 用法

```lua
local Weather = require("online.weather")
Weather:fetch({}, function(data, err) end)  -- 第一参 args（可含 ttl 覆盖，0=不走缓存）

-- 新接口：
local Online = require("online.base")
local M = setmetatable({}, Online)
M.url = function(self) return self.host .. "/…" end
function M:parse(body) return … end
```

UI 只拼装，不要在页面里写死 URL。
