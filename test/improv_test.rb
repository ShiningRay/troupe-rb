# frozen_string_literal: true

require_relative "test_helper"

# 交错执行（DESIGN §5.4 / PLAN M5）：组合矩阵 + 写饥饿防护
# Ruby 适配：annotated 调度到独立线程（GVL 在 I/O 等待点让出），
# strict 仍由单调度线程独占——组合矩阵语义与 Troupe.js 一致。
class ImprovTest < Minitest::Test
  class SessionActor < Troupe::Actor
    initial_props { { "timeline" => [], "reads" => 0 } }

    improv :slow_improv
    read_only :slow_read, :peek
    improv :grind # 调度矩阵（M1）：cancellable × improv
    cancellable :grind

    def slow_improv(ms = 200)
      props["timeline"] << "improv-start"
      sleep(ms / 1000.0)
      props["timeline"] << "improv-end"
      "improv"
    end

    # 长任务：检查点轮询 cancelled?，取消后自愿早停（Issue #7）
    def grind(steps = 100)
      steps.times do
        break if cancelled?

        sleep 0.01
        props["timeline"] << "grind"
      end
      "grind-done"
    end

    def on_cancel
      props["timeline"] << "cancel-hook"
    end

    def slow_read(ms = 200)
      props["timeline"] << "read-start"
      sleep(ms / 1000.0)
      props["timeline"] << "read-end"
      "read"
    end

    def strict(ms = 200)
      props["timeline"] << "strict-start"
      sleep(ms / 1000.0)
      props["timeline"] << "strict-end"
      "strict"
    end

    def peek
      props["reads"] += 1
      "peek"
    end

    def timeline
      props["timeline"]
    end
  end

  def setup
    @troupe = Troupe::Testing.rehearsal(actors: [SessionActor])
  end

  def teardown
    @troupe.shutdown! rescue nil
  end

  def test_annotated_annotated_interleave
    a = @troupe.cast(SessionActor, "s1")
    t0 = Troupe::Util.mono
    t1 = Thread.new { a.slow_improv(250) }
    t2 = Thread.new { a.slow_read(250) }
    t1.join
    t2.join
    elapsed = Troupe::Util.mono - t0
    assert_operator elapsed, :<, 0.45, "annotated × annotated 交错执行（并发完成，#{(elapsed * 1000).round}ms）"
  end

  def test_strict_excludes_everything
    a = @troupe.cast(SessionActor, "s2")
    strict_thread = Thread.new { a.strict(200) }
    sleep 0.05 # strict 已在飞

    t0 = Troupe::Util.mono
    a.slow_improv(50) # annotated 只能等 strict settle
    waited = Troupe::Util.mono - t0
    assert_operator waited, :>=, 0.12, "未标注在飞时 annotated 不启动"

    strict_thread.join
    tl = a.timeline
    assert_equal "strict-start", tl[0]
    assert_equal "strict-end", tl[1], "strict 独占：期间无交错"
    assert_equal "improv-start", tl[2]
  end

  def test_write_starvation_guard_strict_queued_blocks_new_annotated
    a = @troupe.cast(SessionActor, "s3")
    improv_fiber = Thread.new { a.slow_improv(250) } # 在飞 annotated
    sleep 0.05

    strict_result = Thread.new { a.strict(80) } # strict 入队：写饥饿防护开始
    sleep 0.02
    t0 = Troupe::Util.mono
    a.peek # 新 annotated 请求：须等 strict 完成后才开始
    peek_waited = Troupe::Util.mono - t0
    assert_operator peek_waited, :>=, 0.15, "strict 入队后停止启动新 annotated（写等待有界）"

    improv_fiber.join
    strict_result.join
    tl = a.timeline
    assert_equal "improv-start", tl[0]
    assert_equal %w[improv-start improv-end strict-start strict-end], tl.first(4)
  end

  # 串行承诺：strict Turn 逐条执行、成对不交错。
  # 注：并发调用方的"入队顺序"由各线程实际到达 CallBoard 的时刻决定（Ruby 线程
  # 调度），框架不承诺"创建顺序 = 执行顺序"——那是对测试自身的误断；可验证的是
  # 每个 strict-start 都紧跟 strict-end（严格串行）且 5 条全部执行。
  def test_strict_turns_serial_and_paired
    a = @troupe.cast(SessionActor, "s4")
    order = Queue.new
    threads = Array.new(5) { |i| Thread.new { a.strict(10); order << i } }
    threads.each(&:join)
    assert_equal 5, order.size, "5 条 strict 全部执行完毕"

    tl = a.timeline
    starts = tl.each_index.select { |i| tl[i] == "strict-start" }
    assert_equal 5, starts.size
    starts.each do |i|
      assert_equal "strict-end", tl[i + 1],
                   "strict-start 后必须紧跟其 strict-end（严格串行：上一 Turn settle 前不取下一 Call）"
    end
  end

  def test_quiesce_waits_all_in_flight
    a = @troupe.cast(SessionActor, "s5")
    t1 = Thread.new { a.slow_improv(300) }
    t2 = Thread.new { a.slow_read(300) }
    sleep 0.1
    done = @troupe.quiesce(timeout: 3)
    assert done, "quiesce 等待全部在飞 Turn（含 annotated）"
    assert_includes a.timeline, "improv-end"
    assert_includes a.timeline, "read-end"
    t1.join
    t2.join
  end

  # 调度矩阵（M1）：cancellable × improv —— improv 方法同样收到协作取消，
  # 检查点退出 + on_cancel 钩子；未取消时完整执行
  def test_cancellable_improv_method_cooperative_cancel
    a = @troupe.cast(SessionActor, "s6")

    e = assert_raises(Troupe::CallTimeoutError) { a.with_timeout("0.08s").grind(100) }
    assert_equal :executing, e.phase

    wait_until(5) { a.timeline.include?("cancel-hook") } # on_cancel 在 Turn settle 后触发
    ground_count = a.timeline.count("grind")
    assert_operator ground_count, :<, 100, "长循环在检查点自愿早停"
    assert_operator ground_count, :>, 0, "已产生的部分副作用保留"

    # 未取消：完整执行完
    assert_equal "grind-done", a.grind(3)
  end

  def test_annotation_requires_existing_method
    bad = Class.new(Troupe::Actor) do
      role_id "badanno"
      improv :nonexistent
    end
    # 校验延迟到注册时（DSL 顺序自由），form() 仍尽早报错（DESIGN §1.3）
    e = assert_raises(Troupe::ConfigError) do
      Troupe::Testing.rehearsal(actors: [bad])
    end
    assert_match(/不存在/, e.message)
  end
end
