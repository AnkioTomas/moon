# source.chapter — 按章 materialization

代码：[`source/chapter.lua`](../../book.koplugin/source/chapter.lua)。

## 设计

这里的逻辑属于**源侧落地**：目录缓存、章节正文落盘、本地进度选章、预取。  
阅读会话（`ui/reader/session`）只编排切章与生命周期，不下载文件。

起始章（未指定 `chapter_idx` 时）：

1. 读 `pending_progress`（有 `chapter_idx`，或仅有 `fraction>0` 时用 fraction×toc 折算）
2. 再回落远端进度  
夹到 `[1, #toc]`。已无 `books.last_chapter_idx`。

目录：优先 `books.toc` / `toc_fetched_at`；TTL 由调用方解释（如 wechat ~6h）。进度章序超出缓存 → 弃缓存重拉一次。

落盘：写 `.part` 再 rename；**`Store.touch` 成功**才把 path 交给调用方。  
HTML ready = 文件存在且远程 `img src` 已内联；按 size+mtime 签名缓存，上限 512 条。

本地缓存命中快开时仍须 `touch`——旧文件可能早于 chapters 表。切章快开不做后台重复 `openAsync`，避免 UI 线程扫 HTML。

工作目录：`Paths.bookWorkDir(stable_id, source_id)`（`md5(stable_id)`，因 id 可能含斜杠）。

---

## 用法

具体源一般包一层再调公共逻辑，例如：

```lua
function Source:openBookAsync(identity, opts, cb)
    return require("source.chapter").openWithUi(self, identity, opts, {
        -- 注入：loadToc / downloadChapter / progress 等
    }, cb)
end

function Source:loadTocAsync(identity, cb)
    local cached = Store.toc(identity)  -- 或源自己的 Toc.read + TTL
    if cached then
        UIManager:nextTick(function() cb(cached) end)
        return nil
    end
    return self._client:tocAsync(…, function(chapters, err)
        -- setToc 后 cb(chapters)
    end)
end

function Source:prefetchChaptersAsync(identity, toc, from_idx, count, cb)
    -- 会话侧通常预取后续 3 章
end
```

Session 切章：

```lua
Session.gotoChapter(idx, opts)
Session.onChapterBoundary(1)  -- 页尾 → 下一章
-- 内部：源打开邻章 path → switchDocument → 新 ReaderReady（skip_pull）
```

### 注意

- `touch` 失败 = 打开失败，不要把未登记 path 交给 Reader。
- 预取失败应静默可恢复，不能留下半写 `.part` 当正文。
- 会话与 chapter 模块边界：会话不 require 源 client。
