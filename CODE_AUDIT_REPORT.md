# `book.koplugin/` 近 3 天改动代码审计报告

审计基线：`1834d792`，2026-11-03。范围：近 3 天 `git log --since="3 days ago"`（约 50 个提交，`book.koplugin/` 202 个文件变更，净删约 5600 行）。逐个细读的是新增体量最大、且位于网络 / 文件替换 / 登出 / 防休眠路径上的文件：`utils/plugin_update.lua`、`utils/plugin_install.lua`、`http/release.lua`、`http/dns.lua`、`source/logout.lua`、`source/legado/scan.lua`、`source/wechat/shelf_import.lua`、`utils/awake.lua`、`source/kindle/plugin_update.lua`、`source/kavita/kamare_update.lua`，以及 `reader/session/progress.lua`、`features/subscribe/source.lua` 的新改动；其余文件只做了 diff 模式扫描（`pcall(require`、`tostring/tonumber`、裸 `_`、`goto`），没有逐行读。以下是有证据的发现，不声称穷尽。本次仅生成报告，未修改业务代码。

## 需求理解

找出近 3 天改动里的重复实现、单行转发、无效防御和可能的 bug，并在模拟器里验证能验证的部分。

## 核心判断

**值得做，但量很小。** 近 3 天整体是净删代码方向（`-7718 / +2091`），新引入的更新引擎 `utils/plugin_update.lua` 已经把月读 / kamare / kindle.koplugin 三套更新流程收成一份，没有发现 P1 / P2 级问题；只有少量 P3 级可删防御与待确认边界。

## 关键问题

* **数据结构：** 插件更新三个目标（月读 / kamare / kindle）只是 target 描述表，流程唯一，没有分叉的近复制。
* **复杂度：** 最大一块是 `http/dns.lua`（自写 UDP DNS + 多平台 nameserver 读取），复杂度来自设备约束（不能阻塞 getaddrinfo），`pcall` 都有明确来源（ffi 重复声明、平台探测），不算垃圾。
* **最大风险：** 无 P1。最像风险的是登出清库与分批导入收尾这两条「批量标删」路径，目前代码里都有护栏（登出先删凭证；`hideMissing` 对空 keep 不动）。

## 详细发现

### 一、重复实现，优先处理

未发现。`source/kindle/plugin_update.lua` 与 `source/kavita/kamare_update.lua` 的 `text` 表结构相似，但只有两份、文案不同，符合 Rule of Three，不抽。

### 二、单行包装与空层

未发现。`Logout.perform / row / abort` 各自有语义；`ChapterBi.pathFor` 的纯转发已在 `6e1f11bd` 删除。

### 三、无效防御及吞错

