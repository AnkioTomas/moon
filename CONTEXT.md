# CONTEXT — 月读（moon）

本文件是**术语表**，只固定词汇，不放实现或设计决策。

## 书籍与数据源

- **书籍（book）**：moon 的展示单位，身份为 `(source_id, stable_id)`。
- **数据源（source）**：提供书籍列表、打开、进度、笔记、统计的后端（moon / wechat / kavita / local …）。
- **页级源（page-level source）**：远端进度只有「页/spine」粒度、并用 xpointer 描述页内位置的数据源（如 Kavita 的 EPUB）。区别于以「章」为粒度的章节源。

## 阅读进度

- **内容进度（content progress）**：以渲染后内容页为单位的阅读比例，与数据源无关，是「读了多少」的物理量。KOReader 本地文档的 `doc_fraction` 即此。
- **spine 进度（spine progress）**：以 epub 的 spine（HTML 文档）序号计的比例（`pageNum / spine 总数`）。Kavita 对外**只**提供这一种进度，且**进入新 spine 时它会跳变**。
- **本地进度（local progress）**：本机 `pending_progress` 记录的位置。
- **云端进度（remote progress）**：数据源侧记录的位置。
- **冲突基准（conflict basis）**：判定本地与云端是否同一位置所依据的量。**页级源的冲突基准是 spine 序号 + spine 内元素路径，绝不是百分比**——spine 进度与内容进度口径不同，百分比不可比。
- **落后（behind）**：本地位置对应的 spine 序号小于云端。
- **冲突（conflict）**：本地与云端不在同一位置（按冲突基准判定）。
