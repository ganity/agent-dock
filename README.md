# Agent Dock

Agent Dock 是一个本地优先的 AI 编程工作台：用 Rust daemon 统一管理底层 agent 会话，用 Web 和移动端提供可恢复、可追踪、可继续工作的交互界面。

它的目标不是再做一个简单聊天窗口，而是解决“本地 agent 会话难管理、重启后丢上下文、跨设备无法继续、底层错误不可见”的问题。

## 解决的问题

- **会话容易丢失**：daemon 将 session 元数据和事件流持久化到 SQLite，服务重启后仍能看到历史消息和运行记录。
- **底层 agent 难恢复**：支持 Codex thread resume 和 Claude `--resume`，历史会话可以重新挂到底层 runtime。
- **多个工作目录难切换**：创建或 attach 会话时可以选择 workspace root 和目录，适合多仓库、多项目并行工作。
- **浏览器和手机体验割裂**：Web 和 Flutter 移动端都走同一套 daemon API，历史消息用 HTTP 快照加载，新事件用 WebSocket 实时跟随。
- **错误信息不透明**：会展示底层 agent 返回的真实错误消息，例如模型容量、工具失败、运行状态变化，而不是只显示泛化状态。
- **已有 agent 会话难接管**：Attach 流程可以读取真实 resume 候选列表，选择后接入已有 Codex / Claude 会话。

## 应用场景

- **长时间开发任务**：让 agent 持续处理重构、测试修复、文档整理等任务，浏览器关闭或 daemon 重启后仍可恢复。
- **多项目并行处理**：在不同仓库之间切换会话，保留每个项目的历史上下文和 runtime session id。
- **远程/移动查看进度**：在同一局域网内用手机查看会话进展、历史输出和实时事件。
- **接管已有会话**：当底层 Codex / Claude 已经有历史 session 时，通过 Attach 选择真实 resume 候选继续工作。
- **本地私有工作流**：daemon 运行在本机，代码目录、SQLite 数据和附件都保存在本地环境，不依赖额外托管服务。

## 当前能力

- 固定 PIN 登录和用户会话恢复
- workspace root 浏览与目录选择
- SQLite 持久化 `sessions` 和 `session_events`
- HTTP 获取历史快照，WebSocket 订阅实时事件
- Web 前端和 Flutter 移动端
- Codex managed session：`initialize`、`thread/start`、`thread/resume`、`turn/start`
- Codex slash command 映射：`/compact`、`/goal`
- Claude per-turn subprocess：使用 `--resume <session_id>` 延续会话
- Attach existing runtime：加载真实 resume candidates 并选择接入
- 可视化 timeline：用户消息、assistant 输出、thinking、tool call、file change、attach、状态变化
- 重启后恢复：历史 session 可重新打开，Codex 可重新挂到底层 thread

## 本地启动

推荐直接使用仓库内脚本同时启动后端和前端：

```bash
bash ./dev.sh
```

默认端口：

- 后端 daemon：`http://0.0.0.0:4123`
- 前端 Web：`http://0.0.0.0:4950`
- 健康检查：`http://127.0.0.1:4123/api/health`

### Daemon

daemon 会按顺序加载配置：

1. `AGENT_DOCK_CONFIG`
2. `./daemon.local.toml`
3. `./daemon.toml`
4. `./daemon.example.toml`

`daemon.local.toml` 适合放本机配置和密钥，例如语音输入凭据。

单独启动 daemon：

```bash
cargo run -p agent-dock-daemon
```

### Frontend

单独启动 Web 前端：

```bash
cd frontend
npm install
npm run dev -- --host 0.0.0.0 --port 4950
```

### Mobile

Flutter 安装在仓库外部路径 `/home/jhz/development/flutter`。
Android SDK 安装在仓库外部路径 `/home/jhz/Android/Sdk`。

非 login shell 中运行移动端命令前，先设置环境变量：

```bash
export PATH="$HOME/development/flutter/bin:$HOME/Android/Sdk/cmdline-tools/latest/bin:$HOME/Android/Sdk/platform-tools:$PATH"
export ANDROID_HOME="$HOME/Android/Sdk"
export ANDROID_SDK_ROOT="$HOME/Android/Sdk"
```

常用命令：

```bash
cd mobile
flutter test
dart analyze .
flutter run
```

## 数据与恢复模型

- daemon 使用 SQLite 保存 session 列表和事件流。
- 打开历史会话时，客户端先通过 HTTP 读取最近事件快照。
- 进入详情页后，客户端通过 WebSocket 订阅后续事件。
- 如果 session 处于 `suspended`，客户端会调用 resume API，后端再恢复底层 agent runtime。
- Codex 会话优先使用已存 `runtimeSessionId`，没有时从历史事件中的 `threadId` 推断。

## 状态说明

- `running`：底层 agent 正在工作或会话处于活跃运行态。
- `idle`：会话暂时空闲，可以继续发送消息。
- `suspended`：本地 runtime 不在，但有足够信息可重新 resume。
- `completed`：底层进程结束，当前不会继续自动运行。
- 错误文案：当底层返回具体错误时，timeline 会保留真实错误；顶部状态优先显示当前 `running` / `idle` / `suspended`，避免旧错误长期覆盖当前状态。
