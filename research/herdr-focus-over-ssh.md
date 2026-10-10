# herdr 焦点切换经 SSH 的真机可靠性（issue #2）

- 日期：2026-10-10
- 环境：herdr 0.9.1（protocol 22），Linux 开发机，服务器经 socket `/home/tanglei/.config/herdr/herdr.sock` 通信；29 个 live panes、8 个 workspaces、25 个 tabs。
- 方法：真机直接执行 CLI（本实验所在 shell 无 TTY，等效 SSH 非交互执行的进程环境），全部实验不向任何 pane 写入内容，只做 focus 切换；实验结束已将焦点恢复到原始 pane（wW:p1，经三层确认）。
- 结论先行：**`herdr agent focus <pane_id>` 单条命令即可完成全部三层焦点迁移**（pane + tab + workspace 一起切），mac 客户端 `focusPane` 现有的 pane get → workspace focus → tab focus 序列里，第一步 `agent focus` 缺失，且后两步单独执行会落在错误的 pane 上（tab/workspace 的 active pane，而非目标 pane）。

## 一、可靠的调用序列（伪代码级）

### 目标是 agent pane（`agents` 数组里的条目，`agent` 字段非空）

```
focusPane(paneId):                     # paneId 为 herdr 原生 pane id，如 "w9:pE"
    r = herdr agent focus <paneId>     # 一条命令切齐三层
    if r.exit != 0:                    # 错误 JSON 走 stderr，exit 1
        return failure(r.stderr.error.code)   # agent_not_found | ...
    return success
```

就这一条。真机验证（从 wW:p1 出发）：

| 起点 → 目标 | 命令 | pane focused 迁移 | tab focused | workspace focused |
|---|---|---|---|---|
| 同 workspace 同 tab | `agent focus w9:pE` | w9:pE ✓ | w9:t9 ✓ | w9 ✓ |
| 同 workspace 跨 tab | `agent focus w9:p1` | w9:p1 ✓ | w9:t1 ✓ | w9 ✓ |
| 跨 workspace | `agent focus wT:p3` | wT:p3 ✓ | wT:t3 ✓ | wT ✓ |

### 目标是 shell pane（无 agent，`agent_status: "unknown"`）

`agent focus` 拒绝它（见失败模式 #1）。可靠序列是 relay 已实现的 `focus_shell_pane`（`relay/herdr_relay.py:1107`）：

```
focusShellPane(paneId, tabId):
    herdr tab focus <tabId>                    # 进入所在 tab
    loop up to 6 (PANE_WALK_LIMIT):
        layout = herdr pane layout --pane <paneId>
        if layout.focused_pane_id == paneId: return success
        step = walk_direction(rects[focused], rects[paneId])   # 按行重叠判定轴向
        herdr pane focus --direction <step> --pane <focused>
        # 每步重读 layout；一步 changed=false 或 focused 不动 → 放弃
```

若目标 shell pane 是其 tab 内唯一 pane，`tab focus` 一步即达（实验：`tab focus w9:t4` → pane w9:p6 focused）。

### 现有 mac 客户端代码的问题（`herdi-mac/Sources/RelayConnection.swift:573`）

```swift
let output = runHerdr("pane", "get", paneId)          // ① 只取 location
_ = runHerdr("workspace", "focus", location.workspaceId)  // ②
_ = runHerdr("tab", "focus", location.tabId)              // ③
```

- **缺 `agent focus` 这一步**——对 agent pane，②③ 两条到达的 pane 由 herdr 的「tab 内上次聚焦 pane」记忆决定（实验见下），通常不是用户点的那一个。
- 对 agent pane，正确修法是把 ①②③ 换成一条 `agent focus <paneId>`（pane get 都可以省，除非还要用于错误提示）。
- 对 shell pane，保留 relay 的 walk 序列语义。

### workspace/tab 联动是否必要？

**对 agent pane：不必要。** `agent focus` 单发即可切齐三层（上表）。发 workspace/tab focus 反而有害：它们把 pane 焦点交给「tab 内记住的 pane」。

**对 shell pane：`tab focus` 是必要的一步**（walk 的第一步），workspace focus 则随 tab focus 自动联动（tab focus 跨 workspace 时，其 workspace 一起切，实验：从 w9 发 `tab focus wT:t3` → workspace focused=wT）。

## 二、失败模式清单（全部真机实测）

