# Agent instructions (moon)

月读 / Moon — KOReader 插件（纯 Lua/LuaJIT）。本文件是本仓库的 agent 约定。

## Agent skills

### Issue tracker

Tickets live as markdown files under `.scratch/<feature>/` in this repo (fork-local; upstream `AnkioTomas/moon` is not ours). See `docs/agents/issue-tracker.md`.

### Triage labels

The five canonical triage roles, label strings unchanged, recorded in each ticket's `Status:` line. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: `CONTEXT.md` + `docs/adr/` at the repo root. See `docs/agents/domain.md`.

## 开发环境

- 测试：`bash tests/run.sh`（唯一硬依赖是 `luajit`；`tests/run.sh` 自建 `test/` 沙箱，绝不碰真实数据目录）
- `koreader/` 是可选的本机检出（含 `base` 子模块），给 `.luarc.json` 类型补全和 `./run.sh` 模拟器用
- 新增数据源：`docs/source/sources.md` 的「怎么加一个源」
