# cli-bridge 设计文档

日期：2026-07-17

## 1. 目的

Claude Code 通过 Multi-CLI MCP 调用 Codex / OpenCode 时，`Ask-Codex` / `Ask-OpenCode`
每次都是全新会话，不能续接上下文。本设计做一个 Claude Code Skill（`cli-bridge`），
内置一个纯 bash 脚本，直接调用本机 `codex` / `opencode` CLI 的 resume/continue 能力，
实现：

- 多个命名并行线程（同一时间可以维护 `review`、`explore` 等多条独立会话，随时切换）
- 线程与当前 Claude Code 对话绑定（同一个 Claude 对话里的 codex/opencode 线程互相独立于其他对话）
- 模型 / reasoning effort 可按线程配置并持久化
- 既可以被 Claude 调用，也可以被用户在任意终端（Windows Git Bash / macOS）直接手动调用调试
- 不依赖 jq / python，纯 POSIX bash + coreutils

不做的事：不做成正式 MCP server，不支持 codex/opencode 之外的其它 CLI。

> 更新（2026-07-18）：并发保护后来还是加了——见 §2.3。本节其余内容和下面
> 几节仍反映最初的单次实现；cwd、实时活动可见性（`peek`）、输出截断、
> `setup` 全局配置这几块是后续加的，写在 §2.3 之后，没有全部倒推重写前面
> 的叙述，读的时候以代码和后面新增的小节为准。

## 2. 存储设计

### 2.1 作用域（scope）

默认作用域 = 当前 Claude Code 对话 ID，读取环境变量 `CLAUDE_CODE_SESSION_ID`
（已验证该变量在一次 Claude Code 会话内稳定存在）。

- 在 Claude Code 里调用：自动用 `$CLAUDE_CODE_SESSION_ID` 作为 scope，无需用户指定。
- 脱离 Claude Code 直接跑脚本（如 macOS 手动调试）且未设置该环境变量：退化为固定 scope `manual`。
- 任何时候都可以用 `--scope <name>` 显式覆盖，跳出默认绑定规则。

### 2.2 目录布局（纯文本平铺文件，不用 JSON/jq）

```
~/.claude/cli-bridge/sessions/<scope>/<tool>/default_thread          # 纯文本，内容是默认线程名
~/.claude/cli-bridge/sessions/<scope>/<tool>/threads/<thread>/session_id
~/.claude/cli-bridge/sessions/<scope>/<tool>/threads/<thread>/model      # 可能不存在 = 未设置，走 CLI 自身默认
~/.claude/cli-bridge/sessions/<scope>/<tool>/threads/<thread>/effort     # 仅 codex 用；可能不存在
~/.claude/cli-bridge/sessions/<scope>/<tool>/threads/<thread>/last_used  # ISO8601 时间戳
```

`<tool>` ∈ `{codex, opencode}`。每个字段一个文件，读写只用 `cat` / `printf`，
目录不存在时按需 `mkdir -p` 自动创建。这样在 bash 3.2（macOS 自带）和
Git Bash 上行为完全一致，不依赖任何 JSON 解析工具。

另外两个字段是后来加的，存法一样：`threads/<thread>/cwd`（线程绑定的工作
目录，见 §2.4）和 `threads/<thread>/activity.log`（`peek` 用的实时活动
feed，见 §4.3）。

### 2.3 并发保护

最初的设计假设"同一时刻只有一个调用方在操作同一个线程"，后来发现这个假设
不成立（同一个线程可能被并行的多个调用方同时 `ask`），于是补了一层基于
目录的锁：

- `acquire_thread_lock`/`release_thread_lock`（`state.sh`）用 `mkdir` 的原子性
  实现锁（`mkdir` 成功 = 拿到锁，这在 Git Bash 和 macOS 上都能用，不需要
  `flock`）。锁目录是 `threads/<thread>/.lock`，里面存一个 `pid` 文件。
