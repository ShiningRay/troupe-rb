# frozen_string_literal: true

require_relative "lib/troupe/version"

Gem::Specification.new do |s|
  s.name = "troupe"
  s.version = Troupe::VERSION
  s.summary = "Troupe.rb —— Virtual Actor 框架（Troupe.js 的 Ruby 版本）"
  s.description = "面向 Ruby 的 Virtual Actor 框架：永远存在的 Actor、Turn-based 严格串行、" \
                  "Props 持久化、一致性哈希集群、持久提醒。命名与语义对标 Troupe.js（Orleans/Orbit 思想）。"
  s.authors = ["shiningray"]
  s.homepage = "https://github.com/ShiningRay/troupe"
  s.license = "MIT"
  # 支持矩阵：>= 3.2（CI 矩阵 3.2/3.3/3.4/4.0；Ruby 4 起 logger 降为 bundled gem）
  s.required_ruby_version = ">= 3.2"
  s.files = Dir["lib/**/*.rb"] + %w[bin/troupe README.md DESIGN_NOTES.md DESIGN_REVIEW.md LICENSE]
  s.bindir = "bin"
  s.executables = ["troupe"]
  # Ruby 4.0 起 logger/pstore、Ruby 3.4 起 bigdecimal 从默认 gem 降为 bundled gem，
  # 必须显式声明（Issue #1 同源问题）；sqlite3/webrick 为可选适配器（按需 lazy require）
  s.add_dependency "logger", ">= 1.5"
  s.add_dependency "bigdecimal", ">= 1.3"
  s.add_dependency "pstore", ">= 0.1"
  s.add_development_dependency "minitest", "~> 5.0"
  s.add_development_dependency "rake", "~> 13.0"
  # 其余运行时零 gem 依赖：PStore/TCPSocket/JSON 均为 stdlib；sqlite3 为可选适配器
end
