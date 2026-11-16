# frozen_string_literal: true

# 多进程验收 worker（M2 #5，学 troupe.cr pg_worker 子进程矩阵）：
# 独立 Ruby 进程连真实 PG，充当一个 Stage。由 pg_takeover_test 派生与 kill -9。
# stdout 协议：READY 行（激活完成）→ 行为按 mode。
$stdout.sync = true

url = ARGV[0]
mode = ARGV[1] # hold | takeover
ns = ARGV[2]

require_relative "../../lib/troupe"

class MprocCounter < Troupe::Actor
  role_id "mproc"
  schema_version 1
  initial_props { { "n" => 0 } }

  def bump(v = 1)
    props["n"] += v
    save_props
    props["n"]
  end

  def slow(ms = 60_000)
    sleep(ms / 1000.0) # 长 Turn：持有所有权与串行通道
    props["n"] += 100
    save_props
    props["n"]
  end

  def on_stage
    schedule_reminder("beat", "1s") if ENV["MPROC_REMINDER"] == "1" # 提醒恢复验收
  end

  def on_cue(_name, _payload)
    props["n"] += 1
    save_props
  end

  def value
    props["n"]
  end
end

troupe = Troupe.form(
  actors: [MprocCounter], prop_store: url, cue_store: url,
  port: 0, namespace: ns, ownership_lease: ENV.fetch("MPROC_LEASE", "2s")
)
agent = troupe.cast(MprocCounter, "w1")

case mode
when "hold"
  puts "READY n=#{agent.bump(1)}" # 激活 + 提交（epoch 1）
  $stdout.flush
  agent.slow(120_000) # 挂在长 Turn 上等待被 kill -9
when "takeover"
  puts "READY n=#{agent.value}"
  $stdout.flush
  6.times do # 接管后：既有 Props 恢复 + 提醒重投（跨进程）
    agent.bump(1)
    sleep 0.5
  end
  puts "FINAL n=#{agent.value} reminders=#{troupe.cue_store.records.size}"
  troupe.shutdown!
  exit 0
end
