---
name: diagnose-services
description: '对只读环境中的服务和基础设施执行诊断：检查进程与健康状态、查询日志和时间窗口、追踪 traceId、统计 Nginx 状态码，并检查 JVM、磁盘、内存、CPU、端口和全局服务分布。用户提到服务异常、日志、ERROR/WARN、traceId、巡检、JVM、磁盘、内存、网络、Nginx、生产或测试服务器或要求定位故障时使用。只读环境始终只读。'
---

# Diagnose Services

使用技能内脚本完成服务、调用链和主机资源的证据化诊断。只执行查询动作；将允许变更环境中的构建、上传、重启、发布或自定义命令交给 `$operate-test-services`。

## 定位脚本

脚本随技能目录一起分发，以当前 `SKILL.md` 所在目录为基准：

- Windows：`scripts/service-ops.ps1`
- macOS / Linux / Git Bash：`scripts/service-ops.sh`

解析为绝对路径后执行，不依赖当前工作目录：

```bash
pwsh <skill-dir>/scripts/service-ops.ps1 <env> <target> <action> [args]
bash <skill-dir>/scripts/service-ops.sh <env> <target> <action> [args]
```

配置从 `~/.codebuddy/config/` 读取（可用 `SERVICE_OPS_CONF` 覆盖）。首次使用前需按仓库内 `config/*.example.conf` 准备 `environments.conf`、`servers-<env>.conf`、`services-<env>.conf`。

拼装查询命令时读取 [references/commands.md](references/commands.md)。确认服务器、服务、日志目录或配置格式时读取 [references/topology.md](references/topology.md)。

## 诊断流程

1. 运行 `<env> doctor query`，确认 SSH、配置引用和私钥路径完整。
2. 已知服务但问题模糊时运行 `<service> health`，聚合进程、最新日志元数据和最近异常。
3. 已知时间范围时运行 `logsrange`；已知 traceId 时运行 `trace`；已知关键词时运行 `grep`、`grepall` 或 `count`。
4. 怀疑主机资源时按需运行 `jvm`、`disk`、`mem`、`top` 或 `net`。
5. 怀疑网关或接口错误时运行 `nginx-stats`。
6. 汇总结论、证据、已执行动作和未覆盖风险，不倾倒完整终端输出。

## 查询边界

- 将 prod 视为强只读环境，不构建、上传、重启、修改文件或执行通用 `exec`。
- 在此 Skill 中也不执行 test 写操作或通用 `exec`。
- 优先使用 `health`、时间范围、关键词和 tail，避免下载或整文件读取大日志。
- 普通单机查询使用约 20 秒超时；跨服务器查询使用约 60 秒超时。
- 不暴露 SSH 私钥内容、密码、令牌或完整敏感业务字段。
- 失败时报告环境、目标、动作和关键错误，不静默切换环境、服务器或日期范围。

## 输出格式

- **结论**：服务是否运行、问题范围和最可能原因。
- **证据**：服务器、日志文件、时间窗口、错误计数或资源指标。
- **动作**：实际执行的只读查询。
- **风险**：未覆盖服务器、VPN/SSH 不可达、日志缺失或时间范围不完整。
