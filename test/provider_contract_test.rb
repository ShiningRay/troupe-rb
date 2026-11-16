# frozen_string_literal: true

require_relative "test_helper"
require "fileutils"

# Provider 契约测试套件（M2，对齐 troupejs「新 Provider 必须过契约测试套件」纪律）：
# 同一套断言跑全部 PropStore Provider——CAS / 冲突 / fencing / 删除 / 能力矩阵，
# 有所有权的 Provider（Memory/PG）加跑所有权契约（租约 / 单调 epoch / 接管前移 fence）。
# 测试不掩盖部署差异：PG 走真实 PostgreSQL（TROUPE_TEST_PG，CI 必跑 leg——不可用即失败，
# 不是 skip）。
module ProviderContract
  NS = "provider-ns"

  attr_reader :store

  def test_read_missing_returns_nil
    assert_nil store.read(NS, "none", "u1")
  end

  def test_create_then_conflict
    s = store.create(NS, "C", "u1", { "a" => 1 }, schema_version: 1)
    assert_equal 1, s.revision
    e = assert_raises(Troupe::ConflictError) do
      store.create(NS, "C", "u1", { "a" => 2 }, schema_version: 1)
    end
    assert_match(/已存在/, e.message)
  end

  def test_write_cas_semantics
    store.create(NS, "C", "u2", { "n" => 0 }, schema_version: 1)
    s2 = store.write(NS, "C", "u2", { "n" => 1 }, expected_revision: 1, schema_version: 1)
    assert_equal 2, s2.revision

    e = assert_raises(Troupe::ConflictError) do
      store.write(NS, "C", "u2", { "n" => 3 }, expected_revision: 1, schema_version: 1)
    end
    assert_match(/revision CAS 失败/, e.message)
    assert_equal 2, store.read(NS, "C", "u2").revision, "CAS 失败不被盲目重写"
  end

  def test_fencing_token_rejects_stale_writer
    store.create(NS, "C", "u3", { "n" => 0 }, schema_version: 1, fencing_token: 3)
    e = assert_raises(Troupe::ConflictError) do
      store.write(NS, "C", "u3", { "n" => 1 }, expected_revision: 1, schema_version: 1, fencing_token: 2)
    end
    assert_match(/fencing/, e.message)
  end

  def test_write_persists_and_reads_back
    store.create(NS, "C", "u4", { "v" => "中文", "nested" => { "a" => [1, 2] } }, schema_version: 2)
    store.write(NS, "C", "u4", { "v" => "中文2", "nested" => { "a" => [3] } }, expected_revision: 1, schema_version: 2)
    stored = store.read(NS, "C", "u4")
    assert_equal({ "v" => "中文2", "nested" => { "a" => [3] } }, stored.props)
    assert_equal 2, stored.schema_version
    assert_equal 2, stored.revision
  end

  def test_delete_removes_record
    store.create(NS, "C", "u5", { "a" => 1 }, schema_version: 1)
    store.delete(NS, "C", "u5")
    assert_nil store.read(NS, "C", "u5")
  end

  def test_capabilities_declared
    caps = store.capabilities
    assert caps.is_a?(Troupe::StoreCapabilities)
    assert_equal expected_cross_node_safe?, caps.cross_node_safe,
                 "#{store.class.name} 能力声明与实现不符（生产门禁依据）"
  end

  # 各 Provider 自述：本地 Provider 一律 false；PG Provider 在其类内覆写为 true
  def expected_cross_node_safe?
    false
  end

  def test_isolation_between_stage_names
    store.create(NS, "C", "iso-a", { "n" => 1 }, schema_version: 1)
    store.create(NS, "C", "iso-b", { "n" => 2 }, schema_version: 1)
    assert_equal 1, store.read(NS, "C", "iso-a").props["n"]
    assert_equal 2, store.read(NS, "C", "iso-b").props["n"]
  end
end

