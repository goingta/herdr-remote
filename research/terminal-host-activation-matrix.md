# 终端宿主激活矩阵：把窗口带到前台并定位到已附着的 herdr 会话

- 日期：2026-10-10
- 背景：herdr 是类 tmux 的终端复用器，用户桌面终端里跑着 `ssh <host>` 附着 herdr 会话。远程客户端（herdi-mac / herdi-ios / herdi-win / web）完成批准/交互后，希望把桌面上承载该会话的终端窗口带到前台，并把用户视线引到那个具体的 tab / 分屏。
- 方法：以各宿主官方 AppleScript dictionary（sdef）、官方文档、官方仓库源码为一级信息源，交叉验证 GitHub issue 与社区实现。每条关键结论附来源。
- 范围：macOS 上的 Ghostty（≥1.3）、iTerm2 3.x、Terminal.app、VS Code（integrated terminal）。

先给一组贯穿全文的平台事实（适用于所有四个宿主）：

| 激活路径 | 走的系统机制 | TCC Automation 权限 | 能否定位到窗口/tab |
|---|---|---|---|
| `open -a <App>` | LaunchServices | 不需要 | 不能（应用级） |
| `NSRunningApplication.activate(options:)` / `NSWorkspace` | AppKit | 不需要 | 不能（应用级） |
| AppleScript `activate` / `tell … do script` 等任何 `tell` | Apple Events | 需要（kTCCServiceAppleEvents，首次弹 TCC 窗，被拒报 error -1743） | 可以（取决于应用的 dictionary） |

