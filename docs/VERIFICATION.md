# 验证基线（2026-11-17，M4 迭代）

环境：Windows、Ruby 4.0.6、Bundler 4.0.24；真实 PostgreSQL 15.19（docker `troupe-pg` @127.0.0.1:55444，专用库 `troupe_rb_test`）。
Issue 对应：M4（持久流与 Outbox）。M3/M2/M1/M0 基线见下节存档。

## 默认入口

```sh
bundle install
bundle exec rake test                                # 矩阵 leg：PG 项 skip（由专用 PG leg 必跑）
TROUPE_TEST_PG=postgres://…/troupe_rb_test bundle exec rake test   # PG leg：契约 + 多进程接管 + 流/Outbox
```

**结果（PG leg 全量）：185 runs，3119 assertions，0 failures，0 errors，0 skips**（M3 基线 179 → M4 185）。
矩阵 leg（无 PG env）：185 runs，0 failures，0 errors，25 skips（PG 项让位给专用 leg）。

## 逐项验证（M4）

| 项 | 验证方式 | 结果 |
|---|---|---|
| StreamStore 合同 | Memory/PG 同套断言：append seq 单调、read_from 游标后读取、ack GREATEST 只前进（回退拒绝）、消费者失败不 ack 重放（至少一次）、retain 裁剪显式代价 | ✅ |
| Outbox 原子提交 | emit_event 随 save_props 提交入队；CAS 失败（fencing）写的事件不落（pending 基线不变反例） | ✅ |
| OutboxDispatcher | 交付→标记 sent；失败→退避重投成功（至少一次）；持续失败→attempts 达上限→死信、不再投递；PG claim 走 SKIP LOCKED | ✅ |
| Inbox 去重 | record! 首次 true/重复 false（至少一次 → 恰好一次副作用），Memory + PG | ✅ |
| 事件溯源 | rebuild 全量 == rebuild_from_snapshot 快照+增量（一致性契约反例） | ✅ |

## 发现并顺带修复（M4）

- **Memory write 的诊断顺序**：revision CAS 先于 fencing 检查——接管场景旧持有者收到 CAS 错误而非 fencing（与 PG/cr 的「fencing 优先」不一致）；已对齐。
- **PG claim SQL 参数错位**（$1 未引用 → IndeterminateDatatype）与 `AND … OR` 优先级（死信行也会被认领）——加括号。
- **PgInbox.open 误传 String** 给构造器（要求 conn）。
- 第三次踩「save_props 返回 revision ≠ 业务值」坑——测试 actor 须显式返回业务字段。

## 未验证边界（不伪装绿灯）

- OutboxDispatcher 的进程内周期自动运行未内置（交付回调是宿主业务，测试内手动 poll）——后台线程化归 M5 或按需。
- 流的集群广播（StreamStore 集群复制）不在本迭代（订阅/消费 API 进程内注册表）。
- CI 实跑结果待 push 后确认（PG leg 含流/Outbox 真实 PG 契约）。

---

# 存档：M3 基线（2026-11-17，179 runs 全绿）

## 逐项验证（M3）

| 项 | 验证方式 | 结果 |
|---|---|---|
| Show→Actor Audience | `show_audience_test.rb`：完整 Turn 管道交付（save_props CAS 落库可断言）；订阅时白名单/角色校验（生命周期钩子拒绝）；外部边界回调隔离与退订；PublishReport 计数 | ✅ |
| 跨 Stage 转发 | 订阅注册在 t1、Audience Actor 环归属 t2 → route 跨 Stage 转发、Actor 在归属 Stage 激活 | ✅ |
| 慢订阅者隔离 | deadline 有界等待：慢 Turn 计 failed，发布者不被拖住（<2s），快订阅者正常 | ✅ |
| 在线尽力不重投 | Audience Turn 业务异常计 failed、副作用保留、等待后无重复投递 | ✅ |
| OTel 适配 | `otel_test.rb`：traceparent 解析/全零回退；span 形状（hex id、unixNano、status code 1/2）；指标 monotonic Sum（temporality=2）；sink 回调端到端（trace+metrics）；本地调用事件携带 traceparent | ✅ |
| 接管健康指标 | `test_lease_renew_failure_and_handover_metrics`：续租失败 → leaseRenewFailures（troupe 级+角色级）；所有权确已转移 → handovers | ✅ |

