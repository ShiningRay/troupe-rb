# 验证基线（2026-11-14）

环境：Windows、Ruby 4.0.6、Bundler 4.0.24，工作树 `0fa1af1`（文档提交前）。

## 默认入口

```sh
bundle exec rake test
```

**失败，未进入测试**：`test/test_helper.rb:6` 加载 `logger` 报 `LoadError`。Ruby 4 起 logger 为 bundled gem，当前依赖未声明。见 [#1](https://github.com/ShiningRay/troupe/issues/1)。

## 诊断运行

使用 Rake 的直接路径绕开 Bundler，只为观察后续失败，不是修复或替代默认入口：

```sh
ruby C:/Ruby40-x64/lib/ruby/gems/4.0.0/gems/rake-13.4.2/exe/rake test
```

结果：**89 runs，4720 assertions，4 failures，3 errors，0 skips**。

- 1 个 Minitest 6 `assert_same nil` 断言失败（[#4](https://github.com/ShiningRay/troupe/issues/4)）。
- Rehearsal namespace 与硬编码存储 key 不一致，迁移/接管/恢复测试未正确读取既有 Props（[#2](https://github.com/ShiningRay/troupe/issues/2)）。
- 源码另确认多级迁移只调用一次（[#3](https://github.com/ShiningRay/troupe/issues/3)）。

因此 README 的历史“78 runs”不能作为当前测试状态；本文不代表 Issues 已解决，也未进行真实多机故障验收。
