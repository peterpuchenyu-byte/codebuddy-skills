#requires -Version 7
# service-ops.ps1 — 多环境服务运维工具 (只读诊断 / 受控变更)
# 用法: pwsh service-ops.ps1 <env> <service|server|all> <action> [args]
# 环境能力由 config/environments.conf 声明; 未声明时回退为 prod=只读, test=可变更
# 只读环境不提供 build/upload/restart/all/verify

$ErrorActionPreference = 'Stop'
$PluginRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
# 配置目录解析顺序: SERVICE_OPS_CONF > 插件根/config (须含 servers-*.conf) > ~/.codebuddy/config
# 目的: 同一份脚本既能随仓库携带模板运行, 也能沿用用户级配置目录, 不绑定某一台机器
$ConfDir = $env:SERVICE_OPS_CONF
if (-not $ConfDir) {
    foreach ($candidate in @((Join-Path $PluginRoot 'config'), (Join-Path $HOME '.codebuddy/config'))) {
        if (Get-ChildItem $candidate -Filter 'servers-*.conf' -ErrorAction SilentlyContinue) { $ConfDir = $candidate; break }
    }
}
if (-not $ConfDir) { $ConfDir = Join-Path $HOME '.codebuddy/config' }

# 工作区根 (test 环境发版用)
$WsDir = $env:SERVICE_OPS_WS
if (-not $WsDir) { $WsDir = $env:SERVER_OPS_WS }
if (-not $WsDir) {
    @('D:\vibecoding-workspace', (Join-Path $HOME 'vibecoding-workspace')) | ForEach-Object {
        if (Test-Path $_) { $WsDir = $_ }
    }
}

# 颜色输出
function Write-Log($msg) { Write-Host ">> $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "!! $msg" -ForegroundColor Yellow }
function Write-Die($msg) { Write-Host "XX $msg" -ForegroundColor Red; exit 1 }
function Write-Header($msg) { Write-Host $msg -ForegroundColor Cyan }

function Resolve-Date($date) {
    if ($null -eq $date) { return $null }

    $dateText = ([string]$date).Trim()
    if (-not $dateText) { return $null }
    if ($dateText -notmatch '^\d{8}$') { Write-Die "日期必须是 YYYYMMDD: $dateText" }

    $parsedDate = [datetime]::MinValue
    $isValid = [datetime]::TryParseExact(
        $dateText,
        'yyyyMMdd',
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::None,
        [ref]$parsedDate
    )
    if (-not $isValid) { Write-Die "日期无效: $dateText" }

    return $dateText
}

# ---- 环境选择 ----
# 环境由 config/environments.conf 声明, 每行: 名称|只读|允许变更|显示名
# 未提供 environments.conf 时回退到内置的 prod(只读)/test(可变更), 兼容旧用法
function Get-EnvDeclaration($envName) {
    $envFile = Join-Path $ConfDir 'environments.conf'
    if (Test-Path $envFile) {
        $line = (Get-Config $envFile) | Where-Object { ($_ -split '\|')[0].Trim() -eq $envName } | Select-Object -First 1
        if (-not $line) { Write-Die "环境 '$envName' 未在 $envFile 中声明" }
        $parts = $line -split '\|'
        $readOnlyFlag = if ($parts.Count -ge 2) { $parts[1].Trim() } else { '' }
        $deployFlag = if ($parts.Count -ge 3) { $parts[2].Trim() } else { '' }
        return @{
            Name = $envName
            IsReadOnly = [bool]($readOnlyFlag -match '^(?i)(1|yes|true|是|只读)$')
            CanDeploy = [bool]($deployFlag -match '^(?i)(1|yes|true|是)$')
        }
    }
    if ($envName -notin @('prod', 'test')) { Write-Die "环境 '$envName' 未声明（缺少 $envFile）" }
    return @{ Name = $envName; IsReadOnly = ($envName -eq 'prod'); CanDeploy = ($envName -eq 'test') }
}

function Get-EnvConfig($envName) {
    $decl = Get-EnvDeclaration $envName
    return @{
        Name = $decl.Name
        ServersFile = "$ConfDir\servers-$($decl.Name).conf"
        ServicesFile = "$ConfDir\services-$($decl.Name).conf"
        IsReadOnly = $decl.IsReadOnly
        CanDeploy = $decl.CanDeploy
    }
}

# 允许变更类动作的统一守卫: 只读环境或未开启变更的环境一律拒绝
function Assert-Deployable($envName, $action) {
    $cfg = Get-EnvConfig $envName
    if (-not $cfg.CanDeploy) { Write-Die "$action 只在允许变更的环境可用（当前环境 $envName）" }
}

function Get-Config($file) {
    if (-not (Test-Path $file)) { Write-Die "配置文件不存在: $file" }
    Get-Content $file | Where-Object { $_ -and $_ -notmatch '^\s*#' }
}

function Load-Server($envName, $key) {
    $cfg = Get-EnvConfig $envName
    $line = (Get-Config $cfg.ServersFile) | Where-Object { $_ -match "^$key\|" } | Select-Object -First 1
    if (-not $line) { Write-Die "server '$key' 未配置 ($($cfg.ServersFile))" }
    $parts = $line -split '\|'
    $keyPath = $parts[3]
    # 展开 ~ 为 $HOME (跨平台: Windows PowerShell 和 macOS pwsh 都支持 $HOME)
    if ($keyPath -match '^~') { $keyPath = $keyPath -replace '^~', $HOME }
    return @{
        Name = $parts[0]; Host = $parts[1]; User = $parts[2]; Key = $keyPath; Lan = $parts[4]; Desc = $parts[5]
    }
}

function Load-Service($envName, $key) {
    $cfg = Get-EnvConfig $envName
    $line = (Get-Config $cfg.ServicesFile) | Where-Object { $_ -match "^$key\|" } | Select-Object -First 1
    if (-not $line) { Write-Die "service '$key' 未配置 ($($cfg.ServicesFile))" }
    $parts = $line -split '\|'
    $svc = @{
        Name = $parts[0]; Servers = $parts[1]; LogDirTpl = $parts[2]; LogGlob = $parts[3]; Desc = $parts[4]
    }
    # test 环境额外字段 (发版用)
    if ($cfg.CanDeploy -and $parts.Count -ge 10) {
        $svc.Repo = $parts[5]
        $svc.Module = $parts[6]
        $svc.Dir = $parts[7]
        $svc.Artifact = $parts[8]
        $svc.DeployMode = $parts[9]
        $svc.Kind = if ($parts.Count -ge 11 -and $parts[10]) { $parts[10] } else { 'jar' }
        $svc.VerifyUrl = if ($parts.Count -ge 12) { $parts[11] } else { '' }
        $svc.PackageManager = if ($parts.Count -ge 13) { $parts[12] } else { '' }
        # 保留旧字段别名，避免改变既有后端 JAR 发布逻辑。
        $svc.Jar = $svc.Artifact
        $svc.RestartMode = $svc.DeployMode
    }
    return $svc
}

# ---- SSH/SCP 执行 ----
function Ssh-Run($host_, $key, $user, $cmd) {
    $opts = @('-o', 'StrictHostKeyChecking=no', '-o', 'ConnectTimeout=15', '-o', 'BatchMode=yes', '-i', $key)
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($cmd))
    & ssh @opts "${user}@${host_}" "echo $b64 | base64 -d | bash" 2>$null
}

