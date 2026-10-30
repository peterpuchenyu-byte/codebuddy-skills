# 环境与配置参考

本文件描述**通用结构**，不包含任何具体公司的服务器地址、账号或网段。
真实拓扑只存在于 `config/servers-<env>.conf` 与 `config/services-<env>.conf`，且不进版本库。

## 环境模型

环境清单由 `config/environments.conf` 声明，每行四列：

```
名称|只读|允许变更|显示名
```

| 能力 | 由谁决定 | 影响 |
|---|---|---|
| 是否只读 | 第 2 列 | 只读环境拒绝一切变更动作 |
| 是否允许变更 | 第 3 列 | 未开启时 `build/upload/restart/all/verify` 直接拒绝 |

**不要凭环境名推断权限**。`staging` 是否允许发版取决于该列，而不是名字。

插件配置只保存 SSH 私钥**路径**，不保存私钥内容。内网节点需要 VPN；连接失败时先报告网络前提，不反复重试。

## 服务器角色（填写指引）

在 `config/servers-<env>.conf` 中按角色登记，建议在描述列写清职责，例如：

| 角色 | 描述列写法 | 说明 |
|---|---|---|
| 网关 | `Nginx 与门户` | 日志量最大，优先用时间范围查询 |
| 应用 | `核心服务` | 通常为多台，服务行可用逗号引用多个服务器 |
| 中间件 | `MQ/注册中心` | 一般不做业务日志检索 |
| 内网节点 | `内网, 需 VPN` | 不可达时先确认 VPN 再重试 |

## 日志约定

`services-<env>.conf` 的第 3 列是**日志目录模式**，支持两个占位符：

| 占位符 | 含义 |
|---|---|
| `{svc}` | 服务名（该行第 1 列） |
| `{host}` | 服务器的"内网IP或备注"字段 |

常见组合：

| 场景 | 目录模式 | glob |
|---|---|---|
| 按天滚动 | `/opt/{svc}/logs` | `app.*.log` |
| 单文件 | `/opt/{svc}/logs` | `app.log` |
| 混合命名 | `/opt/{svc}/logs` | `*.log` |
| 网关 | `/opt/nginx/logs` | `*.log` |
| 历史备份 | `/data/log-backup/{host}/{svc}` | `*.log` |

日志命名混合时统一用 `*.log` 匹配，避免漏文件。

## 配置格式

- `config/environments.conf`：`name|readonly|canDeploy|displayName`
- `config/servers-<env>.conf`：`name|host|user|key|lan|description`
- `config/services-<env>.conf`：`name|servers|logDir|logGlob|description`，可追加 `repo|module|dir|artifact|deployMode|kind|verifyUrl|packageManager`；旧 10 字段默认 `kind=jar`

配置目录的解析顺序（不再固定依赖插件根）：

1. 环境变量 `SERVICE_OPS_CONF`
2. 仓库内 `config/`（必须已存在 `servers-*.conf`）
3. `~/.codebuddy/config`

变更类动作的工作区根优先读取 `SERVICE_OPS_WS`，兼容旧变量 `SERVER_OPS_WS`；未设置时探测默认工作区路径。
