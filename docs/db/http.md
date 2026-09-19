# http

## 职责

HTTP **成功响应**的本地 JSON 文本缓存（键 → value + 过期时间），供 `Request.get` / 各 client 在 `cache_ttl>0` 时命中，避免重复拉网。

## 非职责

- 与书架 / 进度 / 注解 / 统计同步**无关**
- 不存文件路径、不存 Cookie、不存失败响应
- 不负责业务层「是否该刷新」之外的语义（TTL 由调用方传入）

## 主键 / 索引

- **PK**：`key`
- `idx_http_expires (expires)` — 读前批量淘汰过期行

## 列契约

| 列 | 含义 | 谁写 | 谁读 | 备注 |
|---|---|---|---|---|
| `key` | 缓存键 | `HttpDB.set` | get / clear | 形如 `GET https://host/path?a=1`；可附加 `@len:scope` 隔离认证用户 |
| `value` | JSON 文本 | set（`JSON.encode` 后） | get → decode | NOT NULL |
| `expires` | Unix 秒级过期 | set（`os.time()+ttl`） | get 前 `DELETE WHERE expires<=now` | 列名是 `expires`，不是 `expires_at` |

## 数据流

| 场景 | 路径 |
|---|---|
| GET + `cache_ttl>0` | `http/request` → `http.cache` → `HttpDB.get`；未命中则请求，成功后 `Cache.set` → `HttpDB.set` |
| 写操作后失效 | `Request.clearCache` / `Cache.clear`（可按 URL 子串） |
| 典型调用方 | `online/*`、`zlib/client`、`source/moon/client` 等只读 GET |

键构造见 [`http/cache.lua`](../../book.koplugin/http/cache.lua) 的 `Cache.key`：METHOD + URL（query 规范化）；提供 query 表时剥掉 URL 自带 `?…`，避免双重查询。

## 同步语义

仅本地。无 `sync_status`。与云书架无关。

## 与其他表关系

独立。与 [`books`](books.md) 无边。

## 不变量 / 地雷

1. 只缓存成功响应；`ttl<=0` 或 encode 失败则跳过写入。  
2. get 时 JSON 损坏会删行再 miss，不要静默返回坏数据。  
3. 带鉴权的易变响应若误开长 TTL，会脏读；应用 `scope` 隔离用户。

## 代码入口

- [`book.koplugin/db/http.lua`](../../book.koplugin/db/http.lua)
- [`book.koplugin/http/cache.lua`](../../book.koplugin/http/cache.lua)
- [`book.koplugin/http/request.lua`](../../book.koplugin/http/request.lua)
