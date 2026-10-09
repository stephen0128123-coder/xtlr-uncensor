# ===== 星塔旅人 模组 · 一键恢复国服原版 =====
param([string]$BackupDir = '', [string]$GameDirOverride = '')
. (Join-Path $PSScriptRoot 'common.ps1')

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$root = Split-Path -Parent $PSScriptRoot

Write-Title '星塔旅人（国服）· 退回国服原版'

if (-not (Assert-GameNotRunning)) { exit 1 }

# 1) 收集所有候选备份目录（按名称升序 = 时间由早到晚）
#    注意：必须「最早优先」，因为最早的备份保存的才是原始国服版。
$game = $null
$cands = @()
if ($GameDirOverride) { $cands += $GameDirOverride }          # 显式指定者优先
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
  # 再找包目录旁边的备份
  $bs = Get-ChildItem -LiteralPath $root -Directory -Filter '_uncensor_backup_*' -ErrorAction SilentlyContinue |
        Sort-Object Name
  foreach ($b in $bs) { if ($bakDirs -notcontains $b.FullName) { $bakDirs += $b.FullName } }
}

if ($bakDirs.Count -eq 0) {
  Write-Err2 '没找到任何备份目录（_uncensor_backup_*）。'
  Write-Host '  请确认：① 安装时用的就是本包；② 备份目录未被删除。' -ForegroundColor Yellow
  exit 1
}
if (-not $game) {
  $b0 = $bakDirs[0]
  if (Test-Path -LiteralPath (Join-Path $b0 'game_dir.txt')) {
    $game = (Get-Content -LiteralPath (Join-Path $b0 'game_dir.txt') -Raw).Trim()
  }
}
if (-not (Test-GameDir $game)) {
  Write-Warn2 "备份里记录的游戏目录无效，请手动指定游戏目录。"
  $game = Get-GameDirInteractive
  if (-not $game) { Write-Err2 '未能确定游戏目录，已中止。'; exit 1 }
}

Write-Step "备份目录（$($bakDirs.Count) 个，最早优先）:"
foreach ($b in $bakDirs) { Write-Host "    $b" -ForegroundColor DarkGray }
Write-Step "游戏目录: $game"

$IR = Join-Path $game 'xtlr_Data\StreamingAssets\InstallResource'
$PS = Join-Path $game 'Persistent_Store\AssetBundles'

# 2) 合并所有备份目录的台账（去重，保留最早出现的顺序）
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
if ($items.Count -eq 0) { Write-Err2 '备份台账为空，无法还原。'; exit 1 }

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
  Copy-Item -LiteralPath $src -Destination $dst -Force
  $done++
  Write-Host "  已还原 $L/$pkg" -ForegroundColor DarkGray
}

Write-Title '还原完成'
Write-Ok "已还原 $done 个文件"
if ($fail -gt 0) { Write-Warn2 "$fail 个未能还原" }
Write-Host ''
Write-Host '  游戏已退回国服原版。' -ForegroundColor Cyan
Write-Host ''
