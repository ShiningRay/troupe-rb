# frozen_string_literal: true

require_relative "codec"
require_relative "errors"
require_relative "trace"

module Troupe
  # publish 交付裁决（可断言，对齐 troupe.cr PublishReport）
  PublishReport = Struct.new(:actors_ok, :actors_failed, :external_ok, :external_failed) do
    def to_h
      { "actorsOk" => actors_ok, "actorsFailed" => actors_failed,
        "externalOk" => external_ok, "externalFailed" => external_failed }
    end
  end

  # Actor Audience 订阅：事件作为普通 Turn 交付到 (role, stageName, method)
  class ActorSubscription
    attr_reader :role_id, :stage_name, :method_name

    def initialize(role_id, stage_name, method_name)
      @role_id = role_id
      @stage_name = stage_name
      @method_name = method_name
    end
  end

  # Show（演出，DESIGN §2 / ROADMAP M3，对齐 troupe.cr show.cr）：实时 Audience。
  # **不叫流**：Show 是"短暂尽力而为的 Audience"，与持久流（seq/replay/retain，M4）
  # 显式分开、不混称。
  #
  # 两类订阅，**边界回调与 Actor 订阅分离**（学 cr M4）：
  # - **Actor Audience**（actor_subscribe）：事件作为**普通 Actor Turn** 交付——
  #   经完整管道（白名单/背压/超时/严格串行语义不变），位置透明（route 环归属，
  #   订阅者 Actor 可属于其他 Stage → 跨 Stage 转发）；
  # - **边界回调**（external_subscribe）：非 Actor 观察者直接回调，与 Turn 交付互不影响。
  #
  # 语义：**在线尽力而为，离线不保证**——交付失败（Turn 异常/超时/背压/停机）即放弃
  # 该次通知，**不重投**（持久化诉求走 Reminder / Outbox，M4）。publish 有界等待：
  # 慢订阅者在 deadline 内未完成即计 failed，不拖垮发布者与其他订阅者。
  class Show
    DELIVERY_DEADLINE_S = 5.0

    attr_reader :name

    def initialize(name, troupe)
      @name = name
      @troupe = troupe
      @lock = Mutex.new
      @actor_subs = {}
      @external_subs = {}
    end

    # Actor Audience 订阅：方法必须在角色白名单内（订阅时校验信任边界）
    def actor_subscribe(role_id, stage_name, method_name = :on_show)
      klass = @troupe.repertoire[role_id]
      raise UnknownRoleError, "Show #{@name.inspect} 订阅失败：未知角色 #{role_id}" unless klass

      unless klass.valid_rpc?(method_name)
        raise UnknownMethodError,
              "Show #{@name.inspect} 订阅失败：#{method_name} 不在角色 #{role_id} 白名单（完整 Turn 管道）"
      end

      id = Util.call_id
      @lock.synchronize { @actor_subs[id] = ActorSubscription.new(role_id, stage_name, method_name) }
      id
    end

    def actor_unsubscribe(id)
      @lock.synchronize { !@actor_subs.delete(id).nil? }
    end

    def external_subscribe(&blk)
      id = Util.call_id
      @lock.synchronize { @external_subs[id] = blk }
      id
    end

    def external_unsubscribe(id)
      @lock.synchronize { !@external_subs.delete(id).nil? }
    end

    def actor_subscriber_count
      @lock.synchronize { @actor_subs.size }
    end

    def external_subscriber_count
      @lock.synchronize { @external_subs.size }
    end

    def subscriber_count
      @lock.synchronize { @actor_subs.size + @external_subs.size }
    end

    # 同步 fan-out（有界等待）：Actor 经完整 Turn（在线尽力，失败放弃不重投）；
    # 边界回调独立隔离。返回 PublishReport（交付计数可断言）。
    def publish(payload, delivery_deadline: DELIVERY_DEADLINE_S)
      actor_subs, external_subs = @lock.synchronize do
        [@actor_subs.values.dup, @external_subs.values.dup]
      end
      envelope = { "topic" => @name, "payload" => Codec.copy(payload) }
      deadline_s = delivery_deadline || DELIVERY_DEADLINE_S

      threads = []
      actor_subs.each do |sub|
        threads << Thread.new { deliver_to_actor(sub, envelope, deadline_s) }
      end
      external_subs.each do |blk|
        threads << Thread.new do
          blk.call(Codec.copy(envelope))
          :ok
        rescue StandardError => e
          Log.warn("show #{@name.inspect} 边界回调异常：#{e.class}: #{e.message}")
          :failed
        end
      end

      report = PublishReport.new(0, 0, 0, 0)
      threads.each_with_index do |t, idx|
        t.join(deadline_s + 1.0) # 有界等待：慢订阅者不拖住发布者
        outcome = t.alive? ? :failed : t.value
        if idx < actor_subs.size
          outcome == :ok ? report.actors_ok += 1 : report.actors_failed += 1
        else
          outcome == :ok ? report.external_ok += 1 : report.external_failed += 1
        end
      end
      report
    end

    private

    # Actor Audience 交付：一条普通 Call 走 route（环归属 → 可跨 Stage 转发）。
    # 失败/超时/背压/停机 = 放弃本次通知（在线尽力，不重投）。
    def deliver_to_actor(sub, envelope, deadline_s)
      call = Call.new(
        namespace: @troupe.config.namespace, role_id: sub.role_id, stage_name: sub.stage_name,
        method: sub.method_name, args: [envelope],
        deadline_ms: Util.now_ms + (deadline_s * 1000).to_i,
        source: :show
      )
      @troupe.route(call)
      :ok
    rescue StandardError => e
      Log.warn("show #{@name.inspect} Audience 交付失败（#{sub.role_id}/#{sub.stage_name}：" \
               "#{e.class}: #{e.message}）——在线尽力，不重投")
      :failed
    end
  end
end