## 发现并顺带修复（M3）

- **TraceBus.subscribe 历史性静默不投递**：emit 用 `push_nonblock`——Ruby stdlib Queue/SizedQueue 无此方法（NoMethodError 被 emit 外层 rescue 吞掉，订阅者永远收不到事件，Director tail 一直不可用）。改 `push(event, true)` + ThreadError 救援。
- **OTel exporter Float#times**：`(every * 10).times` 对 Float 不存在——改 mono deadline 轮询。
- **`Troupe::Troupe::VERSION` 常量遮蔽**：OTel 里 `Troupe::VERSION` 被词法解析为 `Troupe::Troupe::VERSION`（roadmap 已登记的 Ruby 工效债实锤）——用 `::Troupe::VERSION`。
- **CI PG leg takeover 断言竞态**（run 43919996911 唯一红点）：接管 worker 持续写导致 revision 快照过期——改下界断言。

## 未验证边界（不伪装绿灯）

- Show 集群级订阅复制（订阅 API 仅进程内注册表；跨 Stage 交付已验证）——集群广播归 M5/统一规划决策项。
- OTel 传输（HTTP/gRPC）由宿主 sink 实现，框架不做网络 IO（按 cr otel.cr 边界）。
- CI 实跑结果待 push 后确认（含 PG leg 重跑）。

---

# 存档：M2 基线（2026-11-17，run 43919996911 PG leg 1 断言竞态红、其余 8 job 绿）

## 逐项验证（M2）

| 项 | 验证方式 | 结果 |
|---|---|---|
| PostgreSQL PropStore | 行级 CAS + fencing 单条 UPDATE（所有权表为权威，epoch 单调唯一持有）；fencing 优先于 CAS 的精确诊断；`provider_contract_test.rb` PG 契约九项 | ✅ |
| 所有权 acquire/renew/takeover/release | 契约测试：重入不涨 epoch、他人持有效租约取不到、过期接管 +1、release 保留墓碑不回退、接管前移 fence、旧 epoch 写被拒 | ✅ |
| PostgreSQL CueStore | `FOR UPDATE SKIP LOCKED` + statusVersion CAS + DB 时钟租约；契约五项 + db_clock 重投 | ✅ |
| 能力矩阵 + 生产门禁 | `StoreCapabilities`；production+transport 拒绝 PStore/Memory（反例测试）；`allow_unsafe_store` 显式降级（测试覆盖） | ✅ |
| Provider 契约测试套件 | 同一套断言跑 Memory/PStore/SQLite/PG 四实现 + 所有权契约（重入/接管/墓碑/fence 前移） | ✅ 48 runs |
| 真实多进程 kill -9 接管 | `pg_takeover_test.rb`：2 个独立进程连真实 PG；READY(n=1 提交) → kill -9 持锁者 → 租约 2s 到期 → 接管者 epoch 2 → Props 恢复（n≥2）+ 提醒重投 → 旧 epoch fencing 写被拒、revision 不变 | ✅ 本地 docker PG 全链路 |
| 传输认证 | `Util.secure_compare` 常时比较（cluster/admin token）；rotate/grace/revoke 测试（旧 token 宽限接受 → revoke 后立即拒绝） | ✅ |

## 发现并顺带修复（M2）

- **`SqlitePropStore` 未定义局部变量 `dir`**（`FileUtils.mkdir_p(dir)`）：Provider 契约套件抓出的潜伏 bug——任何 sqlite PropStore 首次实例化即 NameError。
- **SQLite `@db.changes` 不可靠**（UPDATE 命中后返回 0 → 误报 CAS 冲突且读到已更新行）：改用 `total_changes` 增量。
- **PG TEXT 不能含 null byte**：PropStore.key 的 `\u0000` 连接符在 PG 用 JSON 数组 key 替代。
- **pg gem 无 type map 时全部返回字符串**：显式 Integer 转换（read/acquire/claim/ownership_row/diagnose——字符串比较曾让 diagnose 误判 fencing）。
- **`localhost` 在 Windows/docker 环境走 IPv6 21s 超时**：测试 URL 用 `127.0.0.1`。
- **共享 troupe-pg 库与 troupe.cr 表结构冲突**（列名不同）：专用测试库 `troupe_rb_test` 隔离。
- takeover 测试的 `ownership_row` 断言需 Integer 转换；PG 租约/epoch 的诊断比较一律显式转型。

