# frozen_string_literal: true

module Troupe
  VERSION = "0.1.0"
  # 线路协议版本（M1 起锚定 troupejs protocol-v2 golden fixtures 的 protocolVersion=2；
  # hello 首帧握手显式协商，混跑不匹配即拒绝——学 cr ADR-0001 的 ack 缺口教训）
  PROTOCOL_VERSION = 2
end
