# frozen_string_literal: true

require_relative "trace"

module Troupe
  # OTLP JSON v1 导出适配（ROADMAP M3，对齐 troupe.cr otel.cr：环形缓冲 + sink 回调）。
  #
  # **零外部依赖**：将 Trace 事件（spans）与指标（counters → monotonic Sum）转换为
  # OTLP/JSON Protobuf JSON 映射结构，经 sink 回调交付——推送至 collector 的传输
  # （HTTP/gRPC/文件）是 sink 的宿主实现，框架不做网络 IO。
  #
  # 映射：
  # - TraceEvent → span（traceparent 解析出 traceId/spanId 十六进制；无 traceparent
  #   的事件用全零 id——OTLP 约定全零为无效 id；outcome → status code）；
  # - RoleMetrics 计数 → monotonic Sum（aggregationTemporality=2 累计）；
  # - Stage 名 → resource 属性 service.name。
  module OTel
    SPAN_KIND_INTERNAL = 1
    STATUS_OK = 1
    STATUS_ERROR = 2

    module_function

    # traceparent → [trace_id, span_id]；非法/缺失 → 全零（OTLP 全零为无效 id 约定）
    def parse_traceparent(tp)
      m = tp.is_a?(String) ? /\A00-([0-9a-f]{32})-([0-9a-f]{16})-01\z/.match(tp) : nil
      return ["0" * 32, "0" * 16] unless m

      [m[1], m[2]]
    end

    # Trace 事件 → OTLP JSON 字符串（单 resource 单 scope 的 spans）
    def spans_to_otlp_json(stage_name, events)
      spans = events.filter_map do |ev|
        trace_id, span_id = parse_traceparent(ev["traceparent"])
        end_ns = (ev["at"].to_i * 1_000_000)
        dur_ns = ((ev["durationMs"] || 0).to_f * 1_000_000).round
        start_ns = [end_ns - dur_ns, 0].max
        outcome = ev["outcome"].to_s
        {
          "traceId" => trace_id,
          "spanId" => span_id,
          "parentSpanId" => "",
          "name" => "#{ev['role']}.#{ev['method']}",
          "kind" => SPAN_KIND_INTERNAL,
          "startTimeUnixNano" => start_ns.to_s,
          "endTimeUnixNano" => end_ns.to_s,
          "attributes" => [
            attr("troupe.stage_name", ev["stageName"]),
            attr("troupe.call_id", ev["callId"]),
            attr("troupe.from", ev["from"])
          ].compact,
          "status" => outcome == "ok" ? { "code" => STATUS_OK } : { "code" => STATUS_ERROR, "message" => outcome }
        }
      end
      JSON.generate(
        "resourceSpans" => [
          {
            "resource" => { "attributes" => [attr("service.name", "troupe.#{stage_name}")] },
            "scopeSpans" => [
              { "scope" => { "name" => "troupe.rb", "version" => ::Troupe::VERSION }, "spans" => spans }
            ]
          }
        ]
      )
    end

    # 指标快照 → OTLP JSON 字符串（单 resource 单 scope，counter → monotonic Sum）
    def metrics_to_otlp_json(stage_name, snapshot)
      time_ns = (Util.now_ms * 1_000_000).to_s
      metrics = snapshot.filter_map do |key, value|
        next unless value.is_a?(Hash) # 角色 snapshot 是 Hash；cluster 计数器是标量

        role_metrics = value
        [
          counter_metric("troupe.#{key}.calls", role_metrics["calls"], time_ns),
          counter_metric("troupe.#{key}.errors", role_metrics["errors"], time_ns),
          counter_metric("troupe.#{key}.rejected", role_metrics["rejected"], time_ns),
          counter_metric("troupe.#{key}.activations", role_metrics["activations"], time_ns),
          counter_metric("troupe.#{key}.lease_renew_failures", role_metrics["leaseRenewFailures"], time_ns)
        ]
      end.flatten.compact
      cluster = snapshot
      metrics << counter_metric("troupe.leaseRenewFailures", cluster["leaseRenewFailures"] || 0, time_ns)
      metrics << counter_metric("troupe.handovers", cluster["handovers"] || 0, time_ns)
      JSON.generate(
        "resourceMetrics" => [
          {
            "resource" => { "attributes" => [attr("service.name", "troupe.#{stage_name}")] },
            "scopeMetrics" => [
              { "scope" => { "name" => "troupe.rb", "version" => ::Troupe::VERSION }, "metrics" => metrics }
            ]
          }
        ]
      )
    end

    # sink 接线：订阅 trace 总线 + 周期推指标，交付给宿主 sink 回调。
    # 返回 stop lambda（停机时调用）。传输由 sink 宿主实现（框架不做网络 IO）。
    def attach_exporter(troupe, sink, every: 10.0)
      sub = troupe.trace.subscribe do |ev|
        begin
          sink.call(:trace, spans_to_otlp_json(troupe.advertise, [ev]))
        rescue StandardError => e
          Log.warn("OTel sink trace 交付失败：#{e.class}: #{e.message}")
        end
      end
      stop_flag = { stop: false }
      thread = Thread.new do
        begin
          Thread.current.name = "troupe-otel-exporter"
        rescue StandardError
          nil
        end
        until stop_flag[:stop]
          deadline = Util.mono + every
          while !stop_flag[:stop] && Util.mono < deadline
            sleep 0.05 # 可中断等待：stop 不悬挂
          end
          break if stop_flag[:stop]

          begin
            sink.call(:metrics, metrics_to_otlp_json(troupe.advertise, troupe.metrics.snapshot))
          rescue StandardError => e
            Log.warn("OTel sink metrics 交付失败：#{e.class}: #{e.message}")
          end
        end
      rescue StandardError => e
        Log.error("OTel exporter 退出：#{e.class}: #{e.message}")
      end
      lambda do
        stop_flag[:stop] = true
        thread.join(1)
        sub.close
      end
    end

    def counter_metric(name, value, time_ns)
      {
        "name" => name,
        "sum" => {
          "dataPoints" => [{ "asInt" => value.to_i, "timeUnixNano" => time_ns }],
          "aggregationTemporality" => 2,
          "isMonotonic" => true
        }
      }
    end

    def attr(key, value)
      return nil if value.nil? || value == ""

      { "key" => key, "value" => { "stringValue" => value.to_s } }
    end
  end
end