function Scp-Put($host_, $key, $user, $localPath, $remotePath) {
    $opts = @('-o', 'StrictHostKeyChecking=no', '-o', 'ConnectTimeout=15', '-i', $key)
    & scp @opts "$localPath" "${user}@${host_}:$remotePath" 2>$null
}

function Resolve-LogDir($tpl, $svc, $lan) {
    $tpl -replace '\{svc\}', $svc -replace '\{host\}', $lan
}

# ---- 列出 ----
function Do-List($envName) {
    $cfg = Get-EnvConfig $envName
    Write-Log "[$envName] 已配置服务:"
    Get-Config $cfg.ServicesFile | ForEach-Object { Write-Host $_ }
}

function Do-Servers($envName) {
    $cfg = Get-EnvConfig $envName
    Write-Log "[$envName] 已配置服务器:"
    Get-Config $cfg.ServersFile | ForEach-Object { Write-Host $_ }
}

# ---- 本地运行条件检查 ----
function Do-Doctor($envName, $mode) {
    if (-not $mode) { $mode = 'query' }
    if ($mode -notin @('query', 'deploy')) { Write-Die "doctor 模式必须是 query 或 deploy" }
    if ($mode -eq 'deploy') { Assert-Deployable $envName 'deploy' }

    $cfg = Get-EnvConfig $envName
    $serverLines = @(Get-Config $cfg.ServersFile)
    $serviceLines = @(Get-Config $cfg.ServicesFile)
    $serverNames = @($serverLines | ForEach-Object { ($_ -split '\|')[0] })
    $serviceNames = @($serviceLines | ForEach-Object { ($_ -split '\|')[0] })
    $failures = @()

    foreach ($tool in @('ssh')) {
        if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { $failures += "缺少命令: $tool" }
    }
    foreach ($duplicate in @($serverNames + $serviceNames | Group-Object | Where-Object Count -gt 1)) {
        $failures += "配置名称重复: $($duplicate.Name)"
    }
    foreach ($line in $serviceLines) {
        $parts = $line -split '\|'
        foreach ($serverRef in ($parts[1] -split ',')) {
            if ($serverRef -notin $serverNames) { $failures += "服务 $($parts[0]) 引用了未知服务器 $serverRef" }
        }
        if ($parts.Count -ge 11 -and $parts[10] -and $parts[10] -notin @('jar', 'frontend')) {
            $failures += "服务 $($parts[0]) 的 kind 无效: $($parts[10])"
        }
        if ($parts.Count -ge 11 -and $parts[10] -eq 'frontend') {
            $packageManager = if ($parts.Count -ge 13) { $parts[12] } else { '' }
            if (-not $packageManager) {
                $failures += "前端服务 $($parts[0]) 未配置 packageManager"
            } elseif ($packageManager -ne 'npm' -and $packageManager -notmatch '^pnpm@\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.-]+)?$') {
                $failures += "前端服务 $($parts[0]) 的 packageManager 无效: $packageManager"
            }
        }
    }
    foreach ($line in $serverLines) {
        $parts = $line -split '\|'
        $keyPath = $parts[3] -replace '^~', $HOME
        if (-not (Test-Path $keyPath)) { $failures += "私钥不存在: $keyPath" }
    }

    if ($mode -eq 'deploy') {
        $deployServices = @($serviceLines | ForEach-Object {
            $parts = $_ -split '\|'
            if ($parts.Count -ge 10 -and $parts[5]) {
                [PSCustomObject]@{
                    Kind = if ($parts.Count -ge 11 -and $parts[10]) { $parts[10] } else { 'jar' }
                    PackageManager = if ($parts.Count -ge 13) { $parts[12] } else { '' }
                }
            }
        })
        $requiredTools = @('scp')
        if ($deployServices.Kind -contains 'jar') { $requiredTools += @('mvn', 'java') }
        if ($deployServices.Kind -contains 'frontend') { $requiredTools += @('node', 'tar') }
        if ($deployServices.PackageManager -contains 'npm') { $requiredTools += 'npm' }
        if (@($deployServices.PackageManager | Where-Object { $_ -match '^pnpm@' }).Count -gt 0) { $requiredTools += 'corepack' }
        foreach ($tool in $requiredTools) {
            if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { $failures += "缺少命令: $tool" }
        }
        if (-not $WsDir -or -not (Test-Path $WsDir)) { $failures += "未找到工作区，设置 SERVICE_OPS_WS（兼容 SERVER_OPS_WS）" }
    }

    Write-Log "[$envName] doctor/${mode}: servers=$($serverNames.Count), services=$($serviceNames.Count)"
    if ($failures.Count -gt 0) {
        $failures | Sort-Object -Unique | ForEach-Object { Write-Warn $_ }
        Write-Die "doctor 检查失败，共 $($failures.Count) 项"
    }
    Write-Log "doctor 检查通过"
}

# ---- 查服务进程 ----
function Do-Status($envName, $svc, $serverFilter) {
    $s = Load-Service $envName $svc
    # 进程匹配优先用 artifact (如 dispatch-1.0-SNAPSHOT.jar), 避免误匹配系统进程 (如 /usr/sbin/sedispatch)
    $matchP = if ($s.Artifact) { $s.Artifact } else { $s.Name }
    Write-Log "[$envName] status: $($s.Name) ($($s.Desc))"
    foreach ($srvName in ($s.Servers -split ',')) {
        if ($serverFilter -and $srvName -ne $serverFilter) { continue }
        $srv = Load-Server $envName $srvName
        Write-Header "[$($srv.Name) $($srv.Host) $($srv.Lan)]"
        Ssh-Run $srv.Host $srv.Key $srv.User "ps -ef | grep '$matchP' | grep -v grep || echo '(未运行)'"
    }
}

