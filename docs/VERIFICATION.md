# 验证基线（2026-11-17，M1 迭代）

环境：Windows、Ruby 4.0.6、Bundler 4.0.24，trouperb 工作树（M1 提交）。
Issue 对应：#7 + M1 语义对齐（错误映射 / golden / 版本协商 / 背压 / 调度矩阵）。M0 基线见下节存档。

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