- 拿不到锁时轮询等待，等到 `CLI_BRIDGE_LOCK_WAIT_SECONDS`（默认 30 秒）后
  仍拿不到就报"忙"退出，不会无限等待。
- 等待期间如果发现锁的持有者 PID 已经不存在（`kill -0` 失败），自动清理
  这把"死锁"并重试——进程被杀掉/崩溃而没走到 `release_thread_lock` 时不需
  要人工介入。已知的局限：PID 复用时可能误判死锁仍然存活，属于这种目录锁
  方案固有的、成本收益上不值得进一步解决的边界情况。
- `write_field`/`set_default_thread` 也改成了原子写（写临时文件再
  `mv -f`），避免并发场景下读到"半写"的字段内容。
- `bridge.sh` 里所有会修改线程状态的动作（`ask`/`new`/`model`/`effort`/
  `cwd`）都在开头 `acquire_thread_lock`，所有退出路径（成功/失败/超时/
  提前 die）都要 `release_thread_lock`，不能漏。

### 2.4 cwd（线程绑定工作目录）

每个线程可以绑定一个专属工作目录：

- `new --cwd <dir>` 或裸 `ask` 第一次自动建线程时，如果没传 `--cwd` 就把
  `$(pwd)` 存成这个线程的 cwd；传了就用传的值（先 `require_dir` 校验）。
- 这个值从此对该线程**固定不变**（这是有意的设计，不是遗漏）：Codex 那边
  `-C`/`--cwd` 只在 `codex exec`（新会话）里有效，`codex exec resume`
  根本不接受这个参数（`--help` 实测确认），所以 resume 阶段改 cwd 没有
  意义。为了让"固定不变"这件事对调用方可见、不至于被静默忽略，`do_ask`
  在 cwd 字段已经有值、又传了不同的 `--cwd` 时会直接报错退出，而不是悄悄
  用旧值——早期实现有个 bug 就是拿 `session_id` 是否已设置来判断"能不能改
  cwd"，但 `new` 建线程时 cwd 字段会立刻写入而 `session_id` 还是空的，
  于是这个守卫形同虚设，`--cwd` 被静默忽略且没有任何提示；后来改成直接判
  cwd 字段本身是否已有值，才是正确的不变量。
- `bridge.sh <tool> cwd <thread> <dir>` 可以修改一个线程的 cwd——但对 codex
  只在该线程还没有 `session_id`（还没成功跑过一轮）时才允许，因为一旦
  resume 过，改这个字段对实际行为没有影响，允许改只会让人误以为生效了。
- OpenCode 没有这个限制：`--dir` 是每次调用都传的参数（不像 codex 的 `-C`
  只在建会话时生效），所以理论上完全可以每次都变，但为了和 codex 的语义
  保持一致、避免"cwd 什么时候会变"这件事因 tool 不同而分裂成两套心智模型，
  `ask` 里也用同样的"锁定后拒绝隐式覆盖"策略,只是 `cwd` 子命令没有 codex
  那样的 session_id 限制。

### 2.5 输出边界

早期设计里 `ask` 的成功回复/失败回复都是原样 `cat` 出来，长度不受控。这在
Codex/OpenCode 跑飞（比如卡在读一个巨大文件、或者把大段命令输出当成"最终
回复"写出来）时会把整个巨大 payload 灌回调用方——如果调用方是 Claude Code
自己，这就直接污染了 Claude 的上下文。后来加了三层字节上限（都可以用环境
变量覆盖）：

- `CLI_BRIDGE_MAX_RAW_BYTES`（默认 64 KiB）：codex/opencode 进程的原始
  stdout+stderr 流经这个上限（`tail -c`），只用于内部的错误特征检测
  （`codex_is_untrusted_dir_error` 等），不是最终展示给用户的内容。
- `CLI_BRIDGE_MAX_REPLY_BYTES`（默认 24 KiB）：`ask` 成功时打印给调用方的
  实际回复内容上限。
- `CLI_BRIDGE_MAX_ERROR_BYTES`（默认 16 KiB）：失败时打印到 stderr 的错误
  内容上限。
