# 纯委派编排者：主代理不带原生工具，值不值得做？

调研日期 2026-11-10。问题：面向用户的主代理不能读文件、不能跑 shell、不能编辑，所有查找交给便宜的 explorer，所有命令、构建、测试、编辑交给 coder，自己只做计划、写简报、整合报告。与主流做法（主代理全功能，子代理可选）和两种折中（只读文件；只读文件加只读 shell）比较。本次只做调研，没有改任何代码或配置。

## 结论

**不建议把「主代理完全没有原生工具」作为默认工作方式。** 建议默认用「只读编排者」：能读文件、grep、跑只读 shell（`git log` / `diff` / `show`），不能编辑、不能跑构建和测试，并且用工具限制而不是提示词来保证。纯委派只作为按会话开启的模式，用于规模大、规格清楚、可并行、有测试判定的工作。

- **文献**：多代理在可并行、读多写少的任务上有实测收益（Anthropic 研究系统 +90.2%；Cursor 的「规划者 + 便宜执行者」成本约为单一前沿模型的 1/8），在顺序、强耦合的任务上实测变差（Google / DeepMind：−39% 至 −70%）。日常编码和编译器调试多数属于后者。
- **产品史**：真正发布过无工具协调者的 Roo Code，后来加了「可选读权限」；Kilo Code 已弃用 Orchestrator 模式；Claude Code 官方的协调者示例保留了 Read 和 Bash。没有找到主流 harness 把无工具主代理作为交互式默认。
- **本机数据**：Claude 加权用量的 92–94% 花在顶层 Opus 会话，其中约 3/4 是长工具循环里反复重读上下文。所以「让贵模型少动手」方向是对的；但便宜 explorer 在编译器考古上两次得 1 分，一次往返中位 80–450 秒，编排者必须留一个便宜的核实手段。
- **没有直接证据**：没有找到在真实编码任务上对比「无工具主代理」和「有工具主代理」的受控实验，结论由相邻证据推出。

## 本机数据（实测）

来源：`var/agent-usage.jsonl`（1546 行）、`var/emx/subagent-runs.jsonl`（66 次运行，33 次有评分，2026-10-23 至 11-10）、本机 Claude 会话记录。加权用量按 API 价格比例估算（输入 1、cache read 0.1、cache write 1.25、输出 5）；订阅配额的真实权重没有公开。

- **配额花在哪**：近 14 天顶层 Opus 会话占 Claude 加权用量 94%（近 7 天 92%），Opus 子代理只占 4%。
- **花在什么上**：cache read 73–75%，cache write 17–18%，输出 8%。配额主要被「每次工具调用都重读一遍上下文」吃掉，而不是被输出吃掉。
- **每个顶层 Opus 回合的 cache read**：p50 109 万，p75 274 万，p90 569 万，最大 3180 万 token。
- **长回合是主体**：cache read 超过 100 万的回合有 318 / 621 个，占加权用量 88%；不超过 30 万的 99 个回合只占 2%。
- **主代理在做什么**：近 14 天 44 份 Opus 主线程记录共 5131 次工具调用，Bash 68%，Edit + Write 9%，Read 3%。Bash 以 git、python3、grep、sed、emacs 批量测试为主，也就是查找和执行都在贵模型上。
- **子代理质量**：coder-flash 21 次里 5 次失败，均分 8.6；explorer（gpt-6.1-terra）均分 6.7，其中两次编译器考古任务得 1 分；coder 均分 7.6。

**子代理一次往返的中位时长（秒）**

|  | 中位时长 |
| --- | --- |
| explorer / gpt-6.1-terra | 80 |
| explorer / glm-5.3-flash | 179 |
| explorer-flash | 446 |
| reviewer | 525 |
| coder-flash | 694 |
| coder | 1028 |
| researcher | 1200 |

含义：纯委派下，现在一次 grep 就能回答的问题会变成 80–450 秒的等待；需要跑一条命令确认的事会变成 12–17 分钟。

## 四个工具等级

| 等级 | 主代理的原生工具 | 对配额 | 主要风险 |
| --- | --- | --- | --- |
| 全功能（主流） | 读、写、跑 | 最费，工具循环在贵模型 | 上下文被日志填满 |
| 只读 + 只读 shell | 读、grep、git 只读 | 重活必然外包 | 读取循环仍烧配额 |
| 只读文件 | 读、grep | 同上 | 看 diff 和历史不便 |
| 纯委派 | 无，只能派子代理 | 理论最省 | 核实缺口、延迟、失真 |

