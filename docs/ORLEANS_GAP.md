# Troupe.rb 与 Orleans 的能力差距

> 对标 Orleans 10.0（参考基线 commit 8320d257，2026-11-14）；统一规划：[troupe-planning](https://github.com/ShiningRay/troupe-planning)。
> 本文 2026-11-16 依据 troupejs（M1–M11 + P0–P3 全部完成，CI 235 passed）与 troupe.cr（M0–M6 全部完成，166 specs）两兄弟实现的实测状态重新校准。

## 当前定位

Ruby 版已有虚拟 Actor、严格串行与可选共享线程池、TCP 路由 + gossip + HashRing、Props CAS/revision/fencing、ownership 租约（acquire/renew/release，本地存储）、持久 Cue 与进程内 Show。它不只是 API 原型，但**默认测试入口当前失败**（2026-11-16 复现 `bundle exec rake test` 因 Ruby 4 logger LoadError 未进入测试），存储只能进程级持久，尚不能称为生产级 Orleans 类运行时。

## 三实现横向对照（2026-11-16）

| 能力 | trouperb | troupe.cr | troupejs | Orleans 10 |
|---|---|---|---|---|
| 测试基线 | ❌ 默认入口红（#1） | ✅ 166 specs | ✅ CI 235 passed（PG leg 必跑，skip 即失败） | — |
| CI | ❌ 无 | ✅ | ✅ 矩阵 + nightly + minimal-install | — |
| 存储后端 | Memory/PStore/SQLite（均本地） | Memory/SQLite/PG | Memory/SQLite/PG | Provider 生态 |
| 能力矩阵/生产门禁 | ❌ | 部分（cross_node_safe 标注） | ✅ StoreCapabilities + 生产拒绝不安全 Provider | ✅ |
| ownership/租约 | 本地 acquire/renew/release；无共享存储 | ✅ PG DB 时钟租约 + 单语句 CAS + kill -9 多进程矩阵 | ✅ F1–F6 反例 + stop-serving | ✅ |
| 持久 Reminder 跨节点 | ❌ PStore 本地 | ✅ PG claim/lease | ✅ PG（SKIP LOCKED + DB 时钟） | ✅ |
| 协作取消 | ❌（#7） | ✅ 含 wire cancel | ✅ 含 abortCall | ✅ |
| deadline/UnknownOutcome | 部分 | ✅ 排队过期 vs 执行超时分离 | ✅ | ✅ |
| read_only/improv | ✅ | ✅ M4 | ✅ M5 | Reentrancy |
| Show/实时 | ❌ 仅进程内回调（`show.rb` 自述） | ✅ Actor Audience 经完整 Turn、跨 Stage、慢订阅者隔离 | ✅ ephemeral/durable 拆分（ADR 0005） | Streams |
| 持久流 | ❌ | ✅ PG（游标/ack/replay/retain） | ✅ PG + StreamConsumer | ✅ |
| Outbox/Inbox | ❌ | ✅ | ✅ 同事务 + SKIP LOCKED + 死信 | —（用事务替代） |
| 事件溯源 | ❌ | ✅ pattern（快照+fold） | ❌ 非目标 | ✅ 可选 |
| 版本化目录/放置 | ❌ HashRing 仅路由 | 进程内版本化目录 + least-loaded + 再平衡 | ✅ PG DirectoryRouter（cache→lookup→claim） | ✅ 分区 DHT 交接 |
| 传输安全 | token 默认空串、无 TLS | token 常时比较 + rotate/grace；TLS 仅指导 | ✅ TLS + join token + adminToken 强制 | ✅ |
| 滚动升级/热替换 | ❌ | 指导文档 | ✅ L1 热重载 + L2 签名部署/回滚 | ✅ |
| Golden fixtures/跨语言契约 | ❌ | ✅ 4 组（但哈希已分叉，见下） | ✅ protocol-v2 | — |
| OTel | ❌ | ✅ OTLP JSON 零依赖导出 | ✅ adapter | ✅ |
| 仪表盘/网关 | Edge 仅 healthz/metrics/call | ❌（Booth 延后） | ✅ Booth + BoxOffice(WS) + CLI 全家 | — |
| 幂等记录 | ✅ | ✅ | ✅ | — |

### 跨语言契约已分叉的事实

- troupejs golden `protocol-v2.json` 锚定 **xxh32**（`ns:Cart:k1 → 2646418494`），HashRing 每 Stage 160 vnodes。
- trouperb 实现同为 **xxh32 + 160 vnodes**（`lib/troupe/cluster/hash_ring.rb`、`xxh32.rb`），与 js 同源一致。
- troupe.cr golden `hash.json` 锚定 **CRC32 IEEE + 64 vnodes**，源码注释自认「跨语言 canonical hash 待 M5 公共协议 ADR」；其 ADR-0001 尚为 Proposed、未被 troupe-planning 采纳。
- 结论：trouperb 应先采用 js 的 protocol-v2 向量作为 golden；canonical hash 归属（xxh32 vs CRC32）必须在 troupe-planning 出 ADR，trouperb 不单方面决定。

## 与 Orleans 10 的共同差距（三实现皆无，跟随统一规划）

强一致分布式目录与分区交接（DHT）、资源/能力感知的集群级放置与再平衡、版本容错序列化（codegen）、跨语言混合集群、分布式 ACID 事务（三实现一致声明非目标）、grain extensions。这些不作为 trouperb 单独目标。

## 缺陷 Issues

- [#1 Ruby 4 logger 启动失败](https://github.com/ShiningRay/troupe-rb/issues/1)（2026-11-16 复现）。
- [#2 Rehearsal namespace 随工作目录漂移](https://github.com/ShiningRay/troupe-rb/issues/2)（根因 `config.rb:26` `File.basename(Dir.pwd)`）。
- [#3 多级 schema 迁移未逐级执行](https://github.com/ShiningRay/troupe-rb/issues/3)。
- [#4 Minitest 6 nil 断言与支持矩阵](https://github.com/ShiningRay/troupe-rb/issues/4)。
- [#5 共享存储与真实故障接管](https://github.com/ShiningRay/troupe-rb/issues/5)。
- [#6 Cue 调度器每条到期提醒新建线程且无上限](https://github.com/ShiningRay/troupe-rb/issues/6)。
- [#7 协作式取消缺失](https://github.com/ShiningRay/troupe-rb/issues/7)。

先修 #1–#4、#6 才能重新信任核心验收，再实施 #5、#7；不能根据 README 历史「78 runs」认定当前版本通过。

路线见 [ROADMAP.md](./ROADMAP.md)，实测见 [VERIFICATION.md](./VERIFICATION.md)。
