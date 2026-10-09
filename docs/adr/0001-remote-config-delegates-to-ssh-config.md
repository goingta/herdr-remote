# ADR-0001: Remote 配置单字段化，复杂度交给 ~/.ssh/config

日期：2026-10-09

## 状态

Accepted

## 背景

herdi-mac 菜单栏 app 的 Direct 模式需要知道远端开发机的 SSH 目标，但 `addRemote()` 没有任何 UI 调用点，配置只能手动 `defaults write`。用户（以及未来分发的同事）的 SSH 链路各不相同：ProxyCommand 走 frps 代理、自定义 IdentityFile、UseKeychain、ServerAliveInterval 等。

## 决策

添加 remote 的表单只要求一个必填字段：**SSH 目标字符串**，原样传给 `/usr/bin/ssh`。ProxyCommand / 密钥 / 跳板等一切连接复杂度由用户自己的 `~/.ssh/config` 承载，app 不复刻、不解析、不迁移这些配置。可选字段只有三个：显示名、密码（Keychain + sshpass 兜底）、远端 herdr 路径（默认 `herdr`）。

app 发起的每次 SSH 命令统一附加 `-o ClearAllForwardings=yes`（单次命令执行不需要建转发，避免与用户手动会话的 DynamicForward/RemoteForward 竞争）和 `-o ControlMaster=auto -o ControlPersist=10s`（连接复用，降低经代理链路的握手成本）。

## 后果

- 正向：会写 ssh config 的用户填一个 Host 别名即可；分发给同事时文档只需一句话「确保终端里 `ssh 目标` 能免密连上」。
- 反向：依赖 ssh config 的隐式状态，app 自身无法在无 config 的干净机器上完整工作——这是有意接受的取舍，sshpass + 密码兜底覆盖无公钥场景。
- 轮询节奏：本地 2s、remote 固定 5s，不做成可调项（避免过早设计）。
