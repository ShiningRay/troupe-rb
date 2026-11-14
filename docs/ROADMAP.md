# Troupe.rb Orleans 对标路线图

## 0. 恢复可复现的测试基线（最高优先级）

- [ ] [#1](https://github.com/ShiningRay/troupe/issues/1)：声明 Ruby 4 bundled `logger`，更新 lockfile；恢复 `bundle exec rake test` 默认入口。
- [ ] [#4](https://github.com/ShiningRay/troupe/issues/4)：修正 nil 断言；以 CI 跑 Ruby 最低支持版本、稳定版本和 Ruby 4 矩阵。
- [ ] [#2](https://github.com/ShiningRay/troupe/issues/2)：固定 Rehearsal namespace，所有存储读写来自同一配置；在任意目录名验证。
- [ ] [#3](https://github.com/ShiningRay/troupe/issues/3)：逐级执行 v→v+1 迁移，补 v1→v3、缺失迁移、失败不写和并发迁移测试。

**门禁**：默认命令全绿，迁移/接管确实加载旧 Props，消除同进程首次激活被误认为恢复成功的假阳性。未达此门禁前不宣称核心容错已验证。

## 1. 存储与调度基线

- [ ] 将 PStore 明确限制为开发；优先改进 SQLite 默认路径或引入 PostgreSQL，避免 O(全库) 保存。
- [ ] 解决 `Troupe::Troupe` 常量遮蔽，并规划 kwargs、typed Props、代理内省等 Ruby 工效债，不牺牲线协议一致性。
- [ ] 比较 thread_per_cell、shared pool 与非阻塞 Fiber 调度；报告默认配置而非只报告 opt-in 最优结果。
- [ ] 为远程转发、Actor 互调、慢 Turn、长 Cue 设置有界线程/队列预算和过载拒绝。
- [ ] 明确 `improv/read_only` 在 MRI 任意抢占点的一致性，不宣称与 JS await 点交错相同。

**门禁**：真实负载下内存、线程、队列有界；存储成本随目标 Actor 而非全库增长；默认配置基准可复现。

## 2. 生产共享状态与故障接管

- [ ] [#5](https://github.com/ShiningRay/troupe/issues/5)：PostgreSQL Props CAS、ownership、fencing 与原子 reminders claim。
- [ ] 所有创建/迁移/保存均携 fencing；production 拒绝本地 PStore/SQLite。
- [ ] Cue 调度先按当前环/目录归属过滤，共享存储下重复投递由幂等消费处理。
- [ ] 至少两个独立 Ruby 进程连接真实数据库，执行 kill -9、冻结恢复、租约接管、旧写拒绝和 reminder 重投。
- [ ] 增加生产角色/协议协商、传输认证与加密，不只保护 Director。

**门禁**：跨进程/多机旧 epoch 无法写，Props 与 reminders 可从共享存储恢复，测试输出真实拓扑与数据库版本。

## 3. 编程模型与 Orleans 核心契约

- [ ] 统一 identity、activation incarnation、生命周期、错误分类、deadline、协作取消和 UnknownOutcome。
- [ ] 保留 Ruby DSL 风格，支持 kwargs 的版本化编码与类型 manifest，不引入语言私有 Marshal 作为公共协议。
- [ ] 将串行 Turn、read_only、improv 与超时/取消组合成可验证的调度矩阵。
- [ ] 引入 Rehearsal 的确定性时钟/调度，减少 sleep 阈值造成的 flake。

## 4. 可靠 Show、目录与互操作

- [ ] 当前 Show 明确为进程内实时回调，不能称为流或 Audience。
- [ ] 若实现持久流，独立设计 Actor 订阅、事件日志、游标、ack/replay、保留、慢消费者与幂等；优先复用消息 Provider。
- [ ] 与统一规划共同决定版本化目录、capabilities/资源放置和再平衡，不复制 Orleans 的 .NET 实现。
- [ ] 跨语言前冻结语言中立身份/哈希/信封/schema/错误/trace 契约和 golden fixtures。

## 5. 后续

Booth/OTel、滚动升级/回滚、Provider 兼容套件、Outbox；事务与事件溯源在核心容错和可靠消息之后单独评估。
