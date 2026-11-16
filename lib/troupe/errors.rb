# frozen_string_literal: true

module Troupe
  # 错误分类（DESIGN §6.1）：业务异常 / 请求拒绝 / 执行结果未知 / 存储冲突
  # 每个错误带 kind，跨 Stage 以 {kind:, name:, message:} 传播（js v2 形状）；
  # 解码端兼容 cr golden/errors.json 的 code 表（M1 错误映射，见 Errors::WIRE_CODES）。
  class TroupeError < StandardError
    def kind
      :internal
    end
  end

  # 存储冲突：CAS 失败 / fencing token 过期（DESIGN §6.5、§7.2）
  class ConflictError < TroupeError
    def kind
      :conflict
    end
  end

  # 执行结果未知：超时、断连——不得假定失败（DESIGN §6.5）。
  # 框架不自动重试；需要安全重试的业务持幂等键。
  # phase（M1 语义矩阵）：queued = 排队过期（未开始、无副作用）；executing = 执行超时（结果未知）
  class ResultUnknownError < TroupeError
    def kind
      :unknown
    end
  end

  class CallTimeoutError < ResultUnknownError
    attr_accessor :phase

    def initialize(message = nil, phase: nil)
      @phase = phase
      super(message)
    end
  end

  class ConnectionLostError < ResultUnknownError; end

  # 请求拒绝：校验失败、背压超限、白名单外方法、排队阶段取消——调用未开始执行、无副作用
  # reason 与 cr golden/errors.json 的 CALL_REJECTED reasons 对齐
  # （backpressure/whitelist/shutdown/draining/ownership/invalidated；cancelled 为 trouperb 扩展）
  class CallRejectedError < TroupeError
    attr_reader :reject_reason, :retryable

    def kind
      :rejected
    end

    def initialize(message = nil, reason = nil, retryable: nil)
      # reason 缺省按错误类推导（Backpressure → backpressure 等），显式传参可覆盖
      @reject_reason = reason&.to_s || Errors::REASONS[self.class]
      @retryable = retryable.nil? ? Errors::Retryable.fetch(@reject_reason, false) : retryable
      super(message)
    end
  end

  class BoardFullError < CallRejectedError; end
  class BackpressureError < CallRejectedError; end
  class UnknownMethodError < CallRejectedError; end
  class UnknownRoleError < CallRejectedError; end
  class ProtocolError < CallRejectedError; end
  class InvalidActorStateError < CallRejectedError; end
  class SerializationError < CallRejectedError; end

  # 排队阶段取消（Issue #7）：未开始执行、无副作用，等价拒绝；
  # 执行阶段取消走协作式 cancelled?，不伪造本错误（结果未知 ≠ 失败）
  class CallCancelledError < CallRejectedError; end

  # 激活失败：Props 加载/迁移/校验/onStage 抛错，或所有权等待超时（DESIGN §5.2）
  class ActivationError < TroupeError
    def kind
      :rejected
    end
  end

  class MigrationError < ActivationError; end
  class OwnershipError < ActivationError; end

  # 业务幂等冲突：同键不同参数（DESIGN §6.5）
  class IdempotencyConflictError < TroupeError
    def kind
      :business
    end
  end

  # 启动期错误（§8.5：约定优于配置，但错误必须响）
  class RoleConflictError < TroupeError; end
  class ConfigError < TroupeError; end

  # 远端业务异常（actor 方法 raise）——保留原始类名与消息
  class RemoteError < TroupeError
    def kind
      :business
    end

    attr_reader :error_name

    def initialize(error_name, message)
      @error_name = error_name
      super(message)
    end
  end

  # 错误分类 wire 映射（M1，对齐 troupe.cr golden/errors.json 的 code 表）：
  # 业务/拒绝/未知结果/冲突/幂等冲突可区分；栈（backtrace）永不跨线。
  # 出站形状保持 troupejs protocol-v2 wireErr（{kind, name, message} + rejected 的
  # reason/retryable——golden fixtures 深比较锚定）；入站解码额外兼容 cr 的
  # {"code": ...} 形状。 Reasons 与 cr CALL_REJECTED reasons 对齐。
  module Errors
    WIRE_CODES = {
      ConflictError => "CONFLICT",
      CallTimeoutError => "CALL_TIMEOUT",
      CallRejectedError => "CALL_REJECTED",
      UnknownRoleError => "UNKNOWN_ROLE",
      SerializationError => "INVALID_ARGUMENT",
      InvalidActorStateError => "INVALID_ACTOR_STATE",
      ActivationError => "ACTIVATION",
      IdempotencyConflictError => "IDEMPOTENCY_CONFLICT",
      ResultUnknownError => "UNKNOWN_OUTCOME",
      ProtocolError => "PROTOCOL"
    }.freeze

    REASONS = {
      BoardFullError => "backpressure",
      BackpressureError => "backpressure",
      UnknownMethodError => "whitelist",
      CallCancelledError => "cancelled",
      InvalidActorStateError => "invalidated"
    }.freeze

    # 对齐 cr retryable_by_reason：仅 backpressure 可安全重试（未开始执行）
    Retryable = { "backpressure" => true }.freeze

    module_function

    # 错误实例 → wire 形状（js v2 golden 锚定）：出站不含 code（ golden 深比较），
    # rejected 附 reason/retryable，queued/executing 超时附 phase。
    def wire_payload(e, error_name = nil)
      payload = { "kind" => e.kind.to_s, "name" => (error_name || e.class.name.split("::").last), "message" => e.message.to_s }
      payload["reason"] = e.reject_reason if e.respond_to?(:reject_reason) && e.reject_reason
      payload["retryable"] = e.retryable if e.respond_to?(:retryable) && e.is_a?(CallRejectedError)
      payload["phase"] = e.phase if e.respond_to?(:phase) && e.phase
      payload
    end

    # 类 → cr code 表（本仓映射锚点； 解码用 + 测试断言）
    def code_for(e)
      e.class.ancestors.each do |k|
        return WIRE_CODES[k] if WIRE_CODES.key?(k)
      end
      nil
    end
  end
end
