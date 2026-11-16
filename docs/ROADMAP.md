# Troupe.rb Orleans 对标路线图（v2，2026-11-16）

> 依据 troupejs（M1–M11 + P0–P3 完成）与 troupe.cr（M0–M6 完成）的实施经验重排。
> 差距基线见 [ORLEANS_GAP.md](./ORLEANS_GAP.md)。

## 从兄弟实现吸收的工程纪律（贯穿所有阶段）

1. **完成定义 = 代码 + 文档 + 反例测试 + 边界声明 + CI**（troupe.cr「definition of done」；每次迭代在 VERIFICATION.md 记录命令、结果与「未验证边界」，不伪造绿灯）。
2. **Provider 能力矩阵 + 生产门禁**（troupejs）：`StoreCapabilities{cross_node_safe, supports_fencing, supports_transactions}`；生产模式拒绝非 cross_node_safe Provider；新 Provider 必须过契约测试套件。
3. **PG 租约/fencing 模式**（两实现一致）：行级 CAS 全部收敛到单条 `UPDATE ... WHERE`；租约用数据库服务器时钟；epoch 单调；续租失败即 stop-serving 并失效本地激活（防双活）。
4. **消息语义显式拆分**（troupejs ADR 0005 / troupe.cr M4+M5）：Show = 短暂尽力而为的 Audience（经完整 Turn 管道）；Stream = 持久日志（seq/幂等 eventId/ack 只前进/replay/retain）。两者不混称。
5. **Golden fixtures 先行**（troupe.cr M5）：identity/hash/errors/envelope 四组向量是跨语言对齐锚点；但 canonical hash 已分叉（js/rb=xxh32+160v，cr=CRC32+64v），归 troupe-planning ADR 决策。
6. **一切有界**：线程池、队列深度/字节、in-flight、激活数全部预算化，过载显式拒绝（背压），不无限新建线程（即 #6 的教训）。

## M0 恢复可信基线（最高优先级，先于一切）

