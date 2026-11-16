# frozen_string_literal: true

require_relative "test_helper"

# Show → Actor Audience（ROADMAP M3，对齐 troupe.cr M4 / ROADMAP 纪律「明确不叫流」）：
# 订阅/投递经完整 Turn 管道（白名单/背压/超时/串行），外部订阅者走边界回调；
# 在线尽力而为、无重投承诺；跨 Stage 转发；慢订阅者隔离。
class ShowAudienceTest < Minitest::Test
  class AudienceActor < Troupe::Actor
    role_id "audience"
    initial_props { { "seen" => [], "count" => 0 } }

    # Audience 交付走完整 Turn 管道：业务方法 + save_props（可 CAS 提交）
    def on_show(envelope)
      props["seen"] << { "topic" => envelope["topic"], "v" => envelope["payload"]["v"] }
      props["count"] += 1
      save_props
      props["count"]
    end

    def slow_show(envelope)
      sleep(1.0) # 慢订阅者：publish 的 deadline 内完不成
      props["count"] += 1
      save_props
    end

    def count
      props["count"]
    end

    def seen
      props["seen"]
    end
  end

  class BadActor < Troupe::Actor
    role_id "badaud"
    initial_props { { "count" => 0 } }

    def on_show(envelope)
      props["count"] += 1
      save_props
      raise ArgumentError, "Audience Turn 业务异常（尽力而为：放弃不重投）"
    end

    def count
      props["count"]
    end
  end

  def setup
    @troupes = []
  end

  def teardown
    @troupes.each { |t| t.shutdown! rescue nil }
  end

  def rehearsal(**opts)
    t = Troupe::Testing.rehearsal(**opts)
    @troupes << t
    t
  end

  def test_actor_audience_delivers_via_full_turn_pipeline
    troupe = rehearsal(actors: [AudienceActor])
    show = troupe.show("orders")
    show.actor_subscribe("audience", "a1")

    report = show.publish({ "v" => 1 })
    assert_equal 1, report.actors_ok
    assert_equal 0, report.actors_failed

    # 完整管道：业务提交已落（save_props CAS 成功）
    wait_until { troupe.cast(AudienceActor, "a1").count == 1 }
    assert_equal [{ "topic" => "orders", "v" => 1 }], troupe.cast(AudienceActor, "a1").seen
  end

  def test_actor_subscribe_validates_whitelist_and_role
    troupe = rehearsal(actors: [AudienceActor])
    show = troupe.show("orders")

    e = assert_raises(Troupe::UnknownRoleError) { show.actor_subscribe("nobody", "a") }
    assert_match(/未注册角色/, e.message)

    # 生命周期钩子不可作为 Audience 交付目标（完整管道 = 同一信任边界）
    e = assert_raises(Troupe::UnknownMethodError) { show.actor_subscribe("audience", "a1", :on_stage) }
    assert_match(/白名单/, e.message)
  end

  def test_external_callback_isolated_and_reported
    troupe = rehearsal(actors: [AudienceActor])
    show = troupe.show("events")
    received = Queue.new
    id = show.external_subscribe { |m| received << m }

    report = show.publish({ "v" => 2 })
    assert_equal 1, report.external_ok
    msg = received.pop
    assert_equal "events", msg["topic"]
    assert_equal 2, msg["payload"]["v"]

    assert_equal true, show.external_unsubscribe(id)
    report = show.publish({ "v" => 3 })
    assert_equal 0, report.external_ok
    assert_equal 0, show.subscriber_count
  end

  # 在线尽力而为：Audience Turn 业务异常 → 计 failed、不重投（离线不保证）
  def test_failed_turn_counted_not_redelivered
    troupe = rehearsal(actors: [BadActor])
    show = troupe.show("orders")
    show.actor_subscribe("badaud", "b1")

    report = show.publish({ "v" => 1 })
    assert_equal 1, report.actors_failed, "Turn 异常计入 failed（尽力而为）"
    wait_until { troupe.cast(BadActor, "b1").count == 1 } # Turn 执行过（副作用已提交）
    sleep 0.3
    assert_equal 1, troupe.cast(BadActor, "b1").count, "不重投（无重投承诺）"
  end

  # 慢订阅者隔离：deadline 内未完成 → 计 failed，不拖垮发布者与其他订阅者
  def test_slow_subscriber_isolated
    troupe = rehearsal(actors: [AudienceActor])
    show = troupe.show("orders")
    show.actor_subscribe("audience", "slow-a", :slow_show)
    show.actor_subscribe("audience", "fast-a")

    t0 = Troupe::Util.mono
    report = show.publish({ "v" => 9 }, delivery_deadline: 0.3)
    elapsed = Troupe::Util.mono - t0
    assert_equal 1, report.actors_ok, "快订阅者正常交付"
    assert_equal 1, report.actors_failed, "慢订阅者 deadline 内未完成计 failed"
    assert_operator elapsed, :<, 2.0, "发布者不被慢订阅者拖住（有界等待）"

    # 快订阅者的交付已完成（不受慢订阅者影响）
    wait_until { troupe.cast(AudienceActor, "fast-a").count == 1 }
  end

  # 跨 Stage 转发：订阅注册在本 Stage，Audience Actor 环归属另一 Stage → route 转发
  def test_cross_stage_show_forward
    t1 = Troupe.form(actors: [AudienceActor], prop_store: Troupe::MemoryPropStore.new, port: 0, join_timeout: "5s")
    @troupes << t1
    t2 = Troupe.form(actors: [AudienceActor], prop_store: Troupe::MemoryPropStore.new,
                     port: 0, seeds: [t1.advertise], join_timeout: "5s")
    @troupes << t2
    wait_until { t1.roster.alive_peers.include?(t2.advertise) }

    # 找环上归属 t2 的 Audience Actor
    key = (0..50).find { |i| t1.playbill.owner_address(t1.config.namespace, "audience", "x#{i}") == t2.advertise }
    refute_nil key, "环上应有归 t2 的 key"

    show = t1.show("orders")
    show.actor_subscribe("audience", "x#{key}") # 订阅在 t1，Actor 归 t2
    report = show.publish({ "v" => 42 })
    assert_equal 1, report.actors_ok, "跨 Stage 转发成功"
    wait_until(10) { t2.cast(AudienceActor, "x#{key}").count == 1 }
    assert_equal 42, t2.cast(AudienceActor, "x#{key}").seen[0]["v"]
    assert_equal 1, t2.stage_manager.cell_count, "Actor 在归属 Stage 激活"
  end
end
