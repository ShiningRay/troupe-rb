# frozen_string_literal: true

require_relative "../errors"
require_relative "../util"
require_relative "cue_store"

module Troupe
  # Cue 调度器（DESIGN §7.5）：每 Stage 一个 tick 线程 + 有界投递工作池（Issue #6）。
  # due() 发现 → claim() 在多个 Stage 间分配执行责任 → on_cue 作为一条 Call
  # 进入 CallBoard（受同一调度约束）→ complete() 以 statusVersion 裁决。
  # 至少一次投递：执行中宕机 → 租约到期被重新认领、重复投递。
  #
  # 投递池（借鉴 dispatcher_pool 经验，一切有界）：
  #   * WORKERS 条复用 worker，不再"每条到期提醒新建线程"（单 tick 大量到期
  #     不再瞬时膨胀线程）；QUEUE_DEPTH 满即显式跳过本轮（背压），租约到期重投，
  #     不无限堆积内存；
  #   * stop() 先停 tick，再按序 drain 投递队列（存量提醒处理完 worker 才退出），
  #     宽限期内未完成的慢投递记录日志后放弃（进程停机不被单个慢 on_cue 挂住）。
  class CueScheduler
    BATCH = 64
    WORKERS = 8
    QUEUE_DEPTH = 256
    DRAIN_GRACE_S = 5.0

    attr_reader :troupe, :store, :workers

    def initialize(troupe, store)
      @troupe = troupe
      @store = store
      @tick = Util.parse_duration(troupe.config.cue_tick, "cue tick")
      @lease_ms = (Util.parse_duration(troupe.config.reminder_lease, "提醒租约") * 1000).to_i
      @stopped = false
      @sleeper = Util::Sleeper.new
      @thread = nil
      @queue = SizedQueue.new(QUEUE_DEPTH)
      @workers = []
      @started = false
      @workers_lock = Mutex.new
    end

    def start
      start_workers
      @thread = Thread.new do
        begin
          Thread.current.name = "troupe-cues"
        rescue StandardError
          nil
        end
        loop do
          break if @sleeper.sleep(@tick)
          break if @stopped

          tick
        end
      rescue StandardError => e
        Log.error("cue 调度线程退出：#{e.class}: #{e.message}")
      end
      nil
    end

    def stop
      @stopped = true
      @sleeper.cancel
      @thread&.join(1)
      drain_workers
      nil
    end

    def tick
      now = Util.now_ms
      records = store.due(now, BATCH)
      records.each do |rec|
        next if rec.namespace != @troupe.config.namespace # 多 Troupe 共享存储时只管自己的命名空间
        next if queue_full?(rec) # 有界背压：满则本轮不认领，租约到期重投

        version = store.claim(rec.id, owner: @troupe.owner_id, lease_until: now + @lease_ms)
        next unless version

        # 预检通过后再入队：极端并发下队列恰满时 push 短暂阻塞，
        # 最多等一个 worker 完成当前投递（有界等待，非死锁）
        @queue.push([rec, version])
      end
    rescue StandardError => e
      Log.error("cue tick 异常：#{e.class}: #{e.message}")
    end

    # 队列深度预算检查（认领前）：满则本轮跳过，避免占着租约排队
    # （Ruby 4.0 起 Queue#push 移除 non_block 关键字，背压用预检实现）
    def queue_full?(rec)
      return false if @queue.size < QUEUE_DEPTH

      Log.warn("提醒 #{rec.id} 到期但投递队列已满（#{QUEUE_DEPTH}）：本轮跳过（租约到期重投，背压）")
      true
    end

    def deliver(rec, claimed_version)
      call = Call.new(
        namespace: rec.namespace, role_id: rec.role_id, stage_name: rec.stage_name,
        method: :on_cue, args: [rec.name, rec.payload],
        deadline_ms: Util.now_ms + (Util.parse_duration(@troupe.config.call_timeout, "超时") * 1000).to_i,
        source: :reminder, internal: true
      )
      begin
        @troupe.route(call) # 位置透明：不在场则重新登台，可能经环转发到归属 Stage
      rescue StandardError => e
        Log.warn("提醒 #{rec.id} 投递失败（#{e.class}: #{e.message}）：租约到期将重投（至少一次）")
        return
      end
      next_due = CueStore.compute_next(rec.schedule, Util.now_ms)
      complete(rec, claimed_version, next_due)
    end

    def complete(rec, claimed_version, next_due)
      # 错过多个周期：默认跳过并按当前时刻计算下一次（跳过补发一次已由本次投递完成）
      ok = store.complete(rec.id, expected_status_version: claimed_version, next_due: next_due)
      Log.warn("提醒 #{rec.id} 完成 CAS 失败：已被注销或被重新投递裁决（statusVersion 竞争）") unless ok
    end

    # Actor 端注册入口（Cell#schedule_reminder 委托到这里）
    def upsert_from_actor(namespace, role_id, stage_name, name, spec, payload)
      schedule = CueStore.normalize_schedule(spec)
      id = Util.new_id(namespace, role_id, stage_name, name)
      now = Util.now_ms
      existing = store.find(id)
      next_due = existing ? existing.next_due : CueStore.compute_next(schedule, now)
      store.upsert(ReminderRecord.new(
                     id: id, namespace: namespace, role_id: role_id, stage_name: stage_name,
                     name: name, payload: Codec.copy(payload || nil), schedule: schedule, next_due: next_due
                   ))
      Log.debug("持久提醒已注册：#{id} schedule=#{schedule} next_due=#{Time.at(next_due / 1000.0)}")
      id
    end

    # ---- 有界投递工作池 ----

    def start_workers
      @workers_lock.synchronize do
        return if @started

        @started = true
        @workers = Array.new(WORKERS) { |i| worker_thread(i) }
      end
      nil
    end

    def worker_thread(i)
      t = Thread.new do
        begin
          Thread.current.name = "troupe-cue-worker-#{i}"
        rescue StandardError
          nil
        end
        loop do
          item = @queue.pop
          break if item.equal?(:stop)

          deliver(item[0], item[1])
        rescue StandardError => e
          # 兜底：deliver 内部已救援投递异常；这里防御完成裁决自身 bug，不让 worker 消失
          Log.error("cue worker 异常：#{e.class}: #{e.message} #{e.backtrace&.first}")
        end
      end
      t
    end

    # 停机 drain：:stop 哨兵排在存量任务之后——先处理完已入队提醒再退出；
    # 宽限期内未退出的 worker（慢 on_cue）记录日志后放弃，不挂住停机。
    def drain_workers
      return unless @started

      WORKERS.times { @queue << :stop }
      @workers.each do |t|
        t.join(DRAIN_GRACE_S) or
          Log.error("cue worker 宽限 #{DRAIN_GRACE_S}s 内未退出（慢 on_cue？）：停机放弃等待")
      end
      nil
    end
  end
end