- 超限时 `print_bounded_file`（`bridge.sh`）用"掐头去尾各留一半、中间插入
  明确的截断提示"的方式截断，而不是简单地砍掉后半段——这样调用方至少能同
  时看到开头和结尾发生了什么。

### 2.6 全局配置（`setup` 命令族）

`model_notes.txt`（模型偏好）和 `routing_guidance.txt`（职责分配说明）是
从 v1 打包/安装需求里加的，存放在 `~/.claude/cli-bridge/` 根目录下，**不**
按 scope 或 thread 分目录——这是有意的：一个用户对"gpt-5.6-sol 聪明但贵"
这类判断，是跨越所有 Claude Code 对话、所有线程都成立的长期偏好，不应该
绑定到某一次对话的 scope。

```
~/.claude/cli-bridge/model_notes.txt        # 一行一条，tool|model|tier|note
~/.claude/cli-bridge/routing_guidance.txt   # 自由文本，整体覆盖式写入
```

管理这两个文件的逻辑单独放在 `scripts/lib/config.sh`（而不是塞进管
per-thread 状态的 `state.sh`），对应的纯逻辑测试在 `config.test.sh`。
`bridge.sh` 里的入口是一族独立的顶层命令，不挂在 `<tool>` 下面：

```
bridge.sh setup probe                                    # 环境探测，见 §4.3
bridge.sh setup note    <tool> <model> <tier> <note>      # upsert 一条模型偏好
bridge.sh setup notes                                     # 列出所有偏好
bridge.sh setup note-rm <tool> <model>                    # 删除一条
bridge.sh setup guidance ["<text>"]                       # 查看/整体覆盖职责分配说明
```

这些记录刻意做成**纯参考**：`ask`/`new` 完全不读取、不校验、不用它们拦截
`--model`。是否要让脚本本身强制生效（比如拒绝执行黑名单模型），是明确讨论
过后放弃的 v1 范围——理由是这属于"该不该自动化决策"层面的产品决策，而不是
一个只需要写对逻辑的技术问题，先让 Claude 读文档自己判断，观察够不够用再说。

## 3. 命令格式

单一入口脚本 `bridge.sh`，第一个位置参数是 `<tool>`（`codex` / `opencode`），
第二个是 `<action>`：

```
bridge.sh <tool> ask   [--thread NAME] [--model M] [--effort LEVEL] [--danger-full-access] [--cwd DIR] "<prompt>"
bridge.sh <tool> new   --thread NAME [--model M] [--effort LEVEL] [--cwd DIR]
bridge.sh <tool> switch <thread>
bridge.sh <tool> list
bridge.sh <tool> model  <thread> <model>
bridge.sh <tool> effort <thread> <level>      # 仅 codex；opencode 调用此 action 直接报错退出
bridge.sh codex  peek   <thread>              # 仅 codex；见 §4.3
bridge.sh <tool> cwd    <thread> <dir>        # 见 §2.4
--scope <name>                                 # 全局可选 flag，可出现在 <tool> 之前或之后
--timeout <seconds>                            # 全局可选 flag，覆盖默认 720 秒
```

`setup` 是独立于 `<tool>` 之外的一族命令（`bridge.sh setup ...`，不是
`bridge.sh <tool> setup`），管的是跨 scope、跨线程的全局配置，见 §2.6。

`--danger-full-access` 和 `--effort` 一样仅对 `codex` 有意义（对应 codex 的沙盒模式）；
对 `opencode` 传这两个 flag 直接报错退出，提示"仅 codex 支持"。

行为细则：

- `ask` 不带 `--thread` 时，用该 tool 的 `default_thread`（初始值 `default`）；
  该线程不存在则自动新建（首次调用即建立 session）。
- `new --thread X`：新建或重置线程 X。若 X 原本有 `session_id`，重置后清空该字段
  （旧的 codex/opencode 会话本身还在磁盘上，只是这个线程名不再指向它）；
  已设置的 `model`/`effort` 默认保留，除非本次 `new` 又显式传了 `--model`/`--effort`。
