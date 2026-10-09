# online/ — ankio.net

路径：[`book.koplugin/online/`](../../book.koplugin/online/)。**不是** BookSource，**不是** feature，**不用** MoonSettings。首页 / 锁屏只读这里的数据。

`online/init.lua` 给 main 用：只在 `onNetworkConnected`（以及启动时）对各端点 `ensure()`。JSON 或图过期、参数变了才入队。`current()` 未过期才有值，否则空。图走 `imagePath()`。缓存文件在 `$DATA/.moon/cache/online/<name>.json`，必应 / 摸鱼日报图同目录。

拉网是后台任务（`kind=online`，顶栏可见），不弹进度窗。没网进 waiting，联网再跑。

## 设计

子类填 `name` / `title` / `url` / `parse`。有图再填 `image_ext`。落盘 `{ expire, data, key, image_url? }`。TTL：天气 4 小时，一言 1 分钟，必应 / 摸鱼日报 `untilMidnight()`。HTTP 一律 `cache_ttl = 0`。`args.ttl == 0` 是试查，不写盘、不下图。

| 模块 | 用途 | TTL |
|---|---|---|
| `weather` | 天气；`city` 由首页 / 夜间模式写入；图标 URL 走 jsDelivr | 4 小时 |
| `hitokoto` | 一言；**无图片接口**；过期是空，首页随机另有回退句 | 1 分钟 |
| `myrl` | 摸鱼日报 JSON + 竖屏日报图（`myrl.png`） | 到午夜 |
| `bing` | 必应壁纸元数据 + 图（`bing.jpg`）；`imageUrl()` 优先当天 link，没有则 302 | 到午夜 |

## 用法

```lua
local Weather = require("online.weather")
local wx = Weather:current()          -- 未过期才有；过期或没有是 nil
Weather:watch(function(data, err) end)
Weather:ensure()                     -- 未过期是空操作；地点变了会拆掉重拉
Weather:unwatch(cb)

Weather.city = "Shanghai"            -- 换地点：写参数再 ensure
Weather:ensure()

Weather:fetch({ city = "Shanghai", ttl = 0 }, cb)  -- 只留给试查异地

-- 新接口：
local Online = require("online.base")
local M = setmetatable({ name = "foo", title = "Foo", ttl = 60 }, Online)
function M:url() return self.host .. "/…" end
function M:parse(body) return … end
```

没有 `refresh`。禁止调用方强制刷网。UI 只拼装，不要在页面里写死 URL，不要把结果写进设置。