1. **`agent focus <shell_pane_id>` 直接拒绝。** 实测 `herdr agent focus w9:p6`（shell pane）→ stderr `{"error":{"code":"agent_not_found","message":"agent target w9:p6 not found"}}`，exit 1。客户端必须先分辨目标是否 agent（`pane get` 的 `agent` 字段非空 / relay 数据里的 `has_session`、`status` 有值），shell pane 走 walk 路径。
2. **`agent focus` 不接受 agent kind 标签。** `herdr agent focus codex`（多个 codex 存在）→ `agent_not_found`。skill 文档（`herdr --skill`）说明：target 只收唯一 live agent name 或宿主 pane id，不收 terminal id、不收裸 agent-kind。herdi-mac 场景里 agent name 几乎总是空（`agent list` 里 name 全为 `-`），必须用 pane id。
3. **pane id 带 host 前缀的差异。** herdr 原生 id 是 `<workspace>:<pane>`（如 `w9:pE`），workspace/tab 唯一性只到「一个 herdr 实例内」。多机客户端（Windows relay 模式）的 `Agent.Id` 是 `<relay url>|<pane_id>`，回传 CLI 前必须剥掉前缀——herdi-mac 已这么做（`RelayConnection.swift:576-579` 按 `agent.host + ":"` 剥）。本机无第二个 herdr host 可测跨机 id 冲突，但协议层结论与 relay 现有文档一致：**id 只在单 herdr 内唯一，任何跨源列表都要带来源 key**。
4. **不存在 id 的错误形态。** `agent focus wZ:zz` / `workspace focus wZ` / `tab focus wZ:zz` 分别返回 `agent_not_found` / `workspace_not_found` / `tab_not_found`，exit 1，错误 JSON 在 **stderr**（成功 JSON 在 stdout；`herdr --skill` 末行也写明：server errors → stderr + exit 1，syntax errors → exit 2）。用 stdout 空判失败会漏掉 stderr 里的原因；用 exit code 判失败是可靠的。
5. **workspace focus / tab focus 单发的 pane 落点不可控（这是把第一步换成 agent focus 的核心理由）。** 实测：
   - `workspace focus w9`（w9 的 active_tab 是 w9:t4，shell）→ pane 焦点落 **w9:p6**（active_tab 的当前 pane），即使你想去的是 w9:pE。
   - `tab focus wD:t2`（tab 内 p2/p3 两个 shell）→ pane 焦点落 **wD:p3**，即 tab 内「上次聚焦的 pane」的记忆（attach UI 里用户最后停的那个）。同一条命令重复发落点稳定。
   - 也就是说：workspace focus = 切 workspace + 进它的 active_tab + 恢复该 tab 记住的 pane；tab focus = 进 tab + 恢复该 tab 记住的 pane。都**不是**「聚焦我指定的 pane」。
6. **对 working / blocked 状态的 agent pane focus 是安全的。** 实测对 `claude working` 的 wW:p1 发 `agent focus` 正常返回、agent 状态不受影响。skill 文档说明 explicit focus 命令会把目标 **mark seen**（herdr 服务端 seen 状态）——这是唯一副作用，且正是「用户跳过去看」语义想要的行为。
7. **多 pane tab 里把焦点精确送到指定 pane 只能 walk。** `pane focus` 只支持 `--direction left|right|up|down` + 起点（`--pane <ID>` 或 `--current`），没有「focus 这个 pane」的直接形式。relay 的 `walk_direction`（`relay/herdr_relay.py:1079`）用行重叠判轴向（rect 是字符格，格高约 2 倍格宽，raw dx/dy 比较会在近似方形 split 上选错轴），每步重读 `pane layout`。实测 walk 语义成立：`--pane wD:p3 --direction up` → changed=true, focused=wD:p2。
8. **无 TTY / 非交互执行无差异。** 本实验 shell 本身无 TTY（`tty` 返回非 0），且用 `env -i`（极简环境变量、无 TERM）复测 `agent focus`，行为与交互完全一致：CLI 靠 socket 与服务器通信，不依赖终端。SSH 非交互执行（`ssh host herdr agent focus ...`）同一进程形态，本机 22 端口未开无法直测 loopback SSH，但 mac 客户端的 runSSH 每命令一次完整握手（`RelayConnection.swift:266`，无 ControlMaster——注释写明 persist master 会挂死 poll 线程），配合 `ConnectTimeout=5` 是既有验证过的形态。**真正经 SSH 的实切效果待用户在 mac 上确认。**
9. **连续快速调用无竞态。** 5 连发（w9:pE / wC:pE 交替模拟 widget 连点），每发后 `pane list` 核对，5/5 focused 落在目标上，`state_change_seq` 单调。herdr 服务器单 socket 串行处理，无客户端侧去抖需求。
10. **`pane get` 的 location 字段结构。** `herdr pane get <id>` → `{"id":"cli:pane:get","result":{"pane":{...,"pane_id","workspace_id","tab_id","focused","agent","agent_status","cwd","terminal_title",...}},"type":"pane_info"}`。mac 客户端 `parsePaneLocation` 读的 `result.pane.workspace_id/tab_id` 与真机输出一致（`RelayConnection.swift:256`）。

## 三、实验记录（时序）

环境快照：29 panes / 8 workspaces / 25 tabs，原始焦点 **wW:p1**（wW / wW:t1，claude working，即用户正在用的会话）。

