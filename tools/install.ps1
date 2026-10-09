# ===== 星塔旅人 反和谐包 v1.1 · 安装 =====
# 与 v1.0 的差别：如果本地没有资源（data/full），会自动从 GitHub Release 下载。
# 安装核心逻辑（备份复用 / 台账合并 / md5 校验）与 v1.0 完全一致。

param(
  [string]$ManifestOverride = '',
  [string]$GameDirOverride  = '',
  [switch]$NoDownload       # 跳过下载，用已有 data/
)

. (Join-Path $PSScriptRoot 'common.ps1')

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$root    = Split-Path -Parent $PSScriptRoot
$dataDir = Join-Path $root 'data'
$fullDir = Join-Path $dataDir 'full'
$mani    = if ($ManifestOverride) { $ManifestOverride } else { Join-Path $dataDir 'manifest.tsv' }

Write-Title '星塔旅人（国服）· 反和谐包 v1.1 安装程序'

if (-not (Assert-GameNotRunning)) { exit 1 }

# ---------- 0. 确保资源就绪 ----------
$needFetch = $false
if (-not (Test-Path -LiteralPath $fullDir)) {
  $needFetch = $true
} else {
  $cnt = @(Get-ChildItem -LiteralPath $fullDir -Recurse -File -ErrorAction SilentlyContinue).Count
  if ($cnt -eq 0) { $needFetch = $true }
}

if ($needFetch -and -not $NoDownload) {
  Write-Title '本地无资源，开始从 GitHub 下载'
  $updater = Join-Path $PSScriptRoot 'updater.ps1'
  if (-not (Test-Path -LiteralPath $updater)) { Write-Err2 "缺少下载模块: $updater"; exit 1 }

  & powershell -NoProfile -ExecutionPolicy Bypass -File $updater
  if ($LASTEXITCODE -ne 0) {
    Write-Err2 '资源下载失败，安装中止。'
    Write-Host '  可手动下载 Release 里的文件放进 data/full 后加 -NoDownload 重试。' -ForegroundColor Yellow
    exit 1
  }
} elseif ($needFetch -and $NoDownload) {
  Write-Err2 '本地无资源且指定了 -NoDownload，安装中止。'
  exit 1
} else {
  Write-Ok '本地资源已就绪，跳过下载。'
}

# ---------- 1. 定位游戏 ----------
if (-not (Test-Path -LiteralPath $mani)) { Write-Err2 "缺少清单文件: $mani"; exit 1 }
$game = if ($GameDirOverride) { $GameDirOverride } else { Get-GameDirInteractive }
if (-not (Test-GameDir $game)) { Write-Err2 '未能确定游戏目录，已中止。'; exit 1 }

$rows = Read-Manifest $mani
Write-Step "清单包含 $($rows.Count) 个文件"

# ---- 备份目录（复用最早的一份）----
$existing = @()
$existing += @(Get-ChildItem -LiteralPath $game -Directory -Filter '_uncensor_backup_*' -ErrorAction SilentlyContinue)
$existing += @(Get-ChildItem -LiteralPath $root -Directory -Filter '_uncensor_backup_*' -ErrorAction SilentlyContinue)
$existing  = @($existing | Sort-Object Name)
if ($existing.Count -gt 0) {
  $bak = $existing[0].FullName          # 最早的一份 = 最接近原始的版本
  Write-Step "复用已有备份目录: $bak"
} else {
  $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
  $bak = Join-Path $game "_uncensor_backup_$stamp"
  try { New-Item -ItemType Directory -Path $bak -Force -ErrorAction Stop | Out-Null }
  catch { $bak = Join-Path $root "_uncensor_backup_$stamp"; New-Item -ItemType Directory -Path $bak -Force | Out-Null }
  Write-Step "备份目录: $bak"
}

$IR = Join-Path $game 'xtlr_Data\StreamingAssets\InstallResource'
$PS = Join-Path $game 'Persistent_Store\AssetBundles'

$bakLines = @()
$done = 0; $fail = 0; $skip = 0; $warnPre = 0
$i = 0
foreach ($r in $rows) {
  $i++
  if (($i % 20) -eq 0) { Write-Host "  ... 进度 $i / $($rows.Count)" -ForegroundColor DarkGray }

  $srcF = Join-Path $fullDir $r.file
  if (-not (Test-Path -LiteralPath $srcF)) { Write-Warn2 "缺数据文件 $($r.pkg)"; $skip++; continue }

  $layers = @()
  if ($r.layer -eq 'BOTH') { $layers = @('IR', 'PS') } else { $layers = @($r.layer) }

  foreach ($L in $layers) {
    $dir = if ($L -eq 'IR') { $IR } else { $PS }
    if (-not (Test-Path -LiteralPath $dir)) { continue }
    $dst = Join-Path $dir $r.pkg

    # 备份原始文件（仅首次）
    if (Test-Path -LiteralPath $dst) {
      $bd = Join-Path $bak $L
      New-Item -ItemType Directory -Path $bd -Force | Out-Null
      $bf = Join-Path $bd $r.pkg
      if (-not (Test-Path -LiteralPath $bf)) {
        Copy-Item -LiteralPath $dst -Destination $bf -Force
        $bakLines += ($L + "`t" + $r.pkg)
      }
      if ($r.pre -and (Get-Md5 $dst) -ne $r.pre) { $warnPre++ }
    }

    Copy-Item -LiteralPath $srcF -Destination $dst -Force
    if ((Get-Md5 $dst) -eq $r.post) { $done++ }
    else { Write-Err2 "$L / $($r.pkg) 写入校验失败"; $fail++ }
  }
}

# 台账：合并写回（不覆盖旧台账）
$bmfPath = Join-Path $bak 'backup_manifest.tsv'
$oldLines = @()
if (Test-Path -LiteralPath $bmfPath) {
  $oldLines = @([System.IO.File]::ReadAllLines($bmfPath, [System.Text.Encoding]::UTF8) |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}
$allLines = @($oldLines + $bakLines) | Select-Object -Unique
[System.IO.File]::WriteAllLines($bmfPath, $allLines, (New-Object System.Text.UTF8Encoding($false)))
[System.IO.File]::WriteAllText((Join-Path $bak 'game_dir.txt'), $game, (New-Object System.Text.UTF8Encoding($false)))
try { [System.IO.File]::WriteAllText((Join-Path $root '_last_game_dir.txt'), $game, (New-Object System.Text.UTF8Encoding($false))) } catch {}

Write-Title '安装完成'
Write-Ok "已替换 $done 个文件"
if ($skip   -gt 0) { Write-Warn2 "跳过 $skip 个（缺数据）" }
if ($warnPre -gt 0) { Write-Warn2 "$warnPre 个文件的原始版本与官方清单不符（可能此前已改过；已照常备份）" }
if ($fail   -gt 0) { Write-Err2 "$fail 个校验失败 —— 建议运行 uninstall.bat 回退后重试" }
Write-Host ''
Write-Host "  备份位置：$bak" -ForegroundColor Cyan
Write-Host '  如需退回国服原版，运行 uninstall.bat 即可。' -ForegroundColor Cyan
Write-Host ''
