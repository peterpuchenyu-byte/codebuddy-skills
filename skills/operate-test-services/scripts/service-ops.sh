#!/usr/bin/env bash
# service-ops.sh — 多环境服务运维工具 (生产只读 / 测试受控变更)
# 用法: bash service-ops.sh <env> <service|server|all> <action> [args]
# ⚠️ prod 环境只读 (不提供 build/upload/restart), test 环境全权 (可发版/重启)
# 跨平台: macOS / Linux / Git Bash (Windows)
set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# 配置目录解析顺序: SERVICE_OPS_CONF > 插件根/config (须含 servers-*.conf) > ~/.codebuddy/config
CONF_DIR="${SERVICE_OPS_CONF:-}"
if [ -z "$CONF_DIR" ]; then
  for c in "$PLUGIN_ROOT/config" "$HOME/.codebuddy/config"; do
    if compgen -G "$c/servers-*.conf" >/dev/null 2>&1; then CONF_DIR="$c"; break; fi
  done
fi
[ -n "$CONF_DIR" ] || CONF_DIR="$HOME/.codebuddy/config"

# 工作区根 (test 环境发版用)
WS="${SERVICE_OPS_WS:-${SERVER_OPS_WS:-}}"
if [ -z "$WS" ]; then
  for d in "/d/vibecoding-workspace" "$HOME/vibecoding-workspace" "/c/vibecoding-workspace" "D:/vibecoding-workspace"; do
    [ -d "$d" ] && WS="$d" && break
  done
fi

G='\033[32m'; Y='\033[33m'; R='\033[31m'; C='\033[36m'; N='\033[0m'
log(){ printf "${G}>>${N} %s\n" "$*"; }
warn(){ printf "${Y}!!${N} %s\n" "$*"; }
die(){ printf "${R}XX${N} %s\n" "$*" >&2; exit 1; }
header(){ printf "${C}%s${N}\n" "$*"; }
validate_date(){
  [ -z "${1:-}" ] && return 0
  [[ "$1" =~ ^[0-9]{8}$ ]] || die "日期必须是 YYYYMMDD: $1"
  local normalized=""
  normalized=$(date -d "$1" +%Y%m%d 2>/dev/null || true)
  if [ -z "$normalized" ]; then normalized=$(date -j -f '%Y%m%d' "$1" '+%Y%m%d' 2>/dev/null || true); fi
  [ "$normalized" = "$1" ] || die "日期无效: $1"
}

# ---- base64 编码 (兼容 macOS/Linux/Git Bash) ----
b64enc(){
  if base64 -w0 </dev/null >/dev/null 2>&1; then
    base64 -w0
  else
    base64
  fi
}

# ---- 环境选择 ----
# 环境由 config/environments.conf 声明, 每行: 名称|只读|允许变更|显示名
ENV_DECL_FILE="$CONF_DIR/environments.conf"

env_line(){
  local f="$ENV_DECL_FILE"
  [ -f "$f" ] || { echo ""; return 0; }
  get_config "$f" | awk -F'|' -v n="$1" '{gsub(/^[ \t]+|[ \t]+$/,"",$1); if ($1==n) {print; exit}}'
}

env_flag(){
  local line; line=$(env_line "$1")
  [ -n "${line:-}" ] || { echo 0; return 0; }
  local v; v=$(echo "$line" | awk -F'|' -v i="$2" '{gsub(/^[ \t]+|[ \t]+$/,"",$i); print $i}')
  case "$(echo "${v:-}" | tr 'A-Z' 'a-z')" in
    1|yes|true|是|只读) echo 1 ;;
    *) echo 0 ;;
  esac
}

get_env_files(){
  local envName="$1"
  if [ -f "$ENV_DECL_FILE" ]; then
    [ -n "$(env_line "$envName")" ] || die "环境 '$envName' 未在 $ENV_DECL_FILE 中声明"
  else
    case "$envName" in
      prod|test) ;;
      *) die "环境 '$envName' 未声明（缺少 $ENV_DECL_FILE）" ;;
    esac
  fi
  local ro
  if [ -f "$ENV_DECL_FILE" ]; then ro=$(env_flag "$envName" 2); else [ "$envName" = "prod" ] && ro=1 || ro=0; fi
  echo "$CONF_DIR/servers-$envName.conf|$CONF_DIR/services-$envName.conf|$ro"
}

# 允许变更类动作的统一守卫
assert_deployable(){
  local envName="$1" action="$2" can
  if [ -f "$ENV_DECL_FILE" ]; then can=$(env_flag "$envName" 3); else [ "$envName" = "test" ] && can=1 || can=0; fi
  [ "$can" = "1" ] || die "$action 只在允许变更的环境可用（当前环境 $envName）"
}

get_config(){
  local file="$1"
  [ -f "$file" ] || die "配置文件不存在: $file"
  grep -vE '^\s*#|^\s*$' "$file"
}

# 配置文件存在性检查
# 注意: get_config 通常在 $(...) 子 shell 中调用, 其内部的 die 只退出子 shell,
# 因此主流程必须先用本函数显式检查, 否则配置缺失时会继续执行并报出误导性错误。
require_file(){
  [ -f "$1" ] || die "配置文件不存在: $1"
}

# ---- 加载服务器 ----
load_server(){
  local envName="$1" key="$2"
  local envInfo; envInfo=$(get_env_files "$envName")
  local serversFile; serversFile="${envInfo%%|*}"
  require_file "$serversFile"
  local line; line=$(get_config "$serversFile" | grep -E "^${key}\|" | head -1)
  [ -n "$line" ] || die "server '$key' 未配置 ($serversFile)"
  IFS='|' read -r SRV_NAME SRV_HOST SRV_USER SRV_KEY SRV_LAN SRV_DESC <<< "$line"
  # 展开 ~ (bash 原生支持)
  SRV_KEY="${SRV_KEY/#\~/$HOME}"
  [ -f "$SRV_KEY" ] || die "私钥不存在: $SRV_KEY"
}

# ---- 加载服务 ----
load_service(){
  local envName="$1" key="$2"
  local envInfo; envInfo=$(get_env_files "$envName")
  local rest="${envInfo#*|}"
  local servicesFile; servicesFile="${rest%%|*}"
  require_file "$servicesFile"
  local line; line=$(get_config "$servicesFile" | grep -E "^${key}\|" | head -1)
  [ -n "$line" ] || die "service '$key' 未配置 ($servicesFile)"
  IFS='|' read -r SVC_NAME SVC_SERVERS SVC_LOGDIR_TPL SVC_LOGGLOB SVC_DESC SVC_REPO SVC_MODULE SVC_DIR SVC_ARTIFACT SVC_DEPLOY_MODE SVC_KIND SVC_VERIFY_URL SVC_PACKAGE_MANAGER <<< "$line"
  SVC_KIND="${SVC_KIND:-jar}"
  # 保留旧变量别名，避免改变既有后端 JAR 发布逻辑。
  SVC_JAR="$SVC_ARTIFACT"
  SVC_RESTART="$SVC_DEPLOY_MODE"
}

