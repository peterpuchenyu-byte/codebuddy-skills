# AGENTS.md

给 AI 助手的仓库说明。接手本仓库或在新机器上部署前，先读完本文。

## 这个仓库是什么

一套**与具体公司解耦**的服务运维技能包，供 CodeBuddy 通过 `.codebuddy/skills/` 加载。
它由"引擎 + 配置"两部分组成：

- **引擎**（可跨公司复用）：`scripts/service-ops.ps1`、`scripts/service-ops.sh`，以及两个 `SKILL.md` 里的诊断/发布流程。
- **配置**（每家环境各填一次）：`config/*.conf`，不进版本库。

不要把公司特有的主机、账号、网段、私钥写进任何被 git 跟踪的文件。

## 硬事实（改代码前必须知道）

| 事实 | 内容 |
|---|---|
| 技能加载位置 | 用户级 `~/.codebuddy/skills/<name>/`；项目级 `<workspace>/.codebuddy/skills/<name>/` |
| 技能识别条件 | 目录内存在 `SKILL.md`，且 YAML frontmatter 有 `name` 与 `description` |
| 脚本定位方式 | `SKILL.md` 用相对自身路径的 `../../scripts/`，即仓库根下的 `scripts/`。**不要改成绝对路径** |
| 配置目录解析顺序 | `SERVICE_OPS_CONF` → 仓库内 `config/`（须已存在 `servers-*.conf`）→ `~/.codebuddy/config` |
| 环境权限来源 | `config/environments.conf` 每行 `名称\|只读\|允许变更\|显示名`；**不要按环境名推断能力** |
| 无 environments.conf 时 | 回退为 `prod` 只读、`test` 可变更（兼容旧用法） |
| 变更守卫 | 所有变更动作统一走 `Assert-Deployable`（ps1）/ `assert_deployable`（sh） |
| 发版工作区根 | `SERVICE_OPS_WS`，兼容 `SERVER_OPS_WS` |
| 换行 | `.ps1` 用 CRLF，`.sh` 用 LF |

## 在新机器上部署（按此顺序执行）

1. `git clone <repo>` 到任意位置。
2. 安装技能：Windows 用 `.\install.ps1`，Unix 用 `./install.sh`。默认建链接，`git pull` 后自动生效。
3. 准备配置：把 `config/*.example.conf` 复制到 `~/.codebuddy/config/`，去掉 `.example` 并填入真实值。
4. 自检：`service-ops <env> doctor query`。它会检查 ssh、私钥存在性、配置重复项。
5. 提醒用户重启 IDE —— 否则技能不会出现在列表中。

配置不全时不要伪造数据。缺什么就报告缺什么，并指出该填哪个文件的哪一列。

## 行为边界

- `diagnose-services`：**只读**。不构建、不上传、不重启、不执行通用 `exec`，即使环境允许变更。
- `operate-test-services`：仅在用户本轮明确授权后执行变更。所有生产变更请求必须停止并说明走正式流程。
- 用户的"看看、检查、排查"一律按只读处理，不得据此触发 `build/upload/restart/all`。
- 不绕过脚本直接拼 ssh/scp/mvn 命令。

## 修改本仓库时的规则

1. **双平台同步**：改 `service-ops.ps1` 必须同步改 `service-ops.sh`，反之亦然。两者行为要一致。
2. **不引入绝对路径**：脚本用 `$PSCommandPath` / `BASH_SOURCE` 推导自身位置。
3. **配置只放模板**：新增配置项时，同步更新 `config/*.example.conf` 与 `.gitignore`。
4. **不提交真实值**：提交前检查 `git diff`，确认没有主机、账号、密钥、内网地址。
5. **改完必须验证语法**：
   - `[System.Management.Automation.Language.Parser]::ParseFile($path,[ref]$null,[ref]$errs)`
   - `bash -n scripts/service-ops.sh`
6. **动作须有守卫**：新增变更类动作时，入口先调用 `Assert-Deployable` / `assert_deployable`。
7. 修改 `SKILL.md` 的 `description` 会改变技能触发时机，改动后要说明影响。

## 常见故障

| 现象 | 原因 | 处理 |
|---|---|---|
| 技能不出现 | 未重启 IDE，或目标目录缺 `SKILL.md` | 重启；检查 frontmatter 的 `name`/`description` |
| `配置文件不存在` | 三个 conf 没放到位 | 按解析顺序逐个检查，或用 `SERVICE_OPS_CONF` 显式指定 |
| `环境 'x' 未在 ... 中声明` | `environments.conf` 缺该环境行 | 补一行，或在无该文件时用 `prod`/`test` |
| `只在允许变更的环境可用` | 该环境"允许变更"列为 0 | 修改配置，而不是绕过守卫 |
| ssh 连接超时 | 内网节点需要 VPN | 先报告网络前提，不循环重试 |
| `Permission denied (publickey)` | 私钥路径错或权限过宽 | 检查 conf 第 4 列；Unix 下 `chmod 600` |
| Windows 下链接失败 | 无创建 Junction 权限 | 改用 `-Copy`（ps1）或复制方式安装 |

## 不要做的事

- 不要把真实 `config/*.conf` 提交进仓库，也不要在回复里展开私钥内容。
- 不要按环境名硬编码只读/可变更语义。
- 不要删掉 `environments.conf` 缺失时的回退分支，否则老配置会直接报错。
- 不要在 `SKILL.md` 里写死机器相关的绝对路径。
