# agents/ — 本仓库的 agent 约定

给工程类技能读的配置：问题记在哪、triage 角色怎么映射、领域文档怎么消费。

| 文件 | 讲什么 |
| --- | --- |
| [`issue-tracker.md`](issue-tracker.md) | 本地 markdown tracker（`.scratch/<feature>/`）的目录约定与 wayfinder 操作 |
| [`triage-labels.md`](triage-labels.md) | 五个 canonical triage 角色 ↔ 本仓库实际字符串 |
| [`domain.md`](domain.md) | 探索前读什么（`CONTEXT.md` / `docs/adr/`）、glossary 用词、ADR 冲突怎么标注 |

这些文件由 `setup-matt-pocock-skills` 生成；直接改这里即可，只有换 tracker 时才需要重跑。