# ---- SSH/SCP ----
ssh_run(){
  local host_="$1" key="$2" user="$3" cmd="$4"
  local b64; b64=$(printf '%s' "$cmd" | b64enc)
  ssh -o StrictHostKeyChecking=no -o ConnectTimeout=15 -o BatchMode=yes -i "$key" "${user}@${host_}" "echo $b64 | base64 -d | bash" 2>/dev/null
}

scp_put(){
  local host_="$1" key="$2" user="$3" localPath="$4" remotePath="$5"
  scp -o StrictHostKeyChecking=no -o ConnectTimeout=15 -i "$key" "$localPath" "${user}@${host_}:$remotePath" 2>/dev/null
}

resolve_logdir(){
  local tpl="$1" svc="$2" lan="$3"
  echo "${tpl//\{svc\}/$svc}" | sed "s/{host}/$lan/g"
}

# ---- 列出 ----
do_list(){
  local envInfo; envInfo=$(get_env_files "$1")
  local rest="${envInfo#*|}"; local servicesFile="${rest%%|*}"
  log "[$1] 已配置服务:"
  get_config "$servicesFile" | while IFS= read -r l; do echo "$l"; done
}

do_servers(){
  local envInfo; envInfo=$(get_env_files "$1")
  local serversFile="${envInfo%%|*}"
  log "[$1] 已配置服务器:"
  get_config "$serversFile" | while IFS= read -r l; do echo "$l"; done
}

# ---- 本地运行条件检查 ----
do_doctor(){
  local envName="$1" mode="${2:-query}" failures=0
  [ "$mode" = "query" ] || [ "$mode" = "deploy" ] || die "doctor 模式必须是 query 或 deploy"
  [ "$mode" != "deploy" ] || assert_deployable "$envName" "deploy"
  local envInfo; envInfo=$(get_env_files "$envName")
  local serversFile="${envInfo%%|*}" rest="${envInfo#*|}" servicesFile
  servicesFile="${rest%%|*}"

  command -v ssh >/dev/null 2>&1 || { warn "缺少命令: ssh"; failures=$((failures+1)); }
  local duplicates
  duplicates=$({ get_config "$serversFile" | cut -d'|' -f1; get_config "$servicesFile" | cut -d'|' -f1; } | sort | uniq -d || true)
  if [ -n "$duplicates" ]; then
    while IFS= read -r name; do warn "配置名称重复: $name"; failures=$((failures+1)); done <<< "$duplicates"
  fi

  while IFS='|' read -r serviceName serverRefs _ _ _ _ _ _ _ _ serviceKind _ packageManager; do
    IFS=',' read -ra refs <<< "$serverRefs"
    for serverRef in "${refs[@]}"; do
      grep -qE "^${serverRef}\|" "$serversFile" || { warn "服务 $serviceName 引用了未知服务器 $serverRef"; failures=$((failures+1)); }
    done
    if [ -n "$serviceKind" ] && [ "$serviceKind" != "jar" ] && [ "$serviceKind" != "frontend" ]; then
      warn "服务 $serviceName 的 kind 无效: $serviceKind"; failures=$((failures+1))
    fi
    if [ "$serviceKind" = "frontend" ]; then
      if [ -z "$packageManager" ]; then
        warn "前端服务 $serviceName 未配置 packageManager"; failures=$((failures+1))
      elif [ "$packageManager" != "npm" ] && ! [[ "$packageManager" =~ ^pnpm@[0-9]+\.[0-9]+\.[0-9]+([-+][A-Za-z0-9.-]+)?$ ]]; then
        warn "前端服务 $serviceName 的 packageManager 无效: $packageManager"; failures=$((failures+1))
      fi
    fi
  done < <(get_config "$servicesFile")

  while IFS='|' read -r _ _ _ keyPath _; do
    keyPath="${keyPath/#\~/$HOME}"
    [ -f "$keyPath" ] || { warn "私钥不存在: $keyPath"; failures=$((failures+1)); }
  done < <(get_config "$serversFile")

  if [ "$mode" = "deploy" ]; then
    local deployKinds deployPackageManagers
    deployKinds=$(get_config "$servicesFile" | awk -F'|' '$6 != "" { print ($11 == "" ? "jar" : $11) }' | sort -u)
    deployPackageManagers=$(get_config "$servicesFile" | awk -F'|' '$6 != "" && $11 == "frontend" { print $13 }' | sort -u)
    local requiredTools=(scp)
    grep -qx 'jar' <<< "$deployKinds" && requiredTools+=(mvn java)
    grep -qx 'frontend' <<< "$deployKinds" && requiredTools+=(node tar curl)
    grep -qx 'npm' <<< "$deployPackageManagers" && requiredTools+=(npm)
    grep -qE '^pnpm@' <<< "$deployPackageManagers" && requiredTools+=(corepack)
    for tool in "${requiredTools[@]}"; do command -v "$tool" >/dev/null 2>&1 || { warn "缺少命令: $tool"; failures=$((failures+1)); }; done
    [ -n "$WS" ] && [ -d "$WS" ] || { warn "未找到工作区，设置 SERVICE_OPS_WS（兼容 SERVER_OPS_WS）"; failures=$((failures+1)); }
  fi

  local serverCount serviceCount
  serverCount=$(get_config "$serversFile" | wc -l | tr -d ' ')
  serviceCount=$(get_config "$servicesFile" | wc -l | tr -d ' ')
  log "[$envName] doctor/$mode: servers=$serverCount, services=$serviceCount"
  [ "$failures" -eq 0 ] || die "doctor 检查失败，共 $failures 项"
  log "doctor 检查通过"
}

# ---- 查进程 ----
do_status(){
  local envName="$1" svc="$2" serverFilter="${3:-}"
  load_service "$envName" "$svc"
  # 进程匹配优先用 artifact, 避免误匹配系统进程 (如 /usr/sbin/sedispatch)
  local SVC_MATCH="${SVC_ARTIFACT:-$SVC_NAME}"
  log "[$envName] status: $SVC_NAME ($SVC_DESC)"
  IFS=',' read -ra srv_arr <<< "$SVC_SERVERS"
  for s in "${srv_arr[@]}"; do
    [ -n "$serverFilter" ] && [ "$s" != "$serverFilter" ] && continue
    load_server "$envName" "$s"
    header "[$SRV_NAME $SRV_HOST $SRV_LAN]"
    ssh_run "$SRV_HOST" "$SRV_KEY" "$SRV_USER" "ps -ef | grep '$SVC_MATCH' | grep -v grep || echo '(未运行)'"
  done
}