- [x] [#1](https://github.com/ShiningRay/troupe/issues/1)：gemspec/Gemfile 声明 Ruby 4 bundled `logger`，更新 lockfile；恢复 `bundle exec rake test` 默认入口。（顺带声明 bigdecimal/pstore——同为 bundled gem，3.4/4.0 同样炸 LoadError）
- [x] [#4](https://github.com/ShiningRay/troupe/issues/4)：`assert_same nil` → `assert_nil`；README/gemspec 明确 Ruby 支持矩阵（≥3.2）。
- [x] [#2](https://github.com/ShiningRay/troupe/issues/2)：namespace 显式配置优先；默认值固定 `"default"`（对齐 troupejs）；Rehearsal 同默认；任意目录名下 props/ownership/cluster 全绿 + `ConfigNamespaceTest` 断言预置 Props 读取。
- [x] [#3](https://github.com/ShiningRay/troupe/issues/3)：迁移逐级 v→v+1 循环执行；补 v1→v3、缺失中间迁移报错、失败不落盘测试；并发迁移沿用 CAS 冲突路径（以已提交版本为准）。
- [x] [#6](https://github.com/ShiningRay/troupe/issues/6)：Cue 调度改用有界工作池（8 worker + 256 队列深度预算背压），停机 drain；补单 tick 80 条到期全投递 + 停机不泄漏测试。
- [x] 建立 GitHub Actions：矩阵（Ruby 3.2/3.3/3.4/4.0 × ubuntu/windows）；PG 必跑 leg 留待 M2。
- [x] README 状态横幅改为 CI badge + 真实测试状态，移除历史「78 runs」宣称。

**门禁**：本地默认命令全绿（96 runs × 3 次稳定）；CI 全绿以 Actions 实跑为准（见 VERIFICATION.md ⏳ 项）。

## M1 语义对齐（与 js/cr 共同契约）

- [x] [#7](https://github.com/ShiningRay/troupe/issues/7)：协作取消——排队阶段拒绝（CallCancelledError，无副作用）、执行阶段自愿（`cancelled?` 检查点 + `on_cancel` 钩子）；wire 增加 `cancel` 控制帧（`cancellable` 标志随 call 帧传播）；保持「结果未知 ≠ 失败」；非 cancellable 方法行为回归锁死。
- [x] deadline/UnknownOutcome 语义矩阵：`CallTimeoutError#phase` 分离 queued（排队过期=确定性拒绝）/executing（执行超时=结果未知）；deliver 入队过期确定性短路。
- [x] 错误分类 wire 映射表（对齐 cr `golden/errors.json` 的 code 表）：`Errors::WIRE_CODES` + reason/retryable/phase；出站形状保持 js v2（golden 深比较锚定），入站兼容 cr `{"code":...}`；栈不跨线。
- [x] 引入 golden fixtures：采纳 troupejs `protocol-v2.json` 向量（xxh32/环分配/traceparent/envelope/wireErr 九项锚定测试全绿）；canonical hash 分叉上报 troupe-planning 出 ADR，不单方面改算法。
- [x] 传输版本协商：首帧 hello 携带 protocolVersion（v2 对齐 fixtures），不匹配显式拒绝；非 hello 首帧（旧版本节点）同样显式拒绝。
- [x] 全局背压预算：远程转发（WorkerPool 有界）/Actor 互调（board+bytes 预算）/慢 Turn（无队列增长）/长 Cue（M0 有界池）；字节预算超限反例测试 + reason=backpressure；drain 重投复用 improv 池不再新建线程。
- [x] 调度矩阵 spec：串行 × read_only × improv × 超时（queued/executing phase）× 取消的组合可验证（improv_test 矩阵 + cancel_test + runtime phase 断言）；明确 MRI 抢占点与 JS await 点语义不同，不宣称等价。

**门禁**：golden 全绿；调度矩阵与取消/超时反例测试全绿。（本地 116 runs 全绿；CI 以 Actions 实跑为准）

## M2 生产共享状态与真实故障接管（#5 核心）

- [x] PostgreSQL PropStore：行级 CAS、revision、fence 全路径（fencing 权威在所有权表、epoch 单调）、DB 时钟租约（now()）——所有检查收敛进单条 `UPDATE ... WHERE`（fencing 优先于 CAS 的精确诊断）。
- [x] PostgreSQL 所有权：acquire/renew/takeover/release；接管 stop-serving 由续租失败路径承担（心跳 request_drain!(:ownership_lost)），fencing 兜底拒绝旧 epoch 写。
- [x] PostgreSQL CueStore：`FOR UPDATE SKIP LOCKED` claim + statusVersion CAS + DB 时钟租约；调度按环/namespace 过滤保留，重复投递由幂等消费兜底。
- [x] 能力矩阵 + 生产门禁：`StoreCapabilities{cross_node_safe, supports_fencing, supports_transactions}`；production + transport 拒绝 PStore/SQLite/Memory（显式 `allow_unsafe_store` 降级开关）；Provider 契约测试套件（Memory/PStore/SQLite/PG 四实现 + 所有权契约）。
- [x] 真实多进程验收（学 cr 的 pg_worker 子进程矩阵）：≥2 个独立 Ruby 进程连真实 PG，kill -9 持锁者 → 租约到期接管（epoch 2）→ 旧 epoch 写被拒 → Props/reminder 从共享存储恢复；测试输出真实拓扑与数据库版本（`test/pg_takeover_test.rb`）。
- [x] 传输认证：token 常时比较（Util.secure_compare）+ rotate/grace/revoke（`cluster_token_previous` 宽限）；TLS 先指导文档（README 已知边界，学 js 的 secureConnect 门控可后补）。

**门禁**：跨进程旧 epoch 无法写、无未保护双活写；Props 与 reminders 可从共享存储恢复；PStore 降级为开发用途。（本地 168 runs 全绿 ×2 含 PG；CI PG leg 以 Actions 实跑为准）

## M3 Show→Audience 与可观测

- [x] Show 升级为 Actor Audience：订阅/投递经完整 Turn 管道（学 cr M4），外部订阅者走边界回调；在线尽力而为、无重投承诺、明确不叫流（PublishReport 可断言交付计数）。
- [x] 跨 Stage Show 转发（订阅在本地、Actor 环归属其他 Stage → route 转发）+ 慢订阅者隔离（deadline 有界等待，慢消费者计 failed 不拖垮发布者/其他订阅者）。
- [x] OTel：零依赖 OTLP JSON 导出适配（学 cr `otel.cr`：sink 回调，传输宿主实现；TraceEvent→span / 指标→monotonic Sum）+ W3C traceparent 贯穿（call 帧跨 Stage 传播进 span）。
- [x] Director/metrics 增强：leaseRenewFailures/handovers 等接管健康指标（学 js；续租失败 ⊇ 移交）。

**门禁**：跨 Stage Audience、慢订阅者隔离、离线尽力语义各有反例测试。（本地 179 runs 全绿 ×2；顺带修复 TraceBus.subscribe 静默不投递的历史 bug——push_nonblock 在 Ruby stdlib 不存在）

## M4 持久流与 Outbox（M2 之后；学 js ADR 0005 / cr M5–M6）

- [x] StreamStore（Memory + PostgreSQL）：seq 全局/per-topic 单调持久、幂等 eventId、ack GREATEST 只前进（回退拒绝）、游标 replay、保留裁剪；消费者失败不 ack 重投（至少一次）。
- [x] Outbox：Actor `emit_event` 与 Props CAS **同一原子提交**（失败写事件不落——反例测试）+ 独立 OutboxDispatcher（PG SKIP LOCKED 认领 + 租约 + 退避 + 死信；Memory 语义对齐）；幂等 Inbox 去重（Memory + PG）。
- [x] 事件溯源 pattern（学 cr M6）：rebuild 全量重放 + rebuild_from_snapshot 快照加速（一致性反例：快照+增量 == 全量）；作为扩展点而非默认存储。

**门禁**：流重放/保留/慢消费者、outbox 至少一次 + 死信路径有测试；不宣称 exactly-once。（本地 185 runs 全绿 ×2 含 PG；Memory/PG 同套合同断言）

## M5 跟随统一规划的决策项（不单方面实施）

- [ ] 版本化目录 / 放置策略 / 再平衡：**阻塞中**——等 troupe-planning ADR-002（HashRing+ownership 与版本化 directory 的演进，计划中未出稿）再实施（不单方面实施）。
- [x] Booth 仪表盘 / BoxOffice 网关：**由 troupe-planning ADR-0007（Accepted）裁决**——外部端点分四层，网关（外部客户端↔actor 传输桥）归伴生包 `troupe-gateway`（L3），core 保持零 HTTP/WS 依赖（L1/L2）；trouperb 不内置 Booth/BoxOffice，Booth 桥原型留 examples/booth 草案供伴生包参考。
- [x] 滚动升级/热替换：已文档化 drain→upgrade 流程与 R1–R6 兼容审查清单（[ROLLING_UPGRADE.md](./ROLLING_UPGRADE.md)；hello 协商使跨协议版本必须整批升级——文档明确）。
- [x] 分布式事务：与两兄弟一致，长期非目标（无需实施，文档口径一致）。

## Ruby 特有工效债（穿插在 M1/M2 间处理，不阻塞门禁）

- [ ] kwargs RPC 支持与版本化编码（当前不支持；不得引入 Marshal 作公共协议）。
- [ ] `Troupe::Troupe` 常量遮蔽解决（breaking change，择窗口期；M3 OTel 实现已遇 `Troupe::VERSION` 被解析为 `Troupe::Troupe::VERSION`——库内用 `::Troupe::` 顶层限定规避）。
- [ ] 线程模型基准对比：thread_per_cell（默认）vs shared 池 vs Fiber 方案，报告**默认配置**数字而非 opt-in 最优（吸取 bench-suite 教训：shared 2.77KB/Actor 与默认 47.52KB 不可混用）。
- [x] PStore O(全库) 写入问题：限开发并文档声明（README 已知边界 + gemspec 注释明确开发级定位）。
