# Ruby 并发研究：复现实验与证据

> 日期：2026-11-18。研究正文：[ruby-concurrency.md](./ruby-concurrency.md)。这些实验用于筛选运行时方案，不是新的跨语言正式横评，也没有把 opt-in 数据替换为默认基准。

## 环境与边界

- 设备：DESKTOP-IBMH65K / Windows / i7-1165G7，8 逻辑核。
- 运行时：Ruby 4.0.6 + PRISM，x64-mingw-ucrt；trouperb 0.1.0。
- 使用 `bench-suite/drivers/driver.rb`：window=3s、warmup=0.5s、count=10,000、C=8。
- 本轮跳过 persist 与 cluster；其他语言未同时重跑。与原 2026-11-17 轮的数据是跨轮对照，只能看方向，不能声称精确提升倍数。
- shared 和 worker 本地 ready queue 都是 opt-in 实验。后者是诊断探针，未完成状态机、异常和停机验收，不可直接合入。

## 复现命令

在 `trouperb` 目录、其他 Troupe 仓按 bench-suite 约定并列时：

```bash
# 已实现的共享池：输出到 bench-suite 的缓存目录，不覆盖正式 results/ruby.json
ruby ../bench-suite/drivers/driver.rb \
  --dispatcher shared --skip-cluster --skip-persist \
  --out ../bench-suite/.cache/ruby-concurrency-research/ruby-shared.json

# worker 本地 ready queue：研究性 monkey patch，不修改生产 dispatcher
ruby -Ilib -rtroupe \
  -r../bench-suite/.cache/ruby-concurrency-research/local_queue_dispatcher.rb \
  ../bench-suite/drivers/driver.rb \
  --dispatcher shared --skip-cluster --skip-persist \
  --out ../bench-suite/.cache/ruby-concurrency-research/ruby-local-queues.json
```

本地队列探针通过 monkey patch 将 `Troupe::SharedDispatcherPool` 替换为 `Troupe::LocalQueueDispatcherPool`。该常量替换需在运行驱动前执行；脚本与原始 JSON 保留在 bench-suite 的 `.cache/ruby-concurrency-research/`，不作为生产 artifact 发布。

默认基线来自 [bench-suite 2026-11-17 分析](../../../../bench-suite/results/analysis-2026-11-17.md) 与其 `ruby.json`：`thread_per_cell`，同样 window=3s/count=10k/C=8，但属于较早轮次。

## 实际结果

| 场景 | 11-17 默认线程 | 本轮 shared | 本轮 shared + 实验性本地 ready queue |
|---|---:|---:|---:|
| call-latency ops/s | 11,346.2 | 3,969.2 | 4,689.5 |
| call-hot ops/s | 16,190.3 | 5,416.0 | 6,458.5 |
| call-spread ops/s | 10,568.2 | 4,185.8 | 5,278.6 |
| activate ops/s | 426.0 | 2,051.2 | 3,281.0 |
| 驻留 KB/Actor | 48.2 | 2.72 | 2.64 |

所有本轮场景 `errors=0`。shared 的激活和驻留改善支持“不要为每个常驻 Actor 永久保留 OS 线程”；热路径下降则说明“共享池并不消除跨线程等待”。不能据这张表直接切换默认调度器。

## 必要原语探针

100,000 次同线程 Fiber yield/resume、100,000 次跨线程 Queue 往返、100,000 次短数组 JSON 往返的单机探针（Ruby 4.0.6）：

```text
Fiber handshake                 0.0273 s
Thread::Queue ping-pong         2.5894 s
JSON array round-trip           0.0956 s
```

这只能说明同线程 Fiber 切换比该跨线程唤醒路径便宜；不能换算为完整 Actor 运行时的吞吐提升。另一组重复运行 Queue 探针得到 4.856s，进一步说明微基准也受系统负载影响，必须多轮、同场 A/B。

正常 Ruby 环境下，256B 字符串经 trouperb `Codec.copy` 约 1.644µs/次，且副本不与原字符串共享引用。codec 快路径应以 `Codec.normalize` 的语义为基准：NaN/Infinity 当前由 Ruby JSON 拒绝，Time/Symbol/Hash 键不能依赖对象默认 `to_json`。直接照抄 JS 的非有限浮点转 null 会改变 Ruby 契约。

## 未完成验证

- Async 2.46.0 固定版本安装在本机 `io-event` 原生扩展构建阶段超时，因此没有 Async Actor 端到端结果，也不据此判定 Async 本身有缺陷。
- 没有 Fiber 化 Cell、Actor 互调 continuation、blocking offload 的完整实现与性能数据。
- 没有 Ractor 分片、JRuby/TruffleRuby、M:N 的 Troupe 端到端数据。
- 本轮没有重跑正式五实现基准、cluster 或持久化后端。