# ---- 服务健康聚合 ----
do_health(){
  local envName="$1" svc="$2" serverFilter="${3:-}" date="${4:-}"
  validate_date "$date"
  load_service "$envName" "$svc"
  # 进程匹配优先用 artifact, 避免误匹配系统进程
  local SVC_MATCH="${SVC_ARTIFACT:-$SVC_NAME}"
  IFS=',' read -ra srv_arr <<< "$SVC_SERVERS"
  if [ -n "$serverFilter" ] && [[ ",${SVC_SERVERS}," != *",${serverFilter},"* ]]; then die "$svc 未部署在 $serverFilter"; fi
  log "[$envName] health: $SVC_NAME（进程 + 最近20000行日志）"

  for srvName in "${srv_arr[@]}"; do
    [ -n "$serverFilter" ] && [ "$srvName" != "$serverFilter" ] && continue
    load_server "$envName" "$srvName"
    local logdir fileSel dateDash cmd
    logdir=$(resolve_logdir "$SVC_LOGDIR_TPL" "$SVC_NAME" "$SRV_LAN")
    fileSel="ls -t ${logdir}/${SVC_LOGGLOB} 2>/dev/null | head -1"
    if [ -n "$date" ]; then
      dateDash="${date:0:4}-${date:4:2}-${date:6:2}"
      fileSel="ls -t '${logdir}'/*${date}*.log '${logdir}'/*${dateDash}*.log 2>/dev/null | head -1"
    fi
    header "[$SRV_NAME $SRV_HOST]"
    cmd=$(cat <<EOF
pid=\$(pgrep -f -- '$SVC_MATCH' | head -1)
if [ -n "\$pid" ]; then ps -p "\$pid" -o pid=,pcpu=,pmem=,etime=,args=; else echo 'PROCESS: DOWN'; fi
f=\$($fileSel)
if [ -z "\$f" ]; then echo 'LOG: NOT_FOUND'; exit 0; fi
echo "LOG: \$f"
stat -c 'UPDATED: %y | SIZE: %s bytes' "\$f" 2>/dev/null || true
errors=\$(tail -n 20000 "\$f" | grep -ciE 'ERROR|Exception|Caused by:' || true)
warns=\$(tail -n 20000 "\$f" | grep -ci 'WARN' || true)
echo "RECENT_20000: errors=\$errors warns=\$warns"
echo '=== 最近异常摘要（最多20行） ==='
tail -n 20000 "\$f" | grep -iE 'ERROR|WARN|Exception|Caused by:' | tail -n 20 || true
EOF
)
    ssh_run "$SRV_HOST" "$SRV_KEY" "$SRV_USER" "$cmd"
  done
}

# ---- 查日志 ----
do_logs(){
  local envName="$1" svc="$2" n="${3:-100}" server="${4:-}" date="${5:-}"
  validate_date "$date"
  load_service "$envName" "$svc"
  IFS=',' read -ra srv_arr <<< "$SVC_SERVERS"
  local target="${srv_arr[0]}"
  [ -n "$server" ] && target="$server"
  load_server "$envName" "$target"
  local logdir; logdir=$(resolve_logdir "$SVC_LOGDIR_TPL" "$SVC_NAME" "$SRV_LAN")
  header "[$SRV_NAME $SRV_HOST]"
  log "[$envName] logs ($SVC_DESC): 最近 $n 行"
  if [ -n "$date" ]; then
    local dateDash="${date:0:4}-${date:4:2}-${date:6:2}"
    ssh_run "$SRV_HOST" "$SRV_KEY" "$SRV_USER" "ls -t ${logdir}/*${date}*.log ${logdir}/*${dateDash}*.log 2>/dev/null | head -1 | xargs -r tail -n $n"
  else
    local cmd="f=\$(ls -t ${logdir}/${SVC_LOGGLOB} 2>/dev/null | head -1); if [ -n \"\$f\" ]; then echo \"文件: \$f\"; tail -n $n \"\$f\"; else echo '(无日志文件)'; fi"
    ssh_run "$SRV_HOST" "$SRV_KEY" "$SRV_USER" "$cmd"
  fi
}

# ---- 搜日志 ----
do_grep(){
  local envName="$1" svc="$2" pat="${3:-error}" n="${4:-200}" server="${5:-}" date="${6:-}" ctx="${7:-}"
  validate_date "$date"
  load_service "$envName" "$svc"
  IFS=',' read -ra srv_arr <<< "$SVC_SERVERS"
  local target="${srv_arr[0]}"
  [ -n "$server" ] && target="$server"
  load_server "$envName" "$target"
  local logdir; logdir=$(resolve_logdir "$SVC_LOGDIR_TPL" "$SVC_NAME" "$SRV_LAN")
  header "[$SRV_NAME $SRV_HOST]"
  local ctxDesc=""; [ -n "$ctx" ] && ctxDesc=" 上下文${ctx}行"
  log "[$envName] grep '$pat' ($SVC_DESC): 最近 $n 条$ctxDesc"
  local grepOpts="-hiE"; [ -n "$ctx" ] && grepOpts="-hiE -C $ctx"
  if [ -n "$date" ]; then
    local dateDash="${date:0:4}-${date:4:2}-${date:6:2}"
    ssh_run "$SRV_HOST" "$SRV_KEY" "$SRV_USER" "files=\$(ls -t ${logdir}/*${date}*.log ${logdir}/*${dateDash}*.log 2>/dev/null | head -3); [ -n \"\$files\" ] && echo \"\$files\" | xargs grep $grepOpts '${pat}' | tail -n $n"
  else
    ssh_run "$SRV_HOST" "$SRV_KEY" "$SRV_USER" "files=\$(ls -t ${logdir}/${SVC_LOGGLOB} 2>/dev/null | head -3); [ -n \"\$files\" ] && echo \"\$files\" | xargs grep $grepOpts '${pat}' | tail -n $n"
  fi
}

# ---- 搜日志(所有服务器) ----
do_grepall(){
  local envName="$1" svc="$2" pat="${3:-error}" n="${4:-200}" date="${5:-}" ctx="${6:-}"
  validate_date "$date"
  load_service "$envName" "$svc"
  local ctxDesc=""; [ -n "$ctx" ] && ctxDesc=" 上下文${ctx}行"
  log "[$envName] grep '$pat' on ALL servers for $SVC_NAME: 每台 $n 条$ctxDesc"
  local grepOpts="-hiE"; [ -n "$ctx" ] && grepOpts="-hiE -C $ctx"
  IFS=',' read -ra srv_arr <<< "$SVC_SERVERS"
  for s in "${srv_arr[@]}"; do
    load_server "$envName" "$s"
    local logdir; logdir=$(resolve_logdir "$SVC_LOGDIR_TPL" "$SVC_NAME" "$SRV_LAN")
    header "=== [$SRV_NAME $SRV_HOST $SRV_LAN] ==="
    if [ -n "$date" ]; then
      local dateDash="${date:0:4}-${date:4:2}-${date:6:2}"
      ssh_run "$SRV_HOST" "$SRV_KEY" "$SRV_USER" "files=\$(ls -t ${logdir}/*${date}*.log ${logdir}/*${dateDash}*.log 2>/dev/null | head -3); [ -n \"\$files\" ] && echo \"\$files\" | xargs grep $grepOpts '${pat}' | tail -n $n"
    else
      ssh_run "$SRV_HOST" "$SRV_KEY" "$SRV_USER" "files=\$(ls -t ${logdir}/${SVC_LOGGLOB} 2>/dev/null | head -3); [ -n \"\$files\" ] && echo \"\$files\" | xargs grep $grepOpts '${pat}' | tail -n $n"
    fi
  done
}

