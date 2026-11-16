# frozen_string_literal: true

require_relative "test_helper"

# 集群基础（PLAN M2/M3 验收）：TCP 组团、位置透明、线路边界、畸形帧可控拒绝、
# kill -9 级故障后 Actor 在另一 Stage 以完整 Props 重新登台（共享存储 + 所有权）。
class ClusterTest < Minitest::Test
  class WorkerActor < Troupe::Actor
    initial_props { { "n" => 0, "last" => nil } }

    def add(v = 1)
      props["n"] += v
      save_props
      props["n"]
    end

    def slow(ms)
      sleep(ms / 1000.0)
      "slow-ok"
    end

    def stash(x)
      props["last"] = x
      "stashed"
    end

    def value
      props["n"]
    end
  end

  def setup
    @troupes = []
  end

  def teardown
    @troupes.each { |t| t.shutdown! rescue nil }
  end

  def form_troupe(**opts)
    troupe = Troupe.form({ actors: [WorkerActor], prop_store: Troupe::MemoryPropStore.new,
                           port: 0, join_timeout: "5s" }.merge(opts))
    @troupes << troupe
    troupe
  end

  def test_two_stages_join_and_route_transparently
    t1 = form_troupe
    t2 = form_troupe(seeds: [t1.advertise])
    wait_until { t1.roster.alive_peers.include?(t2.advertise) }
    wait_until { t2.roster.alive_peers.include?(t1.advertise) }

    # 选一个环上归属 t2 的 key，从 t1 发起调用：位置透明
    key = (0..50).find { |i| t1.playbill.owner_address(t1.config.namespace, "Worker", "k#{i}") == t2.advertise }
    refute_nil key, "哈希环应把某些 key 分给 t2"
    agent = t1.cast(WorkerActor, "k#{key}")
    assert_equal 1, agent.add(1)
    assert_equal 2, agent.add(1) # 两次都落到 t2 的同一 Cell（严格串行）
    assert_equal 0, t1.stage_manager.cell_count, "调用方 Stage 不持有该 Actor"
    assert_equal 1, t2.stage_manager.cell_count
  end

  def test_wire_json_boundary_same_as_local
    t1 = form_troupe
    t2 = form_troupe(seeds: [t1.advertise])
    wait_until { t1.roster.alive_peers.include?(t2.advertise) }

    key = (0..50).find { |i| t1.playbill.owner_address(t1.config.namespace, "Worker", "w#{i}") == t2.advertise }
    agent = t1.cast(WorkerActor, "w#{key}")
    symbol_hash = { :name => :x } # Symbol 经线路 → String（JSON 边界语义，与本地一致）
    agent.stash(symbol_hash)
    assert_equal({ "name" => "x" }, troupe_props_of(t2, "Worker", "w#{key}")["last"])
  end

  def test_remote_deadline_and_result_unknown
    t1 = form_troupe
    t2 = form_troupe(seeds: [t1.advertise])
    wait_until { t1.roster.alive_peers.include?(t2.advertise) }
    key = (0..50).find { |i| t1.playbill.owner_address(t1.config.namespace, "Worker", "d#{i}") == t2.advertise }
    agent = t1.cast(WorkerActor, "d#{key}")

    e = assert_raises(Troupe::CallTimeoutError) do
      agent.with_timeout("0.2s").slow(600)
    end
    assert_match(/结果未知/, e.message) # 远程超时同样是结果未知，不是失败
  end

  def test_whitelist_enforced_on_wire
    t1 = form_troupe
    t2 = form_troupe(seeds: [t1.advertise])
    wait_until { t1.roster.alive_peers.include?(t2.advertise) }
    wait_until { t2.roster.alive_peers.include?(t1.advertise) } # 视图收敛，环归属一致

    # 直接构造线路帧调用生命周期钩子：接收端白名单拒绝（信任边界，DESIGN §6.1）
    call = Troupe::Call.new(namespace: t2.config.namespace, role_id: "Worker", stage_name: "evil",
                            method: :on_stage, args: [],
                            deadline_ms: Troupe::Util.now_ms + 3000, source: :remote)
    e = assert_raises(Troupe::UnknownMethodError) { t2.dispatch_inbound(call) }
    assert_match(/白名单/, e.message)
  end

  def test_malformed_frame_rejected_connection_and_process_survive
    t1 = form_troupe
    host, port = t1.advertise.split(":")

    sock = TCPSocket.new(host, port)
    sock.write([16].pack("V") + "not-json-goop!!")
    sock.close

    # 超长帧
    sock2 = TCPSocket.new(host, port)
    sock2.write([Troupe::Transport::FRAME_MAX + 1].pack("V"))
    sock2.close

    # 进程与 Stage 存活，后续调用正常
    a = t1.cast(WorkerActor, "local-ok")
    assert_equal 1, a.add(1)
  end

  # 版本协商（M1）：首帧必须 hello；非 hello 首帧显式拒绝
  def test_non_hello_first_frame_explicitly_rejected
    t1 = form_troupe
    host, port = t1.advertise.split(":")
    tr = Troupe::Transport.new(nil)

    # 合法 JSON 但不是 hello 的首帧（旧版本 trouperb 的 call 帧形态）→ 拒绝并关连接
    sock = TCPSocket.new(host, Integer(port, 10))
    frame = JSON.generate({ "t" => "call", "call" => { "callId" => "x", "method" => "add" } })
    sock.write([frame.bytesize].pack("V") + frame)
    sleep 0.1
    assert_raises(EOFError, IOError, Troupe::ProtocolError) { tr.send(:read_frame, sock) }
    sock.close

    # Stage 存活，正常调用不受影响
    a = t1.cast(WorkerActor, "version-ok")
    assert_equal 1, a.add(1)
  end

  # 版本协商（M1）：hello 携带不匹配的 protocolVersion → 显式 ok:false + 关连接
  def test_version_mismatch_hello_rejected
    t1 = form_troupe
    host, port = t1.advertise.split(":")
    tr = Troupe::Transport.new(nil)

    sock = TCPSocket.new(host, Integer(port, 10))
    hello = JSON.generate({ "t" => "hello", "v" => Troupe::PROTOCOL_VERSION + 99 })
    sock.write([hello.bytesize].pack("V") + hello)
    resp = tr.send(:read_frame, sock)
    assert_equal false, resp["ok"], "版本不匹配显式拒绝（不混跑）"
    assert_equal Troupe::PROTOCOL_VERSION, resp["v"], "响应携带本端版本"
    assert_match(/版本不匹配/, resp["error"])
    sleep 0.1
    assert_raises(EOFError, IOError) { tr.send(:read_frame, sock) } # 随后关连接
    sock.close
  end

  # M3 验收：kill -9 一个 Stage，Actor 在存活 Stage 以完整 Props 重新登台（共享存储）
  def test_stage_death_failover_with_shared_store_and_fencing
    store = Troupe::MemoryPropStore.new(ownership: true)
    # 短租约：真实接管需等旧 Stage 租约到期（心跳随进程一起死亡）
    t1 = form_troupe(prop_store: store, ownership_lease: "1s")
    t2 = form_troupe(prop_store: store, seeds: [t1.advertise], ownership_lease: "1s")
    wait_until { t1.roster.alive_peers.include?(t2.advertise) }

    key = (0..50).find { |i| t1.playbill.owner_address(t1.config.namespace, "Worker", "f#{i}") == t2.advertise }
    agent = t1.cast(WorkerActor, "f#{key}")
    assert_equal 3, 3.times.map { agent.add(1) }.last # 在 t2 上激活并提交

    # kill -9 等价：t2 整个运行时瞬间消失（传输 + 所有权心跳 + 调度器全部停止）
    dead_incarnation = t2.roster.self_incarnation
    t2.shutdown!(grace: "0.2s")
    t1.roster.merge([{ "addr" => t2.advertise, "incarnation" => dead_incarnation, "status" => "dead",
                       "roles" => [], "protocol" => 1 }])
    wait_until { t1.playbill.owner_address(t1.config.namespace, "Worker", "f#{key}") == t1.advertise }
    # 环上归我之后还需等旧租约到期才能接管（所有权激活前置，DESIGN §6.5）
    agent2 = nil
    wait_until(15) do
      agent2 = t1.cast(WorkerActor, "f#{key}")
      begin
        agent2.add(0) # 触发激活（可能先等所有权）
        true
      rescue Troupe::OwnershipError
        false
      end
    end

    # 后续 Call 在 t1 重新登台：Props 从共享存储恢复
    assert_equal 4, agent2.add(1)
    detail = t1.stage_manager.inspect_cell("Worker", "f#{key}")
    assert_equal 2, detail["fencingToken"], "接管后 epoch 单调递增"

    # 旧 Stage（若复活）的旧 token 写入会被拒绝
    stored = store.read(t1.config.namespace, "Worker", "f#{key}")
    assert_raises(Troupe::ConflictError) do
      store.write(t1.config.namespace, "Worker", "f#{key}", stored.props.merge("n" => 999),
                  expected_revision: stored.revision, schema_version: 1, fencing_token: 1)
    end
  end

  # 传输认证（M2）：rotate/grace/revoke——常时比较，宽限期内上一代 token 被接受，
  # 撤销（previous 置空）后立即拒绝
  def test_cluster_token_rotation_grace_and_revoke
    t1 = form_troupe(cluster_token: "v2-token", cluster_token_previous: "v1-token")
    host, port = t1.advertise.split(":")
    tr = Troupe::Transport.new(nil)

    hello_with = lambda do |tok|
      sock = TCPSocket.new(host, Integer(port, 10))
      frame = JSON.generate({ "t" => "hello", "v" => Troupe::PROTOCOL_VERSION, "token" => tok })
      sock.write([frame.bytesize].pack("V") + frame)
      begin
        resp = tr.send(:read_frame, sock)
      rescue EOFError, IOError, Troupe::ProtocolError
        resp = nil
      end
      [sock, resp]
    end

    sock1, resp1 = hello_with.call("v1-token")
    assert resp1 && resp1["ok"], "宽限期内上一代 token 被接受（grace）"
    sock1.close
    sock2, resp2 = hello_with.call("v2-token")
    assert resp2 && resp2["ok"], "当前 token 正常"
    sock2.close

    sock3, resp3 = hello_with.call("wrong")
    assert resp3.nil?, "错误 token 连接被拒"
    sock3.close rescue nil

    t1.config.cluster_token_previous = nil # revoke：撤销上一代
    sock4, resp4 = hello_with.call("v1-token")
    assert resp4.nil?, "撤销后旧 token 立即失效"
    sock4.close rescue nil

    # Stage 存活，正常调用不受影响
    a = t1.cast(WorkerActor, "token-ok")
    assert_equal 1, a.add(1)
  end

  def test_forward_hop_limit
    t1 = form_troupe
    t2 = form_troupe(seeds: [t1.advertise])
    wait_until { t1.roster.alive_peers.include?(t2.advertise) }
    key = (0..50).find { |i| t1.playbill.owner_address(t1.config.namespace, "Worker", "h#{i}") == t2.advertise }

    # 已带 2 跳的转发请求再进 t1（环漂移场景）→ 显式拒绝，防环（DESIGN §6.3）
    call = Troupe::Call.new(namespace: t1.config.namespace, role_id: "Worker", stage_name: "h#{key}",
                            method: :value, args: [],
                            deadline_ms: Troupe::Util.now_ms + 3000, source: :remote, hop: 2)
    e = assert_raises(Troupe::CallRejectedError) { t1.dispatch_inbound(call) }
    assert_match(/跳数上限/, e.message)
  end

  private

  def troupe_props_of(troupe, role, name)
    troupe.stage_manager.inspect_cell(role, name)["props"]
  end
end
