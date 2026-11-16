# 验证基线（2026-11-17，M0 迭代）

环境：Windows、Ruby 4.0.6、Bundler 4.0.24，trouperb 工作树（M0 修复提交）。
Issue 对应：#1 / #2 / #3 / #4 / #6 + CI 建立。

## 默认入口

```sh
bundle install
bundle exec rake test
```

**结果：96 runs，2771 assertions，0 failures，0 errors，0 skips**。
连续执行 3 次全绿（并发时序抖动未复现）。

## 逐项验证

| 项 | 验证方式 | 结果 |
|---|---|---|
| #1 logger（及 bigdecimal/pstore）声明 | gemspec 显式 `add_dependency`；lockfile 更新（logger 1.7.0、bigdecimal、pstore，含 x86_64-linux 平台）；默认入口直接可跑 | ✅ |
| #2 namespace 固定 | 默认值 `"default"`（对齐 troupejs），显式配置 > 环境变量 > 默认；`ConfigNamespaceTest` 在随机名 tmpdir 下断言默认值与预置 Props 的读取/接管 | ✅ props/ownership/cluster 从任意目录名（`/tmp/arbitrary-dir-name-xyz`）运行全绿 |
| #3 迁移逐级 v→v+1 | `run_migration` 循环单步调用 `migrate_props(props, v)`；反例测试：v1→v3 步进、缺失中间步骤显式报错、失败不落盘（存储保持 v1 原状）、并发迁移以已提交版本为准（原有 CAS 冲突路径保留） | ✅ |
| #4 Minitest 断言兼容 | `assert_same nil` → `assert_nil`/`assert_equal`（Minitest 6 直接报错，5.x/6.x 均兼容）；gemspec `required_ruby_version >= 3.2`，README 支持矩阵 | ✅ |
| #6 Cue 有界投递池 | WORKERS=8 复用线程 + QUEUE_DEPTH=256 预算背压（满则本轮不认领、租约到期重投）；反例测试：单 tick 80 条到期全部投递且线程恒为 8、停机 drain（存量投递完成裁决后 worker 全部退出） | ✅ |
| CI 矩阵 | `.github/workflows/ci.yml`：Ruby 3.2/3.3/3.4/4.0 × ubuntu/windows，`bundle exec rake test`；push 后以 Actions 实跑为准 | ⏳ 本地无法预验 |

## 发现并顺带修复（超出 Issue 清单）

- **pstore / bigdecimal 也是 bundled gem**（Ruby 4.0 / 3.4 起降级）：修 #1 时全量扫描 `lib/` 的 stdlib require 后一并声明，否则支持矩阵内的 3.4/4.0 都会在不同位置炸 LoadError。
- **`test_strict_fifo_order` 历史抖动**：并发 caller 的入队顺序由线程调度决定，"创建顺序 = 执行顺序"不是框架承诺；改为断言真正的串行不变量（strict-start 紧跟 strict-end、全部执行）。复跑 3 次曾出现 2 次失败，重写后稳定。
- **Ruby 4.0 `Queue#push` 移除 `non_block:` 关键字**：背压改用入队前深度预检（portable across 3.2–4.0）。
- 本机网络直连 rubygems.org 慢：项目本地 `.bundle/config` 配置清华镜像（已被 `.gitignore` 排除，不影响 CI）。

## 未验证边界（不伪装绿灯）

- CI 矩阵实跑结果待 GitHub Actions（push 后确认）。
- 真实多进程/多机故障接管（#5）未验证——属 M2 范围，当前仅进程内共享存储语义。
- PStore 在 CI 各 Ruby 版本的持久化行为仅覆盖 ubuntu/windows 两条路径的矩阵。
- `examples/booth/`（未跟踪）为 Booth 桥原型，不在本次验证范围。
