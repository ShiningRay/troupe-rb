# frozen_string_literal: true

require_relative "test_helper"

# 协作取消（Issue #7，对齐 Orleans 10.4 advisory 语义）：
# 取消是「建议」不是「回滚」——排队阶段整体拒绝（未开始、无副作用）、
# 执行阶段 Actor 在检查点自愿早停；不向调用方伪造失败（结果未知 ≠ 失败）；
# 未声明 cancellable 的方法行为与旧版本完全一致（回归锁死）。
class CancelTest < Minitest::Test
  class LoadActor < Troupe::Actor
    role_id "load"
    initial_props { { "ticks" => 0, "notices" => 0 } }

    cancellable :chunk_work

    def chunk_work(total = 50)
      total.times do
        break if cancelled? # 检查点：自愿早停

        sleep 0.02
        props["ticks"] += 1
      end
      save_props # 早停后的副作用照常提交
      props["ticks"]
    end

    def on_cancel
      props["notices"] += 1
    end

    def ticks
      props["ticks"]
    end

    def notices
      props["notices"]
    end
  end

  class PlainActor < Troupe::Actor
    role_id "plain"
    initial_props { { "ran" => 0 } }

    def work(ms = 50)
      sleep(ms / 1000.0)
      props["ran"] += 1
      save_props
      props["ran"] # save_props 返回 revision，业务值单独返回
    end

    def ran
      props["ran"]
    end
  end

  class GateActor < Troupe::Actor
    role_id "gate"
    initial_props { { "ran" => [] } }

    cancellable :job

    def park
      sleep 0.25
    end

    def job
      props["ran"] << "job"
      save_props
    end

    def ran
      props["ran"]
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

  # 调用方超时 → 目标收到取消通知（advisory）；长循环在下一个检查点退出；
  # 调用方仍只看到结果未知，不伪造失败
  def test_timeout_notifies_target_and_loop_exits_at_checkpoint
    troupe = rehearsal(actors: [LoadActor])
    agent = troupe.cast(LoadActor, "w1")
    agent.ticks # 激活

    e = assert_raises(Troupe::CallTimeoutError) { agent.with_timeout("0.12s").chunk_work(50) }
    assert_match(/结果未知/, e.message) # 取消不改变结果未知语义

    wait_until(8) { agent.notices >= 1 } # on_cancel 钩子已触发（计数器 +1）
    wait_until(8) { troupe.cast(LoadActor, "w1").ticks < 50 } # 长循环在检查点退出
    assert_operator troupe.cast(LoadActor, "w1").ticks, :>, 0, "已产生的部分副作用照常提交"
  end

  # 未声明 cancellable 的方法：调用方超时不发送取消，执行完整跑完（行为与旧版本一致）
  def test_non_cancellable_method_unaffected_by_timeout
    troupe = rehearsal(actors: [PlainActor])
    agent = troupe.cast(PlainActor, "p1")
    agent.ran

    assert_raises(Troupe::CallTimeoutError) { agent.with_timeout("0.1s").work(400) }
    sleep 0.5
    assert_equal 1, agent.ran, "普通方法完整执行（无取消投递）"
    assert_equal 2, troupe.stage_manager.inspect_cell("plain", "p1")["revision"], "副作用照常提交"
  end

  # cancel 帧打到非 cancellable 在飞 Call：无取消状态 → no-op，调用正常完成
  def test_cancel_frame_on_non_cancellable_call_is_noop
    troupe = rehearsal(actors: [PlainActor])
    agent = troupe.cast(PlainActor, "p2")
    agent.ran

    result = Thread.new { agent.work(150) }
    sleep 0.05 # 确保 work 已开始执行
    assert_nil troupe.stage_manager.cancel_call("plain", "p2", "nonexistent-id"), "advisory：找不到为 nil"
    assert_equal 1, result.value, "非 cancellable 执行不受影响"
  end

  # 排队阶段取消：未开始执行的 Call 整体拒绝（无副作用），等待方收到 CallCancelledError
  def test_queued_stage_cancel_rejects_without_execution
    troupe = rehearsal(actors: [GateActor])
    agent = troupe.cast(GateActor, "g1")
    agent.ran # 激活

    gate = Thread.new { agent.park } # 占住串行通道
    sleep 0.05

    queued = Troupe::Call.new(namespace: troupe.config.namespace, role_id: "gate", stage_name: "g1",
                              method: :job, args: [], deadline_ms: Troupe::Util.now_ms + 5000,
                              source: :local, cancellable: true)
    t = Thread.new do
      begin
        troupe.route(queued)
        :completed
      rescue Troupe::CallCancelledError
        :cancelled
      end
    end
    sleep 0.05 # 入队

    assert_equal :queued, troupe.stage_manager.cancel_call("gate", "g1", queued.call_id)
    assert_equal :cancelled, t.value, "等待方收到排队阶段取消（拒绝，非结果未知）"
    gate.join
    assert_equal [], agent.ran, "排队阶段取消：未执行、无副作用"
  end

  # 排队阶段取消对非 cancellable Call 无效（回归锁）：照常执行
  def test_queued_cancel_ignores_non_cancellable_call
    troupe = rehearsal(actors: [GateActor])
    agent = troupe.cast(GateActor, "g2")
    agent.ran

    gate = Thread.new { agent.park }
    sleep 0.05
    queued = Troupe::Call.new(namespace: troupe.config.namespace, role_id: "gate", stage_name: "g2",
                              method: :job, args: [], deadline_ms: Troupe::Util.now_ms + 5000,
                              source: :local) # 未标注 cancellable
    t = Thread.new { troupe.route(queued) }
    sleep 0.05

    assert_nil troupe.stage_manager.cancel_call("gate", "g2", queued.call_id), "非 cancellable 不受取消影响"
    gate.join
    t.join
    assert_equal ["job"], agent.ran, "照常执行（旧版本行为）"
  end

  # 跨 Stage：cancel 控制帧经现有 codec/信任边界投递到目标 Stage
  def test_cross_stage_cancel_frame_reaches_owner
    store = Troupe::MemoryPropStore.new(ownership: true)
    t1 = Troupe.form(actors: [LoadActor], prop_store: store, port: 0, join_timeout: "5s", ownership_lease: "10s")
    @troupes << t1
    t2 = Troupe.form(actors: [LoadActor], prop_store: store, port: 0, seeds: [t1.advertise],
                     join_timeout: "5s", ownership_lease: "10s")
    @troupes << t2
    wait_until { t1.roster.alive_peers.include?(t2.advertise) }

    key = (0..50).find { |i| t1.playbill.owner_address(t1.config.namespace, "load", "x#{i}") == t2.advertise }
    refute_nil key, "环上应有归 t2 的 key"
    agent = t1.cast(LoadActor, "x#{key}")
    agent.ticks # 激活（在 t2）

    assert_raises(Troupe::CallTimeoutError) { agent.with_timeout("0.12s").chunk_work(50) }
    wait_until(8) { t2.cast(LoadActor, "x#{key}").notices >= 1 } # cancel 帧已到 t2
    wait_until(8) { t2.cast(LoadActor, "x#{key}").ticks < 50 } # 检查点早停
  end

  # 取消帧在 token 校验下被拒（不引入新信任边界）：无 token 的 cancel 帧断连
  def test_cancel_frame_requires_cluster_token
    t1 = Troupe.form(actors: [LoadActor], port: 0, cluster_token: "sekrit", join_timeout: "5s")
    @troupes << t1
    host, port = t1.advertise.split(":")
    sock = TCPSocket.new(host, Integer(port, 10))
    sock.write([JSON.generate({ "t" => "hello", "v" => Troupe::PROTOCOL_VERSION, "token" => "sekrit" }).bytesize].pack("V") +
              JSON.generate({ "t" => "hello", "v" => Troupe::PROTOCOL_VERSION, "token" => "sekrit" }))
    resp = Troupe::Transport.new(nil).send(:read_frame, sock) # read_frame 已做 JSON 解析
    assert_equal true, resp["ok"], "正确 token 的 hello 通过"
    sock.write([JSON.generate({ "t" => "cancel", "callId" => "x" }).bytesize].pack("V") +
               JSON.generate({ "t" => "cancel", "callId" => "x" })) # 无 token
    sleep 0.1
    assert_raises(EOFError, IOError) { Troupe::Transport.new(nil).send(:read_frame, sock) }
    sock.close
  end
end
