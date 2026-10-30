#!/usr/bin/env bash
# codebuddy-skills 安装脚本（macOS / Linux / Git Bash）
# 把本仓库 skills/ 下的技能安装到用户级技能目录。
# 默认使用符号链接，git pull 后立即生效；-c 可改为复制。
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILLS_ROOT="$REPO_ROOT/skills"
TARGET="${CODEBUDDY_SKILLS_DIR:-$HOME/.codebuddy/skills}"
MODE="link"
FORCE=0
ONLY=""

usage() {
  cat <<'EOF'
用法: ./install.sh [选项]

  -s, --skills <a,b,c>   只安装指定技能（逗号分隔）
  -c, --copy             使用复制而非符号链接
  -f, --force            目标已存在时覆盖（默认跳过）
  -t, --target <dir>     自定义安装目录，默认 ~/.codebuddy/skills
  -l, --list             列出仓库内技能
  -h, --help             显示帮助
EOF
}

list_skills() {
  for d in "$SKILLS_ROOT"/*/; do
    [ -f "$d/SKILL.md" ] && basename "$d"
  done
}

while [ $# -gt 0 ]; do
  case "$1" in
    -s|--skills) ONLY="${2:-}"; shift 2 ;;
    -c|--copy) MODE="copy"; shift ;;
    -f|--force) FORCE=1; shift ;;
    -t|--target) TARGET="${2:-}"; shift 2 ;;
    -l|--list) list_skills; exit 0 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数: $1" >&2; usage; exit 1 ;;
  esac
done

[ -d "$SKILLS_ROOT" ] || { echo "XX 未找到技能目录: $SKILLS_ROOT" >&2; exit 1; }

echo "仓库: $REPO_ROOT"
echo "目标: $TARGET"
echo "方式: $MODE"
echo ""

mkdir -p "$TARGET"

INSTALLED=0
SKIPPED=0

for dir in "$SKILLS_ROOT"/*/; do
  [ -f "$dir/SKILL.md" ] || continue
  name="$(basename "$dir")"

  if [ -n "$ONLY" ]; then
    case ",$ONLY," in
      *",$name,"*) ;;
      *) continue ;;
    esac
  fi

  dest="$TARGET/$name"
  exists=0
  if [ -e "$dest" ] || [ -L "$dest" ]; then exists=1; fi

  # 已是指向本仓的链接，视为最新
  if [ -L "$dest" ]; then
    current="$(readlink "$dest" 2>/dev/null || true)"
    if [ "$current" = "${dir%/}" ]; then
      echo "  = $name（已是最新链接）"
      SKIPPED=$((SKIPPED+1))
      continue
    fi
  fi

  if [ "$exists" -eq 1 ] && [ "$FORCE" -eq 0 ]; then
    echo "  ! $name（目标已存在且非本仓链接，已跳过；确认可覆盖时加 -f）"
    SKIPPED=$((SKIPPED+1))
    continue
  fi

  if [ "$exists" -eq 1 ]; then
    rm -rf "$dest"
  fi

  if [ "$MODE" = "copy" ]; then
    cp -R "${dir%/}" "$dest"
    echo "  + $name（已复制）"
  else
    if ln -s "${dir%/}" "$dest" 2>/dev/null; then
      echo "  + $name（已链接）"
    else
      # Git Bash 等环境下符号链接可能不可用，退回复制
      cp -R "${dir%/}" "$dest"
      echo "  + $name（链接不可用，已改为复制）"
    fi
  fi
  INSTALLED=$((INSTALLED+1))
done

echo ""
echo "完成：安装 $INSTALLED，跳过 $SKIPPED。重启 IDE 后技能才会出现在列表中。"
echo "配置：将 config/*.example.conf 复制为对应 *.conf 并填写。"