- **全功能**：Claude Code、Codex、Amp、opencode 的默认；本机现状。
- **只读 + 只读 shell**：Claude Code 文档的协调者示例（`tools: Agent(worker, researcher), Read, Bash`）；与 Cognition 2026 年「写保持单线程」的结论一致。
- **只读文件**：Roo Code Orchestrator 打开可选读权限之后的形态。
- **纯委派**：Roo Code Orchestrator 的默认形态；Cursor 长程自主运行里的规划者（无人值守，不是交互式）。Kilo Code 已弃用。

## 证据表

「性质」一列区分实测和观点；编号对应下面一段里的原文链接和具体数字。

| # | 来源 | 结论 | 性质 |
| --- | --- | --- | --- |
| 1 | Anthropic 研究系统 2025-06 | 研究评测 +90.2%；编码可并行的部分少 | 实测 + 观点 |
| 2 | Building effective agents | 先用最简方案，需要时才加复杂度 | 观点 |
| 3 | Claude 博客 2026-01 | token 多 3–10 倍；按角色拆易失真 | 自测 + 观点 |
| 4 | Cognition 2025-06 | 共享完整轨迹；隐含决策会冲突 | 观点 |
| 5 | Cognition 2026-04 | 写保持单线程，帮手只出智力 | 经验 |
| 6 | DeepMind 等 2025-12 | 顺序任务 −39–70%；并行任务 +80.9% | 实测 |
| 7 | MAST 2025 | 失败 42% 规格、37% 失配、21% 验证 | 实测 |
| 8 | Anthropic 顾问策略 2026-04 | Opus 只当顾问：分更高，成本 −12% | 实测（厂商） |
| 9 | Cursor 2026-01 | 规划 / 执行 / 评判分层可行 | 经验 |
| 10 | Cursor 2026-07 | 规划者不实现；成本约为单模型 1/8 | 实测（自报） |
| 11 | Aider 架构师 2024-09 | 85.0% 对 79.7%，但交互太慢 | 实测 |
| 12 | Roo Code Orchestrator | 无工具协调者；后加可选读权限 | 产品事实 |
| 13 | Kilo Code | Orchestrator 模式已弃用 | 产品决策 |
| 14 | Claude Code 子代理文档 | 协调者示例保留 Read 和 Bash | 文档 |
| 15 | Claude Code 团队文档 | 约 7 倍 token；lead 有时自己动手 | 文档 |
| 16 | Codex 子代理文档 | 并行用于读多的任务，并行写要小心 | 文档 |
| 17 | Amp 文档 | 主代理干活；Oracle 只建议不编辑 | 文档 |
| 18 | Lance Martin 2026-07 | 小题多花 60%；大题 46% 成本拿 96% 分 | 实测（二手） |
| 19 | Orchestrator's Tax 2026-07 | 成本在编排者带走的上下文 | 经验 |
| 20 | Anthropic C 编译器 2026-02 | 不设编排者，靠近乎完美的验证器 | 经验 |
| 21 | Anthropic harness 2026-03 | 三代理 200 美元对单代理 9 美元 | 实测（单例） |
| 22 | Magentic-One 2024-11 | 纯指挥编排者；去掉账本 −31% | 实测 |

## 原文链接与具体数字（按编号）