- `switch <thread>`：把 `default_thread` 指向 `<thread>`。允许指向一个还不存在的线程名，
  下次对它 `ask` 时会自动新建。
- `list`：按 tool 列出所有线程名 + session_id（短） + model + effort + last_used；
  scope 目录不存在时输出"暂无线程"而不是报错。
- `model` / `effort`：只更新对应字段文件；若线程不存在则新建一个"空线程"
  （无 session_id，等第一次 `ask` 时才真正创建会话），这样可以提前配置好模型再开聊。
- 在 Claude Code 里，用户可直接输入 `/cli-bridge codex ask --thread review "xxx"` 触发这个
  Skill；Claude 在需要时也会主动调用同一个脚本。脚本本身不依赖 Claude Code，
  在任何终端都可以 `bash bridge.sh ...` 直接跑。

## 4. 执行细节

### 4.1 Codex

- 新线程：`codex exec --json --skip-git-repo-check -C <cwd> [-m MODEL] [-c model_reasoning_effort=EFFORT] [-s SANDBOX] -o <tmpfile> "<prompt>"`
- 续接线程：`codex exec resume <session_id> --json --skip-git-repo-check [-m MODEL] [-c model_reasoning_effort=EFFORT] -o <tmpfile> "<prompt>"`
  （**没有** `-C`：`codex exec resume --help` 实测确认 resume 根本不接受
  这个参数，工作目录只能在建会话时定，见 §2.4；同理 `-s`/`--sandbox` 也
  不接受，resume 时沙盒模式沿用建会话时的设置，`--danger-full-access` 对
  已 resume 过的线程不生效，`do_ask` 会打一行提示而不是静默丢弃）。
- `--skip-git-repo-check` 恒定带上（当前工作目录经常不是 git 仓库，已实测会报
  `Not inside a trusted directory` 而失败）。
- `--json` 是后来加的（原本没有）：让 codex 输出 JSONL 事件流而不是人类可读
  banner，目的是拿到 §4.3 描述的实时活动 feed。加了 `--json` 之后 stdout
  不再有旧格式的 `session id: <uuid>` 这行文本了。
- 干净回复依然是读 `<tmpfile>`（`-o/--output-last-message`），这个机制和
  `--json` 无关，两个 flag 互相独立，一起用不冲突。
- 新线程的 `session_id` 现在从 JSONL 里 `thread.started` 事件的 `thread_id`
  字段解析（`codex_extract_session_id`），只有在没匹配到时才 fallback 到旧
  banner 正则（兼容旧日志/未来万一 `--json` 拿不到的情况）。
- `model` / `effort` 字段文件存在才拼对应参数，否则不传，走 `~/.codex/config.toml`
  的全局默认。
- 权限：不显式传 `-a`，使用 `codex exec` 自身默认值 `approval=never`
  （失败直接把原因写回文本回复，不会真的弹出确认卡住）。沙盒默认
  `workspace-write`；如需更宽松，`ask`/`new` 支持 `--danger-full-access` 透传为
  `-s danger-full-access`，默认不开，且仅在**新建**会话时有效（见上）。

### 4.2 OpenCode

- 新线程：`opencode run --auto --dir <cwd> [-m MODEL] "<prompt>"`。
- 续接线程：`opencode run --auto --dir <cwd> -s <session_id> [-m MODEL] "<prompt>"`。
- `--auto`（自动批准未被显式拒绝的权限请求）恒定带上，避免非交互调用因为等待
  权限确认而挂起。这是刻意的降权取舍，SKILL.md 里会写明原因。
- 干净回复 = 原始 stdout 过滤掉 `>` 开头的 header 行和空行后剩下的内容。
- `effort` 概念不适用于 opencode；对 opencode 调用 `effort` action 直接报错退出，
  提示"仅 codex 支持"。
