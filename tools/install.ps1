# ===== 星塔旅人 模组 · 安装 =====
param([string]$ManifestOverride = '', [string]$GameDirOverride = '')
. (Join-Path $PSScriptRoot 'common.ps1')

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$root    = Split-Path -Parent $PSScriptRoot
$dataDir = Join-Path $root 'data'
$fullDir = Join-Path $dataDir 'full'
$mani    = if ($ManifestOverride) { $ManifestOverride } else { Join-Path $dataDir 'manifest.tsv' }

Write-Title '星塔旅人（国服）· 模组 安装程序'

# ---- 第一步：环境检查（不通过就绝不装，游戏文件一个字节都不动）----
# 默认自动修复：能自己还原的就直接还原，省掉玩家手动跑 uninstall 的步骤
$preArgs = @{ AutoRepair = $true }
if ($GameDirOverride) { $preArgs['GameDirOverride'] = $GameDirOverride }
& (Join-Path $PSScriptRoot 'precheck.ps1') @preArgs
if ($LASTEXITCODE -ne 0) {
  Write-Host ''
  Write-Err2 '环境检查未通过，安装已中止（游戏文件没有任何改动）'
  Write-Host ''
  exit 1
}

if (-not (Test-Path -LiteralPath $mani)) { Write-Err2 "缺少清单文件: $mani"; exit 1 }
if (-not (Assert-GameNotRunning)) { exit 1 }

$game = if ($GameDirOverride) { $GameDirOverride } else { Get-GameDirInteractive }
if (-not (Test-GameDir $game)) { Write-Err2 '未能确定游戏目录，已中止。'; exit 1 }

$rows = Read-Manifest $mani
Write-Step "清单包含 $($rows.Count) 个文件"

# ---- 备份目录 ----
# 关键：必须复用「最早」的那份备份，因为只有它保存的是原始国服版。
$existing = @()
$existing += @(Get-ChildItem -LiteralPath $game -Directory -Filter '_uncensor_backup_*' -ErrorAction SilentlyContinue)
$existing += @(Get-ChildItem -LiteralPath $root -Directory -Filter '_uncensor_backup_*' -ErrorAction SilentlyContinue)
$existing  = @($existing | Sort-Object Name)
if ($existing.Count -gt 0) {
  $bak = $existing[0].FullName
  Write-Step "复用已有备份目录: $bak"
} else {
  $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
  $bak = Join-Path $game "_uncensor_backup_$stamp"
  try { New-Item -ItemType Directory -Path $bak -Force -ErrorAction Stop | Out-Null }
  catch { $bak = Join-Path $root "_uncensor_backup_$stamp"; New-Item -ItemType Directory -Path $bak -Force | Out-Null }
  Write-Step "备份目录: $bak"
}

# 记录备份对应的游戏版本
$vmf = Join-Path $game 'Persistent_Store\ss_win.mani'
$curResVer = ''
if (Test-Path -LiteralPath $vmf) {
  foreach ($ln in [System.IO.File]::ReadAllLines($vmf, [System.Text.Encoding]::UTF8)) {
    $s = $ln.Trim()
    if ($s.StartsWith('$RES_VER:')) { $curResVer = $s.Substring(9).Trim(); break }
  }
}
if ($curResVer) {
  $vfile = Join-Path $bak 'game_version.txt'
  if (-not (Test-Path -LiteralPath $vfile)) {
    try { [System.IO.File]::WriteAllText($vfile, "RES_VER=$curResVer`r`n", (New-Object System.Text.UTF8Encoding($false))) } catch {}
  }
}

$IR = Join-Path $game 'xtlr_Data\StreamingAssets\InstallResource'
$PS = Join-Path $game 'Persistent_Store\AssetBundles'

