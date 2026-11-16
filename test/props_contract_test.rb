# frozen_string_literal: true

require_relative "test_helper"

# PropStore 合同（DESIGN §7.2/§7.4）：CAS、冲突、迁移、进程级持久
class PropsContractTest < Minitest::Test
  # 显式测试 namespace：读写/激活共用，不依赖默认值与目录名（Issue #2）
  NS = "contract-ns"

  def test_create_conflict_when_exists
    store = Troupe::MemoryPropStore.new
    store.create("ns", "Cart", "u1", { "a" => 1 }, schema_version: 1)
    assert_raises(Troupe::ConflictError) do
      store.create("ns", "Cart", "u1", { "a" => 2 }, schema_version: 1)
    end
  end

  def test_write_cas_semantics
    store = Troupe::MemoryPropStore.new
    s = store.create("ns", "Cart", "u1", { "a" => 1 }, schema_version: 1)
    assert_equal 1, s.revision

    s2 = store.write("ns", "Cart", "u1", { "a" => 2 }, expected_revision: 1, schema_version: 1)
    assert_equal 2, s2.revision

    e = assert_raises(Troupe::ConflictError) do
      store.write("ns", "Cart", "u1", { "a" => 3 }, expected_revision: 1, schema_version: 1)
    end
    assert_match(/revision CAS 失败/, e.message)
    assert_equal 2, store.read("ns", "Cart", "u1").revision # 未被盲目重写
  end

  def test_fencing_token_rejects_stale_writer
    store = Troupe::MemoryPropStore.new(ownership: true)
    store.create("ns", "Cart", "u1", { "a" => 1 }, schema_version: 1, fencing_token: 2)
    e = assert_raises(Troupe::ConflictError) do
      store.write("ns", "Cart", "u1", { "a" => 2 }, expected_revision: 1, schema_version: 1, fencing_token: 1)
    end
    assert_match(/fencing token 过期/, e.message)
  end

  def test_schema_migration_on_activation
    actor_v1 = Class.new(Troupe::Actor) do
      role_id "migr"
      schema_version 1
      initial_props { { "old" => 5 } }
      def get; props; end
    end
    actor_v2 = Class.new(Troupe::Actor) do
      role_id "migr"
      schema_version 2
      initial_props { { "old" => 0, "new" => 0 } }
      def get; props; end

      def migrate_props(stored, _from)
        stored.merge("new" => stored["old"] * 10)
      end
    end

    # 用 v1 写入旧 schema（显式 namespace：不依赖默认值/目录名，Issue #2）
    t1 = Troupe::Testing.rehearsal(actors: [actor_v1], prop_store: (store = Troupe::MemoryPropStore.new),
                                   namespace: NS)
    t1.cast(actor_v1, "m1").get
    t1.shutdown!

    # 用 v2 激活：触发迁移并 CAS 提交
    t2 = Troupe::Testing.rehearsal(actors: [actor_v2], prop_store: store, namespace: NS)
    props = t2.cast(actor_v2, "m1").get
    assert_equal({ "old" => 5, "new" => 50 }, props)
    stored = store.read(NS, "migr", "m1")
    assert_equal 2, stored.schema_version
    t2.shutdown!
  end

  # 逐级迁移（Issue #3）：v1 → v2 → v3 每步只走一版，累积结果在最终 CAS 提交
  def test_stepwise_migration_v1_to_v3
    steps = []
    actor_v3 = Class.new(Troupe::Actor) do
      role_id "multimigr"
      schema_version 3
      initial_props { { "v" => 0, "log" => [] } }
      def get; props; end

      define_method(:migrate_props) do |stored, from|
        steps << from
        case from
        when 1 then stored.merge("v" => stored["v"] + 1)
        when 2 then stored.merge("v" => stored["v"] * 10, "log" => Array(stored["log"]) + ["done"])
        end
      end
    end
    store = Troupe::MemoryPropStore.new
    store.create(NS, "multimigr", "mm1", { "v" => 5 }, schema_version: 1)
    troupe = Troupe::Testing.rehearsal(actors: [actor_v3], prop_store: store, namespace: NS)
    # 逐步计算：v1 存量 5 → (5+1) → ×10 = 60
    assert_equal({ "v" => 60, "log" => ["done"] }, troupe.cast(actor_v3, "mm1").get)
    assert_equal [1, 2], steps, "迁移按 v→v+1 逐级执行"
    assert_equal 3, store.read(NS, "multimigr", "mm1").schema_version
    troupe.shutdown!
  end

  # 缺失中间迁移：v1 存量 + 类 v3 只实现了 1→2，第二步 2→3 未提供 → 激活显式报错
  def test_missing_middle_migration_step_fails_activation
    actor = Class.new(Troupe::Actor) do
      role_id "halfmigr"
      schema_version 3
      initial_props { { "x" => 0 } }
      def get; props; end

      define_method(:migrate_props) do |stored, from|
        raise Troupe::MigrationError, "halfmigr 缺少 #{from}→#{from + 1} 迁移步骤" unless from == 1

        stored.merge("x" => stored["x"] + 1)
      end
    end
    store = Troupe::MemoryPropStore.new
    store.create(NS, "halfmigr", "hm1", { "x" => 0 }, schema_version: 1)
    troupe = Troupe::Testing.rehearsal(actors: [actor], prop_store: store, namespace: NS)
    e = assert_raises(Troupe::MigrationError) { troupe.cast(actor, "hm1").get }
    assert_match(/缺少 2→3/, e.message)
    # 失败不落盘：存储仍是 v1 原始 Props，未写半迁移状态
    stored = store.read(NS, "halfmigr", "hm1")
    assert_equal({ "x" => 0 }, stored.props)
    assert_equal 1, stored.schema_version
    troupe.shutdown!
  end

  def test_missing_migration_fails_activation_explicitly
    actor = Class.new(Troupe::Actor) do
      role_id "nomig"
      schema_version 3
      initial_props { { "x" => 1 } }
      def get; props; end
    end
    store = Troupe::MemoryPropStore.new
    store.create(NS, "nomig", "n1", { "x" => 0 }, schema_version: 1)
    troupe = Troupe::Testing.rehearsal(actors: [actor], prop_store: store, namespace: NS)
    e = assert_raises(Troupe::MigrationError) { troupe.cast(actor, "n1").get }
    assert_match(/migrate_props/, e.message)
    assert_match(/nomig/, e.message)
    troupe.shutdown!
  end

  def test_validate_props_failure_rejects_activation
    actor = Class.new(Troupe::Actor) do
      role_id "valid"
      initial_props { { "x" => 1 } }
      def get; props; end

      def validate_props!(p)
        raise ArgumentError, "x 必须为正数" unless p["x"].to_f.positive?
      end
    end
    store = Troupe::MemoryPropStore.new
    store.create(NS, "valid", "v1", { "x" => -1 }, schema_version: 1)
    troupe = Troupe::Testing.rehearsal(actors: [actor], prop_store: store, namespace: NS)
    e = assert_raises(Troupe::ActivationError) { troupe.cast(actor, "v1").get }
    assert_match(/x 必须为正数/, e.message)
    troupe.shutdown!
  end

  def test_pstore_durability_across_store_instances
    Dir.mktmpdir do |dir|
      path = File.join(dir, "props.pstore")
      s1 = Troupe::PStorePropStore.new(path)
      s1.create("ns", "Cart", "u1", { "a" => 1 }, schema_version: 1)
      s1.write("ns", "Cart", "u1", { "a" => 2 }, expected_revision: 1, schema_version: 1)
      s1.close

      s2 = Troupe::PStorePropStore.new(path) # 进程级持久：新实例读回
      stored = s2.read("ns", "Cart", "u1")
      assert_equal({ "a" => 2 }, stored.props)
      assert_equal 2, stored.revision
      s2.close
    end
  end

  def test_pstore_cas_conflict
    Dir.mktmpdir do |dir|
      store = Troupe::PStorePropStore.new(File.join(dir, "props.pstore"))
      store.create("ns", "C", "u", { "n" => 0 }, schema_version: 1)
      store.write("ns", "C", "u", { "n" => 1 }, expected_revision: 1, schema_version: 1)
      assert_raises(Troupe::ConflictError) do
        store.write("ns", "C", "u", { "n" => 2 }, expected_revision: 1, schema_version: 1)
      end
    end
  end

  def test_troupe_level_pstore_restart_recovery
    Dir.mktmpdir do |dir|
      actor = Class.new(Troupe::Actor) do
        role_id "persist"
        initial_props { { "n" => 0 } }
        def inc
          props["n"] += 1
          save_props
          props["n"]
        end
      end
      t1 = Troupe::Testing.rehearsal(actors: [actor], prop_store: :pstore, props_dir: dir)
      assert_equal 3, 3.times.map { t1.cast(actor, "p1").inc }.last
      t1.shutdown!

      # 进程重启（新 Troupe 实例同目录）：从最后已提交快照（n=3）继续，而不是 initialProps
      t2 = Troupe::Testing.rehearsal(actors: [actor], prop_store: :pstore, props_dir: dir)
      assert_equal 4, t2.cast(actor, "p1").inc
      t2.shutdown!
    end
  end
end