# ---- 搜历史备份 ----
do_backupgrep(){
  local envName="$1" svc="$2" pat="${3:-error}" date="${4:-}" server="${5:-}" ctx="${6:-}"
  validate_date "$date"
  load_service "$envName" "$svc"
  IFS=',' read -ra srv_arr <<< "$SVC_SERVERS"
  local target="${srv_arr[0]}"
  [ -n "$server" ] && target="$server"
  load_server "$envName" "$target"
  local bkdir="/data/prod-log-backup/$SRV_LAN/$SVC_NAME"
  local ctxDesc=""; [ -n "$ctx" ] && ctxDesc=" 上下文${ctx}行"
  header "[$SRV_NAME 备份 $SRV_LAN]"
  log "[$envName] backup grep '$pat' ($SVC_DESC): $bkdir$ctxDesc"
  local grepOpts="-hiE"; [ -n "$ctx" ] && grepOpts="-hiE -C $ctx"
  if [ -n "$date" ]; then
    local dateDash="${date:0:4}-${date:4:2}-${date:6:2}"
    ssh_run "$SRV_HOST" "$SRV_KEY" "$SRV_USER" "files=\$(ls -t ${bkdir}/*${date}*.log ${bkdir}/*${dateDash}*.log 2>/dev/null | head -3); [ -n \"\$files\" ] && echo \"\$files\" | xargs grep $grepOpts '${pat}' | tail -n 200"
  else
    ssh_run "$SRV_HOST" "$SRV_KEY" "$SRV_USER" "files=\$(ls -t ${bkdir}/*.log 2>/dev/null | head -3); [ -n \"\$files\" ] && echo \"\$files\" | xargs grep $grepOpts '${pat}' | tail -n 200"
  fi
}

# ---- 列日志文件 ----
do_logfiles(){
  local envName="$1" svc="$2" server="${3:-}" date="${4:-}"
  validate_date "$date"
  load_service "$envName" "$svc"
  IFS=',' read -ra srv_arr <<< "$SVC_SERVERS"
  local target="${srv_arr[0]}"
  [ -n "$server" ] && target="$server"
  load_server "$envName" "$target"
  local logdir; logdir=$(resolve_logdir "$SVC_LOGDIR_TPL" "$SVC_NAME" "$SRV_LAN")
  header "[$SRV_NAME $SRV_HOST]"
  log "[$envName] log files in: $logdir"
  if [ -n "$date" ]; then
    local dateDash="${date:0:4}-${date:4:2}-${date:6:2}"
    ssh_run "$SRV_HOST" "$SRV_KEY" "$SRV_USER" "ls -lht ${logdir}/*${date}*.log ${logdir}/*${dateDash}*.log 2>/dev/null | head -20"
  else
    ssh_run "$SRV_HOST" "$SRV_KEY" "$SRV_USER" "ls -lht ${logdir}/${SVC_LOGGLOB} 2>/dev/null | head -20"
  fi
}

# ---- 按时间范围搜 ----
do_logsrange(){
  local envName="$1" svc="$2" start="$3" end="$4" pat="${5:-}" server="${6:-}" date="${7:-}"
  validate_date "$date"
  load_service "$envName" "$svc"
  IFS=',' read -ra srv_arr <<< "$SVC_SERVERS"
  local target="${srv_arr[0]}"
  [ -n "$server" ] && target="$server"
  load_server "$envName" "$target"
  local logdir; logdir=$(resolve_logdir "$SVC_LOGDIR_TPL" "$SVC_NAME" "$SRV_LAN")
  header "[$SRV_NAME $SRV_HOST]"
  local patDesc=""; [ -n "$pat" ] && patDesc=" 关键词='$pat'"
  log "[$envName] logs-range $start ~ $end ($SVC_DESC)$patDesc"
  local startTs="[$start" endTs="[$end"
  local fileSel
  if [ -n "$date" ]; then
    local dateDash="${date:0:4}-${date:4:2}-${date:6:2}"
    fileSel="ls -t ${logdir}/*${date}*.log ${logdir}/*${dateDash}*.log 2>/dev/null | head -1"
  else
    fileSel="ls -t ${logdir}/${SVC_LOGGLOB} 2>/dev/null | head -1"
  fi
  if [ -n "$pat" ]; then
    ssh_run "$SRV_HOST" "$SRV_KEY" "$SRV_USER" "f=\$($fileSel); [ -z \"\$f\" ] && echo '(无日志文件)' && exit 0; echo '文件: '\$f; awk -v s='$startTs' -v e='$endTs' '/^\[20[0-9][0-9]-/ { ts=substr(\$0,1,20); in_range=(ts>=s && ts<=e) } in_range { print }' \"\$f\" | grep -iE '${pat}' | tail -n 500"
  else
    ssh_run "$SRV_HOST" "$SRV_KEY" "$SRV_USER" "f=\$($fileSel); [ -z \"\$f\" ] && echo '(无日志文件)' && exit 0; echo '文件: '\$f; awk -v s='$startTs' -v e='$endTs' '/^\[20[0-9][0-9]-/ { ts=substr(\$0,1,20); in_range=(ts>=s && ts<=e) } in_range { print }' \"\$f\" | tail -n 1000"
  fi
}

# ---- traceId 追踪 ----
do_trace(){
  local envName="$1" traceId="$2" svcList="${3:-}" server="${4:-}"
  local envInfo; envInfo=$(get_env_files "$envName")
  local rest="${envInfo#*|}"; local servicesFile="${rest%%|*}"
  # 未显式指定服务时, 默认检索配置中登记的全部服务
  local default_svcs; default_svcs=$(get_config "$servicesFile" | cut -d'|' -f1 | tr '\n' ',')
  IFS=',' read -ra svcs <<< "${svcList:-$default_svcs}"
  log "[$envName] trace '$traceId': 搜 ${#svcs[@]} 个服务"
  for svcName in "${svcs[@]}"; do
    svcName="${svcName## }"; svcName="${svcName%% }"
    [ -z "$svcName" ] && continue
    local line; line=$(get_config "$servicesFile" | grep -E "^${svcName}\|" | head -1)
    [ -n "$line" ] || { warn "  服务 '$svcName' 未配置,跳过"; continue; }
    IFS='|' read -r sName sServers sLogDirTpl sLogGlob <<< "$line"
    IFS=',' read -ra sa <<< "$sServers"
    local target="${sa[0]}"
    if [ -n "$server" ]; then
      for x in "${sa[@]}"; do [ "$x" = "$server" ] && target="$server" && break; done
    fi
    load_server "$envName" "$target"
    local logdir; logdir=$(resolve_logdir "$sLogDirTpl" "$sName" "$SRV_LAN")
    header "=== [$sName on $SRV_NAME $SRV_HOST] ==="
    ssh_run "$SRV_HOST" "$SRV_KEY" "$SRV_USER" "files=\$(ls -t ${logdir}/${sLogGlob} 2>/dev/null | head -3); [ -n \"\$files\" ] && echo \"\$files\" | xargs grep -h '${traceId}' 2>/dev/null | tail -n 20"
  done
}

