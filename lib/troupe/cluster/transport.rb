# frozen_string_literal: true

require "json"
require "socket"
require_relative "../call"
require_relative "../errors"
require_relative "../util"

module Troupe
  # TCP 传输（DESIGN §6.1）：4 字节小端长度前缀 + JSON payload。
  # 单机默认绑定 loopback；帧长度上限 / 未完成请求上限 / 背压显式拒绝；
  # 畸形帧可控拒绝，连接与进程不崩。
  class Transport
    FRAME_MAX = 8 * 1024 * 1024
    DEFAULT_TOKEN = ""

    attr_reader :troupe, :bound_port

    def initialize(troupe)
      @troupe = troupe
      @server = nil
      @accept_thread = nil
      @conns = {}
      @conns_lock = Mutex.new
      @pool = nil
      @stopped = false
      @advertise = nil
    end

    def advertise
      @advertise
    end

    def start
      host = @troupe.config.host
      @server = bind(host, @troupe.config.port)
      @bound_port = @server.addr[1]
      effective_host = @troupe.config.advertise&.split(":")&.first || (host == "0.0.0.0" ? "127.0.0.1" : host)
      @advertise = @troupe.config.advertise || "#{effective_host}:#{@bound_port}"
      @pool = WorkerPool.new(@troupe.config.remote_workers)
      @accept_thread = Thread.new do
        begin
          Thread.current.name = "troupe-accept"
        rescue StandardError
          nil
        end
        accept_loop
      end
      Log.info("Stage 监听 #{@advertise}（mode=#{@troupe.config.mode}）")
    end

    def stop
      @stopped = true
      begin
        @server&.close
      rescue StandardError
        nil
      end
      @pool&.stop
      conns = @conns_lock.synchronize { @conns.values }
      conns.each(&:close!)
      @conns_lock.synchronize { @conns.clear }
    end

    # ---- 出站 ----

    def forward(owner_addr, call)
      conn = conn_for(owner_addr)
      conn.call_remote(call)
    rescue ConnectionLostError, TroupeError
      raise # 超时/拒绝等分类错误原样传播（结果未知语义不改变）
    rescue StandardError => e
      raise ConnectionLostError, "连接 #{owner_addr} 失败：#{e.class}: #{e.message}（结果未知，不等于失败）"
    end

    def ping(addr, timeout: 1.0)
      conn = conn_for(addr)
      conn.request({ "t" => "ping" }, timeout)
      true
    end

    # 协作取消控制帧（Issue #7，advisory）：单向发送，不等响应——
    # 不保证到达；发送失败只记日志（调用方仍在处理自己的结果未知）
    def cancel(owner_addr, call_id)
      conn = conn_for(owner_addr)
      conn.notify("t" => "cancel", "callId" => call_id)
      true
    rescue StandardError => e
      Log.debug("cancel 帧发送失败（advisory）：#{e.class}: #{e.message}")
      false
    end

    # 返回对端 summary（reader 已合并进本地 roster）
    def sync(addr, summary, timeout: 2.0)
      conn = conn_for(addr)
      conn.request({ "t" => "sync", "summary" => summary }, timeout)
    end

    def director_call(addr, method, args, timeout: 5.0)
      conn = conn_for(addr)
      deadline_ms = Util.now_ms + (timeout * 1000).to_i
      call = Call.new(namespace: @troupe.config.namespace, role_id: Director::ROLE_ID, stage_name: "-",
                      method: method.to_sym, args: args, deadline_ms: deadline_ms, source: :admin)
      conn.call_remote(call)
    end

    def subscribe_trace(addr, filter, timeout: 5.0, &blk)
      conn = conn_for(addr)
      conn.on_trace = blk
      conn.request({ "t" => "sub", "filter" => filter }, timeout)
      conn
    end

    def conn_for(addr)
      @conns_lock.synchronize do
        c = @conns[addr]
        return c if c && !c.closed?

        host, port = addr.split(":", 2)
        c = ClientConn.new(self, host, Integer(port, 10))
        @conns[addr] = c
        c
      end
    end

    def client_dead(conn)
      @conns_lock.synchronize do
        @conns.delete_if { |_, c| c.equal?(conn) }
      end
    end

    # ---- 帧 ----

    def read_frame(sock)
      header = read_exact(sock, 4)
      len = header.unpack1("V")
      raise ProtocolError, "帧长度 #{len} 超过上限 #{FRAME_MAX}" if len > FRAME_MAX

      payload = read_exact(sock, len)
      JSON.parse(payload)
    rescue JSON::ParserError
      raise ProtocolError, "帧不是合法 JSON"
    end

    def read_exact(sock, n)
      buf = +"".b
      while buf.bytesize < n
        chunk = sock.read(n - buf.bytesize)
        raise EOFError, "连接关闭" unless chunk

        buf << chunk
      end
      buf
    end

    def write_frame(sock, obj)
      data = JSON.generate(obj)
      raise ProtocolError, "帧超出长度上限" if data.bytesize > FRAME_MAX

      # 统一为二进制：帧头 pack 产物是 ASCII-8BIT，payload 可能是 UTF-8
      sock.write(([data.bytesize].pack("V") + data).b)
    rescue Errno::EPIPE, Errno::ECONNRESET, IOError
      raise ConnectionLostError, "连接已断开（结果未知）"
    end

    def call_to_wire(call)
      frame = {
        "v" => PROTOCOL_VERSION, "callId" => call.call_id,
        "ns" => call.namespace,
        "to" => { "role" => call.role_id, "stageName" => call.stage_name },
        "method" => call.method.to_s, "args" => call.args,
        "deadline" => call.deadline_ms, "hop" => call.hop
      }
      frame["traceparent"] = call.traceparent if call.traceparent # §11.4 跨 Stage 传播
      frame["cancellable"] = true if call.cancellable? # Issue #7：跨 Stage 取消投递
      frame
    end

    def wire_to_call(c)
      to = c["to"] || {}
      call = Call.new(
        namespace: c["ns"].to_s, role_id: to["role"].to_s, stage_name: to["stageName"].to_s,
        method: c["method"].to_s, args: c["args"].is_a?(Array) ? c["args"] : [],
        deadline_ms: c["deadline"] ? Integer(c["deadline"]) : nil,
        source: :remote, call_id: c["callId"], hop: Integer(c["hop"] || 0),
        cancellable: c["cancellable"] == true
      )
      call.traceparent = c["traceparent"].to_s if c["traceparent"]
      call
    end

    # 错误解码：优先 cr code 表（{"code": ...}），兼容 js v2 形状（kind/name/reason/phase）。
    # 栈（backtrace）永不跨线（M1 错误映射）。
    def wire_error(err)
      err ||= {}
      name = err["name"].to_s
      message = err["message"].to_s
      kind = err["kind"].to_s
      reason = err["reason"].to_s
      phase = err["phase"].to_s
      attach = ->(e) { e.tap { |x| x.phase = phase if x.respond_to?(:phase=) && !phase.empty? } }

      case err["code"]
      when "CONFLICT" then ConflictError.new(message)
      when "CALL_TIMEOUT" then attach.call(CallTimeoutError.new(message, phase: phase_to_sym(phase)))
      when "CALL_REJECTED" then CallRejectedError.new(message, reason.empty? ? nil : reason)
      when "UNKNOWN_OUTCOME" then decode_unknown(name, message)
      when "IDEMPOTENCY_CONFLICT" then IdempotencyConflictError.new(message)
      when "UNKNOWN_ROLE" then UnknownRoleError.new(message)
      when "INVALID_ARGUMENT" then SerializationError.new(message)
      when "INVALID_ACTOR_STATE" then InvalidActorStateError.new(message)
      when "ACTIVATION" then decode_activation(name, message)
      when "PROTOCOL" then ProtocolError.new(message)
      else
        decode_legacy(kind, name, message, reason, phase)
      end
    end

    def phase_to_sym(phase)
      phase == "queued" ? :queued : (:executing if phase == "executing")
    end

    def decode_unknown(name, message)
      name == "CallTimeoutError" ? CallTimeoutError.new(message) : ConnectionLostError.new(message)
    end

    def decode_activation(name, message)
      case name
      when "MigrationError" then MigrationError.new(message)
      when "OwnershipError" then OwnershipError.new(message)
      else ActivationError.new(message)
      end
    end

    # js v2 / 旧 trouperb 形状：kind + name（+reason/phase）
    def decode_legacy(kind, name, message, reason, phase)
      case kind
      when "business" then RemoteError.new(name, message)
      when "conflict" then ConflictError.new(message)
      when "unknown" then decode_unknown(name, message)
      else
        klass = name.empty? ? nil : begin
          k = ::Troupe.const_get(name) # 顶层限定：模块内 Troupe 会被词法解析为 Troupe::Troupe
          k.is_a?(Class) && k < ::Troupe::TroupeError ? k : nil
        rescue NameError
          nil
        end
        e = (klass || CallRejectedError).new(message, reason.empty? ? nil : reason)
        e.phase = phase.to_sym if e.respond_to?(:phase=) && !phase.empty?
        e
      end
    end

    private

    def bind(host, port)
      if @troupe.config.mode == "production"
        TCPServer.new(host, port) # production：固定端口，占用即失败
      else
        candidates = port.zero? ? [0] : (port..port + 9).to_a + [0]
        candidates.each do |p|
          begin
            s = TCPServer.new(host, p)
            Log.info("dev 模式：端口 #{port} 被占，改用 #{p}") if p != port && p != 0
            return s
          rescue Errno::EADDRINUSE
            next
          end
        end
        raise ConfigError, "无法绑定 #{host}:#{port}（dev 已尝试 #{port}..#{port + 9} 与随机端口）"
      end
    end

    def accept_loop
      loop do
        client = @server.accept
        Thread.new { serve(client) }
      end
    rescue StandardError => e
      unless @stopped || e.is_a?(IOError)
        Log.debug("accept 循环退出：#{e.class}: #{e.message}")
      end
    end

    def serve(sock)
      peer_ip = begin
        sock.peeraddr(false)[2]
      rescue StandardError
        "unknown"
      end
      # 版本协商（M1）：首帧必须是 hello，携带 protocolVersion；不匹配显式拒绝并关连接。
      # 旧版本节点（无 hello）连入同样被显式拒绝——mixed-version 不静默混跑（学 js）。
      hello = read_frame(sock)
      unless hello.is_a?(Hash) && hello["t"] == "hello"
        raise ProtocolError, "首帧必须是 hello（协议版本协商）：收到 #{hello.is_a?(Hash) ? hello['t'].inspect : hello.class}"
      end

      check_cluster_token!(hello)
      peer_v = hello["v"]
      if peer_v != PROTOCOL_VERSION
        write_frame(sock, { "t" => "hello", "id" => hello["id"], "ok" => false, "v" => PROTOCOL_VERSION,
                            "error" => "协议版本不匹配：本端 v#{PROTOCOL_VERSION}，对端 v#{peer_v.inspect}" })
        raise ProtocolError, "协议版本不匹配：本端 v#{PROTOCOL_VERSION}，对端 v#{peer_v.inspect}（显式拒绝，不混跑）"
      end
      write_frame(sock, { "t" => "hello", "id" => hello["id"], "ok" => true, "v" => PROTOCOL_VERSION })

      loopback = %w[127.0.0.1 ::1 localhost].include?(peer_ip)
      conn = ServerConn.new(self, sock, peer_ip, loopback)
      loop do
        frame = read_frame(sock)
        break unless handle_frame(conn, frame)
      end
    rescue ProtocolError => e
      Log.warn("畸形帧可控拒绝（#{peer_ip}）：#{e.message}") # 连接与进程不崩
    rescue ConnectionLostError, EOFError, IOError, Errno::ECONNRESET, Errno::EPIPE
      # 正常断开
    rescue StandardError => e
      Log.error("连接处理异常（#{peer_ip}）：#{e.class}: #{e.message} @ #{e.backtrace&.first}")
    ensure
      begin
        sock.close
      rescue StandardError
        nil
      end
    end

    def handle_frame(conn, frame)
      unless frame.is_a?(Hash) && frame["t"].is_a?(String)
        raise ProtocolError, "帧缺少类型字段 t"
      end

      check_cluster_token!(frame)
      case frame["t"]
      when "call"
        handle_call(conn, frame)
        true
      when "cancel"
        # 协作取消控制帧（Issue #7，advisory）：按 callId 定位在飞/排队 Call；
        # 非 call 帧，不进白名单路径；cluster token 校验已覆盖信任边界
        @troupe.stage_manager.cancel_by_call_id(frame["callId"].to_s)
        true
      when "ping"
        conn.reply("t" => "ack", "id" => frame["id"], "incarnation" => @troupe.incarnation)
        true
      when "sync"
        @troupe.roster.merge(frame["summary"])
        conn.reply("t" => "sync", "id" => frame["id"], "summary" => @troupe.roster.summary)
        true
      when "sub"
        handle_subscribe(conn, frame)
        true
      when "resp", "trace", "ack", "hello"
        true # 客户端方向的帧出现在服务端：忽略
      else
        raise ProtocolError, "未知帧类型 #{frame['t'].inspect}"
      end
    end

    # cluster token 校验（M2 传输认证）：常时比较；轮换宽限期内接受上一代 token
    # （rotate：current→previous，宽限后 revoke——置空 previous 即完成撤销）
    def check_cluster_token!(frame)
      expected = @troupe.config.cluster_token
      return if expected.nil? || expected.empty?

      provided = frame["token"].to_s
      accepted = [expected, @troupe.config.cluster_token_previous].compact.reject(&:empty?)
      unless accepted.any? { |t| Util.secure_compare(provided, t) }
        raise ProtocolError, "cluster token 校验失败：节点加入需受控网络或 join 凭证（DESIGN §6.1）"
      end
    end

    def handle_call(conn, frame)
      c = frame["call"]
      unless c.is_a?(Hash)
        conn.reply(error_resp(frame, CallRejectedError.new("非法信封：缺少 call")))
        return
      end

      to = c["to"].is_a?(Hash) ? c["to"] : {}
      if to["role"] == Director::ROLE_ID
        admin = @troupe.config.admin_token
        authorized = conn.loopback || (!admin.nil? && !admin.empty? && Util.secure_compare(frame["token"].to_s, admin))
        unless authorized
          conn.reply(error_resp(frame, CallRejectedError.new("Director 仅响应 loopback；远程访问需 TROUPE_ADMIN_TOKEN（DESIGN §11.1）")))
          return
        end

        # Director 是系统内省角色：不进用户 Repertoire，直接在本 Stage 处理
        @pool.push!(proc do
          result = @troupe.director.handle(c["method"].to_s, c["args"].is_a?(Array) ? c["args"] : [])
          conn.reply("t" => "resp", "callId" => c["callId"], "ok" => true, "result" => result)
        rescue TroupeError => e
          conn.reply("t" => "resp", "callId" => c["callId"], "ok" => false,
                     "error" => Errors.wire_payload(e, error_name(e)))
        end)
        return
      end

      call = wire_to_call(c)
      call.from_stage = frame["from"].to_s
      @pool.push!(proc do
        value = @troupe.dispatch_inbound(call)
        conn.reply("t" => "resp", "callId" => call.call_id, "ok" => true, "result" => value)
      rescue TroupeError => e
        conn.reply("t" => "resp", "callId" => call.call_id, "ok" => false,
                   "error" => Errors.wire_payload(e, error_name(e)))
      rescue StandardError => e
        conn.reply("t" => "resp", "callId" => call.call_id, "ok" => false,
                   "error" => { "kind" => "business", "name" => e.class.name.to_s, "message" => e.message.to_s })
      end)
    rescue BackpressureError => e
      conn.reply(error_resp(frame, e))
    end

    def error_name(e)
      e.is_a?(RemoteError) ? e.error_name : e.class.name.split("::").last
    end

    def error_resp(frame, e)
      { "t" => "resp", "callId" => (frame["call"].is_a?(Hash) ? frame["call"]["callId"] : nil), "ok" => false,
        "error" => Errors.wire_payload(e, error_name(e)) }
    end

    def handle_subscribe(conn, frame)
      admin = @troupe.config.admin_token
      authorized = conn.loopback || (!admin.nil? && !admin.empty? && Util.secure_compare(frame["token"].to_s, admin))
      unless authorized
        conn.reply("t" => "sub", "ok" => false, "message" => "tail 需要 loopback 或 admin token")
        return
      end

      sub = @troupe.trace.subscribe(frame["filter"] || {}) do |event|
        conn.reply("t" => "trace", "event" => event)
      end
      conn.on_close { sub.close }
      conn.reply("t" => "sub", "ok" => true)
    end
  end

  # ---- 服务端连接 ----
  class ServerConn
    attr_reader :ip, :loopback

    def initialize(transport, sock, ip, loopback)
      @transport = transport
      @sock = sock
      @ip = ip
      @loopback = loopback
      @wm = Mutex.new
      @on_close = nil
    end

    def on_close(&blk)
      @on_close = blk
    end

    def reply(frame)
      @wm.synchronize { @transport.write_frame(@sock, frame) }
    rescue ConnectionLostError, IOError, Errno::EPIPE
      @on_close&.call
      raise EOFError, "client gone"
    end

    def close
      @on_close&.call
    end
  end

  # ---- 客户端连接（按需建立、断线重连懒初始化） ----
  class ClientConn
    HELLO_TIMEOUT_S = 5.0

    attr_accessor :on_trace

    def initialize(transport, host, port)
      @transport = transport
      @addr = "#{host}:#{port}"
      @sock = TCPSocket.new(host, port)
      begin
        @sock.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)
      rescue StandardError
        nil
      end
      @pending = {}
      @lock = Mutex.new
      @wm = Mutex.new
      @closed = false
      @reader = Thread.new do
        begin
          Thread.current.name = "troupe-client-#{@addr}"
        rescue StandardError
          nil
        end
        read_loop
      end
      negotiate!
    end

    def closed?
      @closed
    end

    def read_loop
      loop do
        frame = @transport.read_frame(@sock)
        case frame["t"]
        when "resp"
          box = @lock.synchronize { @pending.delete(frame["callId"]) }
          if box
            if frame["ok"]
              box.settle_ok(frame["result"])
            else
              box.settle_error(@transport.wire_error(frame["error"]))
            end
          end
        when "hello"
          settle_by_id(frame["id"], frame) # 版本协商响应
        when "trace"
          @on_trace&.call(frame["event"])
        when "sync"
          @transport.troupe.roster.merge(frame["summary"])
          settle_by_id(frame["id"], frame)
        when "ack"
          settle_by_id(frame["id"], frame)
        when "sub"
          settle_by_id(frame["id"], frame)
        end
      end
    rescue StandardError
      close!
    end

    def settle_by_id(id, frame)
      return unless id

      box = @lock.synchronize { @pending.delete(id) }
      box&.settle_ok(frame)
    end

    # 通用请求-响应（hello / ping / sync / sub）
    def request(frame, timeout)
      id = Util.call_id
      box = ResponseBox.new
      frame = frame.merge("id" => id, "token" => token)
      @lock.synchronize { @pending[id] = box }
      begin
        @wm.synchronize { @transport.write_frame(@sock, frame) }
      rescue StandardError => e
        @lock.synchronize { @pending.delete(id) }
        raise ConnectionLostError, "#{@addr} 发送失败：#{e.message}（结果未知）"
      end
      box.wait!(Util.now_ms + (timeout * 1000).to_i)
    end

    # 单向通知帧（cancel，advisory）：不等响应、不占 pending
    def notify(frame)
      @wm.synchronize { @transport.write_frame(@sock, frame.merge("token" => token)) }
      nil
    end

    # 版本协商（M1）：连接后首帧 hello，携带 protocolVersion；不匹配显式拒绝
    def negotiate!
      hello = request({ "t" => "hello", "v" => PROTOCOL_VERSION }, HELLO_TIMEOUT_S)
      unless hello["ok"] && hello["v"] == PROTOCOL_VERSION
        raise ProtocolError,
              "协议版本不匹配：本端 v#{PROTOCOL_VERSION}，对端 #{hello['v'].inspect}（#{hello['error']}）"
      end
    rescue ConnectionLostError => e
      raise ProtocolError, "版本协商失败：#{e.message}（对端可能为不支持 hello 的旧版本节点）"
    rescue CallTimeoutError
      raise ProtocolError, "版本协商超时（对端未响应 hello）"
    end

    def call_remote(call)
      box = ResponseBox.new
      @lock.synchronize { @pending[call.call_id] = box }
      frame = { "t" => "call", "from" => @transport.troupe.advertise, "token" => token, "call" => @transport.call_to_wire(call) }
      begin
        @wm.synchronize { @transport.write_frame(@sock, frame) }
      rescue StandardError => e
        @lock.synchronize { @pending.delete(call.call_id) }
        raise ConnectionLostError, "#{@addr} 发送失败：#{e.message}（结果未知，不等于失败）"
      end
      box.wait!(call.deadline_ms)
    ensure
      @lock.synchronize { @pending.delete(call.call_id) }
    end

    def fail_pending(err)
      boxes = @lock.synchronize do
        boxes = @pending.values
        @pending.clear
        boxes
      end
      boxes.each { |b| b.settle_error(err) }
    end

    def close!
      return if @closed

      @closed = true
      begin
        @sock.close
      rescue StandardError
        nil
      end
      fail_pending(ConnectionLostError.new("#{@addr} 连接断开：结果未知，不等于失败（DESIGN §6.5）"))
      @transport.client_dead(self)
    end

    private

    def token
      @transport.troupe.config.cluster_token.to_s
    end
  end

  # 固定 worker 池：in-flight 上限 = 队列 + worker 数，超限显式拒绝（DESIGN §5.3）
  class WorkerPool
    def initialize(size, max_queue: 512)
      @q = SizedQueue.new(max_queue)
      @workers = Array.new(size) do
        Thread.new do
          begin
            Thread.current.name = "troupe-worker"
          rescue StandardError
            nil
          end
          loop do
            job = @q.pop
            break if job == :stop

            begin
              job.call
            rescue StandardError => e
              Log.error("worker 异常：#{e.class}: #{e.message}")
            end
          end
        end
      end
    end

    def push!(job)
      @q.push(job, true)
    rescue ThreadError
      raise BackpressureError, "in-flight RPC 超限：过载显式拒绝（DESIGN §5.3）"
    end

    def stop
      @workers.size.times { @q.push(:stop) }
      @workers.each { |w| w.join(1) }
    end
  end
end
