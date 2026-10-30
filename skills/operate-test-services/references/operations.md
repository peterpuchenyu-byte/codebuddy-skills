# 测试环境操作参考

以下示例省略脚本绝对路径，以 `service-ops` 表示已解析的 PowerShell 或 Bash 脚本。

## 发布动作

| 命令 | 副作用 |
|---|---|
| `service-ops test doctor deploy` | 无；按服务类型检查配置、SSH key、工作区及 Maven/JDK 或 Node/Corepack/tar/curl |
| `service-ops test <service> plan` | 无；展示目标和发布配置 |
| `service-ops test <service> build` | 后端执行 Maven test profile；前端执行 pnpm 锁定安装和 `build:test` |
| `service-ops test <service> upload` | 后端原子替换 JAR；前端原子替换静态目录并保留上一版目录 |
| `service-ops test <service> restart` | 后端调用远程重启脚本；静态前端为显式无操作 |
| `service-ops test <service> verify` | 无写入；核验后端 JAR/进程/异常或前端 `index.html`/HTTP 200 |
| `service-ops test <service> all` | `build → upload → restart(按类型) → verify` |

`plan/build/upload/restart/verify/all` 在只读环境或未开启变更的环境必须失败。是否可发布以 `config/services-<env>.conf` 的 `repo/module/dir/artifact/deployMode/kind/verifyUrl/packageManager` 字段为准。旧 10 字段服务默认 `kind=jar`，保持原发布行为。

## 服务类型

- `jar`：`artifact` 是模块 `target` 下的 JAR，`deployMode` 是 `script` 或 `stopstart`。
- `frontend`：`artifact` 是仓库内构建目录，`deployMode=static`，`verifyUrl` 是发布后 HTTP 验证地址，`packageManager` 是 `npm` 或 Corepack 使用的固定 `pnpm@版本`。
- 静态前端：构建目录由 `artifact` 指定（通常为 `dist`），发布到目标 Nginx 静态目录；每次切换保留 `dist.backup.<releaseId>` 供人工回滚，不自动清理历史备份。
- 包管理器由 `packageManager` 列决定：`npm` 使用 `npm ci`，`pnpm@版本` 通过 Corepack 执行 `install --frozen-lockfile`。不得临时升级包管理器、改用 `npm install` 或取消冻结安装绕过 lockfile 校验。

## 自定义命令

| 命令 | 副作用 |
|---|---|
| `service-ops test <server> exec <command>` | 在指定测试服务器运行用户明确给出的命令 |

prod `exec` 必须失败。不要使用 `exec` 绕过标准发布链路。

## 示例

```bash
service-ops test doctor deploy
service-ops test order-api plan
service-ops test order-api all
service-ops test order-api verify
service-ops test portal-web plan
service-ops test portal-web all
```

完整发布前确认：

1. 目标是 `test`。
2. 服务存在并配置了发布字段。
3. 用户本轮明确授权了对应写动作。
4. `doctor deploy` 和 `plan` 均通过。
5. 发布后执行 `verify` 并报告证据。
