# Ruby Actor 高并发执行模型研究

> 核查日期：2026-11-18。对象：`trouperb`、**Ruby 4.0+（用户已明确锚定，不再兼容 3.2/3.3）**、Async、concurrent-ruby、Ractor、JRuby/TruffleRuby，以及 Troupe 其他语言调度器。
>
> **当前状态：研究结论，未修改生产运行时。** 完整 `:async` Actor 运行时、Async 真实 I/O 探针、Ractor 分片原型、JRuby/TruffleRuby 全量测试均尚未完成，不能据本文推断它们已通过。

## 结论与建议

Ruby 有比“每激活 Actor 一个 OS 线程”更高并发的实现方式，但**不存在一种替换能同时改善激活密度、I/O 并发、CPU 并行和现有阻塞代码兼容性**。

建议把问题拆成四层：

1. **先减少无谓成本**：空闲 Cell 的线程退场而 Actor 保留；实验无竞争时调用方直接交接/inline 执行；为原始值参数与返回值实现等价语义的免 JSON 快路径；审计热路径上的 trace 与 ID 分配。
2. **再做可选 `:fiber` / `:async` 调度器**：采用 Async 或 Ruby Fiber Scheduler 做同线程交接和异步等待，目标是大量等待中的 Actor、嵌套 Actor 调用和网络 I/O，不是解除 MRI GVL。默认 `thread_per_cell` 继续承载普通阻塞 Ruby 代码。
3. **不要让所有阻塞 Turn 直接占住事件循环**：提供显式 `blocking`/offload API，连接到有界线程池。SQLite、PG、第三方 C 扩展必须逐个验证 Fiber Scheduler 集成或卸载，不能假设都非阻塞。
4. **CPU 并行另立项目**：MRI 上用固定数量的 Ractor 分片或多进程 Stage；需要真正线程并行时评估 JRuby。不要把 Fiber、concurrent-ruby 或每 Actor 一个 Ractor 当成 CPU 并行方案。

最终候选是**混合运行时**：默认保留线程隔离；对明确非阻塞的角色选择 Fiber；阻塞任务有界卸载；CPU 密集任务选择多进程/Ractor；JRuby 仅作为独立部署运行时验证。它不是为了追平 Crystal 的解释器常数，而是消除 Ruby 自身的结构性浪费。

## 基准复查

### 原报告成立的部分

- 11-17 轮原始 Ruby 结果为 `call-latency=11,346/s`、`call-hot=16,190/s`、`call-spread=10,568/s`、`activate=426/s`、`48.2 KB/Actor`，驱动明确使用 `dispatcher=thread_per_cell`。所以该报告测量的是**默认每 Actor 一线程**，不是所有 Ruby 可行机制的上限。
- Crystal 的单线程 Fiber 是快速用户态交接，不是多核并行；其自身基准记录 CPU spin 会阻塞同事件循环中的其他 Actor（`troupe.cr/docs/benchmarks.md`）。Ruby Fiber 化也会继承这个限制。
- Windows 时钟量化、loopback 方差和 RSS 对 Node 堆的低估都是真实口径限制；性能改造应使用同进程交替 A/B、多轮中位数，并补 Linux 复测。

### 必须修正或补测的部分