# ---- 统计关键词 ----
do_count(){
  local envName="$1" svc="$2" pat="${3:-error}" server="${4:-}" date="${5:-}"
  validate_date "$date"
  load_service "$envName" "$svc"
  IFS=',' read -ra srv_arr <<< "$SVC_SERVERS"
  local target="${srv_arr[0]}"
  [ -n "$server" ] && target="$server"
  load_server "$envName" "$target"
  local logdir; logdir=$(resolve_logdir "$SVC_LOGDIR_TPL" "$SVC_NAME" "$SRV_LAN")
  header "[$SRV_NAME $SRV_HOST]"
  log "[$envName] count '$pat' ($SVC_DESC)"
  if [ -n "$date" ]; then
    local dateDash="${date:0:4}-${date:4:2}-${date:6:2}"
    ssh_run "$SRV_HOST" "$SRV_KEY" "$SRV_USER" "files=\$(ls -t ${logdir}/*${date}*.log ${logdir}/*${dateDash}*.log 2>/dev/null | head -3); [ -n \"\$files\" ] && echo \"\$files\" | xargs grep -hicE '${pat}' 2>/dev/null"
  else
    ssh_run "$SRV_HOST" "$SRV_KEY" "$SRV_USER" "files=\$(ls -t ${logdir}/${SVC_LOGGLOB} 2>/dev/null | head -3); [ -n \"\$files\" ] && echo \"\$files\" | xargs grep -hicE '${pat}' 2>/dev/null"
  fi
}

# ---- Nginx 统计 ----
do_nginx_stats(){
  local envName="$1" server="$2" date="${3:-}" domain="${4:-}"
  validate_date "$date"
  load_server "$envName" "$server"
  local logdir="/opt/nginx/logs"
  header "[$SRV_NAME $SRV_HOST]"
  local domDesc=""; [ -n "$domain" ] && domDesc=" 域含'$domain'"
  log "[$envName] nginx stats$domDesc"
  local fileSel
  if [ -n "$domain" ]; then
    fileSel="ls -t ${logdir}/*${domain}*access*.log 2>/dev/null | head -5"
  else
    fileSel="ls -t ${logdir}/*access*.log 2>/dev/null | head -5"
  fi
  local dateFilter=""
  if [ -n "$date" ]; then
    local d="${date:6:2}" m="${date:4:2}" y="${date:0:4}"
    local months=("Jan" "Feb" "Mar" "Apr" "May" "Jun" "Jul" "Aug" "Sep" "Oct" "Nov" "Dec")
    local idx=$((10#$m - 1))
    local mName="${months[$idx]}"
    dateFilter="| grep '${d}/${mName}/${y}'"
  fi
  if [ -n "$domain" ]; then
    ssh_run "$SRV_HOST" "$SRV_KEY" "$SRV_USER" "files=\$($fileSel); [ -z \"\$files\" ] && echo '(无日志文件)' && exit 0; echo '=== 文件列表 ==='; echo \"\$files\"; echo ''; echo '=== 状态码统计 ==='; echo \"\$files\" | xargs cat 2>/dev/null $dateFilter | awk '{print \$9}' | sort | uniq -c | sort -rn | head -20; echo ''; echo '=== Top 20 URL ==='; echo \"\$files\" | xargs cat 2>/dev/null $dateFilter | awk '{print \$9, \$7}' | sort | uniq -c | sort -rn | head -20"
  else
    ssh_run "$SRV_HOST" "$SRV_KEY" "$SRV_USER" "files=\$($fileSel); [ -z \"\$files\" ] && echo '(无日志文件)' && exit 0; echo '=== 文件列表 ==='; echo \"\$files\"; echo ''; echo '=== 状态码统计 ==='; echo \"\$files\" | xargs cat 2>/dev/null $dateFilter | awk '{print \$9}' | sort | uniq -c | sort -rn | head -20; echo ''; echo '=== 5xx Top 20 ==='; echo \"\$files\" | xargs cat 2>/dev/null $dateFilter | awk '\$9 ~ /^5/{print \$9, \$7}' | sort | uniq -c | sort -rn | head -20; echo ''; echo '=== 4xx Top 20 ==='; echo \"\$files\" | xargs cat 2>/dev/null $dateFilter | awk '\$9 ~ /^4/{print \$9, \$7}' | sort | uniq -c | sort -rn | head -20"
  fi
}

# ====== test 独有: 发版 ======
do_deploy_plan(){
  assert_deployable "$1" "plan"
  load_service "$1" "$2"
  [ -n "$SVC_REPO" ] || die "$2 未配置发版信息 (repo/module/dir/artifact/deployMode)"
  IFS=',' read -ra srv_arr <<< "$SVC_SERVERS"
  load_server "$1" "${srv_arr[0]}"
  local failures=0 repoPath="" localArtifact="" requiredTools=()
  if [ -n "$WS" ]; then
    repoPath="$WS/$SVC_REPO"
    if [ "$SVC_KIND" = "frontend" ]; then localArtifact="$repoPath/$SVC_ARTIFACT"; else localArtifact="$repoPath/$SVC_MODULE/target/$SVC_ARTIFACT"; fi
  fi
  if [ "$SVC_KIND" = "frontend" ]; then
    requiredTools=(ssh scp node tar curl)
    if [ "$SVC_PACKAGE_MANAGER" = "npm" ]; then requiredTools+=(npm); else requiredTools+=(corepack); fi
  else
    requiredTools=(ssh scp mvn java)
  fi
  for tool in "${requiredTools[@]}"; do command -v "$tool" >/dev/null 2>&1 || { warn "缺少命令: $tool"; failures=$((failures+1)); }; done
  [ -n "$WS" ] && [ -d "$WS" ] || { warn "未找到工作区，设置 SERVICE_OPS_WS（兼容 SERVER_OPS_WS）"; failures=$((failures+1)); }
  [ -z "$repoPath" ] || [ -d "$repoPath" ] || { warn "仓库不存在: $repoPath"; failures=$((failures+1)); }
  [ -f "$SRV_KEY" ] || { warn "私钥不存在: $SRV_KEY"; failures=$((failures+1)); }
  header "[test deploy plan] $SVC_NAME"
  echo "kind        : $SVC_KIND"
  echo "repo/module : $SVC_REPO/${SVC_MODULE:--}"
  if [ "$SVC_KIND" = "frontend" ]; then echo "target      : $SRV_NAME $SRV_HOST:$SVC_DIR"; else echo "target      : $SRV_NAME $SRV_HOST:$SVC_DIR/$SVC_ARTIFACT"; fi
  echo "deploy mode : $SVC_DEPLOY_MODE"
  echo "artifact    : ${localArtifact:-'(工作区未配置)'}"
  if [ -n "$localArtifact" ] && [ -e "$localArtifact" ]; then echo "exists      : true"; else echo "exists      : false"; fi
  [ -z "$SVC_PACKAGE_MANAGER" ] || echo "package mgr : $SVC_PACKAGE_MANAGER"
  [ -z "$SVC_VERIFY_URL" ] || echo "verify url  : $SVC_VERIFY_URL"
  [ "$failures" -eq 0 ] || die "发版预检未通过"
  log "发版预检通过"
}

do_build(){
  assert_deployable "$1" "build"
  load_service "$1" "$2"
  [ -n "$SVC_REPO" ] || die "$2 未配置发版信息 (repo/module/dir/artifact/deployMode)"
  [ -n "$WS" ] || die "未找到 vibecoding-workspace，设置 SERVICE_OPS_WS（兼容 SERVER_OPS_WS）"
  [ -d "$WS/$SVC_REPO" ] || die "仓库不存在: $WS/$SVC_REPO"
  if [ "$SVC_KIND" = "frontend" ]; then
    [ -n "$SVC_PACKAGE_MANAGER" ] || die "$2 未配置 packageManager"
    local localArtifact="$WS/$SVC_REPO/$SVC_ARTIFACT"
    case "$SVC_PACKAGE_MANAGER" in
      npm)
        log "[test] build: $SVC_REPO (npm ci && build:test)"
        ( cd "$WS/$SVC_REPO" && HUSKY=0 CI=1 npm ci && npm run build:test ) || die "前端构建失败"
        ;;
      pnpm@*)
        [[ "$SVC_PACKAGE_MANAGER" =~ ^pnpm@[0-9]+\.[0-9]+\.[0-9]+([-+][A-Za-z0-9.-]+)?$ ]] || die "$2 的 packageManager 无效: $SVC_PACKAGE_MANAGER"
        log "[test] build: $SVC_REPO ($SVC_PACKAGE_MANAGER install --frozen-lockfile && build:test)"
        ( cd "$WS/$SVC_REPO" && HUSKY=0 CI=1 corepack "$SVC_PACKAGE_MANAGER" install --frozen-lockfile && corepack "$SVC_PACKAGE_MANAGER" run build:test ) || die "前端构建失败"
        ;;
      *) die "$2 的 packageManager 无效: $SVC_PACKAGE_MANAGER" ;;
    esac
    [ -f "$localArtifact/index.html" ] || die "前端构建产物缺少 index.html: $localArtifact"
    log "产物: $localArtifact ($(find "$localArtifact" -type f | wc -l | tr -d ' ') files)"
    return
  fi
  local localJar="$WS/$SVC_REPO/$SVC_MODULE/target/$SVC_ARTIFACT"
  log "[test] build: $SVC_REPO/$SVC_MODULE (mvn -Ptest, JDK8)"
  ( cd "$WS/$SVC_REPO" && mvn -pl "$SVC_MODULE" -am clean package -P test -DskipTests ) || die "mvn 构建失败"
  [ -f "$localJar" ] || die "构建产物不存在: $localJar"
  log "产物: $localJar ($(du -h "$localJar" | cut -f1))"
}

