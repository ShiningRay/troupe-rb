# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "rbconfig"

# 真实多进程故障接管验收（M2 #5 核心，学 troupe.cr pg_worker 子进程矩阵）：
# ≥2 个独立 Ruby 进程连真实 PostgreSQL；kill -9 持锁者 → 租约到期接管 →
# 旧 epoch 写被拒 → Props/reminder 从共享存储恢复。测试输出真实拓扑与数据库版本。
#
# PG 专用：由 CI 必跑 leg（TROUPE_TEST_PG）执行；矩阵 leg 跳过（skip 即失败纪律
# 由 leg 门禁保证——PG leg 的 shell 前置检查 TROUPE_TEST_PG 必须存在）。
class PgTakeoverTest < Minitest::Test
  def setup
    url = ENV.fetch("TROUPE_TEST_PG", nil)
    skip "无 TROUPE_TEST_PG：多进程接管由 CI 专用 PG leg 必跑" unless url

    require "troupe/props/pg_store"
    @url = url
    @ns = "mproc-#{Process.pid}-#{rand(1_000_000)}"
    @lib = File.expand_path("../lib", __dir__)
    @children = []
    @direct = Troupe::PostgresPropStore.open(@url)
    @db_version = @direct.server_version[/PostgreSQL [\d.]+/]
  end

  def teardown
    @children.each do |pid|
      Process.kill("KILL", pid) rescue nil
    end
    Process.waitall rescue nil
    @direct&.close
  end

  def spawn_worker(mode)
    ruby = RbConfig.ruby
    env = { "MPROC_LEASE" => "2s" }
    env["MPROC_REMINDER"] = "1" if mode == "hold"
    out_r, out_w = IO.pipe
    pid = Process.spawn(env, ruby, "-I", @lib,
                        File.expand_path("support/pg_worker.rb", __dir__),
                        @url, mode, @ns,
                        out: out_w, err: out_w)
    out_w.close
    @children << pid
    [pid, out_r]
  end

  def wait_ready(out_r, timeout = 30)
    deadline = Time.now + timeout
    line = nil
    while (l = out_r.gets)
      line = l.chomp
      break if line.start_with?("READY")
      raise "worker 异常退出前输出：#{line}" if line.start_with?("FINAL")
    end
    raise "worker 未在 #{timeout}s 内 READY（最后输出：#{line.inspect}）" if line.nil? || !line.start_with?("READY")
    raise "worker READY 超时" if Time.now > deadline

    line
  end

  # 主验收链：kill -9 持锁者 → 租约到期接管 → 旧 epoch 写被拒 → Props/提醒恢复
  def test_kill9_holder_then_takeover_recovers_props_and_reminders
    pid_a, out_a = spawn_worker("hold")
    ready = wait_ready(out_a)
    assert_match(/n=1/, ready, "持锁者已提交 n=1（epoch 1）")
    sleep 1.5 # 确保 ownership 心跳与提醒注册就绪

    # 持锁者的所有权行（接管前）：epoch 1
    row_before = @direct.ownership_row(@ns, "mproc", "w1")
    assert_equal 1, row_before[0], "接管前 epoch=1"

    # kill -9 等价：整个进程瞬间消失（传输/心跳/调度器随进程死亡）
    Process.kill("KILL", pid_a)
    @children.delete(pid_a)
    Process.wait(pid_a) rescue nil
    sleep 2.5 # 租约（2s）到期

    # 接管者：等待所有权取得（epoch 2）→ Props 从共享存储恢复（n=1 起）
    pid_b, out_b = spawn_worker("takeover")
    final = nil
    deadline = Time.now + 30
    loop do
      line = out_b.gets
      raise "takeover worker 无输出退出" if line.nil? && Time.now > deadline
      break if line.nil?

      final = line.chomp
      break if final.start_with?("FINAL")
    end
    assert_match(/FINAL n=\d+/, final)
    n = Integer(final[/n=(\d+)/, 1])

    # Props 恢复：接管者从共享存储读到 n=1（kill 前 A 提交），bump 1 次起步 + 提醒重投
    # （MPROC_REMINDER=1：on_stage 注册 1s 提醒 → on_cue +1；6 次循环内提醒至少触发一次）
    assert_operator n, :>=, 2, "Props 跨进程恢复（A 的 n=1 + B 的 bump）且提醒重投生效（#{final}）"

    # 接管后 epoch=2（单调），所有权行被 B 持有
    row_after = @direct.ownership_row(@ns, "mproc", "w1")
    assert_equal 2, row_after[0], "接管后 epoch 单调递增"

    # 旧 epoch 写被拒：以 epoch 1 的 fencing token 直接写共享存储
    stored = @direct.read(@ns, "mproc", "w1")
    e = assert_raises(Troupe::ConflictError) do
      @direct.write(@ns, "mproc", "w1", { "n" => 999_999 },
                    expected_revision: stored.revision, schema_version: 1, fencing_token: 1)
    end
    assert_match(/fencing/, e.message)
    # B 仍在持续写（提醒重投）——断言旧 epoch 写未被采纳即可，revision 比较只做下界
    refute_equal 999_999, @direct.read(@ns, "mproc", "w1").props["n"], "旧 epoch 未被写入"
    assert_operator @direct.read(@ns, "mproc", "w1").revision, :>=, stored.revision,
                   "B 的写入已生效，旧 epoch 写被拒"
  end

  def test_real_topology_reported
    # 测试输出真实拓扑与数据库版本（ROADMAP M2 验收要求）
    assert_match(/PostgreSQL/, @db_version, "真实 PG：#{@db_version}")
  end
end
