# frozen_string_literal: true

require_relative "../errors"
require_relative "../util"

module Troupe
  # StreamEvent：持久流事件（追加写、seq 单调）。
  # 与 Show realtime 分开：这是持久层（seq/replay/retain），不是 fan-out（DESIGN/ROADMAP M4）。
  StreamEvent = Struct.new(:topic, :seq, :payload, :created_at)

  # 持久流 Store 接口合同（ROADMAP M4，对齐 troupe.cr stream.cr）：
  # * append 返回持久化 seq（Provider 保证 per-topic 单调且持久）；
  # * 游标/ack 按 (consumer, topic) 持久化——**ack 只前进**（回退返回 false）；
  # * 消费者失败不 ack → 下次从游标重放（**至少一次**；消费侧幂等用 Inbox 去重）；
  # * retain_before 裁剪：慢消费者代价——被裁事件不可重放。
  class StreamStore
    def append(_topic, _payload)
      raise NotImplementedError
    end

    def read_from(_topic, _from_seq, _limit)
      raise NotImplementedError
    end

    def ack(_consumer, _topic, _seq)
      raise NotImplementedError
    end

    def cursor(_consumer, _topic)
      raise NotImplementedError
    end

    def retain_before(_topic, _min_seq)
      raise NotImplementedError
    end

    def event_count(_topic)
      raise NotImplementedError
    end

    def close; end
  end

  # Memory 流实现：Rehearsal/单机测试（语义与 PG 版对齐）
  class MemoryStreamStore < StreamStore
    def initialize
      @mutex = Mutex.new
      @log = Hash.new { |h, k| h[k] = [] }
      @cursors = {}
      @seq = 0
    end

    def append(topic, payload)
      @mutex.synchronize do
        @seq += 1
        @log[topic] << StreamEvent.new(topic, @seq, Codec.copy(payload), Util.now_ms)
        @seq
      end
    end

    def read_from(topic, from_seq, limit)
      @mutex.synchronize do
        @log[topic].select { |e| e.seq > from_seq }.first(limit)
      end
    end

    def ack(consumer, topic, seq)
      @mutex.synchronize do
        k = [consumer, topic]
        current = @cursors[k] || 0
        return false if seq <= current # 只前进：回退拒绝

        @cursors[k] = seq
        true
      end
    end

    def cursor(consumer, topic)
      @mutex.synchronize { @cursors[[consumer, topic]] || 0 }
    end

    def retain_before(topic, min_seq)
      @mutex.synchronize do
        log = @log[topic]
        before = log.size
        log.reject! { |e| e.seq <= min_seq }
        before - log.size
      end
    end

    def event_count(topic)
      @mutex.synchronize { @log[topic].size }
    end
  end

  # 事件溯源扩展点（对齐 troupe.cr event_sourcing.cr；**扩展点而非默认存储路径**）：
  # Actor 状态的真相源是事件流（StreamStore 追加写）而非整份 Props——
  # Turn 产生事件（append）→ 状态由事件重放重建（rebuild）。与 Outbox 组合：
  # Outbox 负责"事件→外部副作用"，事件溯源负责"事件→状态"，互不替代。
  #
  # 并发边界：事件溯源 actor 的 Turn 仍走 strict 串行——事件 append 顺序即 Turn 顺序
  # （read_only 不产生事件；improv 不适用此模式）。
  module EventSourcing
    module_function

    # 全量重放：初始状态 + 顺序应用全部事件
    def rebuild(initial, events, &apply)
      events.reduce(initial) { |state, event| apply.call(state, event) }
    end

    # 快照加速：从快照状态继续重放其后的事件。
    # 语义契约：rebuild_from_snapshot(snapshot, 快照后事件) == rebuild(initial, 全部事件)
    # ——不一致即快照/增量错位（调用方 bug，一致性反例见 stream contract 测试）。
    def rebuild_from_snapshot(snapshot_state, events, &apply)
      events.reduce(snapshot_state) { |state, event| apply.call(state, event) }
    end

    # 领域事件编码进持久流（payload = {type, data}）
    def append_event(store, topic, type, data)
      store.append(topic, { "type" => type, "data" => data })
    end
  end
end
