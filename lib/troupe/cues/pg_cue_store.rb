# frozen_string_literal: true

require_relative "cue_store"
require_relative "../errors"
require_relative "../util"

module Troupe
  # PostgreSQL 生产 CueStore（M2；对齐 troupe.cr reminders_pg.cr 与 ROADMAP
  # 「FOR UPDATE SKIP LOCKED claim + DB 时钟」）：
  #
  # * claim 原子认领：单条 UPDATE 的 WHERE 守卫（status='active' 或 running 且租约
  #   已过期——执行中宕机重投）+ statusVersion CAS；行级锁经
  #   `id IN (SELECT id … FOR UPDATE SKIP LOCKED)` 获取，多 Stage 同时扫描时
  #   被占行直接跳过不阻塞；
  # * 租约（lease_until）用**数据库服务器时钟**（now()），客户端时钟漂移不参与；
  # * 调度先按环/目录归属过滤（scheduler 侧 namespace 过滤保留），重复投递由
  #   幂等消费兜底（至少一次语义不变）。
  class PostgresCueStore < CueStore
    def self.open(url)
      require "pg"
      store = new(PG.connect(url))
      store.ensure_schema!
      store
    end

    def initialize(conn)
      @conn = conn
      @lock = Mutex.new
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

    def upsert(record)
      @lock.synchronize do
        exec(
          "INSERT INTO troupe_cues (id, namespace, role_id, stage_name, name, payload, schedule, next_due) " \
          "VALUES ($1, $2, $3, $4, $5, $6, $7, $8) " \
          "ON CONFLICT (id) DO UPDATE SET namespace = EXCLUDED.namespace, role_id = EXCLUDED.role_id, " \
          "stage_name = EXCLUDED.stage_name, name = EXCLUDED.name, payload = EXCLUDED.payload, " \
          "schedule = EXCLUDED.schedule", # upsert 只更新定义、不动 next_due/status（对齐 Memory 语义）
          record.id, record.namespace, record.role_id, record.stage_name, record.name,
          record.payload ? JSON.generate(record.payload) : nil, record.schedule, record.next_due
        )
      end
      nil
    end

    def find(id)
      row_for(id)
    end

    # 到期查询：active 且到期，或 running 但租约已过期（DB 时钟判定宕机重投）
    def due(now, limit)
      @lock.synchronize do
        @conn.exec_params(
          "SELECT id, namespace, role_id, stage_name, name, payload, schedule, next_due, " \
          "status_version, status FROM troupe_cues " \
          "WHERE next_due <= $1 AND (status = 'active' OR (status = 'running' AND lease_until <= now())) " \
          "ORDER BY next_due LIMIT $2",
          [now, limit]
        ).values.map { |row| record_from_row(row) }
      end
    end

    # 原子认领：FOR UPDATE SKIP LOCKED 行锁 + WHERE 守卫 + statusVersion CAS。
    # 争用失败（已被认领/注销）返回 nil。
    def claim(id, owner:, lease_until:)
      @lock.synchronize do
        row = @conn.exec_params(
          "UPDATE troupe_cues SET status = 'running', owner = $2, " \
          "lease_until = to_timestamp($3::float8 / 1000.0), status_version = status_version + 1 " \
          "WHERE id IN (SELECT id FROM troupe_cues WHERE id = $1 FOR UPDATE SKIP LOCKED) " \
          "AND (status = 'active' OR (status = 'running' AND lease_until <= now())) " \
          "RETURNING status_version",
          [id, owner, lease_until]
        ).values[0]
        row && Integer(row[0]) # pg gem 无 type map 时返回字符串——显式转换
      end
    end

    def complete(id, expected_status_version:, next_due:)
      @lock.synchronize do
        rows = exec(
          "UPDATE troupe_cues SET status = 'active', owner = NULL, lease_until = NULL, " \
          "next_due = $3, status_version = status_version + 1 " \
          "WHERE id = $1 AND status_version = $2",
          id, expected_status_version, next_due
        )
        rows.positive?
      end
    end

    def cancel(id)
      @lock.synchronize do
        exec("DELETE FROM troupe_cues WHERE id = $1", id)
      end
      nil
    end

    def list
      records.map(&:to_h)
    end

    def records
      @lock.synchronize do
        @conn.exec_params(
          "SELECT id, namespace, role_id, stage_name, name, payload, schedule, next_due, " \
          "status_version, status FROM troupe_cues",
          []
        ).values.map { |row| record_from_row(row) }
      end
    end

    def ensure_schema!
      @lock.synchronize do
        @conn.exec_params(
          "CREATE TABLE IF NOT EXISTS troupe_cues (" \
          "id TEXT PRIMARY KEY, namespace TEXT NOT NULL, role_id TEXT NOT NULL, stage_name TEXT NOT NULL, " \
          "name TEXT NOT NULL, payload JSONB, schedule TEXT NOT NULL, next_due BIGINT NOT NULL, " \
          "status_version BIGINT NOT NULL DEFAULT 0, status TEXT NOT NULL DEFAULT 'active', " \
          "owner TEXT, lease_until TIMESTAMPTZ)"
        )
        @conn.exec_params(
          "CREATE INDEX IF NOT EXISTS troupe_cues_due_idx ON troupe_cues (status, next_due)"
        )
      end
      nil
    end

    private

    def exec(sql, *params)
      @conn.exec_params(sql, params).cmd_tuples
    end

    def row_for(id)
      @lock.synchronize do
        row = @conn.exec_params(
          "SELECT id, namespace, role_id, stage_name, name, payload, schedule, next_due, " \
          "status_version, status FROM troupe_cues WHERE id = $1", [id]
        ).values[0]
        row && record_from_row(row)
      end
    end

    def record_from_row(row)
      ReminderRecord.new(
        id: row[0], namespace: row[1], role_id: row[2], stage_name: row[3],
        name: row[4], payload: row[5] ? JSON.parse(row[5]) : nil,
        schedule: row[6], next_due: Integer(row[7]), status_version: Integer(row[8]),
        status: row[9] # pg gem 无 type map 时返回字符串——显式转换
      )
    end
  end
end
