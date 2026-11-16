# frozen_string_literal: true

require_relative "test_helper"
require "json"

# golden fixtures（M1，对齐 troupejs test/golden-protocol.test.ts / ADR 0003）：
# 跨语言协议锚点。实现变更导致本测试红 = 协议漂移——必须显式更新
# test/golden/protocol-v2.json 并附兼容说明；troupejs / troupe.cr 以同一份 fixtures 对齐。
# canonical hash 分叉（cr=CRC32+64v vs js/rb=xxh32+160v）上报 troupe-planning 出 ADR，
# 本仓不单方面改算法。
class GoldenProtocolTest < Minitest::Test
  FIXTURES = JSON.parse(File.read(File.expand_path("golden/protocol-v2.json", __dir__)))

  def test_protocol_version_anchored
    assert_equal FIXTURES["protocolVersion"], Troupe::PROTOCOL_VERSION,
                 "WIRE_PROTOCOL_VERSION 与 fixtures 一致（golden 锚定）"
  end

  def test_xxh32_hash_anchored
    FIXTURES["xxh32"].each do |key, expected|
      assert_equal expected, Troupe::Xxh32.digest(key), "xxh32(#{key.inspect})"
    end
  end

  def test_hash_ring_assignment_anchored
    ring = Troupe::HashRing.new
    FIXTURES["hashRing"]["nodes"].each { |n| ring.add_node(n) }
    FIXTURES["hashRing"]["assignments"].each do |key, owner|
      assert_equal owner, ring.get_node(key), "ring assignment(#{key.inspect})"
    end
  end

  def test_traceparent_format_and_trace_id_anchored
    known = FIXTURES["traceparent"]["known"]
    assert_equal known["traceId"], Troupe::TraceContext.trace_id_of(known["traceparent"])
    assert_nil Troupe::TraceContext.trace_id_of("garbage")

    span = Troupe::TraceContext.new_span
    assert_match(/\A00-[0-9a-f]{32}-[0-9a-f]{16}-01\z/, span)
    assert_match(/\A[0-9a-f]{32}\z/, Troupe::TraceContext.trace_id_of(span))
  end

  # 存储信封形状锚定（mark/version/props/idem——R6 幂等记录结构）
  def test_envelope_shape_anchored
    idem = { "k1" => { "fp" => "fp-hash", "ok" => true, "value" => 42, "exp" => 12_345 } }
    wrapped = Troupe::Envelope.wrap({ "a" => 1 }, idem)
    assert_equal FIXTURES["envelope"]["wrapped"], wrapped # 深比较：漂移即红

    unwrapped = Troupe::Envelope.unwrap(wrapped)
    assert_equal({ "a" => 1 }, unwrapped[:props])
    assert_equal idem, unwrapped[:idem]
    assert_equal FIXTURES["envelope"]["mark"], Troupe::Envelope::MARK
    assert_equal FIXTURES["envelope"]["version"], Troupe::Envelope::VERSION
  end

  def test_envelope_prune_and_bare_passthrough
    now = 2_000
    pruned = Troupe::Envelope.prune_idem({ "live" => { "exp" => 3_000 }, "dead" => { "exp" => 1_000 } }, now)
    assert_equal({ "live" => { "exp" => 3_000 } }, pruned)
    # 裸形态（旧数据/手工植入）直接透传
    out = Troupe::Envelope.unwrap({ "a" => 1 })
    assert_equal({ "a" => 1 }, out[:props])
    assert_equal({}, out[:idem])
  end

  # wire 错误编码形状锚定 + 往返解码（R5 消息兼容语义）
  def test_wire_error_shape_and_roundtrip
    enc = lambda do |name|
      case name
      when "conflict"
        Troupe::Errors.wire_payload(Troupe::ConflictError.new("CAS 冲突：期望 revision=1，实际 revision=2"))
      when "rejected"
        Troupe::Errors.wire_payload(Troupe::CallRejectedError.new("白名单外方法", "whitelist"))
      else
        { "kind" => "business", "name" => "Error", "message" => "boom" }
      end
    end
    FIXTURES["wireErr"].each do |name, expected|
      actual = enc.call(name)
      assert_equal expected, actual, "wireErr #{name} 形状漂移"
      # 往返：decode → 再断言可恢复语义（R5：旧字段不被丢弃）
      decoded = Troupe::Transport.new(nil).send(:wire_error, actual)
      recovered_name = decoded.respond_to?(:error_name) ? decoded.error_name : decoded.class.name.split("::").last
      assert_equal expected["name"], recovered_name
      assert_equal expected["message"], decoded.message
    end
  end

  # cr golden/errors.json code 表映射锚点（M1 错误分类）
  def test_wire_code_mapping_matches_cr_table
    cases = {
      Troupe::ConflictError.new("x") => "CONFLICT",
      Troupe::CallTimeoutError.new("x") => "CALL_TIMEOUT",
      Troupe::CallRejectedError.new("x") => "CALL_REJECTED",
      Troupe::UnknownRoleError.new("x") => "UNKNOWN_ROLE",
      Troupe::SerializationError.new("x") => "INVALID_ARGUMENT",
      Troupe::InvalidActorStateError.new("x") => "INVALID_ACTOR_STATE",
      Troupe::ActivationError.new("x") => "ACTIVATION",
      Troupe::MigrationError.new("x") => "ACTIVATION",
      Troupe::IdempotencyConflictError.new("x") => "IDEMPOTENCY_CONFLICT",
      Troupe::ConnectionLostError.new("x") => "UNKNOWN_OUTCOME"
    }
    cases.each do |err, code|
      assert_equal code, Troupe::Errors.code_for(err), "#{err.class.name} → #{code}"
    end
  end

  # cr {"code": ...} 入站形状可解码（跨语言兼容）；业务错误 kind 兜底不破坏旧解码
  def test_decode_accepts_cr_code_shape
    t = Troupe::Transport.new(nil)
    decoded = t.send(:wire_error, { "code" => "CONFLICT", "kind" => "conflict", "name" => "ConflictError", "message" => "m1" })
    assert_instance_of Troupe::ConflictError, decoded
    assert_equal "m1", decoded.message

    decoded = t.send(:wire_error, { "code" => "CALL_REJECTED", "reason" => "backpressure", "message" => "m2" })
    assert_instance_of Troupe::CallRejectedError, decoded
    assert_equal "backpressure", decoded.reject_reason
    assert_equal true, decoded.retryable
  end
end