- 新会话的 session id：最初是抓 `opencode session list` 人类可读表格的第 3
  行，后来发现表格的表头/列不是稳定接口，改成 `opencode session list --format json -n 1000`
  抓结构化输出。同时改了识别新会话的算法：调用前后各拍一次快照
  （`opencode_session_ids`），取"调用后出现、调用前没有"的那个 ID
  （`opencode_new_session_id`）——如果这个差集不是恰好一个（比如与另一个
  并发的 opencode 调用同时各自新建了会话），直接判定失败，报错让调用方
  重试，而不是猜一个可能是别人会话的 ID 附上去。

### 4.3 实时活动可见性（`peek`）与环境探测（`setup probe`）

`codex_ask_raw` 原本是纯粹的 `raw="$(codex exec ... 2>&1)"`，bash 的命令替
换会完全缓冲，调用中途谁都看不到 codex 在干什么，超时后 reply 文件常常是
空的。后来加了两样东西：

- **活动 feed**：`--json` 输出的每一行 JSONL 事件流经 `codex_capture_stream`
  这个管道函数，一边原样透传给 stdout（保持原有的错误检测逻辑不受影响），
  一边用 `codex_format_activity_line` 过滤成简短的中文状态行写进
  `threads/<thread>/activity.log`。这个过滤器是白名单式的：只有
  `command_execution`/`file_change`/`mcp_tool_call` 这类"动作类"事件才会
  产出一行，`agent_message`/`reasoning` 这类带模型原话/思维链的"内容类"
  事件一律返回空、绝不写盘——这是刻意的设计约束：cli-bridge 经常被当成
  Claude Code 的子代理来派活，完整的回复/思维链一旦被自动打印回调用方，
  会直接污染 Claude 自己的上下文；用户明确要求过"只要工具调用/正在运行命
  令这种简讯，不要思维链"。`activity.log` 每次新 `ask` 都会清空重写（不是
  无限追加），行数上限 `CLI_BRIDGE_ACTIVITY_MAX_LINES`（默认 200）。
- **`bridge.sh codex peek <thread>`**：读 `activity.log` 最后 10 行，仅
  codex 支持（opencode 没有等价的 `--json` 事件流可以喂）。这是完全独立于
  `ask` 返回值的旁路——`ask` 的 stdout 永远只是干净的最终回复，不会自动把
  activity feed 拼进去，必须显式调用 `peek` 才能看。

`setup probe`（见 §2.6）用的是同一种"只做事实搜集，不做判断"的哲学，但
更进一步：它甚至不解析自己拿到的输出，直接把 `codex --version` /
`codex login status` / `codex doctor --json --summary` 和 `opencode --version`
/ `opencode providers list`（去掉 ANSI 转义）/ `opencode models` 的原始
文本拼起来打印。这里刻意放弃了"不用 jq/python"这条戒律对*输出*的约束——
因为这条戒律原本是为了不让 bridge.sh 自己需要解析 JSON，而 `setup probe`
的消费者永远是正在做安装/配置的 Agent（一个 LLM），不是另一段脚本，让它
直接读原始 JSON/文本比 bridge.sh 越俎代庖地半吊子解析更可靠。

## 5. 运行时间 / 异步与超时

- `ask` 可能耗时数分钟（Codex/OpenCode 单次调用官方说明是 1–15 分钟）。
  Claude 调用本脚本执行 `ask` 时，默认走 Bash 工具的 `run_in_background: true`，
  由 Claude Code 自带的后台任务完成通知机制在跑完后自动唤醒 Claude ——
  这是 harness 已有能力，脚本本身不需要为此做任何特殊设计，也不需要用户手动介入。
- `list`/`switch`/`model`/`new`/`effort` 都是纯本地文件读写，瞬时完成，走前台同步调用。
- 脚本内部给 `ask` 的实际 codex/opencode 调用包一层**可移植超时**（不用 GNU `timeout`，
  因为 macOS 系统自带版本没有这个命令）：用 `cmd & pid=$!; ... wait/kill` 的方式实现，
  默认超时 720 秒（12 分钟），可用 `--timeout SECONDS` 覆盖。超时后脚本明确报
  "超时未完成"并以非零退出码结束，不做静默挂起。