## 未验证边界（不伪装绿灯）

- CI PG leg 实跑结果待 GitHub Actions（service container postgres:15 + TROUPE_TEST_PG）。
- 多进程验收未覆盖：kill 整机（网络分区）、PG 主从切换——超出本迭代范围。
- 幂等重放（信封 idem 的运行时消费）接线在 M4（Outbox/Inbox）。
- TLS 未实现（指导文档见 README 已知边界）。
- 环回特性依赖：Windows 本地无法验证 Linux 专有信号（kill -9 用 TerminateProcess 等价）。

---

# 存档：M1 基线（2026-11-17）

## 默认入口

```sh
bundle install
bundle exec rake test
```

**结果：116 runs，2852 assertions，0 failures，0 errors，0 skips**（M0 基线 96 → M1 116）。

## 逐项验证（M1）

| 项 | 验证方式 | 结果 |
|---|---|---|
| #7 协作取消 | `test/cancel_test.rb` 七项：超时→目标通知+检查点早停+副作用照常提交；非 cancellable 超时/排队/cancel 帧三路回归锁死（行为与旧版本一致）；排队取消=CallCancelledError（无副作用）；跨 Stage cancel 帧经环投递到目标 Stage；cancel 帧受 cluster token 校验（无新信任边界） | ✅ |
| deadline 语义矩阵 | `CallTimeoutError#phase`：排队过期=queued（确定性拒绝，deliver 入队过期短路）、执行超时=executing（结果未知）；runtime_test 两处断言 | ✅ |
| 错误分类映射 | `Errors::WIRE_CODES` 对齐 cr golden/errors.json（十类断言）；出站 wireErr 形状 js v2 深比较（golden）；入站兼容 cr `{"code":...}` 解码；backpressure reason/retryable | ✅ |
| golden fixtures | 采纳 troupejs protocol-v2.json（同一文件）：protocolVersion=2 / xxh32 向量 / 环分配 / traceparent 格式与解析 / 信封形状与裸数据兼容 / wireErr 形状与往返 / business 兜底——`test/golden_test.rb` 九项全绿 | ✅ |
| 传输版本协商 | 首帧 hello（v2）；`test_non_hello_first_frame_explicitly_rejected`（旧版节点显式拒绝）；`test_version_mismatch_hello_rejected`（ok:false + 关连接） | ✅ |
| 全局背压预算 | 字节预算超限反例（reason=backpressure，pop 释放）；board/activation 已有测试；drain 重投改 improv 池复用 | ✅ |
| 调度矩阵 | 串行 × read_only × improv × 超时（phase）× 取消（cancellable×improv 检查点早停 + on_cancel）组合测试；MRI 抢占点与 JS await 点不等价的边界在测试注释中声明 | ✅ |

## 发现并顺带修复（M1）

- **`CallRejectedError` reason 按类缺省推导**（Backpressure→backpressure 等），显式传参可覆盖；否则 wire payload 的 reason 字段依赖每个 raise 点手工传参，易漏。
- **deliver 入队过期短路**：deadline 已过的 Call 在 offer 后立即以 phase=queued 拒绝——否则调用方 `box.wait!` 先以 executing 相位抛出（语义矩阵竞态）。
- **M0 存档**：CI run 43902967558（eeee1b5）8/8 jobs 全绿。

## 未验证边界（不伪装绿灯）

- CI 矩阵实跑结果待 GitHub Actions（push 后确认）。
- 幂等记录（信封 idem）只落形状与持久化，框架级 requestId 重放接线在 M2/M4；跨语言 canonical hash 分叉（cr=CRC32+64v）待 troupe-planning ADR。
- cancel 帧的 TLS/token 强认证沿用现有 cluster_token 常量比较（cr security.md 的 rotate/grace 在 M2 传输认证项）。
- `examples/booth/`（未跟踪）不在本次验证范围。

---

# 存档：M0 基线（2026-11-17，run 43902967558 全绿）

Issue 对应：#1 / #2 / #3 / #4 / #6 + CI 建立。

