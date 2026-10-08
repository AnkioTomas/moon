# 联网后各源自己推脏

没有独立编排模块。`main.lua` 把 `onNetworkConnected` 转给每个启用源，默认实现在 [`SourceBase:onNetworkConnected`](../../book.koplugin/source/base.lua)。

## 设计

只推本源有脏行的域，没有脏行的域不调用（书架尤其不能被顺手拉成全量）：

```text
books → notes → stats → progress
```

进度放在最后：微信时长上报会写云端位置，最后落地的必须是精确进度。这一域失败不拦住后面的域。

| 域 | 联网重试 | Pull 时机 |
|---|---|---|
| books | 有脏行才调，且 `dirty_only`（只推删/加） | 桌面打开 / 手动刷新书架 |
| notes | 有脏行才调，`dirty_only` | 仅开书 `SessionNote.pull` |
| stats | 有脏行才调，`dirty_only` | 桌面打开 / 源 `stats_pull` |
| progress | 有脏行才调，`dirty_only` | 仅开书 `ReaderProgress.pull` |

书架脏位只能在**单条** add/delete 推送成功时清除，禁止整源盲清。

关书、划线、翻页这些时机不走这里，由 `reader/session` 和源自己的 `onEvent` 直接调对应的 `sync*Async`。
