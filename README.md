# Troupe.rb

[![CI](https://github.com/ShiningRay/troupe/actions/workflows/ci.yml/badge.svg)](https://github.com/ShiningRay/troupe/actions/workflows/ci.yml)

> Troupe.js（[DESIGN](../troupejs/DESIGN.md) / [PLAN](../troupejs/PLAN.md)）的 Ruby 版本：面向 Ruby 的 **Virtual Actor** 框架，思想对标 Microsoft Orleans 与 EA Orbit，命名与语义全面沿用"剧团（Troupe）"隐喻。**运行时零第三方 gem 依赖**（logger 为 Ruby 4 bundled gem，已显式声明）。

## 核心语义

- **永远存在**：Actor 无需显式创建，用 `(role, stageName)` 全局寻址
- **按需激活**：第一条 Call 到达时在集群某 Stage 登台；生产集群激活前置所有权检查（租约 + fencing token）
- **自动钝化**：空闲超过 Intermission 自动下场，Props 归还 PropStore
- **Turn-based 严格串行**：一次一条 Call，天然无锁；`improv`/`read_only` 标注方法按组合矩阵交错
- **位置透明**：调用方持有 Agent，不关心目标在哪个 Stage；环漂移期自动转发（跳数上限 2）
- **故障即重激活**：Stage 死亡后，下一条 Call 让 Actor 在健康 Stage 重新登台（共享存储 + 所有权接管）

| 概念 | 命名 | | 概念 | 命名 |
|---|---|---|---|---|
| 集群 | **Troupe** | | 持久化状态 | **Props** |
| 节点/进程 | **Stage** | | 存储 Provider | **PropStore** |
| 虚拟 Actor | **Actor** | | 定时器/提醒 | **Cue / Reminder** |
| 代理引用 | **Agent** | | 空闲超时 | **Intermission** |
| 激活/钝化 | **OnStage / OffStage** | | 可重入/只读 | **Improv / ReadOnly** |
| 寻址路由 | **Playbill**（HashRing）| | 测试集群 | **Rehearsal** |
| 成员管理 | **Roster** | | 管理内省 | **Director**（CLI 瘦客户端）|
| 邮箱/消息 | **CallBoard / Call** | | 流 | **Show**（进程内）|

## 快速开始

```ruby
require "troupe"

class CartActor < Troupe::Actor
  role_id "cart"                    # 默认 = 类名去 "Actor" 后缀；持久业务建议显式声明
  intermission "10m"                # 默认 5m
  initial_props { { "items" => [] } }  # 首次登台的初始状态（字符串键：JSON 边界语义）

  def on_stage = puts "[cart:#{stage_name}] 登台"
  def off_stage
    save_props                      # 下场归还 Props
  end

  def add(item)
    props["items"] << item
    save_props                      # 持久成功：CAS 提交成功后才返回
  end

  def peek = props["items"].length
end

troupe = Troupe.form(actors: [CartActor])     # 显式注册（推荐）
cart = troupe.cast(CartActor, "user-123")     # Agent：类型面只有 RPC 方法
cart.add({ "sku" => "sku-1", "qty" => 1 })
cart.peek # => 2
```

运行示例：

```bash
ruby examples/minimal/cart.rb        # DESIGN §3.1 最小示例
ruby examples/drop_shop/shop.rb      # §10.3 限量发售（幂等重放/同键不同参数拒绝）
ruby bin/troupe status               # CLI（先起一个节点）
```

双节点集群：

```bash
TROUPE_PORT=7301 ruby examples/cluster/node.rb
TROUPE_PORT=7302 TROUPE_SEEDS=127.0.0.1:7301 ruby examples/cluster/node.rb
ruby bin/troupe --to 127.0.0.1:7301 ps     # 在场演员（跨 Stage 聚合）
```

## 框架承诺（每条都有对应验收测试）

| 承诺 | 语义 | 测试 |
|---|---|---|
| 激活 single-flight | 并发首调只激活一次 | `test_single_flight_activation…` |
| 严格串行 | 上一 Turn settle 前不取下一 Call | 50 并发 `bump` 无交错 |
| 排队过期不执行 | deadline 已到的排队 Call 直接拒绝，无副作用 | `test_queued_expired…` |
| 响应期限 ≠ 执行占用 | 调用方超时后旧任务继续跑完，后续 Call 不与其交错 | `test_timeout_releases_caller…` |
| 保存失败实例失效 | 下次调用从最后已提交快照继续，不基于未提交状态运行 | `test_save_failure_invalidates…` |
| 幂等恢复 | 同 requestId 同参数重放原结果；同键不同参数拒绝 | `examples/drop_shop` |
| 结果未知 ≠ 失败 | 超时/断连只代表结果未知；框架不自动重试 | `test_remote_deadline…` |
| 所有权 fencing | 接管后 epoch 单调递增，旧实例写入被存储拒绝 | `test_takeover_rejects_old_owner…`、`test_stage_death_failover…` |
| 持久提醒 | 下场后仍触发并重新登台；租约到期重投（至少一次）；Cue 投递走有界工作池（8 worker + 256 深度背压） | `test/cue_test.rb` |
| 协作取消（advisory） | 调用方放弃等待后通知目标早停：排队阶段整体拒绝（无副作用）、执行阶段 `cancelled?` 检查点自愿退出 + `on_cancel` 钩子；取消不伪造失败（结果未知 ≠ 失败）；仅 `cancellable` 标注方法，其余行为不变 | `test/cancel_test.rb` |
| 传输版本协商 | 连接首帧 hello 携带 protocolVersion，不匹配显式拒绝（不混跑） | `test_version_mismatch_hello_rejected` |
| golden 协议锚点 | xxh32/哈希环分配/traceparent/存储信封/wire 错误形状与 troupejs 同一 fixtures | `test/golden_test.rb` |
| 信任边界 | 生命周期钩子/基类成员不可经 RPC；畸形帧可控拒绝 | `test_whitelist_enforced_on_wire`、`test_malformed_frame…` |

运行全部测试（Ruby ≥ 3.2；CI 矩阵 3.2/3.3/3.4/4.0 × ubuntu/windows）：

```bash
bundle install
bundle exec rake test
```

## Orleans 对标与验证

- [Orleans 能力差距](docs/ORLEANS_GAP.md)
- [分阶段实施路线](docs/ROADMAP.md)
- [当前测试与已知失败](docs/VERIFICATION.md)
- [统一多语言规划](https://github.com/ShiningRay/troupe-planning)

## 配置（显式传参 > 环境变量 > 约定默认值）

| 旋钮 | 默认 | 环境变量 |
|---|---|---|
| 部署模式 | `dev`（loopback、端口被占自动换） | `TROUPE_MODE` |
| Stage 监听 | `127.0.0.1:7300` | `TROUPE_PORT` / `TROUPE_HOST` / `TROUPE_ADVERTISE` |
| seeds | 空 = 自成一团 | `TROUPE_SEEDS`（逗号分隔） |
| PropStore | PStore `./.troupe/props.pstore`（进程级持久）；`:memory` / `:sqlite`（需 sqlite3 gem）；`postgres://…`（**跨节点安全**，M2 生产 Provider） | `TROUPE_PROPS_DIR` / `TROUPE_PROPSTORE` / `TROUPE_PG_URL` |
| 命名空间 | `default`（固定值；多套共存请显式配置，不随目录名漂移） | `TROUPE_NAMESPACE` |
| Call 超时 / Intermission / Cue tick | 30s / 5m / 1s | — |
| 调度模型 | `:thread_per_cell`（每 Cell 一条调度线程，阻塞隔离最好）；`:shared`（M=核数(≤8) 条共享调度线程多路复用 Cell，激活/内存成本大降：实测激活 ~×10、KB/Actor ~×17，代价：阻塞 Turn 占一条 worker、不支持 kill!、Intermission 秒级精度） | `TROUPE_DISPATCHER` / `TROUPE_DISPATCHER_THREADS` |
| 优雅停机 | SIGTERM 由应用捕获后调 `troupe.shutdown!`；宽限 10s | `TROUPE_SHUTDOWN_GRACE` |
| Director | 仅 loopback；远程需 token（常时比较） | `TROUPE_ADMIN_TOKEN` |
| 集群 token 轮换 | rotate：`cluster_token_previous` 为上一代（宽限期内接受）；revoke：置空 | `TROUPE_CLUSTER_TOKEN` / `TROUPE_CLUSTER_TOKEN_PREVIOUS` |
| Rehearsal | `Troupe::Testing.rehearsal(actors: [...])` 全内存 | `TROUPE_ENV=test` |

## CLI：`bin/troupe`

`status` `roster` `ps` `inspect` `call` `off` `ring` `cues` `metrics` `tail` `top`，支持 `--to host:port`、`--json`。CLI 是 Director 的瘦客户端——客户端永远只连一个点。

## 实现范围（对照 Troupe.js PLAN）

已实现：**M1** 严格串行运行时 + PropStore 合同（CAS/迁移/校验）；**M2** 本地持久化（PStore）+ TCP 集群（长度前缀 JSON、白名单、背压、畸形帧防护）+ HashRing（纯 Ruby xxh32，160 vnodes）+ 误投转发；**M3** 所有权（租约 + 单调 epoch + fencing）+ Roster（gossip 反熵 + ping/ACK 探测 + 终态不可复活）；**M4** 持久 Cue（CueStore + claim/lease/statusVersion CAS + cron）+ Director/CLI；**M5** 交错执行（组合矩阵 + 写饥饿防护）；**M6** Trace 总线（环形缓冲 + 采样 + 订阅）；**M7** Show（进程内 pub/sub）；**M8（ROADMAP M1）** 语义对齐——协作取消（#7 advisory）、排队/执行超时 phase 分离、错误分类 code 映射（对齐 troupe.cr golden/errors.json）、golden fixtures（xxh32/环/traceparent/信封/wireErr）、传输 hello 版本协商（协议 v2）、存储信封（Props 与幂等记录同行原子落盘）、traceparent 随线路传播、全局背压预算 spec；**M9（ROADMAP M2）** 生产共享状态——PostgreSQL PropStore/CueStore（行级 CAS、DB 时钟租约、单调 epoch、SKIP LOCKED claim）、Provider 能力矩阵 + 生产门禁（cross_node_safe）、Provider 契约测试套件、真实多进程 kill -9 接管验收（CI PG 必跑 leg）、token 常时比较 + rotate/grace/revoke。

路线图（见 [DESIGN_NOTES.md](DESIGN_NOTES.md)）：Postgres 共享 PropStore、BoxOffice、Booth、热重载/热替换（Ruby 无 `setPrototypeOf`，L1/L2 需另设计）、Show 跨节点转发、Extra。

**开发复盘与已知问题**（线程模型容量、PStore 全量写、Improv 交错粒度偏差、与 Ruby 理念的摩擦、对原设计文档歧义的决定）见 [DESIGN_REVIEW.md](DESIGN_REVIEW.md)——含优先级与修法。

## 已知边界

- **单个热点 Actor 只有一个串行通道**：加 Stage 只能分摊不同 Actor 的负载（容量事实，DESIGN §5.3）
- **每在场 Actor 一个调度线程**：Ruby 线程成本高于 JS Promise，高 churn 场景建议调低 Intermission 或提高 `activation_limit` 前评估内存
- **PStore/SQLite 均为进程级持久**：多节点生产的共享 PropStore（Postgres）未实现前，集群故障恢复仅在共享内存 Store（同进程多 Stage）或同机单进程内成立
- **存储信封（M1）**：PropStore 记录的 props 字段为 `{__troupe_envelope__: 1, props, idem}`；旧数据（裸 Props）可直接读取，但新数据被旧版本 trouperb 读取会把信封键当作业务 Props——PStore 为开发级存储，跨版本升级请先排空
- **生产门禁（M2）**：production + transport 模式拒绝非 cross_node_safe 存储（PStore/SQLite/Memory），显式 `allow_unsafe_store: true` 可降级（单机演示自担风险）
- **TLS 未实现**：节点间认证依赖受控网络 + cluster token（常时比较、支持 rotate/grace/revoke）；TLS 门控参照 troupejs secureConnect，需时再补
- 本地调用默认走同一 JSON 编解码边界：Hash 键归一为字符串、Symbol → String、Time → ISO 8601；`local_call_by_reference: true` 可显式关闭复制换性能（语义分叉自担）
