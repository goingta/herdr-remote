# ADR-0002: 行标题统一为 Display Title，组合逻辑下沉 Shared

日期：2026-10-10

## 状态

Accepted

## 背景

Widget 行刚定型为 `项目名 · Session Title`（带 banner 去重与 codex `| project` 后缀剥离），Notch 面板的 AgentSessionRow 仍是「上 agent 名、下项目名」，同一 agent 在两处叫法不同。Session Title 数据（`terminal_title_stripped`）在 Agent 模型上已存在，Notch 行只是没用它。

## 决策

Notch 行与 ApprovalCard 头部改用与 Widget 相同的 Display Title（`项目名 · Session Title` 在上为主、agent 名在下为次），组合规则下沉到 `Shared/HerdiSnapshot.swift`，两个 target 共用一份实现，避免去重规则再漂移时同步两处。回退规则沿用 Widget 的：banner / 空 / 等于 agent 名一律视为没有 Session Title。样式跟随信息层级（第一行 semibold、第二行次要样式）；network 图标跟第一行行尾，blocked 的 `— prompt` 尾巴保留在第一行后；窄宽下第一行 tail 截断。

## 后果

- 正向：Widget / Notch / ApprovalCard 三处对同一 agent 显示同一名字；规则改动只落一处。
- 反向：Widget target 与 app target 之间多了一处共享代码依赖（本就共同编译该文件，无新增机制）。
