# frozen_string_literal: true

require_relative "prop_store"
require_relative "../errors"
require_relative "../util"

module Troupe
  # PostgreSQL 生产 PropStore（M2，#5 核心；对齐 troupe.cr postgresql_prop_store.cr 的
  # 单语句 CAS 模式与 docs/persistence.md 失败语义）：
  #
  # * **cross_node_safe**：Props / 所有权 / 幂等记录共库，CAS 与 fencing 在单条
  #   UPDATE … WHERE 内原子完成；租约与过期判定全部用**数据库服务器时钟**（now()），
  #   客户端时钟漂移不参与；
  # * **epoch 单调**：接管（他人取得）epoch + 1，同 owner 重入不涨；release 保留
  #   epoch 墓碑（fencing 不回退，DESIGN §6.5）；
  # * **旧 epoch 写一律拒绝**：epoch 匹配 + 租约有效都在 UPDATE 的 WHERE 中；
  #   0 行受影响后做精确诊断（fencing 优先于 CAS）；
  # * 无应用层先读后写；写结果不确定（网络超时）时由调用方以 read 校验 revision 决定。
  class PostgresPropStore < PropStore
    LEASE_DEFAULT_MS = 15_000

    attr_reader :capabilities

    def self.open(url, owner_id: nil, lease_ms: LEASE_DEFAULT_MS)
      require "pg"
      store = new(PG.connect(url), owner_id: owner_id, lease_ms: lease_ms)
      store.ensure_schema!
      store
    end

    def initialize(conn, owner_id: nil, lease_ms: LEASE_DEFAULT_MS)
      @conn = conn
      @lease_ms = lease_ms
      @owner = owner_id || Util.incarnation
      @capabilities = StoreCapabilities.new(true, true, true)
      @write_lock = Mutex.new # 单连接串行化（并发写走 CAS，锁只为连接复用）
    end

    def close
      @write_lock.synchronize do
        begin
          @conn.close
        rescue StandardError
          nil
        end
      end
      nil
    end

    def ownership_enabled?
      true
    end

    # ---- Props（CAS + fencing 单语句） ----

    def read(ns, role_id, stage_name)
      row = query_one(
        "SELECT props, revision, schema_version, fence FROM troupe_props WHERE actor_key = $1",
        key(ns, role_id, stage_name)
      )
      return nil unless row

      # pg gem 无 type map 时返回字符串——显式转换（JSONB 保持 String）
      StoredProps.new(props: JSON.parse(row[0]), revision: Integer(row[1]),
                      schema_version: Integer(row[2]), fence: Integer(row[3]))
    end

    def create(ns, role_id, stage_name, props, schema_version:, fencing_token: 0)
      k = key(ns, role_id, stage_name)
      payload = JSON.generate(props)
      rows = exec(
        "INSERT INTO troupe_props (actor_key, props, revision, schema_version, fence, epoch) " \
        "VALUES ($1, $2, 1, $3, $4, $4) " \
        "ON CONFLICT (actor_key) DO NOTHING",
        k, payload, schema_version, fencing_token
      )
      if rows.zero?
        # 创建竞态（跨 Stage 抢激活）：以已存在记录为准（activate! 捕获后读取）
        raise ConflictError, "Props 记录已存在：#{role_id}/#{stage_name}"
      end

      StoredProps.new(props: deep_copy(props), revision: 1, schema_version: schema_version, fence: fencing_token)
    end

    # 单条 UPDATE：CAS（revision）+ fencing（所有权表 epoch 匹配 + 租约有效）原子完成。
    # 所有权表是 fencing 权威（对齐 cr：props 行的 epoch 列只随写入前移，不做 WHERE 条件——
    # 否则接管者首次写会被旧行 epoch 挡住）。token=0（无所有权开发流）退化为纯 CAS。
    # 0 行 → 精确诊断：fencing 优先于 CAS（对齐 cr docs/persistence.md）。
    def write(ns, role_id, stage_name, props, expected_revision:, schema_version:, fencing_token: 0)
      k = key(ns, role_id, stage_name)
      payload = JSON.generate(props)
      rows = exec(
        "UPDATE troupe_props SET props = $2, revision = revision + 1, schema_version = $3, " \
        "fence = GREATEST(fence, $4), epoch = $4 " \
        "WHERE actor_key = $1 AND revision = $5 " \
        "AND $4 > 0 " \
        "AND (SELECT epoch FROM troupe_ownership WHERE actor_key = $1 " \
        "     AND lease_expires_at > now()) = $4", # epoch 单调且任一时刻唯一持有 → epoch 即权威（对齐 cr）
        k, payload, schema_version, fencing_token, expected_revision
      )
      if rows.zero? && fencing_token.zero?
        # 无所有权模式（开发用途）：退化为纯 CAS（revision 匹配即可写，fence 单调前移）
        rows = exec(
          "UPDATE troupe_props SET props = $2, revision = revision + 1, schema_version = $3, " \
          "fence = GREATEST(fence, $4) " \
          "WHERE actor_key = $1 AND revision = $5",
          k, payload, schema_version, fencing_token, expected_revision
        )
      end
      diagnose(k, rows.zero?, expected_revision, fencing_token) if rows.zero?

      stored = read(ns, role_id, stage_name)
      raise ConflictError, "Props 写入后读取失败：#{role_id}/#{stage_name}（结果未知，调用方以 read 校验）" unless stored

      stored
    end

    def delete(ns, role_id, stage_name)
      exec("DELETE FROM troupe_props WHERE actor_key = $1", key(ns, role_id, stage_name))
      exec("DELETE FROM troupe_ownership WHERE actor_key = $1", key(ns, role_id, stage_name))
      nil
    end

    # ---- 所有权（租约 + 单调 epoch，DB 时钟） ----

    # 取得所有权：他人持有效租约 → nil（调用方等待重试）；同 owner 重入不涨 epoch；
    # 租约过期或无记录 → 单调 +1 取得。单条 INSERT ON CONFLICT（对齐 cr ACQUIRE_SQL）。
    def acquire_ownership(ns, role_id, name, owner:, lease_ms:)
      k = key(ns, role_id, name)
      row = query_one(
        "INSERT INTO troupe_ownership (actor_key, epoch, owner, lease_expires_at) " \
        "VALUES ($1, 1, $2, now() + make_interval(secs => $3::float8)) " \
        "ON CONFLICT (actor_key) DO UPDATE SET " \
        "  epoch = CASE WHEN troupe_ownership.owner = EXCLUDED.owner " \
        "               THEN troupe_ownership.epoch ELSE troupe_ownership.epoch + 1 END, " \
        "  owner = EXCLUDED.owner, " \
        "  lease_expires_at = EXCLUDED.lease_expires_at " \
        "WHERE troupe_ownership.lease_expires_at <= now() OR troupe_ownership.owner = EXCLUDED.owner " \
        "RETURNING epoch, owner, (extract(epoch from lease_expires_at) * 1000)::bigint",
        k, owner, lease_ms / 1000.0
      )
      return nil unless row # 他人持有效租约

      OwnershipRecord.new(owner: row[1], epoch: Integer(row[0]), lease_until: Integer(row[2]))
    end

    def renew_ownership(ns, role_id, name, owner:, expected_epoch:, lease_ms:)
      rows = exec(
        "UPDATE troupe_ownership SET lease_expires_at = now() + make_interval(secs => $4::float8) " \
        "WHERE actor_key = $1 AND owner = $2 AND epoch = $3 AND lease_expires_at > now()",
        key(ns, role_id, name), owner, expected_epoch, lease_ms / 1000.0
      )
      rows.positive?
    end

    def release_ownership(ns, role_id, name, owner:, expected_epoch:)
      # 释放但保留 epoch 墓碑（lease_expires_at 拨到过去）：下次接管 epoch 单调递增
      exec(
        "UPDATE troupe_ownership SET lease_expires_at = to_timestamp(0) " \
        "WHERE actor_key = $1 AND owner = $2 AND epoch = $3",
        key(ns, role_id, name), owner, expected_epoch
      )
      nil
    end

    # 测试/诊断支持：所有权行状态（epoch / owner / 租约是否有效）
    def ownership_row(ns, role_id, name)
      row = query_one(
        "SELECT epoch, owner, (extract(epoch from lease_expires_at) * 1000)::bigint " \
        "FROM troupe_ownership WHERE actor_key = $1",
        key(ns, role_id, name)
      )
      row && [Integer(row[0]), row[1], Integer(row[2])] # pg gem 无 type map 时返回字符串
    end

    # 测试支持：把租约拨到过期（模拟接管窗口）
    def expire_ownership!(ns, role_id, name)
      exec("UPDATE troupe_ownership SET lease_expires_at = to_timestamp(0) WHERE actor_key = $1",
           key(ns, role_id, name))
      nil
    end

    def ensure_schema!
      exec("SET client_min_messages = warning") # 静默 CREATE TABLE IF NOT EXISTS 的 NOTICE
      SCHEMA_SQL.each { |sql| exec(sql) }
      nil
    end

    def server_version
      query_one("SELECT version()")[0]
    end

    # 管理/测试支持：执行任意 SQL（清理、诊断）——生产代码不使用
    def exec(sql, *params)
      @write_lock.synchronize do
        @conn.exec_params(sql, params).cmd_tuples
      rescue PG::ConnectionBad, PG::Error => e
        raise ConflictError, "PropStore 写失败：#{e.message[0, 120]}（结果未知，调用方以 read 校验）"
      end
    end

    private

    # PG TEXT 不能含 null byte（PropStore.key 用 \0 连接）：
    # PG Provider 用 JSON 数组作 actor_key（无歧义、可读、可 LIKE 前缀清理）
    def key(ns, role_id, stage_name)
      JSON.generate([ns, role_id, stage_name])
    end

    SCHEMA_SQL = [
      "CREATE TABLE IF NOT EXISTS troupe_ownership (" \
      "actor_key TEXT PRIMARY KEY, epoch BIGINT NOT NULL, owner TEXT NOT NULL, " \
      "lease_expires_at TIMESTAMPTZ NOT NULL)",
      "CREATE TABLE IF NOT EXISTS troupe_props (" \
      "actor_key TEXT PRIMARY KEY, props JSONB NOT NULL, revision BIGINT NOT NULL, " \
      "schema_version INTEGER NOT NULL, fence BIGINT NOT NULL DEFAULT 0, epoch BIGINT NOT NULL DEFAULT 0)",
      "CREATE INDEX IF NOT EXISTS troupe_props_fence_idx ON troupe_props (fence)"
    ].freeze

    private

    def query_one(sql, *params)
      @write_lock.synchronize do
        @conn.exec_params(sql, params).values[0]
      end
    end

    def deep_copy(props)
      JSON.parse(JSON.generate(props))
    end

    # 0 行受影响后的精确诊断：fencing（epoch/租约）优先于 CAS（对齐 cr diagnose）。
    # token=0（无所有权开发流）直接按 revision 对比诊断。
    def diagnose(k, failed, expected_revision, fencing_token)
      row = query_one(
        "SELECT o.epoch, o.owner, (o.lease_expires_at > now()), p.revision " \
        "FROM troupe_props p LEFT JOIN troupe_ownership o ON o.actor_key = p.actor_key " \
        "WHERE p.actor_key = $1",
        k
      )
      unless row
        raise ConflictError, "Props 记录不存在：#{k}"
      end

      held_epoch, holder, lease_valid, revision = row
      held_epoch = held_epoch ? Integer(held_epoch) : 0
      revision = revision ? Integer(revision) : nil

      return diagnose_cas(failed, expected_revision, revision) if fencing_token.zero?

      if row[0].nil? || held_epoch != fencing_token
        raise ConflictError,
              "fencing token 过期：token=#{fencing_token} < epoch=#{held_epoch}（#{holder || '无'}），所有权已转移（DESIGN §6.5）"
      end
      raise ConflictError, "租约已过期（epoch=#{held_epoch}）：需重新 acquire" unless lease_valid

      if revision.nil?
        raise ConflictError, "Props 记录不存在：#{k}"
      end
      diagnose_cas(failed, expected_revision, revision)
    end

    def diagnose_cas(failed, expected_revision, revision)
      if revision.nil?
        raise ConflictError, "Props 记录不存在：#{revision.inspect}"
      end
      raise ConflictError, "revision CAS 失败：expected=#{expected_revision} actual=#{revision}" if failed

      raise ConflictError, "Props 写入未能生效（未知原因）"
    end
  end
end