1. [Anthropic：How we built our multi-agent research system](https://www.anthropic.com/engineering/multi-agent-research-system)。Opus 4 主导 + Sonnet 4 子代理在内部研究评测上比单个 Opus 4 高 90.2%；token 用量解释 80% 的成绩差异；多代理约为聊天的 15 倍 token。原文同时说编码任务真正可并行的部分比研究少，需要共享上下文或依赖多的领域目前不适合多代理；建议子代理把产出写进文件以减少「传话游戏」。实测（内部评测）加观点。
2. [Anthropic：Building effective agents](https://www.anthropic.com/engineering/building-effective-agents)。定义 orchestrator-workers 模式；主张先找最简单的方案，只在需要时增加复杂度。观点。
3. [Claude 博客：Building multi-agent systems: when and how to use them](https://claude.com/blog/building-multi-agent-systems-when-and-how-to-use-them)。多代理通常比单代理多用 3–10 倍 token；按角色（规划、实现、测试）拆分是「传话游戏」，协调花的 token 比干活还多；应按上下文边界拆；验证者容易过早宣布成功。厂商自测（口径较松）加观点。
4. [Cognition：Don't Build Multi-Agents](https://cognition.com/blog/dont-build-multi-agents)。要共享上下文和完整轨迹；动作带着隐含决策，决策冲突导致坏结果；2024 年「大模型描述、小模型落笔」的做法曾因指令歧义失败。观点和经验。
5. [Cognition：Multi-Agents: What's Actually Working](https://cognition.com/blog/multi-agents-working)。写操作保持单线程、其它代理贡献智力而不是动作时效果最好；代理常误以为子代理共享自己的状态；「聪明朋友」模式只有主代理够强时才有效。经验加内部数据。
6. [Google / DeepMind / MIT：Towards a Science of Scaling Agent Systems](https://arxiv.org/abs/2512.08296)。顺序型任务在所有多代理结构下下降 39–70%（中心化 −50.3%）；可并行的金融任务中心化 +80.9%；每千 token 成功数单代理 67.7 对中心化 21.5；单代理基线超过约 45% 后收益饱和；工具多的任务在固定预算下最吃亏。实测，但不是编码基准。
7. [MAST：Why Do Multi-Agent LLM Systems Fail?](https://arxiv.org/abs/2503.13657)。失败归因：规格问题 41.77%，代理间失配 36.94%，任务验证 21.30%；其中重复步骤 17.14%，不追问澄清 11.65%。实测（轨迹标注）。
8. [Anthropic：The advisor strategy](https://claude.com/blog/the-advisor-strategy)。反向模式：便宜模型执行，Opus 只当顾问，不调工具，不面向用户。Sonnet + Opus 顾问在 SWE-bench Multilingual 上 +2.7 个百分点，成本 −11.9%；每次咨询 400–700 token。实测（厂商）。
9. [Cursor：Scaling long-running autonomous coding](https://cursor.com/blog/scaling-agents)。扁平协作和锁失败，代理变得畏缩；规划者 / 执行者 / 评判者分层可行；专设的集成者角色制造的瓶颈比解决的多。经验。
10. [Cursor：Agent swarms and the new model economics](https://cursor.com/blog/agent-swarm-model-economics)。「规划者从不实现，所以它的上下文不会被细节填满」；Opus 4.8 规划 + Composer 2.5 执行花 1,339 美元，GPT-5.5 单独做花 10,565 美元；规划者 token 很少却占约 2/3 成本。实测但自报，条件是全新项目、无人值守、有 sqllogictest 这样的强判定。
11. [Aider：Separating code reasoning and editing](https://aider.chat/2024/09/26/architect.html)。o1-preview 架构师 + 编辑器 85.0% 对单模型 79.7%。注意架构师看得到代码；作者说速度慢，可能不适合交互使用。实测。
12. [Roo Code：Orchestrator（boomerang tasks）](https://docs.roocode.com/features/boomerang-tasks)。发布的无工具协调者：不能读写文件、调 MCP、跑命令，理由是让它专注于流程、避免读文件填满上下文；信息必须显式下传，只有摘要返回。之后提供了可选的读权限。社区反馈有摘要不完整或失实、例行读取和测试都要开子任务的抱怨。设计理由（观点）加产品事实。
13. [Kilo Code：Orchestrator mode](https://kilo.ai/docs/code-with-ai/agents/orchestrator-mode)。「Orchestrator mode is deprecated」；文档的说法是带完整工具的代理（Code、Plan、Debug）现在可以自动委派子代理。产品决策。
14. [Claude Code：Sub-agents](https://code.claude.com/docs/en/sub-agents)。频繁来回、多阶段共享大量上下文、小改动、看重延迟时留在主会话；官方协调者示例是 `tools: Agent(worker, researcher), Read, Bash`。文档。
15. [Claude Code：Agent teams](https://code.claude.com/docs/en/agent-teams) 与 [Costs](https://code.claude.com/docs/en/costs)。团队在队友跑 plan 模式时约为普通会话 7 倍 token；顺序任务、同文件编辑、依赖多的工作用单会话或子代理更好；「lead 有时自己开始实现而不等队友」。文档，含厂商数字。
16. [Codex：Subagents](https://learn.chatgpt.com/docs/agent-configuration/subagents)。并行代理用于读多的任务（探索、测试、分诊、总结）；并行写要更小心；比同等单代理运行更耗 token。文档。
17. [Amp：Models and subagents](https://ampcode.com/docs/models-and-subagents)。主代理处理任务，子代理做聚焦的部分；Oracle 只给意见，从不编辑；子代理之间不能通信，用户不能直接引导。文档。
18. [Lance Martin 的 X 帖](https://x.com/RLanceMartin/status/2075641284635799865) 与 [二手转述](https://claudefa.st/blog/guide/development/multi-agent-orchestration-cost)。简单检索题（每题约 37 万阅读 token）上编排多花 60% 且无收益；重度检索题（每题约 3100 万 token）上 Fable 5 编排 + Sonnet 5 执行以 46% 成本拿到 96% 分数。「委派带来的 token 套利必须抵过协调成本」。实测，但只取得帖子和二手转述，没读到一手全文。
19. [Martin Fowler 站：The Orchestrator's Tax](https://martinfowler.com/articles/orchestrator-tax.html)。成本在编排者「选择带走什么」上；4 个子代理约 12 分钟，串行约 25 分钟；文件归属重叠是该合并任务的信号。经验，没有 token 核算。
20. [Anthropic：Building a C compiler with a team of parallel Claudes](https://www.anthropic.com/engineering/building-c-compiler)。16 个代理，不设编排代理，约 2000 个会话、约 2 万美元、10 万行；关键是近乎完美的任务验证器（用 GCC 作基准），否则模型会去解错的问题。经验，和编译器工作直接相关。
21. [Anthropic：Harness design for long-running application development](https://www.anthropic.com/engineering/harness-design-long-running-apps)。单代理 20 分钟 9 美元，对规划 + 生成 + 评估三代理 6 小时 200 美元；代理给自己的工作打分偏乐观；harness 的每个部件都是「模型自己做不到什么」的假设，会过时。实测（单例）加观点。
22. [Microsoft：Magentic-One](https://arxiv.org/abs/2411.04468)。编排者只指挥其它代理；去掉账本成绩下降 31%；最常见的错误是重复低效动作和验证步骤不足。实测，非编码任务。

## 纯委派什么时候有效

- 委派出去的 token 量大到能抵消协调成本：批量阅读、长构建、基准测试系列、成百上千行日志。
- 子任务互不依赖，可以并行；每个子任务一段话能说清，带验收标准。
- 有强判定器：测试套件、编译器、参照实现（Cursor 的 sqllogictest，C 编译器项目的 GCC）。
- 无人值守或长时间运行，用户不在等每一步。
- 主代理要产出的只是计划和取舍，不需要逐行理解代码。

## 纯委派什么时候有害

- **顺序、强耦合的工作**：调试、改–编–修循环、沿调用链追一个精确事实。编译器考古正是这一类，本机两次 1 分都出在这里。
- **小事**：一次 grep 能回答的问题变成 80–450 秒的往返，外加写简报和读报告的 token。Lance Martin 的小题实验里编排多花 60%。
- **核实缺口**：主代理打不开 file:line，只能相信摘要或再派一次。MAST 里验证类失败占 21%，Claude 博客和 Anthropic harness 文章都提到代理容易过早宣布成功。
- **传话失真**：子代理只拿到简报，各自的隐含决策互相冲突。emx 的子代理只做一件事、不接受追问，回复最多 30000 字符，更依赖简报质量。
- **交互对话**：用户指着一段代码问问题，主代理读不了就只能转述别人的转述。
- **审阅**：atomic review 需要主代理自己读 diff。
- **模型变强之后**：这层约束可能变成纯负担。Kilo 弃用 Orchestrator 模式时的说法是带工具的代理已经会自己委派；Anthropic harness 文章也说这类部件的假设会过时。

## 对本机配置的建议

1. **编排者默认用「只读 + 只读 shell」。** 保留 Read / Grep / Glob、只读的 MCP 工具、`git log` / `diff` / `show` / `blame` 这类只读命令；去掉 Edit / Write / NotebookEdit，以及构建、测试、脚本执行。这已经满足「编排者永不写代码」，同时保住核实报告的能力。
2. **用工具限制保证，不要只靠提示词。** 现状：profile 的 `tools` 只管注入的 MCP 工具，文档明说不是原生工具的沙箱；Claude 的 `disallowedTools` 是代理级的，设了会连 Claude 的 coder、researcher 候选一起限制。按 profile 限制原生工具需要 emx 新增能力。本机数据（Bash 占 68%）和 Claude Code 文档（lead 有时自己动手）都说明提示词规则挡不住。
3. **保留现有委派规则和例外清单。** 「第二次查找之前就委派」继续有效；只读权限用来核实和回答小问题（打开的文件里的定义、一次 grep 的事实、用户指着的代码、读 diff），不是用来自己做调研。
4. **纯委派做成按会话开启的模式**（[doc/subagents.md](doc/subagents.md:589) 的未决问题「direct only」）。适用：大规模机械迁移、多模块普查、基准测试系列、有测试判定的批量实现。不适用：编译器调试、交互式的 Elisp 小改动。
5. **编译器考古不要派给最便宜的 explorer。** 派给 coder 或 researcher 一级，或者由编排者逐条核对报告里的 file:line。长报告让子代理写进文件再回传路径，避免截断和转述失真（Anthropic 研究系统的做法）。
6. **另一条省配额的路：顾问模式。** 便宜模型做主会话，Opus 只作为 expert 被咨询。Anthropic 有实测（成本 −11.9% 且分数更高），Cognition 提醒主代理要够强才有效。值得和第 1 条做对照试验。

## 试用头几天看什么

| 指标 | 现在的基线 | 期望 |
| --- | --- | --- |
| 顶层 Opus 每回合 cache read | p50 109 万，p90 569 万 | 明显下降 |
| cache read 超 100 万的回合 | 318 / 621，占用量 88% | 占比下降 |
| 主代理工具调用构成 | Bash 68%，Edit + Write 9% | 只剩只读调用 |
| 子代理失败 | coder-flash 5 / 21 | 不上升 |
| 子代理评分 | explorer 6.7，coder 7.6 | 不下降 |
| 同一任务重派次数 | 未统计 | 每任务至多 1 次 |
| 小问题的等待 | explorer 中位 80–450 秒 | 小问题不外包 |

- 用量看 `C-c a u`，子代理运行和评分看 `C-c a U`；每回合 cache read 在 `var/agent-usage.jsonl`。
- 同样工作量下 Claude 周配额百分比是否下降，是最终判据。
- 留意等待期间缓存过期：子代理跑得比提示缓存的有效期还久时，编排者下一次请求要按 cache write 重写整个上下文（权重 1.25 对 0.1）。表现是 cache write 占比从现在的 17–18% 上升。这一条是按价格权重推出来的，不是文献结论。
- 记下每次「因为不能跑一条命令而卡住」和「报告有错但没被发现」的情况，这两类决定往哪边调。

## 换等级的信号

- (:text "**往更严走（纯委派）**" :items ["限制之后编排者每回合仍有十次以上读取，cache read 仍在百万级。" "子代理报告评分稳定在 8 以上，核实很少发现问题。" "手头工作以可并行、有测试判定的批量任务为主。"])
- (:text "**往更松走（恢复部分 shell 或编辑）**" :items ["同一事实反复重派，或者为一条命令等十几分钟的情况频繁出现。" "编排者依据未核实的报告做了错误决定。" "小问题的等待让你改去别的会话里自己做。"])
- (:text "**改走顾问模式**" :items ["只读编排者下 Opus 周配额仍然吃紧，而便宜主会话 + expert 咨询的结果评分不差。"])

## 证据的局限

- 没有找到在真实编码任务上直接对比「无工具主代理」和「有工具主代理」的受控实验。
- Cursor 和 Anthropic 的数字是厂商自报；Google / DeepMind 的研究和 Magentic-One 不是编码基准。
- Lance Martin 的实验只取得 X 帖和二手转述。Claude Code 泄漏的 coordinator mode、agent teams 的 delegate mode 是否仍存在，都没能从一手来源确认，没有计入结论。
- 本机样本小：66 次子代理运行，33 次有评分；工具调用统计包含 Opus 作为子代理的会话；用量加权按 API 价格估算。