- **Crystal 不是完全零 JSON 文本序列化**：[stage.cr](../../troupe.cr/src/troupe/stage.cr#L144) 在入队时仍执行 `args.to_json.bytesize` 做字节计费。真实优势是没有本地参数/结果的 JSON parse、单线程无锁交接与编译执行，不是“完全没有 serialize”。原分析报告相应句子应收窄。
- **Ruby 的 `spread/hot < 1` 不能只凭 GVL 命名**：它也可能含线程唤醒、共享队列锁、ResponseBox 等成本。只有调度器与 codec 的消融实验能区分贡献。
- **现有 ping 场景不测试 Fiber 最有价值的场景**：它是同步客户端线程到 Actor 线程的往返。需要新增：同事件循环内的 A→B 调用、多个 Actor 的 I/O 重叠、慢/不兼容库卸载、高并发远程入站、阻塞 Turn 的受害者延迟。
- 本轮补跑共享池不能与原 11-17 轮混作同轮 A/B：本轮只测了本地五个场景，其他实现没有同时重跑，系统负载与代码提交也不同。

### 本轮共享池补测（opt-in，不替代原报告）

Ruby 4.0.6 / Windows / 8 逻辑核，window=3s、count=10k、C=8，跳过 persist 与 cluster；复用原驱动。原始输出保存在 `bench-suite/.cache/ruby-concurrency-research/`，属于缓存实验产物；复现命令、原语探针和限制见[实验与证据](./ruby-concurrency-evidence.md)。

| 场景 | 11-17 默认线程 | 本轮 shared | 本轮 shared + 实验性 worker 本地 ready queue |
|---|---:|---:|---:|
| call-latency ops/s | 11,346 | 3,969 | 4,690 |
| call-hot ops/s | 16,190 | 5,416 | 6,459 |
| call-spread ops/s | 10,568 | 4,186 | 5,279 |
| activate ops/s | 426 | 2,051 | 3,281 |
| 驻留 KB/Actor | 48.2 | 2.72 | 2.64 |

解释：共享池确实消除了每 Cell 的线程创建和常驻线程栈，激活与密度改善约一个量级；但它没有消除跨线程等待，本轮热路径反而更差。本地 ready queue 探针进一步改善了 shared，但仍低于默认线程热路径。**不能由这些跨轮数字直接设 shared 为默认，也不能声称本地队列探针可交付生产。**

仓库已有的 9 月同轮对照也显示 shared 在 activate/驻留上显著改善、call-hot 有 ×1.70 改善，但 latency/spread/cluster 有退化（`bench-suite/results/compare-ruby-shared.txt`）。shared 的 cluster 退化原因尚不确定，必须多轮复测，不凭单轮数据决策。

## Ruby 机制：解决什么，不解决什么

| 机制 | 能解决 | 不能解决 | 对 trouperb 的定位 |
|---|---|---|---|
| Ruby `Thread` / 固定线程池 | 阻塞 I/O 重叠；兼容现有阻塞 Ruby；C 扩展释放 GVL 时可并行 | 每任务/等待占线程；MRI Ruby CPU 仍受 GVL | 保留为默认与 blocking offload 池 |
| `Fiber` | 同线程低开销挂起/恢复；较小栈；明确协程序 | 协作式、不跨线程随意 resume、不加 CPU 核 | Actor Turn/等待的执行载体 |
| Fiber Scheduler | 让受支持的 sleep、I/O、Queue/Mutex 等等待挂起 Fiber 并运行其他 Fiber | **默认不安装 scheduler**；不兼容的库仍会阻塞；不等于并行 | `:fiber` 调度器的基础设施 |
| Async | 成熟的事件循环、任务树、定时器、Queue/Condition、取消、selector | 非抢占；C 扩展可能卡住 reactor；通常每线程一个 reactor | 首个 Fiber 原型优先复用，而非手写 IO selector |
| concurrent-ruby | 有界/可配置线程池、Promise/Future、Map、原子变量、取消 | 核心执行器还是线程；Promise 不自动释放阻塞任务所占线程 | 线程原语的备选；不是 Fiber 并发的替代 |
| Ractor | MRI 上跨 Ractor 的 Ruby CPU 并行；对象隔离 | 可变对象默认深拷贝或 move；类/常量/全局状态受限；创建成本高于 Thread；4.0 仍提示 experimental | 固定 N 个分片/独立计算 worker，不是每 Actor 一个 |
| 多进程 Stage | 隔离、利用多核、兼容普通 gem | 进程内存/部署成本、IPC；Windows 不能依赖 fork 模型 | CPU/故障隔离的务实路线 |
| JRuby | 无全局解释器锁的 JVM 线程并行，JVM 并发库 | JVM 依赖、C 扩展兼容、部署变化；不自动减少线程数 | 单独 CI/性能/兼容验证的候选运行时 |
| TruffleRuby | Ruby 与声明线程安全的 C 扩展可并行 | 预热、兼容与平台限制；C 扩展默认全局 extension lock | 长期试验，不作为短期默认方案 |

### 两个不应漏掉的 Ruby 4+ 边界

- **M:N Thread Scheduler 不是 Fiber/CPU 并行**：Ruby 的 M:N 设计用 M 个 Ruby Thread 复用 N 个原生线程；主 Ractor 默认仍用 1:1，可经 `RUBY_MN_THREADS=1` 开启，非主 Ractor 默认采用 M:N；`RUBY_MAX_CPU` 控制共享原生线程上限（3.3 说明默认 8）。同一 Ractor 内仍不能并行执行普通 Ruby 代码，原生 TLS/C 扩展兼容是主 Ractor 默认关闭的原因之一。官方 M:N 设计与 3.3 实现说明见 https://bugs.ruby-lang.org/issues/19842 。Linux 上可作为“保留线程编程模型、降低原生线程数量”的单独实验，不能假定 Windows 有收益，也不能解除 GVL。
- **替代 Ruby 运行时的 Fiber 不是 MRI 的轻量 Fiber**：JRuby 当前 Fiber 由线程执行器承载，有可选 Java virtual thread 路径；TruffleRuby 官方兼容文档也明确 Fiber 目前使用 OS 线程。它们的卖点是线程 CPU 并行，不是天然获得 MRI Fiber 的驻留密度。JRuby 10.1 主线需要 JRE 21+，且不能沿用 MRI C 扩展；TruffleRuby 40.x 面向 Ruby 4.0、支持许多 C 扩展但默认有全局扩展锁、不实现 Ractor，官方支持平台为 Linux/macOS。替代运行时方案必须单独跑兼容与性能矩阵。

### Fiber / Async 的关键事实

- Ruby 4.0 官方 Fiber 文档说明：Fiber 是协作式轻量并发原语，VM 不主动抢占；默认 `Fiber.scheduler=nil`，Ruby 不内置可直接使用的 scheduler 类，必须由 Async 等 gem 提供。
- Async 2.46.0 是 2026-11-18 查到的最新稳定版，要求 Ruby `>= 3.3`，依赖 `io-event`、`console`、`fiber-annotation`。**用户已决定 trouperb 锚定 Ruby 4.0+**，因此该版本门槛不构成约束，研究按最新 Ruby 4 的 Fiber Scheduler/Ractor 接口与 Async 2.x 设计。现有 gemspec 声明 `>=3.2`，而 Util 的运行时检查更松、仍为 `>=3.1`；实施版本升级时两处都要同步为 `>=4.0`，CI 和 README 也应一起更新。本次研究未修改这些生产文件。
- Async 官方文档明确说兼容的 Net::HTTP 等操作可以透明让出，而不兼容、处理器密集或依赖线程状态的库需要后台线程。事件循环内一个不让出的 Turn 会影响同 reactor 上的全部 Actor。
- Async 当前 Queue/Condition 内部使用 Ruby `Thread::Queue` 与 Fiber Scheduler 集成。它们证明“等待可以不占 OS 线程”，但不是免同步或天然比所有 Queue 都快。
- **Async 的通用阻塞操作卸载池不是默认开启的**：当前 Scheduler 源码只有显式传 `worker_pool:` 或设置 `ASYNC_SCHEDULER_WORKER_POOL=true` 才接入 `blocking_operation_wait`。文件 I/O、PStore 与未做 scheduler 集成的驱动不能默认视为异步；原型必须显式配置并验证有界 worker 池，或将这些操作放入 trouperb 自己的 offload 通道。
- `Mutex` 的等待有 scheduler hooks，但持锁区仍要短，绝不能在锁内等待另一个 Actor 或做长 I/O。

### concurrent-ruby 的关键事实

- `FixedThreadPool`、`CachedThreadPool`、`ThreadPoolExecutor` 是线程复用、排队和背压工具；`Promises.future` 也跑在线程池上。它们可替代当前手写池的部分实现，但不提供 Go 式 M:N 调度。
- Promise chain 可在任务完成后调度 continuation，减少“为等结果再占一条线程”；但普通 Ruby 方法中的 `future.value` 仍然阻塞。它更适合外部 API/传输回调，不能自动把现有同步 Actor 方法变成协程。
- `Promises::Channel`、`ProcessingActor` 和旧 Actor 相关部分位于 `concurrent-ruby-edge`，API 稳定承诺与核心工具不同。不应为了已有 Troupe Cell/Props/生命周期语义另换一套 Actor 框架。
- `Concurrent::Map` 可改善共享目录/缓存的并发访问，但不会改变 GVL，也不会降低每 Actor 的 Thread 成本。

## 对照其他语言：可迁移的是结构，不是 VM 数字

- **Node**：调用方与 Actor 在同一事件循环内交接，Promise 等待不占线程；原始值/原始值数组走免 JSON 快路径。Ruby 可迁移内存 codec 快路径和同 reactor continuation；不能照搬 V8 的执行速度。
- **Crystal**：每 activation 一个 Fiber，同一线程无锁 mailbox 与 Channel 交接，本地参数以 `JSON::Any` 内存对象进入 Actor。可迁移 Fiber 化串行 Turn 和批量 drain；它仍受协作阻塞限制。
- **Go**：每 activation 一个 goroutine，channel/定时器等待由运行时调度。MRI 没有等价的抢占式 M:N goroutine；Ruby 只能选 Fiber 协作模型、线程模型或 Ractor/进程。
- **Elixir**：Actor 有独立 BEAM process，运行时抢占调度；本地消息复制不是 JSON。Ruby Fiber 不具备同样抢占与隔离，Ractor 也不能共享当前 Cell 中的普通可变对象。

其他语言的“每 Actor 一个 Fiber/goroutine/process”不等于 Ruby 必须每 Actor 一个执行载体。Troupe 可保留 Cell 作为身份、Props、队列与生命周期，**只在有工作时调度 Turn，在等待时保留可恢复 continuation**。这比简单把 Thread 名字替换成 Fiber 更重要。

## 推荐的 `:async` 原型

```text
普通外部调用者（任意 Ruby Thread）
  └─ Stage 的线程安全 ingress
       └─ reactor 线程：Cell ready queue + Turn/continuation
            ├─ 本 Actor 未运行 → 启动 strict Turn（FIFO）
            ├─ Actor 等待本地 B / 网络 / timer → 挂起当前 Fiber，reactor 跑其他 Actor
            ├─ strict A 等待 B → A 的串行通道保持占用，直到 continuation settle
            ├─ blocking 标注的库/操作 → 有界 Thread offload → 完成后回 reactor
            └─ 隐式阻塞风险 → 超时/观测/拒绝，不宣称可抢占用户 Ruby 代码

同一进程外部同步 Agent.call → 仍可阻塞其调用方 Thread，但不应阻塞 reactor 内其他 Actor
```

必须保留：

- 每个 `(namespace, role, stage_name)` 至多一个 strict Turn；FIFO、single-flight activation、offStage/quiesce、CAS/fencing 与 props 复制语义不变。
- A→B→A 仍需显式死锁/重入策略。Fiber 能挂起 A，**不等于允许 A 重入**，否则会破坏 strict Props 语义。
- actor 间等待需要 pending 上限；response/callId、取消、deadline 与 UnknownOutcome 语义不能因异步化改变。
- `traceparent`、cancel state、日志上下文需显式随 continuation 传递，审计 Fiber/Thread local 行为。
- reactor 分区后，一个 Cell 固定在一个 reactor 内执行，避免 Fiber 跨线程恢复；跨分区经线程安全消息。
- Async reactor/task API 默认非线程安全，所有外部 ingress 必须经支持的 wakeup/Queue/调度入口，而不是任意线程直接 `resume` Fiber。

## 分阶段实验与验收

### E0：补基准而不是先选实现

在现有 `trouperb/bench/concurrency_bench.rb` 和 `bench-suite` 基础上补场景，不另建一套指标：

- 同进程、交替 A/B，至少 3 轮中位数；保留默认与 opt-in 的完整参数。
- 256B string、原始值数组、嵌套 Hash 的 codec 分项；trace on/off、ID 分配、入队、settle、Actor 方法本体的消融。
- 同 reactor Actor 互调与跨线程同步 Agent 分开测；64/1k/10k waiting Actor；慢 I/O、慢 PG/SQLite、阻塞 C 扩展的受害者延迟。
- 固定 N 个 Ractor 的 CPU/分配型任务、跨分片消息；多进程 Stage 对照。
- cluster 多轮中位与 Linux 复测。不能用共享池一次运行推翻或确认原报告。

### E1：先做低风险局部实验

1. **空闲线程退场，Cell 仍在场**：空闲阈值后结束专属线程，下一次 offer 重新拉起；测试 annotated 在飞、队列竞争、kill/drain/intermission。目标接近 shared 的驻留，保留热 Actor 的线程交接表现。它是实验假设，不保证优于 Fiber/shared。
2. **原始值免 JSON 深拷贝**：字符串 `dup`，数值/布尔/nil 原样，数组新建；Hash 与需要归一化的类型走完整慢路径。保持可变对象不共享，不使用 `local_call_by_reference` 偷换语义。Ruby 4 当前 `JSON.generate` 对 NaN/Infinity 抛 `JSON::GeneratorError`，所以非有限浮点必须保留拒绝语义，不能照搬 JS 的 null 快路径；Time/Symbol/Hash 键等以 `Codec.normalize` 为契约，而不是各类型默认 `to_json`。
3. **inline/直接交接原型**：无竞争时由调用方按 FIFO 成为批处理者，不插自己的队。必须验证不会跨 Actor 重入或绕开 drain/fencing。收益尚未证明，放在独立 dispatcher 开关后。
4. **观测开销**：trace 采样与 event hash/span ID 按需生成，先 profile 再改；不能以关闭持久背压或观测合同换数字。

### E2：可选 Fiber/Async Actor 运行时

最小可行原型只做单 reactor、memory store、strict Turn 和本地 A→B 等待，不先重写所有 transport/store：

- 选择 Async 提供事件循环，不先自写 scheduler；按 Ruby 4.0+ 与 Async 2.x 设计，不再为 Ruby 3.2/3.3 保留旧 scheduler 适配层。
- 将 ResponseBox 抽象为可由 Fiber 等待、也可由外部 Thread 等待的完成源；Actor `cast` 在 reactor 内走异步 continuation，在普通线程中维持同步 facade。
- 第一个原型限制 `improv/read_only`、PG/SQLite、远程 transport，逐个接入，而不是隐式放宽语义。
- 加显式 blocking offload 池；验证池满背压、超时后底层工作仍运行、shutdown 排空。
- 验收标准不只看 ping：I/O 等待并发、10k idle/waiting Actor 内存、A→B 链长、事件循环最大 stall、尾部延迟与现有回归测试。

如果同 reactor 交接、等待密度和 I/O 场景没有稳定收益，或者阻塞兼容成本过高，就停止 Fiber 主线，保留线程优化与多进程路线。

### E3：独立并行运行时验证

- **Ractor 分片**：先固定 N 个 Ractor、每片多个 Cell，Actor 固定分片；props 在片内私有，跨片复制。检查 Troupe/Repertoire/Metric/Trace/Provider 的非 shareable 常量、类 ivar 与全局状态。Ruby 4.0 仍是实验 API，需版本门禁。
- **多进程 Stage**：Linux 优先评估进程池/独立 Stage，通过既有 PG/transport 做隔离与扩容；Windows 不依赖 fork。
- **JRuby**：运行同一测试与 bench-suite，重点观察真正的多核 spread、原生线程成本、C 扩展（sqlite3/pg/json）兼容与 JVM 内存。JRuby 官方主分支要求 JRE 21+。
- **TruffleRuby**：长期候选；确认生产平台、C 扩展线程安全标记和 warmup。不能只看高峰吞吐。

## 不建议的做法

- 全局 `Fiber.set_scheduler(Async::Scheduler.new)` 后原样运行所有 Actor：会把不兼容的阻塞 Turn 变成全 reactor stall。
- 用 concurrent-ruby 替换 Queue/Mutex，就期待高并发：其核心执行模型仍是线程池。
- 把 `local_call_by_reference: true` 当成 codec 优化：它改变了可变参数的隔离语义，默认基准明确不允许。
- 为每个 Actor 建 Ractor 或进程：创建与内存成本相反，且现有类级 DSL/注册表/Provider 不是 Ractor-safe。
- 为了追 benchmark 直接切 shared 默认：本轮与历史对照都显示不同场景存在反向取舍。
- 以 Crystal 280k 为 Ruby 必须追平的目标：其中包含 VM、编译和对象模型差异；应比较 Ruby 改造前后相同语义的真实工作负载。

## 关键未知与复用条件

- 尚未运行 Async 2.46.0 的真实 Actor/I/O 原型。固定版本 gem 安装在本机原生 `io-event` 扩展构建阶段超时，未完成，不据此判断 gem 本身有缺陷。
- 未完成 Fiber 化的 Troupe 端到端 benchmark，不能给出可信提升百分比。微基准只说明 Fiber 同线程交接比跨线程唤醒便宜，不代表完整运行时会获得相同倍数。
- Ractor 分片需要验证当前类 DSL、非 shareable 常量、日志、metrics、codec、存储驱动与 C 扩展；Ruby 4.0 官方仍标注实验性。
- JRuby/TruffleRuby 的 trouperb 兼容、实际内存和性能未验证。
- 本轮临时 dispatcher 探针仅用于定位现成 shared 的额外开销，未完成状态机/异常/停机验证，不能直接合入。

## 主要原始来源

- Ruby 4.0 Fiber（默认 scheduler、协作调度）：https://docs.ruby-lang.org/en/4.0/Fiber.html
- Ruby Fiber Scheduler hooks：https://docs.ruby-lang.org/en/4.0/Fiber/Scheduler.html
- Ruby 4.0 Ractor：https://docs.ruby-lang.org/en/4.0/Ractor.html
- Ruby 4.0 设计与 NEWS：https://docs.ruby-lang.org/en/4.0/language/ractor_md.html ，https://raw.githubusercontent.com/ruby/ruby/master/doc/NEWS/NEWS-4.0.0.md
- Async Getting Started（阻塞兼容边界）：https://socketry.github.io/async/guides/getting-started/index.html
- Async Scheduler 与 thread safety：https://socketry.github.io/async/guides/scheduler/index.html ，https://socketry.github.io/async/guides/thread-safety/index.html
- Async 源码与 gemspec：https://github.com/socketry/async/blob/main/lib/async/scheduler.rb ，https://github.com/socketry/async/blob/main/async.gemspec
- concurrent-ruby 线程池与 Promises：https://github.com/ruby-concurrency/concurrent-ruby/blob/master/docs-source/thread_pools.md ，https://ruby-concurrency.github.io/concurrent-ruby/master/file.promises.out.html
- JRuby：https://github.com/jruby/jruby#readme
- TruffleRuby 与扩展并行：https://github.com/oracle/truffleruby#readme ，https://github.com/oracle/truffleruby/blob/master/doc/user/thread-safe-extensions.md

## 覆盖与复核

已覆盖：MRI Thread/GVL 与 Fiber/Scheduler；Async 实现与文档；concurrent-ruby 核心与 edge 边界；Ractor；M:N Thread Scheduler；多进程；JRuby/TruffleRuby 及其 Fiber 的线程实现；Node/Crystal/Go/Elixir 调度对照；现有 benchmark 口径、shared 补跑、codec/线程交接微基准、共享池本地队列消融。

独立研究与复核：跨语言调度与 Ruby 热路径、Ruby 并发机制分别由两路只读 agent 研究；其“Crystal 仍有序列化”“Fiber 必须同线程交接”“shared 不能无脑默认”“Async worker pool 默认关闭”“JRuby/TruffleRuby Fiber 由线程承载”等修正已并入。第三个未参与结论形成的 agent 按 FIFO/死锁/背压/取消、Ruby 4 机制、跨轮数据、遗漏、Ruby 4+ 版本定位五项独立复核，**通过且无决定性问题**；其 Util=3.1 与 shared hot 改善的修正也已并入。首次复核因长时间无输出被取消，未取得结论，不计为通过；后续聚焦复核才产生本结论。
