<#
.SYNOPSIS
    codebuddy-skills 安装脚本（Windows）

.DESCRIPTION
    把本仓库 skills/ 下的技能安装到用户级技能目录。
    默认使用目录联接（Junction），git pull 后立即生效；-Copy 可改为复制。

.PARAMETER Skills
    只安装指定技能，逗号或空格分隔。缺省安装全部。

.PARAMETER Copy
    使用复制而非联接。

.PARAMETER Force
    目标已存在时覆盖。默认跳过，不覆盖已有技能。

.PARAMETER Target
    自定义安装目录，默认 ~/.codebuddy/skills

.EXAMPLE
    .\install.ps1
    .\install.ps1 -Skills diagnose-services,operate-test-services
    .\install.ps1 -Copy -Force
#>
[CmdletBinding()]
param(
    [string[]]$Skills,
    [switch]$Copy,
    [switch]$Force,
    [string]$Target
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSCommandPath
$SkillsRoot = Join-Path $RepoRoot 'skills'

if (-not $Target) {
    $Target = Join-Path $HOME '.codebuddy/skills'
}

if (-not (Test-Path $SkillsRoot)) {
    Write-Host "XX 未找到技能目录: $SkillsRoot" -ForegroundColor Red
    exit 1
}

$mode = if ($Copy) { 'copy' } else { 'link' }
$installed = 0
$skipped = 0

Write-Host "仓库: $RepoRoot"
Write-Host "目标: $Target"
Write-Host "方式: $mode"
Write-Host ""

New-Item -ItemType Directory -Force -Path $Target | Out-Null

$allSkills = Get-ChildItem $SkillsRoot -Directory | Where-Object { Test-Path (Join-Path $_.FullName 'SKILL.md') }
if ($Skills) {
    $wanted = $Skills | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    $allSkills = $allSkills | Where-Object { $wanted -contains $_.Name }
    $missing = $wanted | Where-Object { $n = $_; -not ($allSkills | Where-Object { $_.Name -eq $n }) }
    foreach ($m in $missing) { Write-Host "!! 未知技能: $m" -ForegroundColor Yellow }
}

if (-not $allSkills) {
    Write-Host "XX 没有可安装的技能" -ForegroundColor Red
    exit 1
}

foreach ($skill in $allSkills) {
    $dest = Join-Path $Target $skill.Name
    $exists = Test-Path $dest
    $isOurLink = $false

    if ($exists) {
        $item = Get-Item $dest -Force
        if ($item.LinkType -and $item.Target) {
            $isOurLink = ($item.Target -join ',') -like "$($skill.FullName)*"
        }
    }

    if ($exists -and $isOurLink) {
        Write-Host "  = $($skill.Name)（已是最新联接）" -ForegroundColor DarkGray
        $skipped++
        continue
    }

    if ($exists -and -not $Force) {
        Write-Host "  ! $($skill.Name)（目标已存在且非本仓联接，已跳过；确认可覆盖时加 -Force）" -ForegroundColor Yellow
        $skipped++
        continue
    }

    if ($exists) {
        Remove-Item $dest -Recurse -Force
    }

    if ($Copy) {
        Copy-Item $skill.FullName $dest -Recurse -Force
        Write-Host "  + $($skill.Name)（已复制）" -ForegroundColor Green
    }
    else {
        New-Item -ItemType Junction -Path $dest -Target $skill.FullName | Out-Null
        Write-Host "  + $($skill.Name)（已联接）" -ForegroundColor Green
    }
    $installed++
}

Write-Host ""
Write-Host "完成：安装 $installed，跳过 $skipped。重启 IDE 后技能才会出现在列表中。" -ForegroundColor Cyan
Write-Host "配置：将 config/*.example.conf 复制为对应 *.conf 并填写。" -ForegroundColor Cyan