# 读历史版本哈希（识别旧模组残留）
$legacy = @{}
$legacyFile = Join-Path $dataDir 'legacy_hashes.json'
if (Test-Path -LiteralPath $legacyFile) {
  try {
    $lj = [System.IO.File]::ReadAllText($legacyFile, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    foreach ($prop in $lj.PSObject.Properties) { $legacy[$prop.Name] = @($prop.Value) }
  } catch { }
}

$bakLines = @()
$done = 0; $fail = 0; $skip = 0
$extraFixed = 0; $extraList = @()
$okPkg = 0; $badPkg = @()
$i = 0

foreach ($r in $rows) {
  $i++
  if (($i % 40) -eq 0) { Write-Host "  ... 进度 $i / $($rows.Count)" -ForegroundColor DarkGray }

  $srcF = Join-Path $fullDir $r.file
  if (-not (Test-Path -LiteralPath $srcF)) { Write-Warn2 "缺数据文件 $($r.pkg)"; $skip++; continue }

  $layers = @()
  if ($r.layer -eq 'BOTH') { $layers = @('IR', 'PS') } else { $layers = @($r.layer) }

  $thisPkgOk = $true

  # ---- 主写入 ----
  foreach ($L in $layers) {
    $dir = if ($L -eq 'IR') { $IR } else { $PS }
    if (-not (Test-Path -LiteralPath $dir)) { $thisPkgOk = $false; continue }
    $dst = Join-Path $dir $r.pkg

    if (Test-Path -LiteralPath $dst) {
      $bd = Join-Path $bak $L
      New-Item -ItemType Directory -Path $bd -Force | Out-Null
      $bf = Join-Path $bd $r.pkg
      if (-not (Test-Path -LiteralPath $bf)) {
        Copy-Item -LiteralPath $dst -Destination $bf -Force
        $bakLines += ($L + "`t" + $r.pkg)
      }
    }

    try {
      Copy-Item -LiteralPath $srcF -Destination $dst -Force
      if ((Get-Md5 $dst) -eq $r.post) { $done++ }
      else { $fail++; $thisPkgOk = $false }
    } catch {
      $fail++
      $thisPkgOk = $false
    }
  }

  # ---- 补写：另一层如果被旧模组污染，也写成我们的版本 ----
  # 只处理「另一层文件已存在」的情况：
  #   · 不存在  → 不动（避免凭空造文件）
  #   · 是官方  → 不动
  #   · 是我们  → 不动
  #   · 是旧模组/未知 → 覆盖成我们的
  if ($r.layer -ne 'BOTH') {
    $other = if ($r.layer -eq 'IR') { 'PS' } else { 'IR' }
    $odir = if ($other -eq 'IR') { $IR } else { $PS }
    $odst = Join-Path $odir $r.pkg
    if (Test-Path -LiteralPath $odst) {
      $ocur = Get-Md5 $odst
      $isOurs = ($r.post -and $ocur -eq $r.post)
      $isOfficial = $false
      # 官方 md5 从清单里的 pre 判断（构建时的官方版）
      if ($r.pre -and $ocur -eq $r.pre) { $isOfficial = $true }
      if (-not $isOurs -and -not $isOfficial) {
        # 备份另一层的原始状态
        $bd = Join-Path $bak $other
        New-Item -ItemType Directory -Path $bd -Force | Out-Null
        $bf = Join-Path $bd $r.pkg
        if (-not (Test-Path -LiteralPath $bf)) {
          Copy-Item -LiteralPath $odst -Destination $bf -Force
          $bakLines += ($other + "`t" + $r.pkg)
        }
        try {
          Copy-Item -LiteralPath $srcF -Destination $odst -Force
          if ((Get-Md5 $odst) -eq $r.post) {
            $extraFixed++
            $extraList += ($other + "/" + $r.pkg)
          } else { $fail++; $thisPkgOk = $false }
        } catch { $fail++; $thisPkgOk = $false }
      }
    }
  }

  if ($thisPkgOk) { $okPkg++ } else { $badPkg += $r.pkg }
}

# 台账：与已有台账合并
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

# 明确报告成功率
$total = $rows.Count
if ($badPkg.Count -eq 0) {
  Write-Ok "全部 $total 个包写入成功"
} else {
  Write-Warn2 "成功 $okPkg / $total 个包，失败 $($badPkg.Count) 个"
  foreach ($b in ($badPkg | Select-Object -First 10)) { Write-Host "        失败: $b" -ForegroundColor Red }
  if ($badPkg.Count -gt 10) { Write-Host "        … 还有 $($badPkg.Count - 10) 个" -ForegroundColor Red }
}

if ($extraFixed -gt 0) {
  Write-Ok "顺带修复了 $extraFixed 个被旧版模组占用的文件（另一层）"
}
if ($skip -gt 0) { Write-Warn2 "跳过 $skip 个（安装包缺数据）" }

Write-Host ''
Write-Host "  备份位置：$bak" -ForegroundColor Cyan
Write-Host '  如需退回国服原版，运行 uninstall.bat 即可。' -ForegroundColor Cyan
if ($badPkg.Count -gt 0) {
  Write-Host ''
  Write-Host '  有包写入失败，可以试试：' -ForegroundColor Yellow
  Write-Host '    1. 关掉杀毒软件实时防护后重跑 install.bat' -ForegroundColor Yellow
  Write-Host '    2. 右键 install.bat → 以管理员身份运行' -ForegroundColor Yellow
  Write-Host '    3. 还是不行就完全退出游戏再试一次' -ForegroundColor Yellow
}
Write-Host ''
