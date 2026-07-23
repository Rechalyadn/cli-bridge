# cli-bridge

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux%20%7C%20WSL%20%7C%20Windows%20(Git%20Bash)-blue)](#安装)
[![Agent Skills](https://img.shields.io/badge/Agent%20Skills-Codex%20%7C%20OpenCode%20%7C%20Claude-blueviolet)](https://skills.sh)

让 Claude Code、Codex 或 OpenCode 通过本机 `codex` / `opencode` CLI 进行**多轮、可续接**的对话，
而不是一次性问答。

纯 bash 3.2+ 脚本，不依赖 jq/python，Windows Git Bash 和 macOS 上行为一致，
既可以被 Claude Code 当 Skill 调用，也可以在任意终端手动跑。

## 功能特性

- **多线程并行会话** — 同时维护多条独立的 codex/opencode 对话（比如一条
  `explore`、一条 `review`），随时切换，互不干扰
- **按宿主会话自动隔离** — 线程绑定宿主 Agent 与其会话 ID；Claude Code 自动读取
  `$CLAUDE_CODE_SESSION_ID`，Codex/OpenCode 适配器可接收它们暴露的 session ID，
  也可用 `--host-session` 显式接入
- **父子会话谱系** — 由 cli-bridge 启动的嵌套 Codex/OpenCode 进程自动继承父逻辑会话，
  不需要子 Agent 再查找父 session
- **线程绑定工作目录** — 每个线程可以固定一个专属 `cwd`，建线程时锁定，生命
  周期内不会被后续调用悄悄改掉
- **并发安全** — 基于目录锁的线程级互斥 + 原子文件写入，同一线程被多个调用
  方同时操作也不会互相踩踏
- **实时活动可见性，不泄漏内容** — `peek` 只展示"正在运行命令 / 正在调用
  工具"这类过程摘要，模型的完整回复和思维链永远不会被打印到日志或调用方的
  上下文里
- **输出边界保护** — 成功回复、失败回复、原始输出流分别有独立的字节上限，
  防止暴走的子进程把巨量内容灌回调用方（尤其是把这个工具当子代理派活给
  Claude Code 自己的时候）
- **模型偏好记录** — `setup note`/`setup guidance` 记录"这个模型适合干什么、
  哪些不要用"之类的长期偏好，供 Claude 参考决策，不做强制拦截

## 依赖

- [`codex`](https://github.com/openai/codex) CLI，已登录
- [`opencode`](https://opencode.ai) CLI，已配置至少一个 provider
- bash 3.2 或更高版本（macOS 自带即可；Windows 用 Git Bash）

两个 CLI 都是可选的——只用得到其中一个也能正常工作，另一个未安装时相关
命令会明确报错，不会互相影响。

## 安装

### 使用 Skills CLI 安装（推荐）

把下面这段话原样交给你当前正在使用的 Agent。它会先做只读预检、向你报告
V1/V2 与 CLI 环境，再打开 Skills CLI 的交互选择界面；**不要自行假设安装到
Claude Code 目录**。

```text
请安装 cli-bridge V2。

1. 从 https://github.com/Rechalyadn/cli-bridge 获取 V2，并先运行
   `bash scripts/install.sh preflight`。报告 cli-bridge 版本、Claude Code/Codex/OpenCode
   已安装副本的状态（legacy-v1/v2/absent）、以及 codex/opencode 的版本和可用性。
2. 如果发现 legacy-v1，说明它所在的位置；不要直接删除。先征求我是否要在 V2
   验证成功后删除旧 skill 副本。保留旧运行时状态作为归档，不要继续使用
   `~/.claude/cli-bridge`。
3. 运行 `bash scripts/install.sh`，进入 Skills CLI 的交互选择。让我选择要安装的
   宿主（Claude Code、Codex、OpenCode），只勾选我确认的对象。
4. 对每个已选宿主，确认其 skill 副本包含 `SKILL.md`、`VERSION`、`scripts/bridge.sh`
   和 `scripts/adapters/`，并运行 `bash scripts/bridge.sh version` 确认是 V2。
5. 运行 `bash scripts/bridge.sh setup probe`；再询问我模型职责、预算偏好和禁用模型，
   经我确认后用 `setup note` / `setup guidance` 写入 V2 共享状态目录
   `~/.cli-bridge`。
```

`bash scripts/install.sh` 默认以全局模式启动 `skills-lc-cli` 的交互目标选择。它会将
skill 分别写到所选宿主的原生目录（例如 Codex 的 `~/.codex/skills`、OpenCode 的
`~/.config/opencode/skills`）；这些副本共享独立的运行时目录 `~/.cli-bridge`，不会再
把活跃会话状态写进 `~/.claude`。

安装前先运行只读预检：

```bash
bash scripts/install.sh preflight
# 等价于：bash scripts/bridge.sh setup preflight
```

它会报告当前 V2 版本、三个宿主目录中的 `legacy-v1`/`v2`/`absent` 状态，以及
Codex/OpenCode CLI 的版本与基础可用性；不会安装、删除、创建运行时状态或调用模型。
可用 `bash scripts/bridge.sh version` 供 Agent 可靠确认副本版本。

### 手动安装

```bash
# 只打印默认的交互安装命令
bash scripts/install.sh --dry-run

# 无交互自动装到指定宿主
bash scripts/install.sh --agent codex

# 项目级安装
bash scripts/install.sh --agent opencode --project
```

装好之后跑一次环境探测和个性化配置，见 [`SETUP.md`](./SETUP.md)。

### 更新

使用 Skills CLI 的更新命令，或重新运行安装流程并选择已有的 V2 目标；不要再对
`~/.claude/skills/cli-bridge` 执行 `git pull` 作为 V2 更新方式。

## 使用

```
bash scripts/adapters/<claude-code|codex|opencode>.sh <codex|opencode> ask [--thread NAME] [--model M] [--effort LEVEL] [--danger-full-access] [--cwd DIR] "<prompt>"
bash scripts/bridge.sh <codex|opencode> new    --thread NAME [--model M] [--effort LEVEL] [--cwd DIR]
bash scripts/bridge.sh <codex|opencode> switch <thread>
bash scripts/bridge.sh <codex|opencode> list
bash scripts/bridge.sh <codex|opencode> history <thread>
bash scripts/bridge.sh <codex|opencode> details <thread> <turn> [--reply]
bash scripts/bridge.sh <codex|opencode> model  <thread> <model>
bash scripts/bridge.sh <codex|opencode> cwd    <thread> <dir>
bash scripts/bridge.sh codex effort <thread> <level>
bash scripts/bridge.sh codex peek   <thread>
bash scripts/bridge.sh setup <probe|note|notes|note-rm|guidance>
```

每次 `ask` 会先返回一行简短调用摘要（工具、线程、turn、状态、耗时、已知的命令/
工具调用数），再返回最终答案。完整过程不会混进主 Agent 上下文：它按 turn 保存到
`~/.cli-bridge/sessions/.../threads/<thread>/turns/<turn>/`。需要追溯时先用
`history` 找 turn，再用 `details` 查看过滤后的活动；只有追加 `--reply` 才会再次打印
该 turn 的最终答案。

完整命令说明和已知报错信息见 [`SKILL.md`](./SKILL.md)。

## 测试

没有网络/真实 CLI 依赖的纯逻辑部分都有自动化测试：

```bash
bash scripts/lib/state.test.sh \
  && bash scripts/lib/codex.test.sh \
  && bash scripts/lib/opencode.test.sh \
  && bash scripts/lib/config.test.sh \
  && bash scripts/install.test.sh \
  && bash scripts/bridge.test.sh \
  && bash scripts/bridge-preflight.test.sh \
  && bash scripts/bridge-output.test.sh
```

会真正调用 `codex`/`opencode` 的部分（`ask`、`setup probe`）只做手动冒烟
测试，没有自动化——理由见 `design.md` §8。

## 文档

| 文件 | 用途 |
|---|---|
| [`SKILL.md`](./SKILL.md) | 跨宿主 Agent Skill 的触发条件 + 命令速查（每次调用这个 Skill 都会读一遍，保持精简） |
| [`SETUP.md`](./SETUP.md) | 首次安装 / 记录模型偏好的详细步骤，只在真的要装机时才需要看 |
| [`design.md`](./design.md) | 完整设计文档：存储布局、并发模型、每个设计取舍的理由 |
| `plan.md` / `plan-*.md` | 各阶段实现前写的计划文档，历史存档，不是活文档 |

## 项目现状

<https://github.com/Rechalyadn/cli-bridge> 是这个 Skill 的正式发布仓库——
安装方式就是上面的 `git clone`，更新就是 `git pull`。维护者本机实际运行的
`~/.claude/skills/cli-bridge` 尚未切换成从这个仓库安装（目前是独立维护的
本地副本），后续会理顺。

## License

MIT，见 [`LICENSE`](./LICENSE)。
