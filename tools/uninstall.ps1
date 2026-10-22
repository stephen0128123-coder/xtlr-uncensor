# ===== 星塔旅人 模组 · 一键恢复国服原版 =====
# 无条件把备份里的文件还原回去。
# 使用前提（写进 README 了）：更新游戏之前先跑这个，再更新。
param([string]$BackupDir = '', [string]$GameDirOverride = '')

. (Join-Path $PSScriptRoot 'common.ps1')

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$root = Split-Path -Parent $PSScriptRoot

Write-Title '星塔旅人（国服）· 退回国服原版'

if (-not (Assert-GameNotRunning)) { exit 1 }

# 1) 定位游戏目录
$game = $null
$cands = @()
if ($GameDirOverride) { $cands += $GameDirOverride }
if (Test-Path -LiteralPath (Join-Path $root '_last_game_dir.txt')) {
  $g0 = (Get-Content -LiteralPath (Join-Path $root '_last_game_dir.txt') -Raw).Trim()
  if (Test-GameDir $g0) { $cands += $g0 }
}
$g = Find-GameDir
if ($g) { $cands += $g }

$bakDirs = @()
if ($BackupDir) {
  $bakDirs += $BackupDir
} else {
  foreach ($c in ($cands | Select-Object -Unique)) {
    $bs = Get-ChildItem -LiteralPath $c -Directory -Filter '_uncensor_backup_*' -ErrorAction SilentlyContinue |
          Sort-Object Name
    if ($bs) {
      foreach ($b in $bs) { if ($bakDirs -notcontains $b.FullName) { $bakDirs += $b.FullName } }
      if (-not $game) { $game = $c }
    }
  }
  if (-not $game) {
    foreach ($c in ($cands | Select-Object -Unique)) { if (Test-GameDir $c) { $game = $c; break } }
  }
}

if ($bakDirs.Count -eq 0) {
  # 没有备份：退而找游戏目录，提示手动处理
  if (-not $game) { $game = Get-GameDirInteractive }
  Write-Err2 '没找到备份目录（_uncensor_backup_*），没法自动还原。'
  Write-Host ''
  Write-Host '  这种情况请用启动器修复：' -ForegroundColor Yellow
  Write-Host '    打开星塔旅人启动器 → 点「完整修复」 → 等它跑完' -ForegroundColor Yellow
  Write-Host ''
  exit 1
}

if (-not $game) { $game = Get-GameDirInteractive }
if (-not (Test-GameDir $game)) { Write-Err2 '未能确定游戏目录，已中止。'; exit 1 }

Write-Step "游戏目录: $game"
Write-Step "备份目录（$($bakDirs.Count) 个）:"
foreach ($b in $bakDirs) { Write-Host "    $b" -ForegroundColor DarkGray }

$IR = Join-Path $game 'xtlr_Data\StreamingAssets\InstallResource'
$PS = Join-Path $game 'Persistent_Store\AssetBundles'

# 2) 合并所有备份目录的台账（去重）
$seen  = @{}
$items = @()
foreach ($b in $bakDirs) {
  $bmf = Join-Path $b 'backup_manifest.tsv'
  if (-not (Test-Path -LiteralPath $bmf)) { continue }
  foreach ($ln in [System.IO.File]::ReadAllLines($bmf, [System.Text.Encoding]::UTF8)) {
    if ([string]::IsNullOrWhiteSpace($ln)) { continue }
    $f = $ln -split "`t"
    if ($f.Count -lt 2) { continue }
    $key = $f[0] + '/' + $f[1]
    if (-not $seen.ContainsKey($key)) { $seen[$key] = $true; $items += , @($f[0], $f[1]) }
  }
}
if ($items.Count -eq 0) {
  Write-Err2 '备份台账是空的，没法还原。'
  Write-Host ''
  Write-Host '  请用启动器的「完整修复」。' -ForegroundColor Yellow
  Write-Host ''
  exit 1
}

# 3) 无条件还原
$done = 0; $fail = 0
foreach ($it in $items) {
  $L = $it[0]; $pkg = $it[1]
  $dir = if ($L -eq 'IR') { $IR } else { $PS }
  $dst = Join-Path $dir $pkg

  $src = $null
  foreach ($b in $bakDirs) {                       # 最早优先
    $cand = Join-Path (Join-Path $b $L) $pkg
    if (Test-Path -LiteralPath $cand) { $src = $cand; break }
  }
  if (-not $src) { Write-Warn2 "缺备份文件 $L/$pkg"; $fail++; continue }

  try {
    Copy-Item -LiteralPath $src -Destination $dst -Force
    $done++
    Write-Host "  已还原 $L/$pkg" -ForegroundColor DarkGray
  } catch {
    Write-Err2 "$L/$pkg 还原失败"
    $fail++
  }
}

Write-Title '还原完成'
Write-Ok "已还原 $done 个文件"
if ($fail -gt 0) { Write-Warn2 "$fail 个没能还原" }
Write-Host ''
Write-Host '  游戏已退回国服原版。' -ForegroundColor Cyan
Write-Host '  接下来可以放心更新游戏，或者重新装小开关。' -ForegroundColor Cyan
Write-Host ''