- `open` 走 LaunchServices daemon，osascript 走 Apple Events——这是两条不同的通路，只有后者受 Automation 权限约束。来源：[Stack Overflow: osascript doesn't activate macOS apps via AppleScript](https://stackoverflow.com/questions/74151101)、[Jamf: LaunchServices 与 AppleEvents 受 TCC 管控的差异](https://www.jamf.com/blog/zero-day-tcc-bypass-tccutil/)。
- `open -a` 已运行应用时还会给它发 reopen 语义（等效点击 Dock 图标），应用通常据此升起窗口；`-g`（不带到前台）/`-j`（隐藏启动）/`-F`（不恢复窗口状态）可改变这一行为。来源：`man open`（[SS64 镜像](https://ss64.com/mac/open.html)）。
- `NSRunningApplication.activate(options:)` 默认只把 main/key window 带到前台；`NSApplicationActivateAllWindows` 才会带全部窗口。macOS 14 起 `NSWorkspace.activateApplication(_:)` 已废弃，改用 `activate(options:)`。来源：[Apple: NSRunningApplication.activate(options:)](https://developer.apple.com/documentation/appkit/nsrunningapplication/activate(options:))、[Apple: ActivationOptions.activateAllWindows](https://developer.apple.com/documentation/appkit/nsapplication/activationoptions/activateAllWindows)（原文："By default, activation brings only the main and key windows forward. If you specify NSApplicationActivateAllWindows, all of the application's windows are brought forward."）。
- error -1743 = `errAEEventNotPermitted`，TCC 拒发 Apple Events；SSH 会话里跑 osascript 拿不到授权弹窗，恒失败。来源：[Apple Discussions](https://discussions.apple.com)、[Apple Developer Forums（macOS 14.4 的 open -a 误弹 TCC 回归）](https://developer.apple.com/forums/thread/747170)。
- ad-hoc / 每次构建签名都变的 app，TCC 授权随签名 hash 重置（对 herdi-mac 本地构建是实际风险）。来源：[Apple Developer Forums](https://developer.apple.com/forums/thread/)、[MacScripter 讨论](https://www.macscripter.net)。

---

## 1. Ghostty

Ghostty 1.3.0（PR 合入于 2026-03-07）起才有 AppleScript 支持，官方定位是 "preview" feature，API 稳定性未承诺。来源：[PR #11208](https://github.com/ghostty-org/ghostty/pull/11208)（README 级 body 含完整能力表）。

### 1.1 激活方式

- **`open -a Ghostty` / NSWorkspace 路线可用**：应用级激活，无 TCC。
- **AppleScript `activate`**：`activate` 不在 Ghostty 自己的 sdef 里（Standard Suite 只声明了 `count` / `exists` / `quit`，见 [Ghostty.sdef](https://github.com/ghostty-org/ghostty/blob/main/macos/Ghostty.sdef) 末尾）；Cocoa 应用对 `misc/actv` Apple Event 有 NSApplication 内建处理，所以 `tell application "Ghostty" to activate` 在实践中通常有效，但 Ghostty 未在 dictionary 层承诺它（PR #11208 作者明确说 "Added some applicable standard definitions stubs" 曾不可用）。**未验证**：未在真机上确认 `activate` 对 Ghostty 的行为。
- **dictionary 提供了比 `activate` 更好的命令**：
  - `activate window <window>`：`makeKeyAndOrderFront` + `NSApp.activate(ignoringOtherApps: true)`，把该窗口带到最前并激活应用。来源：[ScriptWindow.swift:178-191](https://github.com/ghostty-org/ghostty/blob/main/macos/Sources/Features/AppleScript/ScriptWindow.swift)。
  - `focus <terminal>`：聚焦某个 terminal surface，同时 `makeKeyAndOrderFront` + 激活 app——**一条命令同时完成「应用激活 + 窗口置前 + surface 聚焦」三层**。来源：[ScriptTerminal.swift:134-156](https://github.com/ghostty-org/ghostty/blob/main/macos/Sources/Features/AppleScript/ScriptTerminal.swift)、[BaseTerminalController.swift:319-331](https://github.com/ghostty-org/ghostty/blob/main/macos/Sources/Features/Terminal/BaseTerminalController.swift)。
  - `select tab <tab>`：选中并前置 tab。
- 已知怪癖：`new window` / `new tab` 会隐式激活 Ghostty（即使用户没写 `activate`），与其它 macOS 应用不一致，仍然 open：[Issue #11457](https://github.com/ghostty-org/ghostty/issues/11457)。
- 可用 `macos-applescript = false` 整体关闭（默认 true）。来源：[Ghostty 配置参考](https://ghostty.org/docs/config/reference)（"If false, all AppleScript interactions are disabled… The default is true."）。

### 1.2 窗口定位

- 对象模型：application → windows → tabs → terminals（split 后一个 tab 有多个 terminal）。属性：
  - `window`: `id`（stable ID）、`name`（窗口标题）、`selected tab`
  - `tab`: `id`、`name`、`index`、`selected`
  - `terminal`: `id`、`name`（terminal title）、`working directory`、`pid`、`tty`
  来源：[Ghostty.sdef](https://github.com/ghostty-org/ghostty/blob/main/macos/Ghostty.sdef)。
- **`terminal.tty` 是 herdr 场景的理想锚点**：herdr pane 有 tty，ssh 客户端进程的 tty 已知，按 `tty` 匹配即可唯一定位。这组属性正是社区为"已知进程 → 找到拥有它的终端"这个需求推进合入的：[Discussion #10606](https://github.com/ghostty-org/ghostty/discussions/10606)、[Issue #10756](https://github.com/ghostty-org/ghostty/issues/10756)、[Issue #11592](https://github.com/ghostty-org/ghostty/issues/11592)（"workingDirectory alone isn't sufficient because multiple sessions can share the same CWD"）。
- 标题构成：`title` 配置项存在（一旦设置会强制所有窗口的标题并忽略程序发的 OSC 0/2 序列）；默认标题来自运行中程序（OSC 转义或程序名）。`ssh <host>` 默认标题通常是 `ssh` 这个程序名——若要用主机名匹配，需 shell 侧发 OSC（`precmd`/`PROMPT_COMMAND` 里对 `$SSH_CONNECTION` 发 `\e]2;ssh <host>\a`）或依赖 herdr 客户端配置里的 title 模板。来源：[Ghostty 配置参考 title 条目](https://ghostty.org/docs/config/reference)（"This will force the title of the window to be this title at all times and Ghostty will ignore any set title escape sequences…"）。

### 1.3 按键能力

- `input text <text> to <terminal>`：向任意 terminal surface 粘贴式写入文本（实现是 `surface.sendText(text)`，**不带换行**，需另发 `send key "enter"`）。对后台 surface 同样有效。来源：[Ghostty.sdef input text](https://github.com/ghostty-org/ghostty/blob/main/macos/Ghostty.sdef)、[ScriptInputTextCommand.swift](https://github.com/ghostty-org/ghostty/blob/main/macos/Sources/Features/AppleScript/ScriptInputTextCommand.swift)。
- `send key "enter" to <terminal>`（支持 modifiers、press/release）、`send mouse button/position/scroll`。
- `perform action <action-string> on <terminal>`：执行 Ghostty action 字符串。
- 结论：**Ghostty 的按键能力已超出"只有 activate"的旧认知**——1.3 后有完整的定向输入 API，herdr 需要 "把文本送进已附着会话" 完全可行。

### 1.4 权限（TCC）

- 任何 AppleScript 命令（含 `focus` / `activate window` / `input text`）都触发标准 Apple Events TCC 弹窗（首次）。Ghostty 官方立场："Apple secures AppleScript via TCC by asking for permission when a script is run… Because this is always asked, we do default AppleScript to being enabled." 来源：[PR #11208 Security 一节](https://github.com/ghostty-org/ghostty/pull/11208)。
- 被拒后报 error -1743；`macos-applescript = false` 时 Ghostty 主动回同样错误号：源码 [AppDelegate+AppleScript.swift:301-315](https://github.com/ghostty-org/ghostty/blob/main/macos/Sources/Features/AppleScript/AppDelegate+AppleScript.swift)（"AppleScript is disabled by the macos-applescript configuration"）。
- `open -a` / NSWorkspace 路线不需要任何权限，但只能到应用级。

---

## 2. iTerm2

### 2.1 激活方式

- `open -a iTerm` / NSWorkspace：应用级，无 TCC。
- AppleScript `tell application "iTerm2" to activate`：常规可用。另有 `select` 命令按层级可用：`window.select`（"Gives the window keyboard focus and brings it to the front"）、`tab.select`（成为当前 tab）、`session.select`（"Makes the session active in its tab. Does not affect which tab is selected or which window has keyboard focus"——所以要到具体 session 需三层组合：session.select + tab.select + window.select，或 activate app）。来源：[iTerm2 官方 AppleScript 文档](https://iterm2.com/documentation-scripting.html)。
- Python API 更精确：`session.async_activate(select_tab=True, order_window_front=True)` 一步完成 "session 激活 + tab 选中 + 窗口前置并给键盘焦点"。来源：[iTerm2 Python API Session 文档](https://iterm2.com/python-api/session.html)。

### 2.2 窗口定位

- 对象模型：application → windows → tabs → sessions（split pane 时一个 tab 多个 session）。枚举与匹配是官方文档明示的用法（`windows`、`tabs`、`sessions` 数组）。来源：[iTerm2 AppleScript 文档 Objects 一节](https://iterm2.com/documentation-scripting.html)。
- 可匹配字段：
  - `session.name`：session 标题（"A string property with the session's name as seen in its title bar"），默认由 profile 的 Title 复选项组合而成（Session Name / Profile Name / Job / User / Host / PWD / TTY…），其中 **Host 项需要 Shell Integration 才能显示远程主机名**。来源：[iTerm2 文档 Title 组合说明](https://iterm2.com/documentation-one-page.html)（Profiles → General → Title 一节）。
  - `session.tty`（如 `/dev/ttys01`）、`session.id`、`session.unique id`、`session.profile name`、`session.contents`。
  - `window.name`：窗口标题栏文字。
- `ssh <host>` 会话：若 profile 勾了 Host 且装了 Shell Integration，session.name 含主机名，可直接 `name contains host` 匹配；否则回落到 tty 匹配（herdr 侧知道 ssh 进程 tty）。
- 社区参考实现（按名字遍历三层匹配）：[Stack Overflow 42772237](https://stackoverflow.com/questions/42772237)、[Stack Overflow 59848631](https://stackoverflow.com/questions/59848631)。

### 2.3 按键能力

- `write text "text"` / `write text "text" newline NO`：向指定 session 写入（"Writes text to the session, as though you had typed it"），支持写任意（含后台）session——遍历 `windows → tabs → sessions` 拿到 session 引用即可。来源：[iTerm2 AppleScript 文档 Sessions 一节](https://iterm2.com/documentation-scripting.html)。
- 还有 `write contents of file`、`variable` 读写、`is at shell prompt` / `is processing` 状态探测。
- Python API：`session.async_send_text(text)`。来源：[Python API](https://iterm2.com/python-api/session.html)。
- 注意：AppleScript 整体被 iTerm2 标注为 **Deprecated**（官方文档侧栏 "Scripting with AppleScript (Deprecated)"），维护但推荐 Python API。来源：[iTerm2 Scripting Fundamentals](https://iterm2.com/documentation-scripting-fundamentals.html)。

### 2.4 权限（TCC）

- AppleScript `tell` 触发标准 TCC Automation 弹窗（"Terminal/herdi 想要控制 iTerm2"），被拒报 -1743。
- iTerm2 自身还有一层脚本控制设置（Settings → General → Magic → "Allow scripts to control iTerm2" / Enable Python API）。社区报告里 `write text` 到非当前 session 的限制与之相关（[Stack Overflow 42772237](https://stackoverflow.com/questions/42772237) 提到默认只写 current session、需开设置）——**该限制的具体边界未在官方文档中找到明确表述，标注：部分未验证**；最稳妥路径是始终遍历出显式 session 引用再写。
- `open -a` / NSWorkspace：无权限要求，应用级。

---

## 3. Terminal.app

### 3.1 激活方式

- `open -a Terminal` / NSWorkspace：应用级，无 TCC。
- AppleScript `activate`：常规可用（Terminal 的 dictionary 是 macOS 内建最完整的之一）。
- 按 window 激活：`set index of window N to 1` 把某窗口提到最前 + `activate`；也有 `set frontmost to true`。来源：[MacScripter do script 讨论](https://macscripter.net/viewtopic.php?id=46811)、[SS64 osascript 示例](https://ss64.com/mac/osascript.html)。

### 3.2 窗口定位

- 对象模型：application → windows → tabs（每个 tab 即一个 session；无 split 概念）。`window` 有 `name`、`id`、`selected tab`、`tab N`。
- 可匹配字段（Terminal.sdef，View via Script Editor → Open Dictionary；Apple 官方在线文档已下线，属性参考见 [Apple Support Terminal User Guide](https://support.apple.com/guide/terminal/terminal-property-reference-trmlproprf/mac) 与社区镜像）：
  - `tab.tty`（**r/o，`/dev/ttys001` 形式**）——与 herdr pane 的 tty 直接对账，是最可靠锚点。
  - `tab.custom title` + `tab.title displays custom title`：程序/脚本设置的自定义标题；`tab.title`（窗口标题）。
  - `window.name`：默认由 profile 的 "title displays…" 复选框组合（device name = tty、working directory、shell path、window size、custom title），**默认窗口名通常是 tty 名**（如 `ttys001`）。标题也可被程序发 OSC 0/1/2 改写（`terminal(1)` man 的 Operating System Escape Sequences 一节；[SS64 osascript 页](https://ss64.com/mac/osascript.html) 与 `man terminal`）。
  - OSC 7（`file://host/path` working directory 通报）由 `/etc/zshrc_Apple_Terminal` 等维护，可与 cwd 匹配。来源：[dgl.cx ANSI Terminal security](https://dgl.cx/2023/09/ansi-terminal-security)（Apple Terminal 支持 OSC 7）。
- `ssh <host>`：默认标题只有 `tty` 或 cwd，**不含主机名**；要么按 tty 匹配（herdr 有 pane tty），要么在 shell 侧对 `$SSH_CONNECTION` 发 OSC 2 标题。
- 社区按 tty 匹配 tab 的成熟用法：`if (tty of t begins with "ttys003") then do script … in t`；用 `ps -o tty= -p <pid>` 对账。来源：[tmux-terminal-tabs 实现](https://github.com/spookyscaryghosts/tmux-terminal-tabs)、[Apple SE 340447](https://apple.stackexchange.com/questions/340447)。

### 3.3 按键能力

- **`do script "<cmd>"` 是"开新东西"语义，这是 herdr 集成最大的坑**：不带 `in` 子句时开**新 window**；`do script "cmd" in window 1` 开新 tab；只有 `do script "cmd" in tab N of window M` / `in <session 引用>` 才是向已有 session 写入。来源：[SS64 applescript 页](https://ss64.com/mac/osascript.html)、[MacScripter](https://macscripter.net/viewtopic.php?id=46811)、[Apple 官方自动化指南（存档）](https://developer.apple.com/library/archive/documentation/LanguagesUtilities/Conceptual/MacAutomationScriptingGuide/ControlTerminalWindows.html)（现 404，内容见 SS64/社区镜像）。
- 结论：向**已附着 herdr 的 tab** 发键技术上可行（拿到 tab/session 引用后 `do script … in <session>`），但每次都是"输入一行命令"，等效键盘输入；对 TUI 型 herdr 的 approval 场景（要按键/选择）没有结构化 API，只能发文本行。
- 只读能力：`tab.contents` / `tab.history` 可读屏。

### 3.4 权限（TCC）

- 所有 `tell application "Terminal"` 触发 TCC Automation（首次弹窗，来源应用 × 目标应用粒度），被拒报 -1743。
- `open -a` / NSWorkspace 无权限，应用级。

---

## 4. VS Code（integrated terminal）

### 4.1 激活方式

- `open -a "Visual Studio Code"` / NSWorkspace / `code` CLI（后者走自己的 IPC 唤起已有实例）：应用/窗口级。
- `code -r <folder|file>`：**复用"最后活动的窗口"** 并打开目标，等效激活该窗口（"-r or --reuse-window: Forces opening a file or folder in the last active window"；`-n` 强制新窗口）。来源：[VS Code CLI 官方文档](https://code.visualstudio.com/docs/editor/command-line)。
- `vscode://file/<path>` URL：开项目/文件（含 `:line:column`），同样落在窗口级。来源：[VS Code CLI 文档 Opening VS Code with URLs 一节](https://code.visualstudio.com/docs/editor/command-line)。
- AppleScript：VS Code 没有有意义的 scripting dictionary（Electron 应用，标准 suite 之外几乎无命令），`activate` 之外的窗口级定位没有官方通路。

### 4.2 窗口定位

- **`code` CLI 无法按窗口寻址**（没有 "focus window with this folder" 的 flag；`-r` 只认"最后活动窗口"），也无法定位到某个 integrated terminal。
- 窗口标题由 `window.title` 模板决定，macOS 默认 `${activeEditorShort}${separator}${rootName}${separator}${profileName}`，**变量集里没有 `${activeTerminal}`**——窗口标题默认反映 active editor / workspace 名，与哪个 terminal 在跑无关。来源：VS Code 源码 [windowTitle.ts（defaultWindowTitle 常量）](https://github.com/microsoft/vscode/blob/main/src/vs/workbench/browser/parts/titlebar/windowTitle.ts)、[workbench.contribution.ts（window.title 变量清单，无 activeTerminal）](https://github.com/microsoft/vscode/blob/main/src/vs/workbench/browser/workbench.contribution.ts)。
- terminal tab 标题：`terminal.integrated.tabs.title` 默认 `'${process}'`；shell/CLI 发的 OSC 标题（sequence）在 `allowAgentCliTitle` 开启且 shell 是 agent CLI（claude/codex/copilot/gemini…）时以 `${sequence}` 呈现；rename/Api 设置的标题存为 staticTitle 并**覆盖模板**。来源：VS Code 源码 [terminalConfiguration.ts](https://github.com/microsoft/vscode/blob/main/src/vs/workbench/contrib/terminal/common/terminalConfiguration.ts)、[terminal.ts:81（设置键名）](https://github.com/microsoft/vscode/blob/main/src/vs/workbench/contrib/terminal/common/terminal.ts)、[terminalInstance.ts:2761-2765、2148-2193](https://github.com/microsoft/vscode/blob/main/src/vs/workbench/contrib/terminal/browser/terminalInstance.ts)。
- **按窗口模糊定位**：如果 herdr workspace 的目录 == VS Code 打开的 folder，且用户只有一个窗口打开该 folder，`code -r <folder>` 会把那个窗口带上来。多窗口 / 同 folder 多实例 / 无 workspace 的纯 terminal 窗口都不可分辨。来源同上 CLI 文档。

### 4.3 按键能力

- **`code` CLI 没有任何向 terminal 写入或聚焦 terminal 的能力**——命令集只覆盖开文件/folder、diff、merge、扩展管理、tunnel。来源：[VS Code CLI 文档 Core CLI options 表](https://code.visualstudio.com/docs/editor/command-line)。
- 社区诉求与官方态度：[#168885 "ability to open vscode from `code` command line that focuses integrated terminal"](https://github.com/microsoft/vscode/issues/168885)（open，已进 backlog）；[#93826](https://github.com/microsoft/vscode/issues/93826) 被 Tyriar 以 "we try to avoid workbench-related features in the CLI" 关闭（dup of [#34442](https://github.com/microsoft/vscode/issues/34442)）。
- 存在但不可从 CLI 触达的内部命令：`workbench.action.terminal.focus`（keybinding / palette / tasks 专用）。来源：VS Code 源码 [terminalStrings.ts:20](https://github.com/microsoft/vscode/blob/main/src/vs/workbench/contrib/terminal/common/terminalStrings.ts)。
- **绕行通路（需要装 companion 扩展，v1 不建议）**：扩展 API 有 `window.terminals`（全部 terminal 列表）、`window.activeTerminal`、`Terminal.show()`（reveal + 聚焦）、`Terminal.sendText(text, shouldExecute)`、`Terminal.name` 可按标题匹配。来源：[vscode.d.ts:7672（Terminal）、11164（window.terminals）](https://github.com/microsoft/vscode/blob/main/src/vscode-dts/vscode.d.ts)。即"按 terminal 标题找到 instance → show() → sendText()"在扩展 API 层面是完整的；分发成本是一个 Marketplace 扩展。

### 4.4 权限（TCC）

- `open -a` / `code` CLI / `vscode://` URL：无 TCC Automation 要求。
- 若走 AppleScript `tell application "Electron"`（只剩 activate 级别）：会触发 TCC，但换不来窗口级定位，价值为零。

---

## v1 激活策略建议

推荐锚点统一为 **tty**（四个宿主中三个直接可查，herdr 自身就有每个 pane 的 tty；ssh 场景里远程 herdr 的 pane tty 在 ssh 客户端侧可经 `ssh -t`/`ps` 对账），fallback 到标题匹配，最后回落应用级激活。

| 行为维度 | Ghostty | iTerm2 | Terminal.app | VS Code |
|---|---|---|---|---|
| v1 激活路线 | **AppleScript `focus <terminal>`**（一条命令：surface 聚焦 + 窗口置前 + app 激活）；TTY 匹配 → `working directory`/`name` 匹配 → `open -a Ghostty` 应用级兜底。需 Ghostty ≥1.3 且 `macos-applescript` 未关 | **AppleScript：按 tty/名字遍历 `windows→tabs→sessions` → `session.select` + `tab.select` + `window.select` + `activate`**；应用级兜底 `open -a iTerm`。可选 Python API `async_activate()` | **AppleScript：按 `tty of tab` 对账 → `set index of window … to 1` + `activate`**；应用级兜底 `open -a Terminal` | **`code -r <folder>` 或 NSWorkspace `activate` 应用/窗口级**；无法定位到 terminal。若将来做 companion 扩展，则 `window.terminals` 按名匹配 → `Terminal.show()` |
| 窗口/会话定位粒度 | window / tab / terminal（split），**tty+pid 原生可查** | window / tab / session，tty 可查，session.name 可含 host（需 Shell Integration） | window / tab（=session），**tty 可查**，标题默认 tty 名 | 窗口（folder 模糊匹配）；**terminal 不可达**（无扩展时） |
| 向会话发键 | `input text` + `send key`（后台 surface 可定向） | `write text`（后台 session 可定向，官方 deprecated 但可用） | `do script … in <session>`（向已有 tab 发一行；开新窗口陷阱） | 无（扩展 API `sendText` 可补，v1 不做） |
| TCC 弹窗 | 有（AppleScript 路线）；`open -a` 兜底路线无 | 有；`open -a` 兜底路线无 | 有；`open -a` 兜底路线无 | 无（`code -r` / NSWorkspace / URL 均免） |
| herdr 需要配合的约定 | 对 `$SSH_CONNECTION` 发 OSC 2 标题（`ssh <host>`）或直接用 tty 锚点 | profile 勾 Host + Shell Integration，或 tty 锚点 | shell 侧发 OSC 2，或 tty 锚点 | workspace 目录 = herdr workspace 目录（唯一可行的弱关联） |

v1 实施要点：

1. **herdi-mac 是被激活的发起方也是 AppleScript 的执行方**：TCC 弹窗的授予主体是 herdi-mac（"Herdi 想要控制 Ghostty/iTerm2/Terminal"），首次弹窗要在产品上给用户一句说明；被拒后降级为 `open -a` 应用级激活并提示用户去 System Settings → Privacy & Security → Automation 打开。本地 ad-hoc 构建签名每次变化会重置 TCC 授权（见开头平台事实），开发期需 `tccutil reset AppleEvents` 后重弹。
2. Ghostty 的 `focus <terminal>` 是四宿主中唯一"一条命令三层完成"的路径，且提供 tty/pid 原生字段，优先做；但 API 标为 preview（1.3），需容错 `errAEEventNotPermitted`（-1743，含 `macos-applescript=false` 的情形）与 command not found（旧版 Ghostty）两种失败。
3. Terminal.app 与 iTerm2 共用"tty → tab/session → select + activate"骨架，仅 dictionary 字段名不同（`tab.tty` vs `session.tty`）。
4. VS Code v1 接受降级：激活到窗口（`code -r <folder>`，要求 herdr 记录 ssh 会话启动时的本地目录），UI 上如实说明"无法定位到具体 terminal"。

## VS Code 特殊性结论

1. **workspace/目录匹配可行但弱**：`code -r <folder>` 把 folder 打进"最后活动窗口"并激活之（[CLI 文档](https://code.visualstudio.com/docs/editor/command-line)）。当 herdr workspace 目录与 VS Code 打开的 folder 一致、且该 folder 只有一个窗口时，`code -r` 就是"激活那个窗口"。限制：多窗口开同一 folder 时无法选择；无 folder 的纯 terminal 窗口、SSH Remote 打开的远程 workspace（`vscode-remote://`）对不上本地 folder 路径；`-r` 依赖"最后活动窗口"的隐式状态。
2. **`code` CLI 的能力边界**：只能开文件/folder/URL/扩展管理/tunnel（[Core CLI options](https://code.visualstudio.com/docs/editor/command-line)），无 `--command`、无 focus-terminal、无向 terminal 写入；focus integrated terminal 是仍然 open 的 feature request（[#168885](https://github.com/microsoft/vscode/issues/168885)，backlog），更早的 [#93826](https://github.com/microsoft/vscode/issues/93826) 被维护者以"CLI 回避 workbench 功能"关闭。
3. **窗口标题与 terminal 无关**：`window.title` 变量集没有 `${activeTerminal}`（[源码](https://github.com/microsoft/vscode/blob/main/src/vs/workbench/browser/workbench.contribution.ts)），terminal 的 OSC 标题只体现在 terminal tab 上（`terminal.integrated.tabs.title`，agent CLI 时 `${sequence}`，[源码](https://github.com/microsoft/vscode/blob/main/src/vs/workbench/contrib/terminal/browser/terminalInstance.ts)），因此"按窗口标题匹配 ssh 主机名"这条路在 VS Code 上天然不存在。
4. **唯一的精确通路是 companion 扩展**：`window.terminals` + `Terminal.name` 匹配 + `Terminal.show()` + `Terminal.sendText()`（[vscode.d.ts](https://github.com/microsoft/vscode/blob/main/src/vscode-dts/vscode.d.ts)）能补齐"定位 + 激活 + 发键"，但需要发布扩展并让用户安装，v1 不建议；且 `window.terminals` 的列表只含 API 已知的 terminal、窗口切换语义仍受 Electron 前台规则约束。

---

## 参考来源

Ghostty：
- [PR #11208 "AppleScript"（1.3 合入，能力表与安全说明）](https://github.com/ghostty-org/ghostty/pull/11208)
- [Ghostty.sdef（官方 AppleScript dictionary）](https://github.com/ghostty-org/ghostty/blob/main/macos/Ghostty.sdef)
- [Ghostty 配置参考：title、macos-applescript](https://ghostty.org/docs/config/reference)
- [Issue #11457：new window/tab 隐式激活](https://github.com/ghostty-org/ghostty/issues/11457)
- [Issue #11592：AppleScript terminal 加 pid/tty 属性](https://github.com/ghostty-org/ghostty/issues/11592)、[Discussion #10606](https://github.com/ghostty-org/ghostty/discussions/10606)
- 源码：[ScriptTerminal.swift](https://github.com/ghostty-org/ghostty/blob/main/macos/Sources/Features/AppleScript/ScriptTerminal.swift)、[ScriptWindow.swift](https://github.com/ghostty-org/ghostty/blob/main/macos/Sources/Features/AppleScript/ScriptWindow.swift)、[ScriptInputTextCommand.swift](https://github.com/ghostty-org/ghostty/blob/main/macos/Sources/Features/AppleScript/ScriptInputTextCommand.swift)、[BaseTerminalController.focusSurface](https://github.com/ghostty-org/ghostty/blob/main/macos/Sources/Features/Terminal/BaseTerminalController.swift)、[AppDelegate+AppleScript.swift](https://github.com/ghostty-org/ghostty/blob/main/macos/Sources/Features/AppleScript/AppDelegate+AppleScript.swift)

iTerm2：
- [AppleScript 文档（windows/tabs/sessions、select、write text）](https://iterm2.com/documentation-scripting.html)
- [Scripting Fundamentals（AppleScript 标注 Deprecated）](https://iterm2.com/documentation-scripting-fundamentals.html)
- [Python API Session（async_activate / async_send_text）](https://iterm2.com/python-api/session.html)
- [Stack Overflow 42772237 / 59848631（按名字匹配 session 的社区实践）](https://stackoverflow.com/questions/42772237)

Terminal.app：
- [Apple Support: Terminal User Guide（属性参考）](https://support.apple.com/guide/terminal/terminal-property-reference-trmlproprf/mac)
- `terminal(1)` man（Operating System Escape Sequences，OSC 0/1/2；`man terminal` 于 macOS 本机）；OSC 7 见 [dgl.cx/2023/09/ansi-terminal-security](https://dgl.cx/2023/09/ansi-terminal-security)
- [SS64 osascript（do script 语义与示例）](https://ss64.com/mac/osascript.html)、[SS64 open(1)](https://ss64.com/mac/open.html)
- [MacScripter：do script 与 window index](https://macscripter.net/viewtopic.php?id=46811)
- [tmux-terminal-tabs（按 tty 匹配 Terminal tab 的实现）](https://github.com/spookyscaryghosts/tmux-terminal-tabs)

VS Code：
- [CLI 文档（-r/-n/-g、vscode:// URL、无 terminal 能力）](https://code.visualstudio.com/docs/editor/command-line)
- [Issue #168885（CLI focus integrated terminal，open/backlog）](https://github.com/microsoft/vscode/issues/168885)、[Issue #93826（closed as dup）](https://github.com/microsoft/vscode/issues/93826)、[Issue #34442](https://github.com/microsoft/vscode/issues/34442)
- 源码：[windowTitle.ts（defaultWindowTitle）](https://github.com/microsoft/vscode/blob/main/src/vs/workbench/browser/parts/titlebar/windowTitle.ts)、[workbench.contribution.ts（window.title 变量清单）](https://github.com/microsoft/vscode/blob/main/src/vs/workbench/browser/workbench.contribution.ts)、[terminalConfiguration.ts（tabs.title 默认 '${process}'）](https://github.com/microsoft/vscode/blob/main/src/vs/workbench/contrib/terminal/common/terminalConfiguration.ts)、[terminalInstance.ts（title/sequence/staticTitle）](https://github.com/microsoft/vscode/blob/main/src/vs/workbench/contrib/terminal/browser/terminalInstance.ts)、[vscode.d.ts（Terminal.show/sendText、window.terminals）](https://github.com/microsoft/vscode/blob/main/src/vscode-dts/vscode.d.ts)
- [Shell Integration（OSC 633 / FinalTerm 133 序列）](https://code.visualstudio.com/docs/terminal/shell-integration)

通用（激活与权限）：
- [Apple: NSRunningApplication.activate(options:)](https://developer.apple.com/documentation/appkit/nsrunningapplication/activate(options:))、[ActivationOptions.activateAllWindows](https://developer.apple.com/documentation/appkit/nsapplication/activationoptions/activateAllWindows)
- [Stack Overflow 74151101（osascript vs open：Apple Events vs LaunchServices）](https://stackoverflow.com/questions/74151101)
- [Apple Developer Forums：macOS 14.4 open -a 误弹 TCC 回归](https://developer.apple.com/forums/thread/747170)
- [Apple Discussions / MacScripter：error -1743 与 Automation 权限](https://discussions.apple.com)
- [Jamf：TCC 与 LaunchServices/AppleEvents 管控差异](https://www.jamf.com/blog/zero-day-tcc-bypass-tccutil/)