do_upload(){
  assert_deployable "$1" "upload"
  load_service "$1" "$2"
  [ -n "$SVC_DIR" ] || die "$2 未配置发版信息"
  IFS=',' read -ra srv_arr <<< "$SVC_SERVERS"
  load_server "$1" "${srv_arr[0]}"
  if [ "$SVC_KIND" = "frontend" ]; then
    local localDir="$WS/$SVC_REPO/$SVC_ARTIFACT"
    [ -f "$localDir/index.html" ] || die "前端产物不存在或缺少 index.html，先 build: $localDir"
    local releaseId targetParent targetName remoteArchive remoteStage remoteBackup localArchive
    releaseId="$(date +%Y%m%d%H%M%S)-$$"
    targetParent="${SVC_DIR%/*}"
    targetName="${SVC_DIR##*/}"
    remoteArchive="$targetParent/.$targetName.$releaseId.tar.gz"
    remoteStage="$targetParent/.$targetName.new.$releaseId"
    remoteBackup="$targetParent/$targetName.backup.$releaseId"
    localArchive="${TMPDIR:-/tmp}/service-ops-$SVC_NAME-$releaseId.tar.gz"
    tar -czf "$localArchive" -C "$localDir" . || { rm -f "$localArchive"; die "前端产物打包失败: $localDir"; }
    log "[test] upload: $localDir -> $SRV_HOST:$SVC_DIR (目录原子替换)"
    scp_put "$SRV_HOST" "$SRV_KEY" "$SRV_USER" "$localArchive" "$remoteArchive" || { rm -f "$localArchive"; die "前端产物上传失败"; }
    local cmd
    cmd="set -e
mkdir '$remoteStage'
tar -xzf '$remoteArchive' -C '$remoteStage'
test -f '$remoteStage/index.html'
had_current=0
if [ -e '$SVC_DIR' ]; then
  mv '$SVC_DIR' '$remoteBackup'
  had_current=1
fi
if mv '$remoteStage' '$SVC_DIR'; then
  rm -f '$remoteArchive'
  echo 'uploaded; backup=$remoteBackup'
else
  if [ \"\$had_current\" -eq 1 ]; then mv '$remoteBackup' '$SVC_DIR'; fi
  exit 1
fi"
    ssh_run "$SRV_HOST" "$SRV_KEY" "$SRV_USER" "$cmd" || { rm -f "$localArchive"; die "前端目录切换失败；脚本已尝试恢复原目录"; }
    rm -f "$localArchive"
    return
  fi
  local localJar="$WS/$SVC_REPO/$SVC_MODULE/target/$SVC_ARTIFACT"
  [ -f "$localJar" ] || die "本地 jar 不存在, 先 build: $localJar"
  local tmp="$SVC_DIR/$SVC_ARTIFACT.new"
  log "[test] upload: $localJar -> $SRV_HOST:$SVC_DIR/$SVC_ARTIFACT (原子覆盖)"
  scp_put "$SRV_HOST" "$SRV_KEY" "$SRV_USER" "$localJar" "$tmp"
  ssh_run "$SRV_HOST" "$SRV_KEY" "$SRV_USER" "mv -f '$tmp' '$SVC_DIR/$SVC_ARTIFACT' && echo uploaded"
}

do_restart(){
  assert_deployable "$1" "restart"
  load_service "$1" "$2"
  [ -n "$SVC_DIR" ] || die "$2 未配置发版信息"
  if [ "$SVC_KIND" = "frontend" ]; then log "[test] restart: $SVC_NAME 为静态前端，无需重启"; return; fi
  IFS=',' read -ra srv_arr <<< "$SVC_SERVERS"
  load_server "$1" "${srv_arr[0]}"
  log "[test] restart: $SVC_NAME on $SRV_NAME ($SRV_HOST)"
  case "$SVC_RESTART" in
    script)    ssh_run "$SRV_HOST" "$SRV_KEY" "$SRV_USER" "bash '$SVC_DIR/restart.sh'" ;;
    stopstart) ssh_run "$SRV_HOST" "$SRV_KEY" "$SRV_USER" "cd '$SVC_DIR' && bash stop.sh && sleep 1 && bash start.sh" ;;
    *) die "未知 restart 模式: $SVC_RESTART" ;;
  esac
}