## 6. 错误处理

- 已知坑位由脚本自动规避/识别：
  - Codex 的 `Not inside a trusted directory` → 恒定带 `--skip-git-repo-check` 规避，
    不需要运行时识别。
  - Resume 时目标 session 已失效（被删除/过期）→ 识别对应报错文本后，提示
    "线程 <name> 的会话已失效，请用 `new --thread <name>` 重建"，非零退出，
    不做静默新建同名会话（避免用户误以为还是原上下文）。
- 其余错误（模型不存在、网络失败、认证过期等）原样把 codex/opencode 的报错文本
  冒泡给调用方（通常是 Claude），由调用方判断要不要重试/换线程/换模型，
  脚本不做额外的静默兜底或重试。

## 7. 文件清单（实现阶段产出，含后续新增）

```
~/.claude/skills/cli-bridge/
  SKILL.md                    # 技能描述 + 触发条件 + 使用说明 + 首次安装步骤
  design.md                    # 本文档
  plan.md, plan-*.md            # 各阶段实现前写的计划文档（历史记录，不是活文档）
  scripts/bridge.sh             # 入口脚本：TOOL/ACTION 解析、do_* 命令、setup 命令族
  scripts/lib/state.sh          # 按 scope/thread 的平铺文件存储 + 目录锁（§2.3）
  scripts/lib/state.test.sh
  scripts/lib/codex.sh          # codex_ask_raw + JSONL 解析/活动过滤（§4.1, §4.3）
  scripts/lib/codex.test.sh
  scripts/lib/opencode.sh       # opencode_ask_raw + session id 匹配（§4.2）
  scripts/lib/opencode.test.sh
  scripts/lib/config.sh         # 全局 model_notes/routing_guidance 存储（§2.6）
  scripts/lib/config.test.sh

~/.claude/cli-bridge/                        # 运行时数据，不在技能目录里
  model_notes.txt                             # 全局，见 §2.6
  routing_guidance.txt                        # 全局，见 §2.6
  sessions/<scope>/<tool>/threads/<thread>/... # 见 §2.2/§2.4
```

## 8. 测试方式

`state.sh`/`codex.sh`/`opencode.sh`/`config.sh` 里的纯逻辑函数（不调用真实
`codex`/`opencode` CLI 的部分）都有对应的 `*.test.sh`，用简单的
`assert_eq` 断言 + fixture 字符串，不需要网络或真实 CLI；四个文件一起跑：

```
bash scripts/lib/state.test.sh && bash scripts/lib/codex.test.sh \
  && bash scripts/lib/opencode.test.sh && bash scripts/lib/config.test.sh
```

会真正调用 `codex`/`opencode` CLI 的部分（`codex_ask_raw`、
`opencode_ask_raw`、`setup probe`）没有自动化测试，仍然靠手动冒烟测试
（实现/改动完成后逐条跑一遍）：

1. `codex ask` 无 `--thread` → 自动建 `default` 线程，返回干净回复
2. 同一 `default` 线程连续两次 `ask`，第二次能读到第一次告诉它的信息 → 验证续接成功
3. `codex new --thread review --model gpt-5.5` → `codex ask --thread review` 用的是
   `gpt-5.5`（可以从 codex 输出的 banner 或行为侧面验证）
4. `codex switch review` 后裸 `ask`（不带 `--thread`）落到 `review` 线程
5. `codex list` 输出包含刚才建的线程、session_id、model
6. 故意删掉某线程记录的 session_id 对应内容 / 传一个假 session_id 触发 resume 失败 →
   看到"线程已失效，请 new 重建"的提示而不是卡死或静默新建
7. 同样跑一遍 opencode 的 1/2/4/5
8. 换一个 `--scope` 跑，验证不同 scope 之间线程互不可见
9. 在非 git 仓库目录（当前用户主目录本身即是）跑，验证不会报
   `Not inside a trusted directory`