# ---- 服务健康聚合 ----
function Do-Health($envName, $svc, $serverFilter, $date) {
    $date = Resolve-Date $date
    $s = Load-Service $envName $svc
    # 进程匹配优先用 artifact, 避免误匹配系统进程
    $matchP = if ($s.Artifact) { $s.Artifact } else { $s.Name }
    $servers = @($s.Servers -split ',')
    if ($serverFilter -and $serverFilter -notin $servers) { Write-Die "$svc 未部署在 $serverFilter" }
    Write-Log "[$envName] health: $($s.Name)（进程 + 最近20000行日志）"

    foreach ($srvName in $servers) {
        if ($serverFilter -and $srvName -ne $serverFilter) { continue }
        $srv = Load-Server $envName $srvName
        $logdir = Resolve-LogDir $s.LogDirTpl $s.Name $srv.Lan
        $fileSel = "ls -t ${logdir}/$($s.LogGlob) 2>/dev/null | head -1"
        if ($date) {
            $dateDash = "$($date.Substring(0,4))-$($date.Substring(4,2))-$($date.Substring(6,2))"
            $fileSel = "ls -t '${logdir}'/*${date}*.log '${logdir}'/*${dateDash}*.log 2>/dev/null | head -1"
        }
        Write-Header "[$($srv.Name) $($srv.Host)]"
        $cmd = @"
pid=`$(pgrep -f -- '$matchP' | head -1)
if [ -n "`$pid" ]; then ps -p "`$pid" -o pid=,pcpu=,pmem=,etime=,args=; else echo 'PROCESS: DOWN'; fi
f=`$($fileSel)
if [ -z "`$f" ]; then echo 'LOG: NOT_FOUND'; exit 0; fi
echo "LOG: `$f"
stat -c 'UPDATED: %y | SIZE: %s bytes' "`$f" 2>/dev/null || true
errors=`$(tail -n 20000 "`$f" | grep -ciE 'ERROR|Exception|Caused by:' || true)
warns=`$(tail -n 20000 "`$f" | grep -ci 'WARN' || true)
echo "RECENT_20000: errors=`$errors warns=`$warns"
echo '=== 最近异常摘要（最多20行） ==='
tail -n 20000 "`$f" | grep -iE 'ERROR|WARN|Exception|Caused by:' | tail -n 20 || true
"@
        Ssh-Run $srv.Host $srv.Key $srv.User $cmd
    }
}

# ---- 查日志 ----
function Do-Logs($envName, $svc, $n, $server, $date) {
    $date = Resolve-Date $date
    $s = Load-Service $envName $svc
    $srvArr = $s.Servers -split ','
    $target = if ($server) { $server } else { $srvArr[0] }
    $srv = Load-Server $envName $target
    $logdir = Resolve-LogDir $s.LogDirTpl $s.Name $srv.Lan
    Write-Header "[$($srv.Name) $($srv.Host)]"
    Write-Log "[$envName] logs ($($s.Desc)): 最近 $n 行"
    if ($date) {
        $dateDash = "$($date.Substring(0,4))-$($date.Substring(4,2))-$($date.Substring(6,2))"
        $cmd = "ls -t '${logdir}'/*${date}*.log '${logdir}'/*${dateDash}*.log 2>/dev/null | head -1 | xargs -r tail -n $n"
        Ssh-Run $srv.Host $srv.Key $srv.User $cmd
    } else {
        $cmd = @"
f=`$(ls -t ${logdir}/$($s.LogGlob) 2>/dev/null | head -1)
if [ -n "`$f" ]; then echo "文件: `$f"; tail -n $n "`$f"; else echo "(无日志文件)"; fi
"@
        Ssh-Run $srv.Host $srv.Key $srv.User $cmd
    }
}

# ---- 搜日志 ----
function Do-Grep($envName, $svc, $pat, $n, $server, $date, $context) {
    $date = Resolve-Date $date
    $s = Load-Service $envName $svc
    $srvArr = $s.Servers -split ','
    $target = if ($server) { $server } else { $srvArr[0] }
    $srv = Load-Server $envName $target
    $logdir = Resolve-LogDir $s.LogDirTpl $s.Name $srv.Lan
    Write-Header "[$($srv.Name) $($srv.Host)]"
    $ctxDesc = if ($context) { " 上下文${context}行" } else { "" }
    Write-Log "[$envName] grep '$pat' ($($s.Desc)): 最近 $n 条$ctxDesc"
    $glob = $s.LogGlob
    $grepOpts = "-hiE"
    if ($context) { $grepOpts = "-hiE -C $context" }
    if ($date) {
        $dateDash = "$($date.Substring(0,4))-$($date.Substring(4,2))-$($date.Substring(6,2))"
        $cmd = @"
files=`$(ls -t ${logdir}/*${date}*.log ${logdir}/*${dateDash}*.log 2>/dev/null | head -3)
if [ -n "`$files" ]; then echo "`$files" | xargs grep $grepOpts '${pat}' | tail -n $n; fi
"@
    } else {
        $cmd = @"
files=`$(ls -t ${logdir}/${glob} 2>/dev/null | head -3)
if [ -n "`$files" ]; then echo "`$files" | xargs grep $grepOpts '${pat}' | tail -n $n; fi
"@
    }
    Ssh-Run $srv.Host $srv.Key $srv.User $cmd
}

# ---- 搜日志 (所有服务器) ----
function Do-GrepAll($envName, $svc, $pat, $n, $date, $context) {
    $date = Resolve-Date $date
    $s = Load-Service $envName $svc
    $ctxDesc = if ($context) { " 上下文${context}行" } else { "" }
    Write-Log "[$envName] grep '$pat' on ALL servers for $($s.Name): 每台 $n 条$ctxDesc"
    $glob = $s.LogGlob
    $grepOpts = "-hiE"
    if ($context) { $grepOpts = "-hiE -C $context" }
    foreach ($srvName in ($s.Servers -split ',')) {
        $srv = Load-Server $envName $srvName
        $logdir = Resolve-LogDir $s.LogDirTpl $s.Name $srv.Lan
        Write-Header "=== [$($srv.Name) $($srv.Host) $($srv.Lan)] ==="
        if ($date) {
            $dateDash = "$($date.Substring(0,4))-$($date.Substring(4,2))-$($date.Substring(6,2))"
            $cmd = @"
files=`$(ls -t ${logdir}/*${date}*.log ${logdir}/*${dateDash}*.log 2>/dev/null | head -3)
if [ -n "`$files" ]; then echo "`$files" | xargs grep $grepOpts '${pat}' | tail -n $n; fi
"@
        } else {
            $cmd = @"
files=`$(ls -t ${logdir}/${glob} 2>/dev/null | head -3)
if [ -n "`$files" ]; then echo "`$files" | xargs grep $grepOpts '${pat}' | tail -n $n; fi
"@
        }
        Ssh-Run $srv.Host $srv.Key $srv.User $cmd
    }
}

