# cli-bridge 首次安装 / 环境配置

只在你实际要在一台机器上装好/个性化 cli-bridge 时才需要读这份文档——平常
调用 `ask`/`new`/`switch` 等日常操作不需要看这里，`SKILL.md` 里的命令速查
就够了。

`bridge.sh setup <probe|note|notes|note-rm|guidance>` 是一族独立于
`<tool>` 之外的命令（不是 `bridge.sh <tool> setup`），专门服务这件事。

## 步骤

1. **探测环境**：`bash scripts/bridge.sh setup probe`

   它会依次跑 `codex --version` / `codex login status` /
   `codex doctor --json --summary`，以及 `opencode --version` /
   `opencode providers list` / `opencode models`，把原始输出打印在
   `=== codex ===` / `=== opencode ===` 标题下面。任何一个工具不存在都不会
   让整个探测失败——那一节只会打印"`<tool> 未找到（不在 PATH 中）`"然后
   继续跑另一个。

2. **自己解读探测结果，做判断**：这一步命令本身刻意不做任何判断（不比较
   版本新旧、不联网核实"是不是最新版"）——它没有可靠的办法知道当前最新
   版本是什么，这个判断交给正在执行安装的 Agent（也就是你）：
   - **完全没装** → 告诉用户自己去装，不要替用户瞎猜安装命令/链接。
   - **装了但没登录 / 认证过期** → 告诉用户自己跑 `codex login` 或
     `opencode providers login`（这是交互式/需要浏览器的流程，没法脚本化）。
   - **版本看起来很旧，或者 `codex doctor` 的 reachability 检查报错** →
     凭你自己的判断，建议 `codex update` / `opencode upgrade`，或者提醒
     用户可能是网络/代理问题。

3. **和用户聊模型偏好，记下来**：问用户希望哪些 provider/model 用在什么
   场景（比如"贵但聪明，当第二意见用" vs "便宜，随便造" vs "别用这个"）。
   每记一条：

   ```
   bridge.sh setup note <tool> <model> <tier> "<note>"
   ```

   `tool` 只能是 `codex`/`opencode`；`tier` 是自由文本（`expert`/`bulk`/
   `cheap`/`disallowed` 之类，没有固定枚举，用用户自己的说法就行）；
   `model`/`tier`/`note` 都不能包含 `|` 字符（内部用它分隔字段）。重复对
   同一个 `tool`+`model` 调用会覆盖旧记录，不会重复追加。

   ```
   bridge.sh setup notes              # 列出所有记录
   bridge.sh setup note-rm <tool> <model>   # 删除一条
   ```

4. **（可选）记一段职责分配说明**：

   ```
   bridge.sh setup guidance "<完整文本>"
   ```

   这是整篇覆盖写入，不是追加——每次调用都要传完整的最新文本，不是差异。
   不传参数时（`bridge.sh setup guidance`）打印当前内容。

## 这些记录只是参考，不会被脚本强制生效

`ask`/`new` 完全不会读取、校验或用这些记录拦截 `--model`。这是有意的设计
决定（不是遗漏）：让 Claude 在真正要选模型/选工具的时候自己去
`bridge.sh setup notes` 和 `bridge.sh setup guidance` 读一遍、自行判断，
而不是让 bridge.sh 自己长出一套黑名单/自动路由逻辑。如果以后发现纯参考
不够用，可以再讨论要不要加强制校验，但这不是 v1 的范围。

完整设计动机见 `design.md` §2.6、§4.3，以及 `plan-packaging-v1.md`。
