# cli-bridge

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux%20%7C%20WSL%20%7C%20Windows%20(Git%20Bash)-blue)](#安装)
[![Claude Code](https://img.shields.io/badge/Claude%20Code-Skill-blueviolet)](https://claude.ai/code)

让 Claude Code 通过本机 `codex` / `opencode` CLI 进行**多轮、可续接**的对话，
而不是 Multi-CLI MCP 的 `Ask-Codex` / `Ask-OpenCode` 那种一次性问答。

纯 bash 3.2+ 脚本，不依赖 jq/python，Windows Git Bash 和 macOS 上行为一致，
既可以被 Claude Code 当 Skill 调用，也可以在任意终端手动跑。

## 功能特性

- **多线程并行会话** — 同时维护多条独立的 codex/opencode 对话（比如一条
  `explore`、一条 `review`），随时切换，互不干扰
- **按对话自动隔离** — 线程默认绑定当前 Claude Code 对话（读
  `$CLAUDE_CODE_SESSION_ID`），不同对话之间的同名线程互不可见；也可以用
  `--scope` 手动接管
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

### 给你的 Agent（推荐）

把下面这段话原样发给 Claude Code（或其他你正在用的 coding agent），它就能
自己完成安装、探测环境、并和你确认模型偏好：

```
帮我安装 cli-bridge 这个 Skill：

1. git clone https://github.com/Rechalyadn/cli-bridge.git ~/.claude/skills/cli-bridge
   （只想在当前项目里用的话，克隆到 ./.claude/skills/cli-bridge 而不是 ~/.claude/skills/cli-bridge）
2. 跑一遍 bash ~/.claude/skills/cli-bridge/scripts/bridge.sh setup probe，
   把结果读给我看，告诉我需要做什么（比如登录 codex/opencode）。
3. 打开 ~/.claude/skills/cli-bridge/SETUP.md，按里面的步骤跟我确认想用哪些
   模型、职责怎么分配，帮我记录下来。
```

### 手动安装

```bash
# 全局安装（对所有项目生效）
git clone https://github.com/Rechalyadn/cli-bridge.git ~/.claude/skills/cli-bridge

# 或者项目级安装（只对当前项目生效）
git clone https://github.com/Rechalyadn/cli-bridge.git /path/to/project/.claude/skills/cli-bridge
```

装好之后跑一次环境探测和个性化配置，见 [`SETUP.md`](./SETUP.md)。

### 更新

```bash
cd ~/.claude/skills/cli-bridge && git pull
```

## 使用

```
bash scripts/bridge.sh <codex|opencode> ask    [--thread NAME] [--model M] [--effort LEVEL] [--danger-full-access] [--cwd DIR] "<prompt>"
bash scripts/bridge.sh <codex|opencode> new    --thread NAME [--model M] [--effort LEVEL] [--cwd DIR]
bash scripts/bridge.sh <codex|opencode> switch <thread>
bash scripts/bridge.sh <codex|opencode> list
bash scripts/bridge.sh <codex|opencode> model  <thread> <model>
bash scripts/bridge.sh <codex|opencode> cwd    <thread> <dir>
bash scripts/bridge.sh codex effort <thread> <level>
bash scripts/bridge.sh codex peek   <thread>
bash scripts/bridge.sh setup <probe|note|notes|note-rm|guidance>
```

完整命令说明和已知报错信息见 [`SKILL.md`](./SKILL.md)。

## 测试

没有网络/真实 CLI 依赖的纯逻辑部分都有自动化测试：

```bash
bash scripts/lib/state.test.sh \
  && bash scripts/lib/codex.test.sh \
  && bash scripts/lib/opencode.test.sh \
  && bash scripts/lib/config.test.sh
```

会真正调用 `codex`/`opencode` 的部分（`ask`、`setup probe`）只做手动冒烟
测试，没有自动化——理由见 `design.md` §8。

## 文档

| 文件 | 用途 |
|---|---|
| [`SKILL.md`](./SKILL.md) | Claude Code Skill 的触发条件 + 命令速查（每次调用这个 Skill 都会读一遍，保持精简） |
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