# 所有权契约（租约 + 单调 epoch + fencing 前移）：仅 ownership_enabled? Provider
module OwnershipContract
  NS = ProviderContract::NS
  attr_reader :store

  def test_ownership_acquire_renew_release
    now = Troupe::Util.now_ms
    r1 = store.acquire_ownership(NS, "O", "u", owner: "A", lease_ms: 60_000)
    assert_equal 1, r1.epoch
    assert_equal "A", r1.owner

    r2 = store.acquire_ownership(NS, "O", "u", owner: "A", lease_ms: 60_000)
    assert_equal 1, r2.epoch, "同 owner 重入不涨 epoch"

    assert_nil store.acquire_ownership(NS, "O", "u", owner: "B", lease_ms: 60_000), "他人持有效租约取不到"

    expire_ownership!(NS, "O", "u")
    r3 = store.acquire_ownership(NS, "O", "u", owner: "B", lease_ms: 60_000)
    assert_equal 2, r3.epoch, "租约过期被顶替：epoch 单调 +1"

    refute store.renew_ownership(NS, "O", "u", owner: "A", expected_epoch: 1, lease_ms: 60_000), "旧持有者续租被拒"
    store.release_ownership(NS, "O", "u", owner: "B", expected_epoch: 2)
    expire_ownership!(NS, "O", "u")
    r4 = store.acquire_ownership(NS, "O", "u", owner: "C", lease_ms: 60_000)
    assert_equal 3, r4.epoch, "release 保留 epoch 墓碑：不回退"
  end

  def test_takeover_bumps_fence_stale_writer_rejected
    # 真实时序：A 先取得所有权（epoch 1）并写 Props（fence=1）→ 租约过期 → B 接管（epoch 2）
    a = store.acquire_ownership(NS, "O", "f", owner: "A", lease_ms: 60_000)
    assert_equal 1, a.epoch
    store.create(NS, "O", "f", { "n" => 1 }, schema_version: 1, fencing_token: a.epoch)
    expire_ownership!(NS, "O", "f")
    rec = store.acquire_ownership(NS, "O", "f", owner: "B", lease_ms: 60_000)
    assert_equal 2, rec.epoch

    # 旧 epoch（1）写入被拒
    e = assert_raises(Troupe::ConflictError) do
      store.write(NS, "O", "f", { "n" => 999 }, expected_revision: 1, schema_version: 1, fencing_token: 1)
    end
    assert_match(/fencing/, e.message)

    # 新 epoch 写入成功，fence 前移
    store.write(NS, "O", "f", { "n" => 2 }, expected_revision: 1, schema_version: 1, fencing_token: 2)
    assert_equal 2, store.read(NS, "O", "f").fence
  end
end

class MemoryProviderContractTest < Minitest::Test
  include ProviderContract

  def setup
    @store = Troupe::MemoryPropStore.new(ownership: true)
  end

  def expire_ownership!(ns, role_id, name)
    store.ownership_record(ns, role_id, name)[:lease_until] = Troupe::Util.now_ms - 1
  end
end

class MemoryOwnershipContractTest < Minitest::Test
  include OwnershipContract

  def setup
    @store = Troupe::MemoryPropStore.new(ownership: true)
  end

  def expire_ownership!(ns, role_id, name)
    store.ownership_record(ns, role_id, name)[:lease_until] = Troupe::Util.now_ms - 1
  end
end

class PStoreProviderContractTest < Minitest::Test
  include ProviderContract

  def setup
    @dir = Dir.mktmpdir
    @store = Troupe::PStorePropStore.new(File.join(@dir, "props.pstore"))
  end

  def teardown
    @store.close
    FileUtils.remove_entry(@dir)
  end

  def expire_ownership!(*)
    raise Minitest::Skip, "PStore 无所有权"
  end
end

class SqliteProviderContractTest < Minitest::Test
  include ProviderContract

  def setup
    require "troupe/props/sqlite_store"
    @dir = Dir.mktmpdir
    @store = Troupe::SqlitePropStore.new(File.join(@dir, "props.db"))
  end

  def teardown
    @store.close
    FileUtils.remove_entry(@dir)
  end

  def expire_ownership!(*)
    raise Minitest::Skip, "SQLite 无所有权"
  end
end

# PostgreSQL Provider（M2）：真实 PG 必跑——TROUPE_TEST_PG 不可用即失败（skip 即失败纪律）
class PostgresProviderContractTest < Minitest::Test
  include ProviderContract
  include OwnershipContract

  def setup
    url = ENV.fetch("TROUPE_TEST_PG", nil)
    skip "无 TROUPE_TEST_PG：PG 契约由 CI 专用 PG leg 必跑（该 leg 中环境缺失即红）" unless url

    require "troupe/props/pg_store"
    @store = Troupe::PostgresPropStore.open(url)
    @store.exec("DELETE FROM troupe_props WHERE actor_key LIKE '%\"#{ProviderContract::NS}\"%'")
    @store.exec("DELETE FROM troupe_ownership WHERE actor_key LIKE '%\"#{ProviderContract::NS}\"%'")
  end

  def teardown
    @store&.close
  end

  def expire_ownership!(ns, role_id, name)
    store.expire_ownership!(ns, role_id, name)
  end

  def test_db_clock_lease_and_monotonic_takeover
    # 租约判定用数据库时钟：过期由 expire_ownership!（to_timestamp(0)）与 now() 比较产生
    store.acquire_ownership(NS, "O", "dbclock", owner: "A", lease_ms: 60_000)
    store.expire_ownership!(NS, "O", "dbclock")
    assert_equal 2, store.acquire_ownership(NS, "O", "dbclock", owner: "B", lease_ms: 60_000).epoch
  end

  def expected_cross_node_safe?
    true # PG Provider：cross_node_safe 生产门禁的唯一合法来源
  end

  def test_capability_flags_full
    assert_equal true, store.capabilities.supports_fencing
    assert_equal true, store.capabilities.supports_transactions
  end

  def test_report_real_topology
    # 真实拓扑与数据库版本可见（ROADMAP M2 验收要求测试输出真实拓扑）
    version = store.server_version
    assert_match(/PostgreSQL/i, version, "真实 PG 连接：#{version[0, 60]}")
  end
