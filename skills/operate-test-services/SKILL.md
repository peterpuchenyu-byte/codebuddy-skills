---
name: operate-test-services
description: '对允许变更的环境执行有副作用的服务运维：预检发布条件、展示变更计划、构建并发布 Maven/JAR 后端或前端静态资源、发布后验证，或在用户明确要求时执行服务器自定义命令。用户要求测试发版、构建、上传、部署、重启、更新 JAR、发布前端、执行测试机命令或验证发布结果时使用。不得用于只读环境的变更。'
---

# Operate Test Services

仅在用户本轮明确授权后操作允许变更的环境。环境的只读/可变更语义由 `config/environments.conf` 声明。对只读环境的任何变更请求都停止执行，并说明必须走正式生产运维流程。

## 定位脚本

以当前 `SKILL.md` 的绝对路径为基准，解析插件根目录脚本：

- Windows：`../../scripts/service-ops.ps1`
- macOS / Linux / Git Bash：`../../scripts/service-ops.sh`

将脚本路径解析为绝对路径后执行：

```bash
pwsh <plugin-root>/scripts/service-ops.ps1 <env> <target> <action> [args]
bash <plugin-root>/scripts/service-ops.sh <env> <target> <action> [args]
```

拼装命令或判断副作用时读取 [references/operations.md](references/operations.md)。

## 授权边界

- 将“看看、排查、检查、预检”解释为只读，不据此执行 build、upload、restart、all 或 exec。
- 将“发布、部署、一键发版”解释为授权执行目标服务的完整 `all` 链路。
- 将“重启、上传、构建、执行命令”解释为只授权对应动作，不扩展为完整发布。
- 目标服务、环境或命令不明确时停止写操作并确认，不猜测。
- 不绕过脚本环境保护，不直接拼 SSH/SCP/Maven 命令替代脚本。

## 发布流程

1. 运行 `<env> doctor deploy`，按已配置服务类型检查 SSH、工作区、Maven/JDK 或 Node/Corepack/tar 等依赖。
2. 运行 `<env> <service> plan`，展示服务类型、repo/module、构建产物、目标服务器、发布模式和验证 URL。
3. 按授权范围运行 `build`、`upload`、`restart` 或完整 `all`。
4. 运行 `verify`：后端核验远程 JAR、进程和最近异常；前端核验远程 `index.html` 与 HTTP 200。
5. 返回每个阶段的成功/失败证据；任一阶段失败即停止后续写操作。

静态前端服务（`kind=frontend`）完全由服务配置驱动：`artifact` 指定构建目录，`deployMode=static`，`packageManager` 决定包管理器——`pnpm@版本` 通过 Corepack 执行 `install --frozen-lockfile`，`npm` 执行 `npm ci`。manifest 与 lockfile 不兼容或不同步时必须停止，不得用 `--force`、`--no-frozen-lockfile` 或 `npm install` 绕过。`upload` 将构建产物打包后在 Nginx 目录旁解压并原子替换，保留带时间戳的上一版目录用于回滚，`restart` 为显式无操作。不得把前端仓按 JAR 发布。内网节点不可达时先报告 VPN 前提，不循环重试。完整发布使用约 600 秒超时。

## 自定义测试命令

仅当用户明确给出测试服务器和命令时运行 `test <server> exec <command>`。执行前检查命令目标与副作用，不运行删除数据、清空目录、改防火墙或其他难恢复命令，除非用户明确授权且目标经过只读确认。

## 输出格式

- **计划**：服务类型、仓库/模块、目标服务器、构建产物、发布模式和授权动作。
- **执行**：doctor、plan、build、upload、restart、verify 或 exec 的实际结果。
- **验证**：后端报告远程 JAR 时间、进程状态和最近异常；前端报告远程 `index.html` 与 HTTP 状态。
- **风险**：未覆盖节点、VPN/SSH 不可达、回滚条件或验证缺口。