do_all(){
  assert_deployable "$1" "all"
  local svc="$2"
  load_service "test" "$svc"
  IFS=',' read -ra srv_arr <<< "$SVC_SERVERS"
  load_server "test" "${srv_arr[0]}"
  do_build "test" "$svc"
  do_upload "test" "$svc"
  do_restart "test" "$svc"
  if [ "$SVC_KIND" != "frontend" ]; then
    log "等进程起来 (最多 30s)..."
    ssh_run "$SRV_HOST" "$SRV_KEY" "$SRV_USER" "for i in \$(seq 1 30); do pgrep -f '$SVC_ARTIFACT' >/dev/null 2>&1 && echo \"已起(第\${i}次)\" && break; sleep 1; done"
  fi
  do_deploy_verify "test" "$svc"
}

do_deploy_verify(){
  assert_deployable "$1" "verify"
  load_service "$1" "$2"
  [ -n "$SVC_DIR" ] || die "$2 未配置发版信息"
  IFS=',' read -ra srv_arr <<< "$SVC_SERVERS"
  local srvName="${srv_arr[0]}"
  load_server "$1" "$srvName"
  header "[test deploy verify] $SVC_NAME"
  if [ "$SVC_KIND" = "frontend" ]; then
    ssh_run "$SRV_HOST" "$SRV_KEY" "$SRV_USER" "test -f '$SVC_DIR/index.html' && stat -c 'INDEX: %n | UPDATED: %y | SIZE: %s bytes' '$SVC_DIR/index.html' || { echo 'INDEX: NOT_FOUND'; exit 1; }" || die "远程前端产物验证失败"
    [ -n "$SVC_VERIFY_URL" ] || die "$2 未配置 verifyUrl"
    local separator='?'
    [[ "$SVC_VERIFY_URL" == *\?* ]] && separator='&'
    local httpCode
    httpCode=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 "$SVC_VERIFY_URL${separator}_service_ops=$(date +%s)") || die "前端 HTTP 验证失败"
    [ "$httpCode" = "200" ] || die "前端 HTTP 验证失败: $httpCode"
    log "HTTP: $httpCode $SVC_VERIFY_URL"
    return
  fi
  ssh_run "$SRV_HOST" "$SRV_KEY" "$SRV_USER" "stat -c 'JAR: %n | UPDATED: %y | SIZE: %s bytes' '$SVC_DIR/$SVC_ARTIFACT' 2>/dev/null || echo 'JAR: NOT_FOUND'"
  do_health "$1" "$2" "$srvName"
}

# ====== 服务器级 ======
do_server_ps(){ load_server "$1" "$2"; header "[$SRV_NAME $SRV_HOST $SRV_LAN]"; ssh_run "$SRV_HOST" "$SRV_KEY" "$SRV_USER" "ps -ef | grep -i java | grep -v grep"; }
do_server_disk(){ load_server "$1" "$2"; header "[$SRV_NAME $SRV_HOST]"; ssh_run "$SRV_HOST" "$SRV_KEY" "$SRV_USER" "df -h | grep -vE 'tmpfs|overlay|udev'"; }
do_server_mem(){ load_server "$1" "$2"; header "[$SRV_NAME $SRV_HOST]"; ssh_run "$SRV_HOST" "$SRV_KEY" "$SRV_USER" "free -m"; }
do_server_top(){ load_server "$1" "$2"; header "[$SRV_NAME $SRV_HOST]"; ssh_run "$SRV_HOST" "$SRV_KEY" "$SRV_USER" "top -bn1 | head -25"; }
do_server_services(){ load_server "$1" "$2"; header "[$SRV_NAME $SRV_HOST $SRV_LAN]"; log "($SRV_DESC)"; ssh_run "$SRV_HOST" "$SRV_KEY" "$SRV_USER" "ls /opt/ 2>/dev/null | grep -v -E 'containerd|fonts|backup'"; }
do_server_net(){
  load_server "$1" "$2"; header "[$SRV_NAME $SRV_HOST $SRV_LAN]"; log "网络: 端口监听 + 活跃连接 TOP"
  ssh_run "$SRV_HOST" "$SRV_KEY" "$SRV_USER" "echo '=== 监听端口 ==='; ss -tln 2>/dev/null | head -40; echo ''; echo '=== 活跃连接 TOP 20 ==='; ss -tn 2>/dev/null | awk 'NR>1{n=split(\$5,a,\":\"); if(n>1) print a[1]}' | sort | uniq -c | sort -rn | head -20; echo ''; echo '=== ESTABLISHED ==='; ss -tn 2>/dev/null | grep ESTAB | wc -l"
}
do_server_jvm(){
  local envName="$1" srvName="$2" filter="${3:-}"
  [ -z "$filter" ] || [[ "$filter" =~ ^[A-Za-z0-9._-]+$ ]] || die "jvm filter 仅允许字母、数字、点、下划线和连字符"
  load_server "$envName" "$srvName"
  header "[$SRV_NAME $SRV_HOST]"; log "JVM: PID / CPU / MEM / ELAPSED / COMMAND"
  local cmd="ps -eo pid,pcpu,pmem,etime,args --sort=-pcpu | awk 'NR==1 || /[j]ava/'"
  if [ -n "$filter" ]; then cmd="$cmd | grep -F -- '$filter' | head -30"; else cmd="$cmd | head -30"; fi
  ssh_run "$SRV_HOST" "$SRV_KEY" "$SRV_USER" "$cmd"
}
do_server_exec(){
  [ "$1" != "prod" ] || die "exec 已在 prod 禁用；使用 ps/disk/mem/top/services/net/jvm 等只读动作"
  load_server "$1" "$2"; header "[$SRV_NAME $SRV_HOST]"; shift 2; ssh_run "$SRV_HOST" "$SRV_KEY" "$SRV_USER" "$*"
}

# ====== 全局 ======
do_all_disk(){
  local envInfo; envInfo=$(get_env_files "$1"); local serversFile="${envInfo%%|*}"
  log "[$1] 所有服务器磁盘:"
  while IFS='|' read -r name host user key lan desc; do
    [ -z "$name" ] && continue
    load_server "$1" "$name"
    header "=== [$SRV_NAME $SRV_HOST] ==="
    ssh_run "$SRV_HOST" "$SRV_KEY" "$SRV_USER" "df -h | grep -vE 'tmpfs|overlay|udev'"
  done < <(get_config "$serversFile")
}

do_all_ps(){
  local envInfo; envInfo=$(get_env_files "$1"); local serversFile="${envInfo%%|*}"
  log "[$1] 所有服务器 Java 进程:"
  while IFS='|' read -r name host user key lan desc; do
    [ -z "$name" ] && continue
    load_server "$1" "$name"
    header "=== [$SRV_NAME $SRV_HOST] ==="
    ssh_run "$SRV_HOST" "$SRV_KEY" "$SRV_USER" "ps -ef | grep -i java | grep -v grep | awk '{print \$2, \$8, \$9, \$10, \$11}'"
  done < <(get_config "$serversFile")
}

