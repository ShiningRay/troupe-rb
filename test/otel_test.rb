# frozen_string_literal: true

require_relative "test_helper"

# OTel 零依赖 OTLP JSON 导出适配（ROADMAP M3，对齐 troupe.cr otel.cr）：
# TraceEvent → span（traceparent 解析 / outcome → status / unixNano 时间）；
# 指标 → monotonic Sum；sink 回调接线（传输是宿主实现，框架不做网络 IO）。
class OTelTest < Minitest::Test
  class CounterActor < Troupe::Actor
    role_id "otelc"
    initial_props { { "n" => 0 } }

    def bump(v = 1)
      props["n"] += v
      save_props
    end

    def boom
      raise ArgumentError, "业务失败"
    end
  end

  def test_parse_traceparent_and_fallbacks
    tid, sid = Troupe::OTel.parse_traceparent("00-#{'a' * 32}-#{'b' * 16}-01")
    assert_equal "a" * 32, tid
    assert_equal "b" * 16, sid

    tid, sid = Troupe::OTel.parse_traceparent("garbage")
    assert_equal "0" * 32, tid, "全零 = OTLP 无效 id 约定"
    assert_equal "0" * 16, sid
    tid, = Troupe::OTel.parse_traceparent(nil)
    assert_equal "0" * 32, tid
  end

  def test_spans_to_otlp_json_shape
    at = Troupe::Util.now_ms
    events = [{
      "at" => at, "stage" => "stage-a", "from" => "local", "role" => "otelc", "stageName" => "s1",
      "method" => "bump", "durationMs" => 2.5, "outcome" => "ok", "callId" => "c-1",
      "traceparent" => "00-#{'1' * 32}-#{'2' * 16}-01"
    }]
    json = JSON.parse(Troupe::OTel.spans_to_otlp_json("stage-a", events))

    rs = json["resourceSpans"][0]
    assert_equal "troupe.stage-a", rs["resource"]["attributes"][0]["value"]["stringValue"]
    span = rs["scopeSpans"][0]["spans"][0]
    assert_equal "1" * 32, span["traceId"]
    assert_equal "2" * 16, span["spanId"]
    assert_equal "otelc.bump", span["name"]
    assert_equal 1, span["kind"]
    assert_equal({ "code" => 1 }, span["status"])
    start_ns = Integer(span["startTimeUnixNano"])
    end_ns = Integer(span["endTimeUnixNano"])
    assert_equal at * 1_000_000, end_ns
    assert_operator end_ns - start_ns, :>=, 2_000_000, "durationMs 映射到 unixNano 时长"

    # 失败 outcome → status code 2 + message
    events[0]["outcome"] = "business"
    json = JSON.parse(Troupe::OTel.spans_to_otlp_json("stage-a", events))
    assert_equal({ "code" => 2, "message" => "business" }, json["resourceSpans"][0]["scopeSpans"][0]["spans"][0]["status"])

    # 无 traceparent 的事件 → 全零 id（OTLP 无效 id 约定）
    events[0].delete("traceparent")
    json = JSON.parse(Troupe::OTel.spans_to_otlp_json("stage-a", events))
    assert_equal("0" * 32, json["resourceSpans"][0]["scopeSpans"][0]["spans"][0]["traceId"])
  end

  def test_metrics_to_otlp_json_shape
    snapshot = {
      "leaseRenewFailures" => 1, "handovers" => 2,
      "otelc" => { "calls" => 5, "errors" => 1, "rejected" => 0, "activations" => 2, "leaseRenewFailures" => 1,
                   "p50ms" => 1.0, "p99ms" => 2.0, "maxMs" => 3.0 }
    }
    json = JSON.parse(Troupe::OTel.metrics_to_otlp_json("stage-a", snapshot))
    rm = json["resourceMetrics"][0]
    assert_equal "troupe.stage-a", rm["resource"]["attributes"][0]["value"]["stringValue"]
    metrics = rm["scopeMetrics"][0]["metrics"]
    names = metrics.map { |m| m["name"] }
    assert_includes names, "troupe.otelc.calls"
    assert_includes names, "troupe.otelc.lease_renew_failures"
    assert_includes names, "troupe.leaseRenewFailures"
    assert_includes names, "troupe.handovers"
    calls = metrics.find { |m| m["name"] == "troupe.otelc.calls" }
    assert_equal 5, calls["sum"]["dataPoints"][0]["asInt"]
    assert_equal 2, calls["sum"]["aggregationTemporality"] # 累计
    assert_equal true, calls["sum"]["isMonotonic"]
  end

  # traceparent 贯穿：本地调用产事件并携带 traceparent；成功/失败 outcome 可区分
  def test_trace_events_carry_traceparent
    troupe = Troupe::Testing.rehearsal(actors: [CounterActor])
    begin
      troupe.cast(CounterActor, "s1").bump(1)
      troupe.cast(CounterActor, "s1").boom rescue nil
      wait_until { troupe.trace.recent(50).count { |e| e["method"] == "bump" } >= 1 }
      events = troupe.trace.recent(50)
      bump = events.find { |e| e["method"] == "bump" }
      assert_match(/\A00-[0-9a-f]{32}-[0-9a-f]{16}-01\z/, bump["traceparent"])
      boom = events.find { |e| e["method"] == "boom" }
      assert_equal "business", boom["outcome"]

      # 端到端：事件转 OTLP span 的 traceId 与事件 traceparent 一致
      json = JSON.parse(Troupe::OTel.spans_to_otlp_json(troupe.advertise, [bump]))
      tid, = Troupe::OTel.parse_traceparent(bump["traceparent"])
      assert_equal tid, json["resourceSpans"][0]["scopeSpans"][0]["spans"][0]["traceId"]
    ensure
      troupe.shutdown!
    end
  end

  # sink 接线：trace 事件经 sink 回调交付 OTLP JSON；stop 可停止
  def test_attach_exporter_delivers_to_sink
    troupe = Troupe::Testing.rehearsal(actors: [CounterActor])
    received = Queue.new
    stop = Troupe::OTel.attach_exporter(troupe, ->(kind, json) { received << [kind, json] }, every: 0.3)
    begin
      troupe.cast(CounterActor, "s2").bump(1)
      kind, json = loop do
        k, j = received.pop
        break [k, j] if k == :trace # 周期性 metrics 推送可能先到
      end
      parsed = JSON.parse(json)
      assert_equal 1, parsed["resourceSpans"][0]["scopeSpans"][0]["spans"].size
    ensure
      stop.call
      troupe.shutdown!
    end
  end
end
