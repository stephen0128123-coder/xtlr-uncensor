# ===== 星塔旅人 反和谐包 · 安装 =====
param([string]$ManifestOverride = '', [string]$GameDirOverride = '')
. (Join-Path $PSScriptRoot 'common.ps1')

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$root    = Split-Path -Parent $PSScriptRoot
$dataDir = Join-Path $root 'data'
$fullDir = Join-Path $dataDir 'full'
$mani    = if ($ManifestOverride) { $ManifestOverride } else { Join-Path $dataDir 'manifest.tsv' }

Write-Title '星塔旅人（国服）· 反和谐包 安装程序'

if (-not (Test-Path -LiteralPath $mani)) { Write-Err2 "缺少清单文件: $mani"; exit 1 }
if (-not (Assert-GameNotRunning)) { exit 1 }

$game = if ($GameDirOverride) { $GameDirOverride } else { Get-GameDirInteractive }
if (-not (Test-GameDir $game)) { Write-Err2 '未能确定游戏目录，已中止。'; exit 1 }

$rows = Read-Manifest $mani
Write-Step "清单包含 $($rows.Count) 个文件"

# ---- 备份目录 ----
# 关键：必须复用「最早」的那份备份，因为只有它保存的是原始国服版。
# 如果每次都新建备份，第二次安装会把「已改过的文件」当成原始版备份，
# 导致 uninstall 无法真正退回国服原版。
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
      # 原始 md5 与官方清单不符时仅提示
      if ($r.pre -and (Get-Md5 $dst) -ne $r.pre) { $warnPre++ }
    }

    Copy-Item -LiteralPath $srcF -Destination $dst -Force
    if ((Get-Md5 $dst) -eq $r.post) { $done++ }
    else { Write-Err2 "$L / $($r.pkg) 写入校验失败"; $fail++ }
  }
}

# 台账：与已有台账合并（重复安装时本次可能无新增备份，不能覆盖旧台账）
$bmfPath = Join-Path $bak 'backup_manifest.tsv'
$oldLines = @()
if (Test-Path -LiteralPath $bmfPath) {
  $oldLines = @([System.IO.File]::ReadAllLines($bmfPath, [System.Text.Encoding]::UTF8) |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}
$allLines = @($oldLines + $bakLines) | Select-Object -Unique
[System.IO.File]::WriteAllLines($bmfPath, $allLines, (New-Object System.Text.UTF8Encoding($false)))
[System.IO.File]::WriteAllText((Join-Path $bak 'game_dir.txt'), $game, (New-Object System.Text.UTF8Encoding($false)))
# 记录游戏目录，供 uninstall 精确定位（无需用户再选一次）
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