1. **[P3] 交付内模块被 `pcall(require)` 包成空结果。** [`features/lockscreen/background.lua`](book.koplugin/features/lockscreen/background.lua#L174) `local ok, External = pcall(require, "utils.external")`，失败返回 `{}, true`。`utils/external.lua` 随插件一起交付，不存在「可能没装」。契约：这个 require 必须成功；该写法会把 `utils.external` 自身的语法 / 加载错误吞成「没有第三方背景，且已就绪」。最小删法：改成直接 `require("utils.external")`。（`source/kavita/cache.lua:270` 的 `pcall(require, "kamarefeatures")` 是第三方插件可能缺失的文件，不算。）近期提交 `68313254` 已对 turbo 补丁做过同类清理，这一处是遗漏。

### 四、可能存在的 bug，按影响排序

1. **[P3，待确认边界] 分批导入落盘非原子。** [`source/wechat/shelf_import.lua`](book.koplugin/source/wechat/shelf_import.lua#L35) `stash` 直接 `io.open(path, "wb")` 覆盖上一份；写到一半失败会留下被截断的 `shelf_full.json`，`size()` 仍返回非空，浏览器会下载到残缺 JSON 并在解码时失败（用户看到的是导入失败，而不是数据损坏，且可重试，所以是 P3）。最小修法：写 `.part` 再 `os.rename`。要补的测试：`stash` 写失败时旧文件保持不变。
2. **[P3，待确认边界] `commit` 对浏览器传入的 `ids` 不校验类型。** [`features/wechat_import/init.lua`](book.koplugin/features/wechat_import/init.lua#L34) `ShelfImport.commit(params.ids or {}, ...)`，`BookDB.hideMissing` 内 `#keep` / `ipairs(keep)`。该接口已要求浏览器配对令牌，调用方是自家页面；若 `ids` 是非表值会抛错到路由层（由 server 兜底成错误响应）。若浏览器中途中断后仍调用 commit，则按已入库的部分 ids 隐藏其余书（与「快照」口径一致，设计如此）。不建议改，只记录。
3. **[P3，待确认边界] `Awake.hold` 还原的是升旗前的值。** [`utils/awake.lua`](book.koplugin/utils/awake.lua#L44) 持有期间若别的模块（autoturn、设备层）把 `pause_auto_suspend` 改回 false，放旗时会被 `before` 覆盖回旧值。注释已声明意图，实际是否出现需要真机验证，未复现。
4. **[P3，代码路径明确] 更新安装永久保留 `.<插件名>-backup`。** [`utils/plugin_install.lua`](book.koplugin/utils/plugin_install.lua#L128) 旧目录改名为同级备份后不再清理（设计上为回滚），在 Kindle 这类小存储设备上多占一份插件体积；下一次更新才会被 `removeTree(backup)` 覆盖。存储页已识别更新包但未见清理入口。是否清理属产品取舍，不建议为此加状态。

## Linus 式方案

1. 删掉 `background.lua` 里那个多余的 `pcall(require)`。
2. 如果在意，`stash` 改成写临时文件再 rename；其余 P3 不动。
3. 不引入任何新抽象。

## 代码检查

**语法：** ✅ 离线测试全跑：`./tests/run.sh` → `530 passed, 0 skipped, 0 failed (82419 assertions)`。未跑 LuaLS 静态诊断（约 2 分钟，本次未执行）。

**逻辑：** ✅ 重点路径逐行读过：更新流程的镜像回落（`fail` → 直连一次，直连失败即结束，无死循环）、`Release.pick` 的 `settled` 防重入与 `cancelAll`、`Install.run` 的回滚分支（换位失败会还原备份）、`Tasks.cancelPrefixed` 的 `\0` 边界（登出不会误伤 `wechat2` 之类）。

**兼容性：** ✅ 本次未改代码。

模拟器验证（`./run.sh` 启动，经 `tools/emu.sh` 在主循环执行，结束后已停掉模拟器并移除驱动补丁）：

| 项 | 结果 |
|---|---|
| `Updater.newer` 比较（`1.2.3` vs `1.2.3-dev` / `1.2.3` / `1.2.4` 对 `1.2.3`） | `true / false / true`，符合预期 |
| `legado.scan.hosts("192.168.1.5")` / `localIP()` / `isShelf` | 253 个主机 / `198.18.0.1`（本机代理 TUN 网段）/ `true` |
| `Awake.hold` 升降旗 | `held` 先 `true` 后 `false`，定时器清理无报错 |
| `http.dns`：服务器列表与 `encode/decode` 往返 | 系统 DNS + 阿里 DNS 四个，往返通过 |
| `Release.pick` 模块可加载 | `function` |
| 局域网扫描整条流程（`Scan.find`） | 15 秒内正常结束并回调，无异常 |
| 在线更新检查（`kindle.koplugin`） | 模拟器 `isConnected` 为假，按设计立即返回「网络不可用，请先连接 Wi-Fi」，未能验证联网路径 |

未验证：联网下载 / 镜像竞速 / 替换插件目录 / 重启流程、退出登录清库、段评二级回复、屏幕镜像、蓝牙、电池健康度等设备相关功能（模拟器无对应硬件或会改真实数据，按约定不做）。

## 过度设计

**🟢 极简。** 新增代码有体量但每处都有设备侧理由；近 3 天的净删行数说明在做减法。
