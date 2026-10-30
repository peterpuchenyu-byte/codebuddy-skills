# codebuddy-skills

可跨机器复用的 CodeBuddy 技能集合。当前收录两个**服务运维**技能：只读诊断与受控变更。

设计目标：换一台机器、甚至换一家公司，只需填几个配置文件，就能继续用同一套诊断与发布流程。

## 收录内容

| 技能 | 职责 | 默认能力 |
|---|---|---|
| `diagnose-services` | 服务与主机只读诊断：进程、健康、日志、traceId、Nginx 状态码、JVM/磁盘/内存/CPU | 只读 |
| `operate-test-services` | 受控变更：预检、构建、上传、重启、发布验证 | 需环境显式开启 |

两者共用同一套脚本与配置，脚本位于 `scripts/`，技能内的 `SKILL.md` 通过 `../../scripts/` 引用。

## 目录结构

```text
.
├── AGENTS.md                 # 给 AI 助手的仓库说明（接手前先读）
├── README.md
├── install.ps1               # Windows 安装脚本
├── install.sh                # macOS / Linux / Git Bash 安装脚本
├── config/
│   ├── environments.example.conf
│   ├── servers.example.conf
│   └── services.example.conf
├── scripts/
│   ├── service-ops.ps1
│   └── service-ops.sh
└── skills/
    ├── diagnose-services/
    │   ├── SKILL.md
    │   ├── references/{commands.md,topology.md}
    │   └── agents/openai.yaml
    └── operate-test-services/
        ├── SKILL.md
        ├── references/operations.md
        └── agents/openai.yaml
```

## 快速开始

### 1. 克隆并安装

Windows（PowerShell 7）：

```powershell
git clone <repo-url> codebuddy-skills
cd codebuddy-skills
.\install.ps1
```

macOS / Linux / Git Bash：

```bash
git clone <repo-url> codebuddy-skills
cd codebuddy-skills
./install.sh
```

默认安装到 `~/.codebuddy/skills/`，使用目录联接（Windows）或符号链接（Unix）。`git pull` 后无需重新安装。安装后需要重启 IDE，技能才会出现在列表中。

常用参数：

```bash
./install.sh -l                          # 列出仓库内技能
./install.sh -s diagnose-services        # 只装一个
./install.sh -c                          # 用复制而非链接
./install.sh -t /path/to/skills          # 自定义安装目录
```

已存在的目标目录默认**跳过**，不会被覆盖；确认可覆盖时加 `-f`。

### 2. 准备配置

仓库里只有 `*.example.conf` 模板，真实配置不进版本库。

```bash
mkdir -p ~/.codebuddy/config
cp config/environments.example.conf ~/.codebuddy/config/environments.conf
cp config/servers.example.conf     ~/.codebuddy/config/servers-prod.conf
cp config/services.example.conf    ~/.codebuddy/config/services-prod.conf
```

三份文件的字段说明写在各自文件的头部注释里。最小可运行需要：

- `environments.conf`：环境名 + 是否只读 + 是否允许变更
- `servers-<env>.conf`：主机、账号、私钥路径
- `services-<env>.conf`：服务名、所在服务器、日志目录、日志 glob

### 3. 自检

```bash
pwsh scripts/service-ops.ps1 <env> doctor query     # Windows
bash scripts/service-ops.sh  <env> doctor query     # Unix
```

`doctor` 会检查 SSH 可用性、配置完整性、私钥存在性与重复项。

## 常用命令

```bash
# 只读诊断
service-ops <env> list                       # 已配置服务
service-ops <env> servers                    # 已配置服务器
service-ops <env> <service> health            # 进程 + 最新日志 + 最近异常
service-ops <env> <service> logs 20250101     # 指定日期日志
service-ops <env> <service> trace <traceId>   # 追踪调用链
service-ops <env> <service> grep ERROR        # 关键字检索
service-ops <env> <service> count ERROR 20250101
service-ops <env> <server> disk|mem|top|jvm|net|services
service-ops <env> all nginx-stats             # 网关状态码统计

# 受控变更（要求环境开启"允许变更"）
service-ops <env> doctor deploy
service-ops <env> <service> plan|build|upload|restart|verify
service-ops <env> <service> all               # 完整链路
```

## 环境与权限模型

环境的权限由数据决定，不由名字推断：

```
名称|只读|允许变更|显示名
prod|1|0|生产
staging|1|1|预发布
```

- 只读=1：拒绝一切变更动作
- 允许变更=0：拒绝 `build/upload/restart/all/verify`

未提供 `environments.conf` 时，脚本回退为兼容行为：`prod` 只读、`test` 可变更。

## 配置目录解析顺序

脚本不再硬编码配置位置，按顺序查找：

1. 环境变量 `SERVICE_OPS_CONF` 指定的目录
2. 仓库内 `config/`（必须已存在 `servers-*.conf`）
3. `~/.codebuddy/config`

因此同一份脚本既能随仓库自带配置，也能沿用用户级配置目录。

## 安全约定

- 仓库中**永不**包含真实主机、账号、内网网段与私钥。
- `config/servers-*.conf`、`config/services-*.conf`、`config/environments.conf` 已在 `.gitignore` 中。
- 私钥只记录路径，不复制进仓库，不在输出中回显。
- 只读环境视为强只读：不构建、不上传、不重启、不修改远程文件。

## 新增技能

```text
skills/<skill-name>/
├── SKILL.md          # 必需，YAML frontmatter 含 name 与 description
├── scripts/          # 可选，脚本放技能目录内，用相对自身路径解析
├── references/       # 可选，按需加载的文档
└── assets/           # 可选，产物模板
```

要求：

- 目录名小写英文 + 连字符，与 frontmatter 的 `name` 一致
- 不写机器相关的绝对路径
- 需要外部配置时提供 `*.example.*` 模板，并把真实文件加入 `.gitignore`
- 双平台脚本同时提供时，`.ps1` 用 CRLF，`.sh` 用 LF
