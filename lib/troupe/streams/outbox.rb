# frozen_string_literal: true

require_relative "../errors"
require_relative "../util"

module Troupe
  # OutboxDispatcher（M4）：独立于 Actor Turn 的交付调度器。
  # poll → 交付回调 → 标记已投递；交付回调抛错 → outbox_mark_failed（退避重排，
  # attempts 达上限 → 死信）→ **至少一次**：接收方必须幂等（Inbox 去重）。
  # 认领走 Provider 的 claim_outbox_batch（PG 为 SKIP LOCKED + 租约——多 dispatcher
  # 并发不重不漏；失败崩溃的租约到期自动重投）。
  class OutboxDispatcher
    DEFAULT_MAX_ATTEMPTS = 5
    DEFAULT_BACKOFF_MS = 2_000

    attr_reader :store

    def initialize(store, deliver, batch: 64, max_attempts: DEFAULT_MAX_ATTEMPTS,
                   backoff_ms: DEFAULT_BACKOFF_MS)
      @store = store
      @deliver = deliver
      @batch = batch
      @max_attempts = max_attempts
      @backoff_ms = backoff_ms
    end

    # 单次轮询：返回本轮交付成功（标记 sent）的条数。
    # 交付回调抛错 → 失败裁决（退避/死信），本轮不重试。
    def poll_once(owner: "dispatcher")
      delivered = 0
      @store.claim_outbox_batch(limit: @batch, owner: owner, lease_ms: 30_000).each do |record|
        begin
          @deliver.call(record)
        rescue StandardError => e
          Log.warn("outbox #{record.event_id} 交付失败（#{e.class}: #{e.message}）：退避重投（至少一次）")
          @store.outbox_mark_failed(record, max_attempts: @max_attempts, backoff_ms: @backoff_ms)
          next
        end
        delivered += 1 if @store.outbox_mark_delivered(record)
      end
      delivered
    end
  end

  # 幂等 Inbox（M4）：消费方事件去重——record! 返回 true = 首次见到（执行副作用），
  # false = 已处理过（跳过）。至少一次投递 + Inbox = 业务层的恰好一次副作用。
  class Inbox
    def self.open(url = nil)
      url ? PgInbox.open(url) : MemoryInbox.new
    end
  end

  class MemoryInbox < Inbox
    def initialize
      @mutex = Mutex.new
      @seen = {}
    end

    # true = 首次（执行副作用）；false = 重复（跳过）
    def record!(consumer, event_id)
      @mutex.synchronize do
        seen = @seen[consumer] ||= {}
        return false if seen[event_id]

        seen[event_id] = Util.now_ms
        true
      end
    end

    def seen?(consumer, event_id)
      @mutex.synchronize { @seen[consumer]&.key?(event_id) ? true : false }
    end
  end

  class PgInbox < Inbox
    def self.open(url)
      require "pg"
      inbox = new(PG.connect(url))
      inbox.ensure_schema!
      inbox
    end

    def initialize(conn)
      @conn = conn
      @lock = Mutex.new
      @conn.exec_params("SET client_min_messages = warning", [])
    end

    def ensure_schema!
      @lock.synchronize do
        @conn.exec_params(
          "CREATE TABLE IF NOT EXISTS troupe_inbox (" \
          "consumer TEXT NOT NULL, event_id TEXT NOT NULL, created_at TIMESTAMPTZ NOT NULL, " \
          "PRIMARY KEY (consumer, event_id))", []
        )
      end
      nil
    end

    def record!(consumer, event_id)
      @lock.synchronize do
        @conn.exec_params(
          "INSERT INTO troupe_inbox (consumer, event_id, created_at) VALUES ($1, $2, now()) " \
          "ON CONFLICT (consumer, event_id) DO NOTHING",
          [consumer, event_id]
        ).cmd_tuples.positive?
      end
    end

    def seen?(consumer, event_id)
      @lock.synchronize do
        @conn.exec_params(
          "SELECT 1 FROM troupe_inbox WHERE consumer = $1 AND event_id = $2",
          [consumer, event_id]
        ).values.size.positive?
      end
    end

    def close
      @lock.synchronize do
        begin
          @conn.close
        rescue StandardError
          nil
        end
      end
      nil
    end
  end
end
