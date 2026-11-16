# frozen_string_literal: true

require_relative "test_helper"

# 持久流 + Outbox + Inbox + 事件溯源（ROADMAP M4，对齐 troupe.cr stream/outbox/event_sourcing）：
# 流与 Show realtime 显式分开（seq/replay/retain vs 尽力 fan-out）。
class M4StreamsTest < Minitest::Test
  class OutboxActor < Troupe::Actor
    role_id "outbox"
    initial_props { { "n" => 0 } }

    def bump_and_emit(v = 1)
      props["n"] += v
      emit_event("orders", { "v" => v, "n" => props["n"] })
      save_props
      props["n"]
    end

    def bump_only(v = 1)
      props["n"] += v
      save_props
      props["n"] # save_props 返回 revision，业务值单独返回
    end

    def value
      props["n"]
    end
  end

  # ---- 流合同（Memory + PG 同套断言） ----

  def make_stream
    if (url = ENV["TROUPE_TEST_PG"])
      require "troupe/streams/pg_stream_store"
      store = Troupe::PostgresStreamStore.open(url)
      store.instance_variable_get(:@conn).exec_params(
        "DELETE FROM troupe_stream WHERE topic LIKE $1; " \
        "DELETE FROM troupe_stream_cursor WHERE topic LIKE $1", ["m4t%"]
      ) rescue nil
      [store, true]
    else
      [Troupe::MemoryStreamStore.new, false]
    end
  end

  def test_stream_append_read_ack_cursor_retain
    store, = make_stream
    topic = "m4t-#{rand(1_000_000)}"

    s1 = store.append(topic, { "i" => 1 })
    s2 = store.append(topic, { "i" => 2 })
    s3 = store.append(topic, { "i" => 3 })
    assert_operator s1, :<, s2
    assert_operator s2, :<, s3, "seq 单调递增"

    events = store.read_from(topic, s1, 10)
    assert_equal [s2, s3], events.map(&:seq), "read_from 从 from_seq 之后（不含）"
    assert_equal({ "i" => 2 }, events[0].payload)

    # ack 只前进：回退拒绝
    assert_equal true, store.ack("c1", topic, s2)
    assert_equal s2, store.cursor("c1", topic)
    assert_equal false, store.ack("c1", topic, s1), "回退 ack 不生效"
    assert_equal s2, store.cursor("c1", topic)

    # 消费者失败不 ack → 至少一次重放：从游标处重读
    assert_equal [s3], store.read_from(topic, store.cursor("c1", topic), 10).map(&:seq)
    store.ack("c1", topic, s3)

    # 保留裁剪：被裁事件不可重放（显式代价）
    assert_equal 2, store.retain_before(topic, s2)
    assert_equal 1, store.event_count(topic)
    assert_equal [s3], store.read_from(topic, 0, 10).map(&:seq)
  end

  # 事件溯源：全量重放 == 快照 + 增量（一致性反例）
  def test_event_sourcing_snapshot_consistency
    store, = make_stream
    topic = "m4t-es-#{rand(1_000_000)}"

    [1, 2, 3, 4].each { |i| Troupe::EventSourcing.append_event(store, topic, "inc", { "delta" => i }) }
    events = store.read_from(topic, 0, 100)

    apply = ->(state, ev) { state + ev.payload["data"]["delta"] }
    full = Troupe::EventSourcing.rebuild(0, events, &apply)
    assert_equal 10, full

    snapshot_seq = events[1].seq # 快照在第二条事件后
    snapshot_state = Troupe::EventSourcing.rebuild(0, events.first(2), &apply)
    incremental = Troupe::EventSourcing.rebuild_from_snapshot(
      snapshot_state, store.read_from(topic, snapshot_seq, 100), &apply
    )
    assert_equal full, incremental, "快照 + 增量 == 全量重放（一致性契约）"
  end

  # ---- Outbox ----

  def setup
    @pg_url = ENV["TROUPE_TEST_PG"]
    if @pg_url
      require "troupe/props/pg_store"
      @direct = Troupe::PostgresPropStore.open(@pg_url)
      @direct.exec("DELETE FROM troupe_outbox WHERE actor_key LIKE '%\"m4ob\"%'") rescue nil
    end
  end

  def teardown
    @direct&.close
  end

  def form_outbox_troupe(**opts)
    if @pg_url
      t = Troupe::Testing.rehearsal(actors: [OutboxActor], prop_store: @direct, namespace: "m4ob", **opts)
    else
      t = Troupe::Testing.rehearsal(actors: [OutboxActor], namespace: "m4ob", **opts)
    end
    (@troupes ||= []) << t
    t
  end

  # emit_event + save_props → Outbox 原子落盘（与 Props 同提交）
  def test_emit_event_committed_with_props
    troupe = form_outbox_troupe
    store = troupe.prop_store
    troupe.cast(OutboxActor, "o1").bump_and_emit(5)

    counts = store.outbox_counts
    assert_equal 1, counts["pending"], "事件随 Props 提交入队"

    # Outbox record 形状
    rec = store.claim_outbox_batch(limit: 10, owner: "d1", lease_ms: 30_000).first
    refute_nil rec
    assert_equal "orders", rec.topic
    # PG 共享库上 Props 跨运行持久（n 累计）——断言本运行确定性的字段
    assert_equal 5, rec.payload["v"]
    assert_equal 1, rec.attempts
  end

  # 原子性反例：CAS 失败（save_props 抛 ConflictError）→ 事件同样不落
  def test_outbox_not_committed_on_failed_props_write
    troupe = form_outbox_troupe(prop_store: (store = Troupe::MemoryPropStore.new(ownership: true)))
    troupe_b = nil
    begin
      a = troupe.cast(OutboxActor, "o2")
      a.bump_and_emit(1)

      # B 接管（epoch 2）→ A 的旧 token 写被拒 → 事件不落
      store.ownership_record(troupe.config.namespace, "outbox", "o2")[:lease_until] =
        Troupe::Util.now_ms - 1
      troupe_b = Troupe::Testing.rehearsal(actors: [OutboxActor], prop_store: store,
                                           namespace: "m4ob", ownership_acquire_timeout: "5s")
      assert_equal 2, troupe_b.cast(OutboxActor, "o2").bump_only(1), "B 接管（epoch 2），Props 从共享存储恢复（n=1+1）"

      before_pending = store.outbox_counts["pending"].to_i
      e = assert_raises(Troupe::ConflictError) { a.bump_and_emit(99) }
      assert_match(/fencing/, e.message)

      assert_equal before_pending, store.outbox_counts["pending"].to_i,
                   "失败写的事件不落（同原子提交）：pending 不因失败写增加"
    ensure
      troupe_b&.shutdown!
    end
  end

  # dispatcher：交付 → 标记 sent；失败 → 退避重投 → 死信；Inbox 幂等去重
  def test_outbox_dispatcher_deliver_retry_dead_letter_and_inbox
    store = (@direct || Troupe::MemoryPropStore.new)
    troupe = form_outbox_troupe(prop_store: store)
    troupe.cast(OutboxActor, "o3").bump_and_emit(1)
    troupe.cast(OutboxActor, "o3").bump_and_emit(2)

    delivered_ids = []
    fail_event = nil
    dispatcher = Troupe::OutboxDispatcher.new(store, lambda { |rec|
      if rec.payload["v"] == 2 && rec.attempts < 3
        raise "交付失败（模拟外部故障）"
      end
      delivered_ids << rec.event_id
    }, batch: 10, max_attempts: 3, backoff_ms: 0)

    assert_equal 1, dispatcher.poll_once, "v=1 首轮交付成功"
    assert_equal 0, dispatcher.poll_once, "v=2 交付失败不标记（本轮 0 成功）"

    # backoff 0 → 重投：attempts 达标后成功
    assert_equal 1, dispatcher.poll_once(owner: "d2")
    assert_equal 2, delivered_ids.size, "至少一次：失败后重投成功"
    counts = store.outbox_counts
    assert_equal 2, counts["sent"], "两条已投递"
    assert_equal 0, counts["pending"].to_i
    assert_equal 0, counts["dead"].to_i
    assert_equal 0, dispatcher.poll_once, "已 sent 不再投递"

    # 死信路径：持续失败 → attempts 达 max → dead
    dead_store = Troupe::MemoryPropStore.new
    dead_troupe = Troupe::Testing.rehearsal(actors: [OutboxActor], prop_store: dead_store, namespace: "m4ob")
    (@troupes ||= []) << dead_troupe
    dead_troupe.cast(OutboxActor, "o4").bump_and_emit(7)
    failing = Troupe::OutboxDispatcher.new(dead_store, ->(_r) { raise "永远失败" },
                                           batch: 10, max_attempts: 2, backoff_ms: 0)
    2.times { failing.poll_once }
    assert_equal 1, dead_store.outbox_counts["dead"], "attempts 达上限 → 死信"
    assert_equal 0, failing.poll_once, "死信不再投递"
  end

  def test_inbox_dedup
    inbox = (@pg_url ? Troupe::Inbox.open(@pg_url) : Troupe::Inbox.open)
    consumer = "m4-inbox-#{rand(1_000_000)}"
    begin
      assert_equal true, inbox.record!(consumer, "evt-1"), "首次 = 执行副作用"
      assert_equal false, inbox.record!(consumer, "evt-1"), "重复 = 跳过（至少一次 → 恰好一次副作用）"
      assert_equal true, inbox.record!(consumer, "evt-2")
      assert_equal true, inbox.seen?(consumer, "evt-1")
      assert_equal false, inbox.seen?(consumer, "evt-x")
    ensure
      inbox.respond_to?(:close) && inbox.method(:close).owner != Troupe::Inbox && inbox.close
    end
  end
end