# ====== usage ======
usage(){
  cat <<EOF
service-ops.sh — 多环境服务运维工具 (bash 版, 跨平台)
用法: bash service-ops.sh <env> <service|server|all> <action> [args]
⚠️ prod 只读, test 全权 (可发版/重启)

通用 service 级:
  status [server]                 查服务进程
  logs [N] [server] [date]        最近 N 行日志 (默认100)
  grep <pat> [N] [server] [date] [ctx]  搜日志 (默认200, ctx=上下文行)
  grepall <pat> [N] [date] [ctx]  搜日志(所有服务器)
  backupgrep <pat> [date] [server] [ctx]  搜历史备份(prod共享盘)
  logsrange <start> <end> [pat] [server] [date]  按时间范围搜
  count <pat> [server] [date]     统计关键词
  logfiles [server] [date]        列日志文件

全局:
  doctor [query|deploy]             本地依赖/配置/私钥预检
  trace <traceId> [服务列表] [server]  traceId追踪
  nginx-stats <server> [date] [domain]  Nginx统计
  list | servers | all-disk | all-ps

变更类动作 (需环境允许变更):
  plan | build | upload | restart | verify | all
  后端走 Maven/JAR；前端走包管理器锁定安装 + 静态目录原子替换

service 诊断:
  health [server] [date]          聚合进程、日志元数据和最近异常

server 级:
  ps | disk | mem | top | services | net | jvm [filter]
  exec <cmd>                      仅在允许变更的环境可用

示例:
  bash service-ops.sh prod order-api logs 20
  bash service-ops.sh prod trace "cdea832f6c5e477b"
  bash service-ops.sh prod app-01 net
  bash service-ops.sh staging order-api all
  bash service-ops.sh staging portal-web plan
EOF
}

# ====== main ======
[ $# -ge 1 ] || { usage; exit 0; }
ENV_NAME="$1"
get_env_files "$ENV_NAME" >/dev/null
[ $# -ge 2 ] || { usage; exit 1; }
ARG2="$2"; ARG3="${3:-}"
shift 3 2>/dev/null || shift $# 2>/dev/null
rest=("$@")

# 全局动作
case "$ARG2" in
  list)        do_list "$ENV_NAME"; exit 0 ;;
  servers)     do_servers "$ENV_NAME"; exit 0 ;;
  doctor)      do_doctor "$ENV_NAME" "${ARG3:-query}"; exit 0 ;;
  all-disk)    do_all_disk "$ENV_NAME"; exit 0 ;;
  all-ps)      do_all_ps "$ENV_NAME"; exit 0 ;;
  trace)       [ -n "$ARG3" ] || die "trace 需要 traceId"; do_trace "$ENV_NAME" "$ARG3" "${rest[0]:-}" "${rest[1]:-}"; exit 0 ;;
  nginx-stats) [ -n "$ARG3" ] || die "nginx-stats 需要 server"; do_nginx_stats "$ENV_NAME" "$ARG3" "${rest[0]:-}" "${rest[1]:-}"; exit 0 ;;
esac

# 判断 server 级还是 service 级
envInfo=$(get_env_files "$ENV_NAME")
serversFile="${envInfo%%|*}"
rest2="${envInfo#*|}"; servicesFile="${rest2%%|*}"

isServer=$(get_config "$serversFile" | grep -cE "^${ARG2}\|" || true)
isService=$(get_config "$servicesFile" | grep -cE "^${ARG2}\|" || true)

if [ "$isServer" -gt 0 ]; then
  [ -n "$ARG3" ] || { usage; exit 1; }
  case "$ARG3" in
    ps)       do_server_ps "$ENV_NAME" "$ARG2" ;;
    disk)     do_server_disk "$ENV_NAME" "$ARG2" ;;
    mem)      do_server_mem "$ENV_NAME" "$ARG2" ;;
    top)      do_server_top "$ENV_NAME" "$ARG2" ;;
    services) do_server_services "$ENV_NAME" "$ARG2" ;;
    net)      do_server_net "$ENV_NAME" "$ARG2" ;;
    jvm)      do_server_jvm "$ENV_NAME" "$ARG2" "${rest[0]:-}" ;;
    exec)     [ $# -ge 1 ] || die "exec 需要命令"; do_server_exec "$ENV_NAME" "$ARG2" "$@" ;;
    *) usage; die "server 级 action: ps|disk|mem|top|services|net|jvm|exec(test only)" ;;
  esac
elif [ "$isService" -gt 0 ]; then
  act="${ARG3:-status}"
  case "$act" in
    status)     do_status "$ENV_NAME" "$ARG2" "${rest[0]:-}" ;;
    health)     do_health "$ENV_NAME" "$ARG2" "${rest[0]:-}" "${rest[1]:-}" ;;
    logs)       do_logs "$ENV_NAME" "$ARG2" "${rest[0]:-100}" "${rest[1]:-}" "${rest[2]:-}" ;;
    grep)       do_grep "$ENV_NAME" "$ARG2" "${rest[0]:-error}" "${rest[1]:-200}" "${rest[2]:-}" "${rest[3]:-}" "${rest[4]:-}" ;;
    grepall)    do_grepall "$ENV_NAME" "$ARG2" "${rest[0]:-error}" "${rest[1]:-200}" "${rest[2]:-}" "${rest[3]:-}" ;;
    backupgrep) do_backupgrep "$ENV_NAME" "$ARG2" "${rest[0]:-error}" "${rest[1]:-}" "${rest[2]:-}" "${rest[3]:-}" ;;
    logsrange)  [ -n "${rest[0]:-}" ] || die "logsrange 需要 start end"; do_logsrange "$ENV_NAME" "$ARG2" "${rest[0]}" "${rest[1]}" "${rest[2]:-}" "${rest[3]:-}" "${rest[4]:-}" ;;
    count)      do_count "$ENV_NAME" "$ARG2" "${rest[0]:-error}" "${rest[1]:-}" "${rest[2]:-}" ;;
    logfiles)   do_logfiles "$ENV_NAME" "$ARG2" "${rest[0]:-}" "${rest[1]:-}" ;;
    plan)       do_deploy_plan "$ENV_NAME" "$ARG2" ;;
    build)      do_build "$ENV_NAME" "$ARG2" ;;
    upload)     do_upload "$ENV_NAME" "$ARG2" ;;
    restart)    do_restart "$ENV_NAME" "$ARG2" ;;
    verify)     do_deploy_verify "$ENV_NAME" "$ARG2" ;;
    all)        do_all "$ENV_NAME" "$ARG2" ;;
    *) usage; die "service 级 action: status|health|logs|grep|grepall|backupgrep|logsrange|count|logfiles|plan|build|upload|restart|verify|all" ;;
  esac
else
  die "未知 service/server: '$ARG2' (list 查服务, servers 查服务器)"
fi
