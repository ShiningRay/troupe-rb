# frozen_string_literal: true

module Troupe
  # 存储信封（对齐 troupejs core/envelope，DESIGN §6.5/§7.3）：幂等记录必须随
  # Props **原子提交**，因此运行时写入 PropStore 的 props 字段是本信封——
  # 用户 Props 与幂等记录同一行落盘。PropStore 只存 blob，信封由运行时解释
  # （Director/inspect 展示时同样先解包）。
  #
  # 兼容：非信封形态（裸对象）视为手工植入的用户 Props——旧数据直接可读；
  # 新数据被旧版本读取会把信封键当作用户 Props（PStore 为开发级存储，
  # 滚动升级场景见 README 已知边界）。
  module Envelope
    MARK = "__troupe_envelope__"
    VERSION = 1

    module_function

    # IdemRecord 形状（R6）：{ fp: 参数指纹, ok: 成功与否, value: 结果, err: {name, message}, exp: 过期 epoch ms }
    def wrap(props, idem)
      { MARK => VERSION, "props" => props, "idem" => idem || {} }
    end

    def unwrap(stored_props)
      if stored_props.is_a?(Hash) && stored_props[MARK] == VERSION
        { props: stored_props["props"], idem: stored_props["idem"] || {} }
      else
        { props: stored_props, idem: {} } # 裸形态：非信封数据
      end
    end

    def enveloped?(stored_props)
      stored_props.is_a?(Hash) && stored_props[MARK] == VERSION
    end

    # 清除已过保留期限的幂等记录（save/load 时惰性执行，DESIGN §6.5 默认 7 天）
    def prune_idem(idem, now_ms)
      out = {}
      (idem || {}).each do |k, rec|
        out[k] = rec if rec.is_a?(Hash) && rec["exp"].to_i > now_ms
      end
      out
    end
  end
end
