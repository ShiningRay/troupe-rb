# frozen_string_literal: true

require_relative "stream_store"

module Troupe
  # PostgreSQL 持久流 Provider（ROADMAP M4，对齐 troupe.cr stream_pg.cr）：
  # * 事件日志 troupe_stream(topic, seq, payload, created_at)：seq 为全局 SEQUENCE
  #   （单调持久），per-topic 亦单调——保序读取；
  # * 游标 troupe_stream_cursor(consumer, topic, seq)：ack 用 GREATEST 只前进
  #   （回退 ack 不生效 → false）；
  # * 保留：retain_before 单条 DELETE（慢消费者被裁事件不可重放——显式代价）。
  class PostgresStreamStore < StreamStore
    def self.open(url)
      require "pg"
      store = new(PG.connect(url))
      store.ensure_schema!
      store
    end

    def initialize(conn)
      @conn = conn
      @lock = Mutex.new
      @conn.exec_params("SET client_min_messages = warning", [])
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

    def ensure_schema!
      @lock.synchronize do
        [
          "CREATE SEQUENCE IF NOT EXISTS troupe_stream_seq",
          "CREATE TABLE IF NOT EXISTS troupe_stream (" \
          "topic TEXT NOT NULL, seq BIGINT NOT NULL, payload JSONB NOT NULL, created_at TIMESTAMPTZ NOT NULL)",
          "CREATE INDEX IF NOT EXISTS troupe_stream_topic_seq_idx ON troupe_stream (topic, seq)",
          "CREATE TABLE IF NOT EXISTS troupe_stream_cursor (" \
          "consumer TEXT NOT NULL, topic TEXT NOT NULL, seq BIGINT NOT NULL, " \
          "PRIMARY KEY (consumer, topic))"
        ].each { |sql| @conn.exec_params(sql, []) }
      end
      nil
    end

    def append(topic, payload)
      @lock.synchronize do
        Integer(@conn.exec_params(
                  "INSERT INTO troupe_stream (topic, seq, payload, created_at) " \
                  "VALUES ($1, nextval('troupe_stream_seq'), $2, now()) RETURNING seq",
                  [topic, JSON.generate(payload)]
                ).values[0][0])
      end
    end

    def read_from(topic, from_seq, limit)
      @lock.synchronize do
        @conn.exec_params(
          "SELECT seq, payload, (extract(epoch from created_at) * 1000)::bigint " \
          "FROM troupe_stream WHERE topic = $1 AND seq > $2 ORDER BY seq LIMIT $3",
          [topic, from_seq, limit]
        ).values.map do |row|
          StreamEvent.new(topic, Integer(row[0]), JSON.parse(row[1]), Integer(row[2]))
        end
      end
    end

    def ack(consumer, topic, seq)
      @lock.synchronize do
        # GREATEST 只前进：回退 ack 不生效（0 行 → false）
        @conn.exec_params(
          "INSERT INTO troupe_stream_cursor (consumer, topic, seq) VALUES ($1, $2, $3) " \
          "ON CONFLICT (consumer, topic) DO UPDATE SET seq = GREATEST(troupe_stream_cursor.seq, EXCLUDED.seq) " \
          "WHERE EXCLUDED.seq > troupe_stream_cursor.seq",
          [consumer, topic, seq]
        ).cmd_tuples.positive?
      end
    end

    def cursor(consumer, topic)
      @lock.synchronize do
        row = @conn.exec_params(
          "SELECT seq FROM troupe_stream_cursor WHERE consumer = $1 AND topic = $2",
          [consumer, topic]
        ).values[0]
        row ? Integer(row[0]) : 0
      end
    end

    def retain_before(topic, min_seq)
      @lock.synchronize do
        @conn.exec_params(
          "DELETE FROM troupe_stream WHERE topic = $1 AND seq <= $2",
          [topic, min_seq]
        ).cmd_tuples
      end
    end

    def event_count(topic)
      @lock.synchronize do
        Integer(@conn.exec_params("SELECT COUNT(*) FROM troupe_stream WHERE topic = $1", [topic]).values[0][0])
      end
    end
  end
end
