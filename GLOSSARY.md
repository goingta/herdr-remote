# Glossary

## Remote

一个 SSH 目标（如 `tanglei.azshentong.com` 或 `user@host`），原样传给 `/usr/bin/ssh`。**复杂度全部由 `~/.ssh/config` 承载**：ProxyCommand、IdentityFile、UseKeychain 等对 app 发起的调用自动生效。每-remote 可选覆盖远端 herdr 二进制路径。

## Remote Settings

一个 remote 的附加配置：显示名（label）、远端 herdr 路径（默认 `herdr`）。密码不属于 Remote Settings——它存 Keychain（service `com.dcolinmorgan.herdi.ssh`，account 为 SSH 目标字符串本身），配置里只表达"是否使用"。

## Agent

一个 herdr pane 里在跑的 coding agent（claude / codex 等）。id 跨 host 时带 host 前缀（`host:pane_id`）。没有 agent 的 pane 不算 Agent。

## Direct / Relay

mac app 的两种连接模式。**Direct**：app 自己 shell 出 `herdr pane list`（本机 + 每个 remote 经 SSH）。**Relay**：连 relay 的 WebSocket。配置入口设计针对 Direct 模式。

## Poll

Direct 模式下每 2s（remote 每 5s）执行一次的 `herdr pane list` 轮询。remote poll 复用 SSH 连接（ControlMaster auto），并清除所有端口转发（ClearAllForwardings）。

## Test Connection

保存前的一次验证调用：`ssh <目标> <herdr路径> pane list`，结果分类为「返回 N 个 agent / 认证失败 / 超时 / command not found / sshpass 缺失」。