end

# CueStore 契约（M2）：due/claim CAS/complete 裁决/注销/租约过期重投
module CueStoreContract
  attr_reader :cues

  NS = "cue-contract-ns"

  def record(id, due_ms = nil)
    Troupe::ReminderRecord.new(id: id, namespace: NS, role_id: "R", stage_name: "s",
                               name: "beat", payload: { "k" => 1 }, schedule: "every:60s",
                               next_due: due_ms || (Troupe::Util.now_ms - 1000))
  end

  def test_upsert_find_roundtrip
    cues.upsert(record("c1"))
    found = cues.find("c1")
    refute_nil found
    assert_equal NS, found.namespace
    assert_equal "beat", found.name
    assert_equal({ "k" => 1 }, found.payload)
    assert_equal 0, found.status_version
    assert_equal "active", found.status
  end

  def test_upsert_updates_definition_not_next_due
    cues.upsert(record("c1", 5_000))
    cues.upsert(record("c1", 9_999))
    assert_equal 5_000, cues.find("c1").next_due, "upsert 只更新定义、不动 next_due"
  end

  def test_due_and_claim_cas
    cues.upsert(record("c2"))
    # 共享存储上可能有其他 namespace 的到期提醒（多 Stage 共库）：按本 ns 过斷言
    due = cues.due(Troupe::Util.now_ms + 100, 50).select { |r| r.namespace == NS }
    assert_equal ["c2"], due.map(&:id)

    owner_a = "stage-a"
    v1 = cues.claim("c2", owner: owner_a, lease_until: Troupe::Util.now_ms + 30_000)
    refute_nil v1, "首次认领成功"
    v2 = cues.claim("c2", owner: "stage-b", lease_until: Troupe::Util.now_ms + 30_000)
    assert_nil v2, "有效租约内他人认领失败（CAS）"

    # 租约过期 → 重新可认领（至少一次：执行中宕机重投）
    expire_cue_lease!("c2")
    v3 = cues.claim("c2", owner: "stage-b", lease_until: Troupe::Util.now_ms + 30_000)
    refute_nil v3, "租约过期重投"
    assert_operator v3, :>, v1, "statusVersion 单调"

    # complete 以 statusVersion 裁决
    assert_equal true, cues.complete("c2", expected_status_version: v3, next_due: Troupe::Util.now_ms + 60_000)
    assert_equal false, cues.complete("c2", expected_status_version: v3, next_due: 0), "旧版本裁决失败"
    assert_equal "active", cues.find("c2").status
  end

  def test_cancel_removes
    cues.upsert(record("c3"))
    cues.cancel("c3")
    assert_nil cues.find("c3")
  end
end

class MemoryCueStoreContractTest < Minitest::Test
  include CueStoreContract

  def setup
    @cues = Troupe::MemoryCueStore.new
  end

  def expire_cue_lease!(id)
    rec = @cues.records.find { |r| r.id == id }
    rec.lease_until = Troupe::Util.now_ms - 1
  end
end

class PostgresCueStoreContractTest < Minitest::Test
  include CueStoreContract

  def setup
    url = ENV.fetch("TROUPE_TEST_PG", nil)
    skip "无 TROUPE_TEST_PG：PG 契约由 CI 专用 PG leg 必跑（该 leg 中环境缺失即红）" unless url

    require "troupe/cues/pg_cue_store"
    @cues = Troupe::PostgresCueStore.open(url)
    @cues.instance_variable_get(:@conn).exec_params(
      "DELETE FROM troupe_cues WHERE namespace = $1 OR namespace LIKE $2",
      [CueStoreContract::NS, "mproc-%"]
    )
  end

  def teardown
    @cues&.close
  end

  def expire_cue_lease!(id)
    @cues.instance_variable_get(:@conn).exec_params(
      "UPDATE troupe_cues SET lease_until = to_timestamp(0) WHERE id = $1", [id]
    )
  end

  def test_db_clock_reclaim
    cues.upsert(record("c4"))
    v1 = cues.claim("c4", owner: "stage-a", lease_until: Troupe::Util.now_ms + 30_000)
    refute_nil v1
    # DB 时钟：lease_until 由 claim 写入 DB，过期判定 now() 比较（客户端时钟不参与）
    expire_cue_lease!("c4")
    v2 = cues.claim("c4", owner: "stage-b", lease_until: Troupe::Util.now_ms + 30_000)
    assert_operator v2, :>, v1, "DB 时钟租约过期重投"
  end
end