# ---- 搜历史备份日志 (prod独有, 共享盘) ----
function Do-BackupGrep($envName, $svc, $pat, $date, $server, $context) {
    $date = Resolve-Date $date
    $s = Load-Service $envName $svc
    $srvArr = $s.Servers -split ','
    $target = if ($server) { $server } else { $srvArr[0] }
    $srv = Load-Server $envName $target
    $bkdir = "/data/prod-log-backup/$($srv.Lan)/$($s.Name)"
    $ctxDesc = if ($context) { " 上下文${context}行" } else { "" }
    Write-Header "[$($srv.Name) 备份 $($srv.Lan)]"
    Write-Log "[$envName] backup grep '$pat' ($($s.Desc)): $bkdir$ctxDesc"
    $grepOpts = "-hiE"
    if ($context) { $grepOpts = "-hiE -C $context" }
    if ($date) {
        $dateDash = "$($date.Substring(0,4))-$($date.Substring(4,2))-$($date.Substring(6,2))"
        $cmd = @"
files=`$(ls -t ${bkdir}/*${date}*.log ${bkdir}/*${dateDash}*.log 2>/dev/null | head -3)
if [ -n "`$files" ]; then echo "`$files" | xargs grep $grepOpts '${pat}' | tail -n 200; fi
"@
    } else {
        $cmd = @"
files=`$(ls -t ${bkdir}/*.log 2>/dev/null | head -3)
if [ -n "`$files" ]; then echo "`$files" | xargs grep $grepOpts '${pat}' | tail -n 200; fi
"@
    }
    Ssh-Run $srv.Host $srv.Key $srv.User $cmd
}

# ---- 列出日志文件 ----
function Do-LogFiles($envName, $svc, $server, $date) {
    $date = Resolve-Date $date
    $s = Load-Service $envName $svc
    $srvArr = $s.Servers -split ','
    $target = if ($server) { $server } else { $srvArr[0] }
    $srv = Load-Server $envName $target
    $logdir = Resolve-LogDir $s.LogDirTpl $s.Name $srv.Lan
    Write-Header "[$($srv.Name) $($srv.Host)]"
    Write-Log "[$envName] log files in: $logdir"
    if ($date) {
        $dateDash = "$($date.Substring(0,4))-$($date.Substring(4,2))-$($date.Substring(6,2))"
        $cmd = "ls -lht ${logdir}/*${date}*.log ${logdir}/*${dateDash}*.log 2>/dev/null | head -20"
    } else {
        $cmd = "ls -lht ${logdir}/$($s.LogGlob) 2>/dev/null | head -20"
    }
    Ssh-Run $srv.Host $srv.Key $srv.User $cmd
}

# ---- 按时间范围搜日志 ----
function Do-LogsRange($envName, $svc, $start, $end, $pat, $server, $date) {
    $date = Resolve-Date $date
    $s = Load-Service $envName $svc
    $srvArr = $s.Servers -split ','
    $target = if ($server) { $server } else { $srvArr[0] }
    $srv = Load-Server $envName $target
    $logdir = Resolve-LogDir $s.LogDirTpl $s.Name $srv.Lan
    $glob = $s.LogGlob
    Write-Header "[$($srv.Name) $($srv.Host)]"
    $patDesc = if ($pat) { " 关键词='$pat'" } else { "" }
    Write-Log "[$envName] logs-range $start ~ $end ($($s.Desc))$patDesc"
    $startTs = "[$start"
    $endTs = "[$end"
    if ($date) {
        $dateDash = "$($date.Substring(0,4))-$($date.Substring(4,2))-$($date.Substring(6,2))"
        $fileSel = "ls -t ${logdir}/*${date}*.log ${logdir}/*${dateDash}*.log 2>/dev/null | head -1"
    } else {
        $fileSel = "ls -t ${logdir}/${glob} 2>/dev/null | head -1"
    }
    if ($pat) {
        $cmd = @"
f=`$($fileSel)
if [ -z "`$f" ]; then echo "(无日志文件)"; exit 0; fi
echo "文件: `$f"
awk -v s='${startTs}' -v e='${endTs}' '/^\[20[0-9][0-9]-/ { ts=substr(`$0,1,20); in_range=(ts>=s && ts<=e) } in_range { print }' "`$f" | grep -iE '${pat}' | tail -n 500
"@
    } else {
        $cmd = @"
f=`$($fileSel)
if [ -z "`$f" ]; then echo "(无日志文件)"; exit 0; fi
echo "文件: `$f"
awk -v s='${startTs}' -v e='${endTs}' '/^\[20[0-9][0-9]-/ { ts=substr(`$0,1,20); in_range=(ts>=s && ts<=e) } in_range { print }' "`$f" | tail -n 1000
"@
    }
    Ssh-Run $srv.Host $srv.Key $srv.User $cmd
}

# ---- traceId 追踪 ----
function Do-Trace($envName, $traceId, $svcList, $server) {
    $cfg = Get-EnvConfig $envName
    # 未显式指定服务时, 默认检索配置中登记的全部服务
    $default_svcs = @((Get-Config $cfg.ServicesFile) | ForEach-Object { ($_ -split '\|')[0].Trim() } | Where-Object { $_ })
    $svcs = if ($svcList) { $svcList -split ',' } else { $default_svcs }
    Write-Log "[$envName] trace '$traceId': 搜 $($svcs.Count) 个服务"
    foreach ($svcName in $svcs) {
        $svcName = $svcName.Trim()
        if (-not $svcName) { continue }
        $line = (Get-Config $cfg.ServicesFile) | Where-Object { $_ -match "^$svcName\|" } | Select-Object -First 1
        if (-not $line) { Write-Warn "  服务 '$svcName' 未配置,跳过"; continue }
        $parts = $line -split '\|'
        $sName, $sServers, $sLogDirTpl, $sLogGlob = $parts[0], $parts[1], $parts[2], $parts[3]
        $srvArr = $sServers -split ','
        $target = if ($server -and ($srvArr -contains $server)) { $server } else { $srvArr[0] }
        $srv = Load-Server $envName $target
        $logdir = Resolve-LogDir $sLogDirTpl $sName $srv.Lan
        Write-Header "=== [$sName on $($srv.Name) $($srv.Host)] ==="
        $cmd = @"
files=`$(ls -t ${logdir}/${sLogGlob} 2>/dev/null | head -3)
if [ -n "`$files" ]; then echo "`$files" | xargs grep -h "${traceId}" 2>/dev/null | tail -n 20; fi
"@
        Ssh-Run $srv.Host $srv.Key $srv.User $cmd
    }
}

# ---- 统计关键词 ----
function Do-Count($envName, $svc, $pat, $server, $date) {
    $date = Resolve-Date $date
    $s = Load-Service $envName $svc
    $srvArr = $s.Servers -split ','
    $target = if ($server) { $server } else { $srvArr[0] }
    $srv = Load-Server $envName $target
    $logdir = Resolve-LogDir $s.LogDirTpl $s.Name $srv.Lan
    $glob = $s.LogGlob
    Write-Header "[$($srv.Name) $($srv.Host)]"
    Write-Log "[$envName] count '$pat' ($($s.Desc))"
    if ($date) {
        $dateDash = "$($date.Substring(0,4))-$($date.Substring(4,2))-$($date.Substring(6,2))"
        $cmd = @"
files=`$(ls -t ${logdir}/*${date}*.log ${logdir}/*${dateDash}*.log 2>/dev/null | head -3)
if [ -n "`$files" ]; then echo "`$files" | xargs grep -hicE '${pat}' 2>/dev/null; fi
"@
    } else {
        $cmd = @"
files=`$(ls -t ${logdir}/${glob} 2>/dev/null | head -3)
if [ -n "`$files" ]; then echo "`$files" | xargs grep -hicE '${pat}' 2>/dev/null; fi
"@
    }
    Ssh-Run $srv.Host $srv.Key $srv.User $cmd
}

# ---- Nginx 统计 ----
function Do-NginxStats($envName, $server, $date, $domain) {
    $date = Resolve-Date $date
    $srv = Load-Server $envName $server
    $logdir = "/opt/nginx/logs"
    Write-Header "[$($srv.Name) $($srv.Host)]"
    $domDesc = if ($domain) { " 域含'$domain'" } else { "" }
    Write-Log "[$envName] nginx stats$domDesc"
    if ($domain) {
        $fileSel = "ls -t ${logdir}/*${domain}*access*.log 2>/dev/null | head -5"
    } else {
        $fileSel = "ls -t ${logdir}/*access*.log 2>/dev/null | head -5"
    }
    $dateFilter = ""
    if ($date) {
        $d = $date.Substring(6,2); $m = $date.Substring(4,2); $y = $date.Substring(0,4)
        $months = @{ '01'='Jan'; '02'='Feb'; '03'='Mar'; '04'='Apr'; '05'='May'; '06'='Jun'; '07'='Jul'; '08'='Aug'; '09'='Sep'; '10'='Oct'; '11'='Nov'; '12'='Dec' }
        $mName = $months[$m]
        $dateFilter = "| grep '${d}/${mName}/${y}'"
    }
    if ($domain) {
        $cmd = @"
files=`$($fileSel)
if [ -z "`$files" ]; then echo "(无日志文件)"; exit 0; fi
echo "=== 文件列表 ==="; echo "`$files"; echo ""
echo "=== 状态码统计 ==="
echo "`$files" | xargs cat 2>/dev/null ${dateFilter} | awk '{print `$9}' | sort | uniq -c | sort -rn | head -20
echo ""; echo "=== Top 20 URL ==="
echo "`$files" | xargs cat 2>/dev/null ${dateFilter} | awk '{print `$9, `$7}' | sort | uniq -c | sort -rn | head -20
"@
    } else {
        $cmd = @"
files=`$($fileSel)
if [ -z "`$files" ]; then echo "(无日志文件)"; exit 0; fi
echo "=== 文件列表 ==="; echo "`$files"; echo ""
echo "=== 状态码统计 ==="
echo "`$files" | xargs cat 2>/dev/null ${dateFilter} | awk '{print `$9}' | sort | uniq -c | sort -rn | head -20
echo ""; echo "=== 5xx Top 20 ==="
echo "`$files" | xargs cat 2>/dev/null ${dateFilter} | awk '`$9 ~ /^5/{print `$9, `$7}' | sort | uniq -c | sort -rn | head -20
echo ""; echo "=== 4xx Top 20 ==="
echo "`$files" | xargs cat 2>/dev/null ${dateFilter} | awk '`$9 ~ /^4/{print `$9, `$7}' | sort | uniq -c | sort -rn | head -20
"@
    }
    Ssh-Run $srv.Host $srv.Key $srv.User $cmd
}

# ====== test 独有: 发版功能 ======
function Do-DeployPlan($envName, $svc) {
    Assert-Deployable $envName 'plan'
    $s = Load-Service $envName $svc
    if (-not $s.Repo) { Write-Die "$svc 未配置发版信息 (repo/module/dir/artifact/deployMode)" }
    $srv = Load-Server $envName ($s.Servers -split ',')[0]
    $repoPath = if ($WsDir) { Join-Path $WsDir $s.Repo } else { '' }
    $localArtifact = if (-not $repoPath) { '' } elseif ($s.Kind -eq 'frontend') {
        Join-Path $repoPath $s.Artifact
    } else {
        Join-Path $repoPath "$($s.Module)/target/$($s.Artifact)"
    }
    $failures = @()

    $requiredTools = if ($s.Kind -eq 'frontend') {
        @('ssh', 'scp', 'node', 'tar') + $(if ($s.PackageManager -eq 'npm') { 'npm' } else { 'corepack' })
    } else {
        @('ssh', 'scp', 'mvn', 'java')
    }
    foreach ($tool in $requiredTools) {
        if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { $failures += "缺少命令: $tool" }
    }
    if (-not $WsDir -or -not (Test-Path $WsDir)) { $failures += "未找到工作区，设置 SERVICE_OPS_WS（兼容 SERVER_OPS_WS）" }
    elseif (-not (Test-Path $repoPath)) { $failures += "仓库不存在: $repoPath" }
    if (-not (Test-Path $srv.Key)) { $failures += "私钥不存在: $($srv.Key)" }

    Write-Header "[test deploy plan] $($s.Name)"
    Write-Host "kind        : $($s.Kind)"
    Write-Host "repo/module : $($s.Repo)/$(if ($s.Module) { $s.Module } else { '-' })"
    Write-Host "target      : $($srv.Name) $($srv.Host):$($s.Dir)$(if ($s.Kind -eq 'frontend') { '' } else { "/$($s.Artifact)" })"
    Write-Host "deploy mode : $($s.DeployMode)"
    Write-Host "artifact    : $(if ($localArtifact) { $localArtifact } else { '(工作区未配置)' })"
    Write-Host "exists      : $([bool]($localArtifact -and (Test-Path $localArtifact)))"
    if ($s.PackageManager) { Write-Host "package mgr : $($s.PackageManager)" }
    if ($s.VerifyUrl) { Write-Host "verify url  : $($s.VerifyUrl)" }
    if ($failures.Count -gt 0) {
        $failures | Sort-Object -Unique | ForEach-Object { Write-Warn $_ }
        Write-Die "发版预检未通过"
    }
    Write-Log "发版预检通过"
}

function Do-Build($envName, $svc) {
    Assert-Deployable $envName 'build'
    $s = Load-Service $envName $svc
    if (-not $s.Repo) { Write-Die "$svc 未配置发版信息 (repo/module/dir/artifact/deployMode)" }
    if (-not $WsDir) { Write-Die "未找到 vibecoding-workspace，设置 SERVICE_OPS_WS（兼容 SERVER_OPS_WS）" }
    $repoPath = "$WsDir/$($s.Repo)"
    if (-not (Test-Path $repoPath)) { Write-Die "仓库不存在: $repoPath" }

    if ($s.Kind -eq 'frontend') {
        if (-not $s.PackageManager) { Write-Die "$svc 未配置 packageManager" }
        $localArtifact = Join-Path $repoPath $s.Artifact
        $installDescription = if ($s.PackageManager -eq 'npm') { 'npm ci' } else { "$($s.PackageManager) install --frozen-lockfile" }
        Write-Log "[$envName] build: $($s.Repo) ($installDescription && build:test)"
        $oldHusky = $env:HUSKY
        $oldCi = $env:CI
        $installExitCode = 0
        $buildExitCode = 0
        Push-Location $repoPath
        try {
            $env:HUSKY = '0'
            $env:CI = '1'
            if ($s.PackageManager -eq 'npm') {
                & npm ci 2>&1 | ForEach-Object { Write-Host $_ }
            } elseif ($s.PackageManager -match '^pnpm@\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.-]+)?$') {
                & corepack $s.PackageManager install --frozen-lockfile 2>&1 | ForEach-Object { Write-Host $_ }
            } else {
                Write-Die "$svc 的 packageManager 无效: $($s.PackageManager)"
            }
            $installExitCode = $LASTEXITCODE
            if ($installExitCode -eq 0) {
                if ($s.PackageManager -eq 'npm') {
                    & npm run build:test 2>&1 | ForEach-Object { Write-Host $_ }
                } else {
                    & corepack $s.PackageManager run build:test 2>&1 | ForEach-Object { Write-Host $_ }
                }
                $buildExitCode = $LASTEXITCODE
            }
        } finally {
            Pop-Location
            if ($null -eq $oldHusky) { Remove-Item Env:HUSKY -ErrorAction SilentlyContinue } else { $env:HUSKY = $oldHusky }
            if ($null -eq $oldCi) { Remove-Item Env:CI -ErrorAction SilentlyContinue } else { $env:CI = $oldCi }
        }
        if ($installExitCode -ne 0) { Write-Die "$($s.PackageManager) install 失败" }
        if ($buildExitCode -ne 0) { Write-Die "$($s.PackageManager) build:test 失败" }
        if (-not (Test-Path (Join-Path $localArtifact 'index.html'))) { Write-Die "前端构建产物缺少 index.html: $localArtifact" }
        $fileCount = @(Get-ChildItem $localArtifact -File -Recurse).Count
        Write-Log "产物: $localArtifact ($fileCount files)"
        return $localArtifact
    }

    $localJar = "$repoPath/$($s.Module)/target/$($s.Artifact)"
    Write-Log "[$envName] build: $($s.Repo)/$($s.Module) (mvn -Ptest, JDK8)"
    & mvn -f $repoPath -pl $s.Module -am clean package -P test -DskipTests 2>&1 | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) { Write-Die "mvn 构建失败" }
    if (-not (Test-Path $localJar)) { Write-Die "构建产物不存在: $localJar" }
    $size = (Get-Item $localJar).Length / 1MB
    Write-Log "产物: $localJar ($([math]::Round($size,1))MB)"
    return $localJar
}

function Do-Upload($envName, $svc) {
    Assert-Deployable $envName 'upload'
    $s = Load-Service $envName $svc
    if (-not $s.Dir) { Write-Die "$svc 未配置发版信息" }
    $srv = Load-Server $envName ($s.Servers -split ',')[0]
    if ($s.Kind -eq 'frontend') {
        $localDir = "$WsDir/$($s.Repo)/$($s.Artifact)"
        if (-not (Test-Path (Join-Path $localDir 'index.html'))) { Write-Die "前端产物不存在或缺少 index.html，先 build: $localDir" }
        $releaseId = "$(Get-Date -Format 'yyyyMMddHHmmss')-$(([guid]::NewGuid().ToString('N')).Substring(0, 8))"
        $targetParent = $s.Dir -replace '/[^/]+$', ''
        $targetName = ($s.Dir -split '/')[-1]
        $remoteArchive = "$targetParent/.$targetName.$releaseId.tar.gz"
        $remoteStage = "$targetParent/.$targetName.new.$releaseId"
        $remoteBackup = "$targetParent/$targetName.backup.$releaseId"
        $localArchive = Join-Path ([IO.Path]::GetTempPath()) "service-ops-$($s.Name)-$releaseId.tar.gz"
        try {
            & tar -czf $localArchive -C $localDir .
            if ($LASTEXITCODE -ne 0) { Write-Die "前端产物打包失败: $localDir" }
            Write-Log "[$envName] upload: $localDir -> $($srv.Host):$($s.Dir) (目录原子替换)"
            Scp-Put $srv.Host $srv.Key $srv.User $localArchive $remoteArchive
            if ($LASTEXITCODE -ne 0) { Write-Die "前端产物上传失败" }
            $cmd = @"
set -e
mkdir '$remoteStage'
tar -xzf '$remoteArchive' -C '$remoteStage'
test -f '$remoteStage/index.html'
had_current=0
if [ -e '$($s.Dir)' ]; then
  mv '$($s.Dir)' '$remoteBackup'
  had_current=1
fi
if mv '$remoteStage' '$($s.Dir)'; then
  rm -f '$remoteArchive'
  echo "uploaded; backup=$remoteBackup"
else
  if [ "`$had_current" -eq 1 ]; then mv '$remoteBackup' '$($s.Dir)'; fi
  exit 1
fi
"@
            Ssh-Run $srv.Host $srv.Key $srv.User $cmd
            if ($LASTEXITCODE -ne 0) { Write-Die "前端目录切换失败；脚本已尝试恢复原目录" }
        } finally {
            Remove-Item $localArchive -Force -ErrorAction SilentlyContinue
        }
        return
    }

    $localJar = "$WsDir/$($s.Repo)/$($s.Module)/target/$($s.Artifact)"
    if (-not (Test-Path $localJar)) { Write-Die "本地 jar 不存在, 先 build: $localJar" }
    $tmp = "$($s.Dir)/$($s.Artifact).new"
    Write-Log "[$envName] upload: $localJar -> $($srv.Host):$($s.Dir)/$($s.Artifact) (原子覆盖)"
    Scp-Put $srv.Host $srv.Key $srv.User $localJar $tmp
    Ssh-Run $srv.Host $srv.Key $srv.User "mv -f '$tmp' '$($s.Dir)/$($s.Artifact)' && echo uploaded"
}

function Do-Restart($envName, $svc) {
    Assert-Deployable $envName 'restart'
    $s = Load-Service $envName $svc
    if (-not $s.Dir) { Write-Die "$svc 未配置发版信息" }
    if ($s.Kind -eq 'frontend') { Write-Log "[$envName] restart: $($s.Name) 为静态前端，无需重启"; return }
    $srv = Load-Server $envName ($s.Servers -split ',')[0]
    Write-Log "[$envName] restart: $($s.Name) on $($srv.Name) ($($srv.Host))"
    switch ($s.RestartMode) {
        'script'    { Ssh-Run $srv.Host $srv.Key $srv.User "bash '$($s.Dir)/restart.sh'" }
        'stopstart' { Ssh-Run $srv.Host $srv.Key $srv.User "cd '$($s.Dir)' && bash stop.sh && sleep 1 && bash start.sh" }
        default     { Write-Die "未知 restart 模式: $($s.RestartMode)" }
    }
}

function Do-All($envName, $svc) {
    Assert-Deployable $envName 'all'
    $s = Load-Service $envName $svc
    $srv = Load-Server $envName ($s.Servers -split ',')[0]
    Do-Build $envName $svc
    Do-Upload $envName $svc
    Do-Restart $envName $svc
    if ($s.Kind -ne 'frontend') {
        Write-Log "等进程起来 (最多 30s)..."
        $jarName = $s.Artifact
        $cmd = @"
for i in `$(seq 1 30); do
  pgrep -f '${jarName}' >/dev/null 2>&1 && echo "已起(第`${i}次)" && break
  sleep 1
done
"@
        Ssh-Run $srv.Host $srv.Key $srv.User $cmd
    }
    Do-DeployVerify $envName $svc
}

function Do-DeployVerify($envName, $svc) {
    Assert-Deployable $envName 'verify'
    $s = Load-Service $envName $svc
    if (-not $s.Dir) { Write-Die "$svc 未配置发版信息" }
    $srvName = ($s.Servers -split ',')[0]
    $srv = Load-Server $envName $srvName
    Write-Header "[test deploy verify] $($s.Name)"
    if ($s.Kind -eq 'frontend') {
        Ssh-Run $srv.Host $srv.Key $srv.User "test -f '$($s.Dir)/index.html' && stat -c 'INDEX: %n | UPDATED: %y | SIZE: %s bytes' '$($s.Dir)/index.html' || { echo 'INDEX: NOT_FOUND'; exit 1; }"
        if ($LASTEXITCODE -ne 0) { Write-Die "远程前端产物验证失败" }
        if (-not $s.VerifyUrl) { Write-Die "$svc 未配置 verifyUrl" }
        $separator = if ($s.VerifyUrl.Contains('?')) { '&' } else { '?' }
        $verifyUri = "$($s.VerifyUrl)$($separator)_service_ops=$([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())"
        $response = Invoke-WebRequest -Uri $verifyUri -UseBasicParsing -TimeoutSec 15
        if ($response.StatusCode -ne 200) { Write-Die "前端 HTTP 验证失败: $($response.StatusCode)" }
        Write-Log "HTTP: $($response.StatusCode) $($s.VerifyUrl) ($($response.RawContentLength) bytes)"
        return
    }
    Ssh-Run $srv.Host $srv.Key $srv.User "stat -c 'JAR: %n | UPDATED: %y | SIZE: %s bytes' '$($s.Dir)/$($s.Artifact)' 2>/dev/null || echo 'JAR: NOT_FOUND'"
    Do-Health $envName $svc $srvName ''
}

# ====== 服务器级操作 ======
function Do-Server-PS($envName, $srvName) {
    $srv = Load-Server $envName $srvName
    Write-Header "[$($srv.Name) $($srv.Host) $($srv.Lan)]"
    Ssh-Run $srv.Host $srv.Key $srv.User "ps -ef | grep -i java | grep -v grep"
}

function Do-Server-Disk($envName, $srvName) {
    $srv = Load-Server $envName $srvName
    Write-Header "[$($srv.Name) $($srv.Host)]"
    Ssh-Run $srv.Host $srv.Key $srv.User "df -h | grep -vE 'tmpfs|overlay|udev'"
}

function Do-Server-Mem($envName, $srvName) {
    $srv = Load-Server $envName $srvName
    Write-Header "[$($srv.Name) $($srv.Host)]"
    Ssh-Run $srv.Host $srv.Key $srv.User "free -m"
}

function Do-Server-Top($envName, $srvName) {
    $srv = Load-Server $envName $srvName
    Write-Header "[$($srv.Name) $($srv.Host)]"
    Ssh-Run $srv.Host $srv.Key $srv.User "top -bn1 | head -25"
}

function Do-Server-Services($envName, $srvName) {
    $srv = Load-Server $envName $srvName
    Write-Header "[$($srv.Name) $($srv.Host) $($srv.Lan)]"
    Write-Log "($($srv.Desc))"
    Ssh-Run $srv.Host $srv.Key $srv.User "ls /opt/ 2>/dev/null | grep -v -E 'containerd|fonts|backup'"
}

function Do-Server-Net($envName, $srvName) {
    $srv = Load-Server $envName $srvName
    Write-Header "[$($srv.Name) $($srv.Host) $($srv.Lan)]"
    Write-Log "网络: 端口监听 + 活跃连接 TOP"
    $cmd = @"
echo "=== 监听端口 (LISTEN) ==="
ss -tln 2>/dev/null | head -40
echo ""
echo "=== 活跃连接 TOP 20 (按对端IP) ==="
ss -tn 2>/dev/null | awk 'NR>1{n=split(`$5,a,":"); if(n>1) print a[1]}' | sort | uniq -c | sort -rn | head -20
echo ""
echo "=== ESTABLISHED 连接数 ==="
ss -tn 2>/dev/null | grep ESTAB | wc -l
"@
    Ssh-Run $srv.Host $srv.Key $srv.User $cmd
}

function Do-Server-Jvm($envName, $srvName, $filter) {
    if ($filter -and $filter -notmatch '^[A-Za-z0-9._-]+$') { Write-Die "jvm filter 仅允许字母、数字、点、下划线和连字符" }
    $srv = Load-Server $envName $srvName
    Write-Header "[$($srv.Name) $($srv.Host)]"
    Write-Log "JVM: PID / CPU / MEM / ELAPSED / COMMAND"
    $cmd = "ps -eo pid,pcpu,pmem,etime,args --sort=-pcpu | awk 'NR==1 || /[j]ava/'"
    if ($filter) { $cmd += " | grep -F -- '$filter' | head -30" } else { $cmd += " | head -30" }
    Ssh-Run $srv.Host $srv.Key $srv.User $cmd
}

function Do-Server-Exec($envName, $srvName, $cmd) {
    if ($envName -eq 'prod') { Write-Die "exec 已在 prod 禁用；使用 ps/disk/mem/top/services/net/jvm 等只读动作" }
    $srv = Load-Server $envName $srvName
    Write-Header "[$($srv.Name) $($srv.Host)]"
    Ssh-Run $srv.Host $srv.Key $srv.User $cmd
}

# ====== 全局操作 ======
function Do-All-Disk($envName) {
    $cfg = Get-EnvConfig $envName
    Write-Log "[$envName] 所有服务器磁盘:"
    foreach ($line in (Get-Config $cfg.ServersFile)) {
        $parts = $line -split '\|'
        $srv = Load-Server $envName $parts[0]
        Write-Header "=== [$($srv.Name) $($srv.Host)] ==="
        Ssh-Run $srv.Host $srv.Key $srv.User "df -h | grep -vE 'tmpfs|overlay|udev'"
    }
}

function Do-All-PS($envName) {
    $cfg = Get-EnvConfig $envName
    Write-Log "[$envName] 所有服务器 Java 进程:"
    foreach ($line in (Get-Config $cfg.ServersFile)) {
        $parts = $line -split '\|'
        $srv = Load-Server $envName $parts[0]
        Write-Header "=== [$($srv.Name) $($srv.Host)] ==="
        Ssh-Run $srv.Host $srv.Key $srv.User "ps -ef | grep -i java | grep -v grep | awk '{print `$2, `$8, `$9, `$10, `$11}'"
    }
}

# ====== Usage ======
function Show-Usage {
    @'
service-ops.ps1 — 多环境服务运维工具
用法: pwsh service-ops.ps1 <env> <service|server|all> <action> [args]
⚠️ prod 只读 (无 build/upload/restart), test 全权 (可发版/重启)

通用 service 级:
  status [server]                 查服务进程
  logs [N] [server] [date]        最近 N 行日志 (默认100)
  grep <pat> [N] [server] [date] [ctx]  搜日志 (默认200条, ctx=上下文行)
  grepall <pat> [N] [date] [ctx]  搜日志(所有服务器)
  backupgrep <pat> [date] [server] [ctx]  搜历史备份(prod共享盘)
  logsrange <start> <end> [pat] [server] [date]  按时间范围搜
  count <pat> [server] [date]     统计关键词次数
  logfiles [server] [date]        列日志文件

全局:
  doctor [query|deploy]             本地依赖/配置/私钥预检
  trace <traceId> [服务列表] [server]  traceId追踪
  nginx-stats <server> [date] [domain]  Nginx统计
  list | servers | all-disk | all-ps

test 独有 (发版):
  plan                            展示发版目标并检查本地条件
  build                           后端 Maven 构建 / 前端 pnpm build:test
  upload                          JAR 原子覆盖 / 前端静态目录原子替换
  restart                         后端远程重启；静态前端无需重启
  verify                          核验 JAR/进程或前端 index.html/HTTP
  all                             build→upload→restart(按类型)→verify

server 级:
  ps | disk | mem | top | services | net | jvm [filter]
  exec <cmd>                      仅在允许变更的环境可用

service 诊断:
  health [server] [date]          聚合进程、日志元数据和最近异常

示例:
  pwsh service-ops.ps1 prod order-api logs 20
  pwsh service-ops.ps1 prod order-api grepall "Exception"
  pwsh service-ops.ps1 prod trace "cdea832f6c5e477b"
  pwsh service-ops.ps1 prod app-01 net
  pwsh service-ops.ps1 staging order-api all
  pwsh service-ops.ps1 staging portal-web plan
  pwsh service-ops.ps1 staging order-api logs 200
'@ | Write-Host
}

# ====== main ======
$args_list = @($args)
if ($args_list.Count -lt 1) { Show-Usage; exit 0 }

$EnvName = $args_list[0]
# 环境合法性完全由 environments.conf 决定; 缺少该文件时回退为 prod/test
[void](Get-EnvDeclaration $EnvName)

if ($args_list.Count -lt 2) { Show-Usage; exit 1 }
$Arg2 = $args_list[1]
$Arg3 = if ($args_list.Count -ge 3) { $args_list[2] } else { '' }
$rest = if ($args_list.Count -ge 4) { $args_list[3..($args_list.Count-1)] } else { @() }

# 全局动作
switch ($Arg2) {
    'list'        { Do-List $EnvName; exit 0 }
    'servers'     { Do-Servers $EnvName; exit 0 }
    'doctor'      { Do-Doctor $EnvName $Arg3; exit 0 }
    'all-disk'    { Do-All-Disk $EnvName; exit 0 }
    'all-ps'      { Do-All-PS $EnvName; exit 0 }
    'trace'       { $r=@($rest); if (-not $Arg3) { Write-Die "trace 需要 traceId" }; Do-Trace $EnvName $Arg3 $r[0] $r[1]; exit 0 }
    'nginx-stats' { $r=@($rest); if (-not $Arg3) { Write-Die "nginx-stats 需要 server" }; Do-NginxStats $EnvName $Arg3 $r[0] $r[1]; exit 0 }
}

# 判断 server 级还是 service 级
$cfg = Get-EnvConfig $EnvName
$isServer = (Get-Config $cfg.ServersFile) -match "^$Arg2\|"
$isService = (Get-Config $cfg.ServicesFile) -match "^$Arg2\|"

if ($isServer) {
    if (-not $Arg3) { Show-Usage; exit 1 }
    switch ($Arg3) {
        'ps'       { Do-Server-PS $EnvName $Arg2 }
        'disk'     { Do-Server-Disk $EnvName $Arg2 }
        'mem'      { Do-Server-Mem $EnvName $Arg2 }
        'top'      { Do-Server-Top $EnvName $Arg2 }
        'services' { Do-Server-Services $EnvName $Arg2 }
        'net'      { Do-Server-Net $EnvName $Arg2 }
        'jvm'      { $r=@($rest); Do-Server-Jvm $EnvName $Arg2 $r[0] }
        'exec'     { $r=@($rest); if ($r.Count -lt 1) { Write-Die "exec 需要命令" }; Do-Server-Exec $EnvName $Arg2 ($r -join ' ') }
        default    { Show-Usage; Write-Die "server 级 action: ps|disk|mem|top|services|net|jvm|exec(test only)" }
    }
} elseif ($isService) {
    $act = if ($Arg3) { $Arg3 } else { 'status' }
    switch ($act) {
        'status'     { $r=@($rest); Do-Status $EnvName $Arg2 $r[0] }
        'health'     { $r=@($rest); Do-Health $EnvName $Arg2 $r[0] $r[1] }
        'logs'       { $r=@($rest); Do-Logs $EnvName $Arg2 $r[0] $r[1] $r[2] }
        'grep'       { $r=@($rest); Do-Grep $EnvName $Arg2 $r[0] $r[1] $r[2] $r[3] $r[4] }
        'grepall'    { $r=@($rest); Do-GrepAll $EnvName $Arg2 $r[0] $r[1] $r[2] $r[3] }
        'backupgrep' { $r=@($rest); Do-BackupGrep $EnvName $Arg2 $r[0] $r[1] $r[2] $r[3] }
        'logsrange'  { $r=@($rest); if (-not $r[0]) { Write-Die "logsrange 需要 start end" }; Do-LogsRange $EnvName $Arg2 $r[0] $r[1] $r[2] $r[3] $r[4] }
        'count'      { $r=@($rest); Do-Count $EnvName $Arg2 $r[0] $r[1] $r[2] }
        'logfiles'   { $r=@($rest); Do-LogFiles $EnvName $Arg2 $r[0] $r[1] }
        'plan'       { Do-DeployPlan $EnvName $Arg2 }
        'build'      { Do-Build $EnvName $Arg2 }
        'upload'     { Do-Upload $EnvName $Arg2 }
        'restart'    { Do-Restart $EnvName $Arg2 }
        'verify'     { Do-DeployVerify $EnvName $Arg2 }
        'all'        { Do-All $EnvName $Arg2 }
        default      { Show-Usage; Write-Die "service 级 action: status|health|logs|grep|grepall|backupgrep|logsrange|count|logfiles|plan|build|upload|restart|verify|all" }
    }
} else {
    Write-Die "未知 service/server: '$Arg2' (list 查服务, servers 查服务器)"
}