| # | 操作 | 结果 |
|---|---|---|
| 1 | `agent focus w9:pE`（第一步单独，目标同 ws 同 tab） | focused: wW:p1 → **w9:pE**；tab=w9:t9、ws=w9 一并迁移 ✓ |
| 2 | `agent focus w9:p6`（shell pane） | `agent_not_found`，exit 1 ✗（失败模式 #1） |
| 3 | `agent focus w9:p1`（同 ws 跨 tab） | focused → w9:p1，tab=w9:t1 ✓ |
| 4 | `agent focus wT:p3`（跨 workspace） | focused → wT:p3，tab=wT:t3、ws=wT ✓ |
| 5 | `agent focus wZ:zz` / `focus codex` | `agent_not_found`，stderr，exit 1（失败模式 #2/#4） |
| 6 | `workspace focus w9` 单发（ws active_tab=w9:t4） | focused 落 **w9:p6**（active tab 的 pane），非指定目标（失败模式 #5） |
| 7 | `tab focus w9:t9` 单发（tab 内单 pane） | focused → w9:pE ✓ |
| 8 | `tab focus wT:t3` 单发**跨 workspace** | focused → wT:p3，ws=wT 联动 ✓ |
| 9 | `workspace focus wV` 单发（单 tab ws） | focused → wV:p1 ✓ |
| 10 | 5 连发 agent focus（w9:pE/wC:pE 交替） | 5/5 落点正确，无竞态 ✓ |
| 11 | 完整三步（pane get wT:p3 → agent focus wT:p3 → workspace focus wT → tab focus wT:t3） | 全部 ok，最终 wT:p3（agent focus 已达成，后两步冗余但无害——本例 tab 记忆恰是 p3） |
| 12 | `env -i`（无 TERM、极简 env）下 `agent focus w9:pE` | 与交互一致 ✓（失败模式 #8） |
| 13 | `tab focus w9:t4`（shell tab 单 pane） | focused → shell w9:p6 ✓（walk 可省为一步的情形） |
| 14 | `workspace focus wC`（active_tab wC:t1 含 pE+p18） | focused 落 **wC:pE**（tab 记忆），非 active_tab 首个 pane |
| 15 | `tab focus wD:t2`（p2+p3）重复两次 | 两次均落 wD:p3（tab 记忆，稳定）（失败模式 #5） |
| 16 | `pane focus --pane wD:p3 --direction up` | changed=true → wD:p2（walk 语义验证） |
| 17 | `pane focus --pane wD:p2 --direction right` | changed=false, reason=no_neighbor（同列拆分，右方无邻居——walk 需按轴向重试） |
| 18 | `agent focus` 对 working pane（wW:p1） | exit 0，状态不受影响（失败模式 #6） |
| 19 | 三层一致性快照 | pane/ws/tab 的 focused 永远一致（同一时刻同一目标） |
| 20 | 恢复：`agent focus wW:p1` + `workspace focus wW` + `tab focus wW:t1` | 三层确认回到 wW:p1 / wW / wW:t1 ✓（与实验前一致） |

## 四、给实现的具体建议

1. **agent pane**：`focusPane` 改为单发 `herdr agent focus <barePaneId>`，删除 workspace/tab 两步；解析 exit code + stderr 的 `error.code` 判失败（stdout JSON 可用于确认 `focused: true`）。
2. **shell pane**（若 mac 客户端将来列出它们）：复用 relay `focus_shell_pane` 的 walk 序列（tab focus + ≤6 步 pane focus，每步重读 layout），或直接经 relay 的 WS `focus` 消息（relay 已实现，`herdr_relay.py:3396`）。
3. **id 处理**：发往 CLI 的永远是剥掉 `<host>|` / `<host>:` 前缀的 herdr 原生 id；保留现有 `remotePaneId` 剥前缀逻辑。
4. **连点**：无需去抖，5 连发实测无竞态；但每次调用是独立 SSH 握手（~数百 ms），widget 高频调用时可考虑只对最后一个目标执行（客户端侧取消前一 task），属优化非正确性问题。
5. **附着端实切效果**：本机验证的是服务器焦点状态三层迁移；herdr attach 视图是否随之切换待用户在真机附着端确认（理论上 workspace/tab/pane 焦点就是 attach UI 的渲染依据）。

## 附：引用源

- herdr 0.9.1 CLI 真机实测（全部命令输出见实验记录表）
- `herdr --skill`（herdr 官方 agent skill）：AgentTarget 语义、focus mark-seen 副作用、错误通道约定
- `/home/tanglei/workspace/herdr-remote/relay/herdr_relay.py:1079`（walk_direction）、`:1107`（focus_shell_pane）、`:3396`（WS focus handler）
- `/home/tanglei/workspace/herdr-remote/herdi-mac/Sources/RelayConnection.swift:256`（parsePaneLocation）、`:266`（runSSH）、`:573`（focusPane 现状）
- `herdr api schema --json`（protocol 22）：`agent.focus` params=`AgentTarget{target}`、`tab.focus`=`TabTarget{tab_id}`、`workspace.focus`=`WorkspaceTarget{workspace_id}`；`pane_focused`/`tab_focused`/`workspace_focused` 事件
