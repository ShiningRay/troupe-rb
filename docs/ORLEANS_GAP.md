# Troupe.rb 与 Orleans 的能力差距

> 对标 Orleans 10.0；统一规划：[troupe-planning](https://github.com/ShiningRay/troupe-planning)。

## 当前定位

Ruby 版已有虚拟 Actor、严格串行与可选共享线程池、TCP 路由、Props CAS、租约/fencing、持久 Cue 和进程内 Show。它不只是 API 原型，但当前测试基线失败、存储只能进程级持久，尚不能称为生产级 Orleans 类运行时。

## 主要差距

| 领域 | 当前实现 | 与 Orleans 的差距 |
|---|---|---|
| 核心运行时 | Cell 串行、激活/钝化、Props 保存、标注交错 | 调度语义受 MRI 抢占/GVL 影响；远程取消、生命周期与背压需补齐 |
| 密度 | 默认每 Cell 一线程；可选共享池 | 无证据支持 Orleans 级激活密度；共享池不是默认配置且阻塞会耗 worker |
| Props | PStore/SQLite/Memory，CAS、schemaVersion、fencing | 无共享 Provider；迁移非逐级；默认 PStore 全量写；无版本化 Provider 生态 |
| 集群 | TCP+JSON、gossip、HashRing | 故障测试主要为同进程内存，缺真实进程/数据库接管、目录和放置策略 |
| Cue | PStore 持久、claim/lease、至少一次 | 无共享生产 CueStore；共享存储下需按归属过滤，避免多节点重复调度 |
| Show | 仅进程内回调 | 非 Actor Audience、非跨节点，更非持久流；无序列 token/游标/重放 |
| 类型与协议 | Ruby DSL、JSON、私有 TCP | kwargs 不支持、动态代理内省弱、无语言中立契约与跨版本协议矩阵 |
| 运维 | CLI/Trace/Metrics | 缺 CI、Booth/BoxOffice、OTel、滚动升级与发布验证 |
| 高级模块 | 幂等、CAS | 没有持久 Outbox、事件溯源、跨 Actor 事务或 grain extensions |

## 缺陷 Issues

- [#1 Ruby 4 logger 启动失败](https://github.com/ShiningRay/troupe/issues/1)。
- [#2 Rehearsal namespace 导致验收绕过旧 Props](https://github.com/ShiningRay/troupe/issues/2)。
- [#3 多级 schema 迁移未逐级执行](https://github.com/ShiningRay/troupe/issues/3)。
- [#4 Minitest 6 nil 断言与支持矩阵](https://github.com/ShiningRay/troupe/issues/4)。
- [#5 共享存储与真实故障接管](https://github.com/ShiningRay/troupe/issues/5)。

先修 #1–#4 才能重新信任核心验收，再实施 #5；不能根据 README 的历史“78 runs”认定当前版本通过。

路线见 [ROADMAP.md](./ROADMAP.md)，实测见 [VERIFICATION.md](./VERIFICATION.md)。
