# frozen_string_literal: true

require_relative "../codec"
require_relative "../errors"
require_relative "../util"

module Troupe
  # 存储中的一份 Props：并发修订号（revision，CAS 用）与结构版本
  # （schema_version，迁移用）是两个维度（DESIGN §7.2）；fence 为所有权 fencing token。
  class StoredProps
    attr_reader :props, :revision, :schema_version, :fence

    def initialize(props:, revision:, schema_version:, fence: 0)
      @props = props
      @revision = revision
      @schema_version = schema_version
      @fence = fence
    end
  end

  # 所有权记录（DESIGN §6.5）：epoch 为单调递增的 fencing token
  class OwnershipRecord
    attr_reader :owner, :epoch, :lease_until

    def initialize(owner:, epoch:, lease_until:)
      @owner = owner
      @epoch = epoch
      @lease_until = lease_until
    end
  end

  # StoreCapabilities（M2，对齐 troupejs Provider 能力矩阵）：
  # 生产门禁依据，不是文档声明——production + transport 模式拒绝非 cross_node_safe Provider。
  StoreCapabilities = Struct.new(:cross_node_safe, :supports_fencing, :supports_transactions) do
    def to_h
      { "crossNodeSafe" => cross_node_safe, "supportsFencing" => supports_fencing,
        "supportsTransactions" => supports_transactions }
    end
  end

  # OutboxRecord（M4）：Actor 内 emit、随 Props **同一原子提交**落盘，
  # 由 OutboxDispatcher 独立交付外部副作用（至少一次；接收方用 Inbox 幂等去重）。
  OutboxRecord = Struct.new(:namespace, :role_id, :stage_name, :event_id, :topic, :payload,
                            :created_at, :attempts, :status) do
    def to_h
      { "namespace" => namespace, "role" => role_id, "stageName" => stage_name,
        "eventId" => event_id, "topic" => topic, "payload" => payload,
        "createdAt" => created_at, "attempts" => attempts, "status" => status }
    end
  end

  # PropStore（道具间）接口合同（DESIGN §7.2）：
  # * create/write 必须原子（如单条 UPDATE … WHERE revision = ?）；
  # * 冲突抛 ConflictError；
  # * 写结果不确定（网络超时）时，调用方以 read 校验实际 revision 后决定，不盲目重写。
  #
  # Outbox 合同（M4）：write(outbox: [records]) 与 Props CAS **同一原子提交**
  # （Memory 同锁、PG 同事务）；claim_outbox_batch / outbox_mark_delivered /
  # outbox_mark_failed 支撑独立 dispatcher（SKIP LOCKED、租约、退避、死信）。
  class PropStore
    # Provider 能力矩阵（M2，对齐 troupejs）：生产门禁依据——
    # production + transport 模式拒绝非 cross_node_safe Provider（除非显式降级开关）
    def capabilities
      StoreCapabilities.new(false, false, false)
    end

    def read(_namespace, _role_id, _stage_name)
      raise NotImplementedError
    end

    # 仅当不存在时成功（原子）
    def create(_namespace, _role_id, _stage_name, _props, schema_version:, fencing_token: 0)
      raise NotImplementedError
    end

    # CAS：仅当当前 revision == expected_revision 才写入；返回新 revision，冲突抛 ConflictError。
    # outbox（M4）：随本次写原子提交的事件（emit_event → save_props 路径）
    def write(_namespace, _role_id, _stage_name, _props, expected_revision:, schema_version:,
              fencing_token: 0, outbox: [])
      raise NotImplementedError
    end

    def delete(_namespace, _role_id, _stage_name)
      raise NotImplementedError
    end

    # ---- Outbox 独立 dispatcher 合同（M4） ----

    # 认领一批待交付记录（SKIP LOCKED 语义：多 dispatcher 并发不重不漏）；
    # 认领即租约 + attempts +1。失败重试/死信由 outbox_mark_failed 裁决。
    def claim_outbox_batch(limit:, owner:, lease_ms:)
      raise NotImplementedError, "#{self.class.name} 未实现 Outbox"
    end

    def outbox_mark_delivered(record)
      raise NotImplementedError
    end

    # 交付失败：attempts 达 max → 死信（返回 true）；否则退避重排（返回 false）
    def outbox_mark_failed(record, max_attempts:, backoff_ms:)
      raise NotImplementedError
    end

    def outbox_counts
      {}
    end

    # 共享存储能力（多节点生产必需）：承载所有权记录与 fencing（DESIGN §6.5）
    def ownership_enabled?
      false
    end

    def acquire_ownership(_ns, _role_id, _name, owner:, lease_ms:)
      raise NotImplementedError, "#{self.class.name} 不支持所有权：多节点生产需部署共享 PropStore（DESIGN §7.2）"
    end

    def renew_ownership(_ns, _role_id, _name, owner:, expected_epoch:, lease_ms:)
      raise NotImplementedError
    end

    def release_ownership(_ns, _role_id, _name, owner:, expected_epoch:)
      raise NotImplementedError
    end

    def close; end

    def self.key(ns, role_id, stage_name)
      "#{ns}\u0000#{role_id}\u0000#{stage_name}"
    end
  end

  # InMemoryPropStore：无持久级别——Rehearsal / 测试（DESIGN §7.2）。
  # 写路径与文件/数据库实现走同一 CAS / fencing 合同，测试不掩盖部署差异。
  class MemoryPropStore < PropStore
    def initialize(ownership: true)
      @mutex = Mutex.new
      @props = {}
      @ownership = {}
      @outbox = {}
      @outbox_lease = {}
      @outbox_owner = {}
      @outbox_next_try = {}
      @supports_ownership = ownership
      # 进程内共享（同进程多 Stage 集群测试可用），但不跨节点：cross_node_safe=false
      @capabilities = StoreCapabilities.new(false, true, false)
    end

    def capabilities
      @capabilities
    end

    def ownership_enabled?
      @supports_ownership
    end

    def read(ns, role_id, stage_name)
      @mutex.synchronize do
        rec = @props[PropStore.key(ns, role_id, stage_name)]
        rec && StoredProps.new(props: Codec.copy(rec[:props]), revision: rec[:revision],
                               schema_version: rec[:schema_version], fence: rec[:fence])
      end
    end

    def create(ns, role_id, stage_name, props, schema_version:, fencing_token: 0)
      k = PropStore.key(ns, role_id, stage_name)
      @mutex.synchronize do
        raise ConflictError, "Props 记录已存在：#{role_id}/#{stage_name}" if @props.key?(k)

        rec = { props: Codec.copy(props), revision: 1, schema_version: schema_version, fence: fencing_token }
        @props[k] = rec
        StoredProps.new(props: Codec.copy(rec[:props]), revision: 1, schema_version: schema_version, fence: fencing_token)
      end
    end

    def write(ns, role_id, stage_name, props, expected_revision:, schema_version:, fencing_token: 0, outbox: [])
      k = PropStore.key(ns, role_id, stage_name)
      @mutex.synchronize do
        rec = @props[k] || raise(ConflictError, "Props 记录不存在：#{role_id}/#{stage_name}")
        # fencing 优先于 CAS 诊断（对齐 PG/cr docs/persistence.md）
        if fencing_token < rec[:fence]
          raise ConflictError,
                "fencing token 过期：token=#{fencing_token} < fence=#{rec[:fence]}，所有权已转移（DESIGN §6.5）"
        end
        unless rec[:revision] == expected_revision
          raise ConflictError, "revision CAS 失败：expected=#{expected_revision} actual=#{rec[:revision]}（#{role_id}/#{stage_name}）"
        end

        rec[:props] = Codec.copy(props)
        rec[:revision] += 1
        rec[:schema_version] = schema_version
        rec[:fence] = fencing_token if fencing_token > rec[:fence]
        # Outbox 与 Props 同锁原子提交（M4）：写失败（raise）则事件同样不落
        outbox.each do |r|
          (@outbox[k] ||= []) << OutboxRecord.new(
            ns, role_id, stage_name, r[:event_id] || Util.call_id, r[:topic],
            Codec.copy(r[:payload]), Util.now_ms, 0, "pending"
          )
        end
        StoredProps.new(props: Codec.copy(rec[:props]), revision: rec[:revision],
                        schema_version: rec[:schema_version], fence: rec[:fence])
      end
    end

    # ---- Outbox（Memory：语义与 PG 版对齐） ----

    def claim_outbox_batch(limit:, owner:, lease_ms:)
      now = Util.now_ms
      claimed = []
      @mutex.synchronize do
        @outbox.each_value do |rows|
          rows.each do |r|
            next if claimed.size >= limit
            next if @outbox_next_try[r.event_id] && @outbox_next_try[r.event_id] > now

            claimable = r.status == "pending" ||
                        (r.status == "running" && (@outbox_lease[r.event_id] || 0) <= now)
            next unless claimable

            r.attempts += 1
            r.status = "running"
            @outbox_lease[r.event_id] = now + lease_ms
            @outbox_owner[r.event_id] = owner
            claimed << OutboxRecord.new(*r.to_a)
          end
        end
      end
      claimed
    end

    def outbox_mark_delivered(record)
      @mutex.synchronize do
        r = find_outbox(record)
        return false unless r && r.status == "running"

        r.status = "sent"
        true
      end
    end

    def outbox_mark_failed(record, max_attempts:, backoff_ms:)
      @mutex.synchronize do
        r = find_outbox(record)
        return false unless r && r.status == "running"

        if r.attempts >= max_attempts
          r.status = "dead" # 死信：人工介入
        else
          r.status = "pending"
          @outbox_next_try[r.event_id] = Util.now_ms + backoff_ms
        end
        true
      end
    end

    def outbox_counts
      @mutex.synchronize do
        all = @outbox.values.flatten
        { "pending" => all.count { |r| r.status == "pending" },
          "running" => all.count { |r| r.status == "running" },
          "sent" => all.count { |r| r.status == "sent" },
          "dead" => all.count { |r| r.status == "dead" } }
      end
    end

    # 测试/诊断支持
    def outbox_records
      @mutex.synchronize { @outbox.values.flatten.map { |r| OutboxRecord.new(*r.to_a) } }
    end

    def delete(ns, role_id, stage_name)
      @mutex.synchronize do
        @props.delete(PropStore.key(ns, role_id, stage_name))
        @ownership.delete(PropStore.key(ns, role_id, stage_name))
      end
      nil
    end

    # ---- 所有权（租约 + 单调 epoch，DESIGN §6.5） ----

    def acquire_ownership(ns, role_id, name, owner:, lease_ms:)
      k = PropStore.key(ns, role_id, name)
      now = Util.now_ms
      @mutex.synchronize do
        rec = @ownership[k]
        if rec.nil? || rec[:lease_until] <= now || rec[:owner] == owner
          epoch = rec.nil? ? 1 : (rec[:owner] == owner ? rec[:epoch] : rec[:epoch] + 1)
          rec = { owner: owner, epoch: epoch, lease_until: now + lease_ms }
          @ownership[k] = rec
          # 接管（epoch 前进）即前移 Props 记录的 fence：旧持有者的后续写入被拒（DESIGN §6.5）
          if (props_rec = @props[k]) && epoch > props_rec[:fence]
            props_rec[:fence] = epoch
          end
          OwnershipRecord.new(owner: rec[:owner], epoch: rec[:epoch], lease_until: rec[:lease_until])
        end
      end
    end

    def renew_ownership(ns, role_id, name, owner:, expected_epoch:, lease_ms:)
      k = PropStore.key(ns, role_id, name)
      now = Util.now_ms
      @mutex.synchronize do
        rec = @ownership[k]
        return false unless rec && rec[:owner] == owner && rec[:epoch] == expected_epoch

        rec[:lease_until] = now + lease_ms
        true
      end
    end

    def release_ownership(ns, role_id, name, owner:, expected_epoch:)
      k = PropStore.key(ns, role_id, name)
      @mutex.synchronize do
        rec = @ownership[k]
        if rec && rec[:owner] == owner && rec[:epoch] == expected_epoch
          # 释放但保留 epoch 墓碑：下次接管 epoch 单调递增（fencing 不回退，DESIGN §6.5）
          rec[:lease_until] = 0
        end
      end
      nil
    end

    def ownership_record(ns, role_id, name)
      @mutex.synchronize { @ownership[PropStore.key(ns, role_id, name)] }
    end

    def snapshot
      @mutex.synchronize { { props: @props.dup, ownership: @ownership.dup } }
    end

    private

    def find_outbox(record)
      (@outbox[PropStore.key(record.namespace, record.role_id, record.stage_name)] || [])
        .find { |r| r.event_id == record.event_id }
    end

    def load_raw(hash)
      @mutex.synchronize do
        @props.update(hash.transform_keys(&:to_s)) { |_old, new| new }
      end
    end
  end
end