| 项 | 验证方式 | 结果 |
|---|---|---|
| #1 logger（及 bigdecimal/pstore）声明 | gemspec 显式 `add_dependency`；lockfile 更新（logger 1.7.0、bigdecimal、pstore，含 x86_64-linux 平台）；默认入口直接可跑 | ✅ |
| #2 namespace 固定 | 默认值 `"default"`（对齐 troupejs），显式配置 > 环境变量 > 默认；`ConfigNamespaceTest` 在随机名 tmpdir 下断言默认值与预置 Props 的读取/接管 | ✅ props/ownership/cluster 从任意目录名运行全绿 |
| #3 迁移逐级 v→v+1 | `run_migration` 循环单步调用 `migrate_props(props, v)`；反例测试：v1→v3 步进、缺失中间步骤显式报错、失败不落盘 | ✅ |
| #4 Minitest 断言兼容 | `assert_same nil` → `assert_nil`/`assert_equal`；gemspec `required_ruby_version >= 3.2` | ✅ |
| #6 Cue 有界投递池 | 8 worker + 256 深度预算背压；单 tick 80 条到期全投递、线程恒为 8、停机 drain | ✅ |
| CI 矩阵 | Ruby 3.2/3.3/3.4/4.0 × ubuntu/windows | ✅ run 43902967558 8/8 jobs 全绿 |

M0 发现（存档）：pstore/bigdecimal 同为 bundled gem（Ruby 4.0/3.4 降级）需一并声明；`test_strict_fifo_order` 历史抖动源于把"线程创建顺序=入队顺序"误当框架承诺（已改为串行不变量断言）；Ruby 4.0 `Queue#push` 移除 `non_block:` 关键字（SizedQueue 保留位置参数形式）。
| #2 namespace 固定 | 默认值 `"default"`（对齐 troupejs），显式配置 > 环境变量 > 默认；`ConfigNamespaceTest` 在随机名 tmpdir 下断言默认值与预置 Props 的读取/接管 | ✅ props/ownership/cluster 从任意目录名（`/tmp/arbitrary-dir-name-xyz`）运行全绿 |
| #3 迁移逐级 v→v+1 | `run_migration` 循环单步调用 `migrate_props(props, v)`；反例测试：v1→v3 步进、缺失中间步骤显式报错、失败不落盘（存储保持 v1 原状）、并发迁移以已提交版本为准（原有 CAS 冲突路径保留） | ✅ |
| #4 Minitest 断言兼容 | `assert_same nil` → `assert_nil`/`assert_equal`（Minitest 6 直接报错，5.x/6.x 均兼容）；gemspec `required_ruby_version >= 3.2`，README 支持矩阵 | ✅ |
| #6 Cue 有界投递池 | WORKERS=8 复用线程 + QUEUE_DEPTH=256 预算背压（满则本轮不认领、租约到期重投）；反例测试：单 tick 80 条到期全部投递且线程恒为 8、停机 drain（存量投递完成裁决后 worker 全部退出） | ✅ |
| CI 矩阵 | `.github/workflows/ci.yml`：Ruby 3.2/3.3/3.4/4.0 × ubuntu/windows，`bundle exec rake test` | ✅ run [43902967558](https://github.com/ShiningRay/troupe/actions/runs/43902967558) 8/8 jobs 全绿（eeee1b5） |

## 发现并顺带修复（超出 Issue 清单）

- **pstore / bigdecimal 也是 bundled gem**（Ruby 4.0 / 3.4 起降级）：修 #1 时全量扫描 `lib/` 的 stdlib require 后一并声明，否则支持矩阵内的 3.4/4.0 都会在不同位置炸 LoadError。
- **`test_strict_fifo_order` 历史抖动**：并发 caller 的入队顺序由线程调度决定，"创建顺序 = 执行顺序"不是框架承诺；改为断言真正的串行不变量（strict-start 紧跟 strict-end、全部执行）。复跑 3 次曾出现 2 次失败，重写后稳定。
- **Ruby 4.0 `Queue#push` 移除 `non_block:` 关键字**：背压改用入队前深度预检（portable across 3.2–4.0）。
- 本机网络直连 rubygems.org 慢：项目本地 `.bundle/config` 配置清华镜像（已被 `.gitignore` 排除，不影响 CI）。

## 未验证边界（不伪装绿灯）


- 真实多进程/多机故障接管（#5）未验证——属 M2 范围，当前仅进程内共享存储语义。
- PStore 在 CI 各 Ruby 版本的持久化行为仅覆盖 ubuntu/windows 两条路径的矩阵。
- `examples/booth/`（未跟踪）为 Booth 桥原型，不在本次验证范围。
