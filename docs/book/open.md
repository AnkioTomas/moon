# book.open — 打开文档

代码：[`book/open.lua`](../../book.koplugin/book/open.lua)。

## 设计

UI 选中的是带 `source_id/stable_id` 的书记录，不是「当前活跃源里的某本书」。因此打开链路：

```text
Open.book(plugin, book)
  → Registry.resolve(book.source_id)     -- 属主源，可非活跃
  → source:openBookAsync(identity, nil, cb)（章号等由源自己决定）
  → 源侧准备文件并 Store.touch
  → ReaderUI:showReader(path)
  → nextTick 关闭桌面（避免 FileManager 闪一帧）
```

`Open.generation` + `pending_job`：新的一次打开会取消尚未交接给 Reader 的旧打开。`showReader` 回调里若用户已经在看别的文档，丢弃本次交接。

登记（`touch`）失败不能继续打开——否则后续 `ensureIdentity` 会对不上。

---

## 用法

```lua
local Open = require("book.open")

-- 桌面 / 详情「开始阅读」
Open.book(plugin, book, function(ok)  -- 错误已由 InfoMessage 提示，回调不带 err；被更新一代打开取消时不回调
    if not ok then
        -- Open 内部已 InfoMessage；此处可选做 UI 收尾
    end
end)

-- book 至少要有：
--   source_id, stable_id
--   以及源 openBookAsync 需要的展示字段（title 等）
```

源侧典型实现：

```lua
function Source:openBookAsync(identity, opts, cb)
    -- 下载或命中缓存…
    local ok, err = require("book.store").touch(path, identity, {
        chapter_idx = opts and opts.chapter_idx,
        toc = toc,
    })
    if ok then cb(path) else cb(nil, err) end
    return { cancel = function() … end }
end
```

### 注意

- 不要在 Open 里默认 `Registry.current()`——换源串书的根因。
- 关桌面必须排在 Reader 入栈之后一拍，顺序反了会闪底层 FM。
- 连续快速点两本书：靠 generation 丢弃过期回调，调用方不必自己防抖。
