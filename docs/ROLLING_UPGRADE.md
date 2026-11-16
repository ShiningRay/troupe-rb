# 滚动升级 / 热替换流程（ROADMAP M5：先文档化 drain→upgrade）

> 机制已全部存在（R1–R6 兼容规则见 troupe-planning）；本文档化操作顺序与边界。

## 语义前提

- **升级窗口 = Stage 级 drain**：`troupe.shutdown!(grace:)` 拒新 Call → 排干在飞 →
  全员 offStage + saveProps → 释放所有权（租约到期自愈兜底）。Actor 是虚拟的——
  升级一个 Stage 不丢状态，下一条 Call 在健康 Stage 重新登台（M2 共享存储语义）。
- **升级窗口内**：该 Stage 的 Actor 在其他 Stage 重活（ring 视图经 gossip 收敛，
  转发跳数上限 2 兜底漂移期）。
- **不支持的滚动形态**：混跑不同 `PROTOCOL_VERSION` 的节点（hello 握手显式拒绝，
  M1）；混跑不同存储信封格式的 PStore 目录（M1 已知边界——PStore 为开发级存储）。

## drain → upgrade → 回归 流程

1. **隔离流量**（负载均衡摘除该 Stage 或停止向其派发）。
2. **优雅停演**：向进程发 SIGTERM，应用捕获后调 `troupe.shutdown!(grace: "10s")`
   （`TROUPE_SHUTDOWN_GRACE` 可配）。宽限期内：拒新 Call（内部 Call 除外）→
   在飞 Turn settle → offStage 钩子 + saveProps（CAS 提交，fencing 保护）→ 退出
   Roster。宽限期内未排空的 Turn：日志报错后放弃（用户任务挂起靠进程隔离，
   至少一次语义由持久化兜底）。
3. **替换进程/镜像**：新版本代码 + 同一 `TROUPE_NAMESPACE` + 同一共享存储
   （PostgreSQL Provider）+ `TROUPE_ADVERTISE` 指向本机端口。
4. **回归集群**：`TROUPE_SEEDS` 加入现有节点 → gossip 收敛 → 环归属重算 →
   该 Stage 按需重新激活 Actor（从共享存储读最后已提交快照；schema_version
   驱动逐级迁移，M0）。
5. **逐台重复**（一次一个 Stage），期间集群持续可用。

## R1–R6 兼容审查要点（升级前 checklist）

- [ ] Props schema 迁移逐级可走（旧 schema_version → 新版本，缺失中间步骤会显式报错）。
- [ ] wire 帧：新增字段只增不改（旧端解码兼容）；帧类型新增（cancel 等）对旧端
      是显式拒绝 → **必须整批同版本升级，不能逐台**（hello 协商保证不静默混跑）。
- [ ] 错误分类 code/reason 兼容（新增 reason 旧端按 rejected 处理）。
- [ ] 存储信封/幂等记录形状变更 = 破坏性（需排空 + 目录迁移，不做在线热替换）。
- [ ] Outbox/Stream/Inbox 表结构变更按追加式演进（新列可空），不重命名。

## 热替换（不重启进程）的边界

Ruby 无 `setPrototypeOf` 式热替换原语；代码级热替换需另设计（BENCH 工效债清单）。
当前支持的"热"操作：`Director off` 单 Actor 下场（offStage + saveProps）→
下一条 Call 重新登台——用于**数据修复/单 Actor 重置**，不是代码热替换。
