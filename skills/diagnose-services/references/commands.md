# 只读命令参考

以下示例省略脚本绝对路径，以 `service-ops` 表示已解析的 PowerShell 或 Bash 脚本。

## 全局查询

| 命令 | 说明 |
|---|---|
| `service-ops <env> doctor query` | 检查查询依赖、配置引用和 SSH key |
| `service-ops <env> list` | 列出服务 |
| `service-ops <env> servers` | 列出服务器 |
| `service-ops <env> trace <traceId> [services] [server]` | 默认追踪核心服务，可指定逗号分隔服务 |
| `service-ops <env> nginx-stats <server> [date] [domain]` | 统计状态码、5xx/4xx 和 URL |
| `service-ops <env> all-disk` | 查询所有服务器磁盘 |
| `service-ops <env> all-ps` | 查询所有服务器 Java 进程 |

## 服务查询

| 命令 | 说明 |
|---|---|
| `service-ops <env> <service> status [server]` | 查询服务进程 |
| `service-ops <env> <service> health [server] [date]` | 聚合进程、最新日志和最近 2 万行错误/WARN |
| `service-ops <env> <service> logs [N] [server] [date]` | 查询最近 N 行日志，默认 100 |
| `service-ops <env> <service> grep <pattern> [N] [server] [date] [ctx]` | 在单台服务器搜索，默认 200 条 |
| `service-ops <env> <service> grepall <pattern> [N] [date] [ctx]` | 在全部部署服务器搜索 |
| `service-ops prod <service> backupgrep <pattern> [date] [server] [ctx]` | 搜索生产历史备份 |
| `service-ops <env> <service> logsrange <start> <end> [pattern] [server] [date]` | 按时间范围搜索 |
| `service-ops <env> <service> count <pattern> [server] [date]` | 统计关键词 |
| `service-ops <env> <service> logfiles [server] [date]` | 列出日志文件 |

日期使用 `YYYYMMDD`，时间使用 `YYYY-MM-DD HH:mm`。`health` 不指定服务器时检查服务配置中的全部服务器。

## 主机查询

| 命令 | 说明 |
|---|---|
| `service-ops <env> <server> ps` | 查询 Java 进程 |
| `service-ops <env> <server> jvm [filter]` | 查询 JVM CPU、内存、运行时长和命令行 |
| `service-ops <env> <server> disk` | 查询文件系统容量 |
| `service-ops <env> <server> mem` | 查询内存摘要 |
| `service-ops <env> <server> top` | 查询 CPU 快照 |
| `service-ops <env> <server> services` | 查询 `/opt` 服务目录 |
| `service-ops <env> <server> net` | 查询监听端口与连接统计 |

不要在此 Skill 中调用 test `exec` 或任何发布动作。

## 常见流程

```bash
service-ops prod order-api health app-01
service-ops prod order-api logsrange "2026-08-18 10:00" "2026-08-18 10:20" "ERROR" app-01
service-ops prod trace "ec960f54fa55417092ed4077910b7c49"
```
