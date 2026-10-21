# ===== 星塔旅人 模组 · 安装前环境检查 =====
# 目的：把「装不好」的常见原因在动手之前全查出来，能自动修就修，修不了就说明白。
# 背景：模组是分享给玩家的，很多人不按标准步骤操作（装过旧版没卸载就更新游戏等），
#       导致同样的包在不同人机器上效果不一致。
param([string]$GameDirOverride = '', [switch]$AutoRepair)

. (Join-Path $PSScriptRoot 'common.ps1')

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$root    = Split-Path -Parent $PSScriptRoot
$dataDir = Join-Path $root 'data'
$fullDir = Join-Path $dataDir 'full'
$mani    = Join-Path $dataDir 'manifest.tsv'
$expect  = Join-Path $dataDir 'game_version.txt'

$errors  = New-Object System.Collections.ArrayList
$warns   = New-Object System.Collections.ArrayList
$repairs = New-Object System.Collections.ArrayList

function Add-Err([string]$t)  { [void]$errors.Add($t) }
function Add-Warn([string]$t) { [void]$warns.Add($t) }
function Add-Rep([string]$t)  { [void]$repairs.Add($t) }

Write-Title '星塔旅人（国服）· 安装前环境检查'

# ---------------------------------------------------------- 1. 安装包完整性
Write-Step '[1/6] 检查安装包自身 ...'
$rows = @()
if (-not (Test-Path -LiteralPath $mani)) {
  Add-Err '缺少 data\manifest.tsv（解压不完整？）'
}
if (-not (Test-Path -LiteralPath $fullDir)) {
  Add-Err '缺少 data\full 目录（解压不完整？）'
}
if ((Test-Path -LiteralPath $mani) -and (Test-Path -LiteralPath $fullDir)) {
  $rows = Read-Manifest $mani
  $missingData = 0
  $firstBad = ''
  foreach ($r in $rows) {
    $f = Join-Path $fullDir $r.file
    if (-not (Test-Path -LiteralPath $f)) { $missingData++; if (-not $firstBad) { $firstBad = $r.file } }
  }
  if ($missingData -gt 0) {
    Add-Err "安装包缺 $missingData 个资源文件（首个：$firstBad）—— 请重新解压"
  } else {
    Write-Host "      清单 $($rows.Count) 个文件，资源齐全" -ForegroundColor DarkGray
  }
}

# ---------------------------------------------------------- 2. 游戏是否退出
Write-Step '[2/6] 检查游戏是否已退出 ...'
if (-not (Assert-GameNotRunning)) { Add-Err '游戏正在运行（xtlr.exe），请先完全退出' }

# ---------------------------------------------------------- 3. 定位游戏目录
Write-Step '[3/6] 定位游戏目录 ...'
$game = if ($GameDirOverride) { $GameDirOverride } else { Get-GameDirInteractive }
if (-not (Test-GameDir $game)) {
  Add-Err '未找到有效的游戏安装目录'
} else {
  Write-Host "      $game" -ForegroundColor DarkGray
}

if ($game -and (Test-GameDir $game)) {
  $IR = Join-Path $game 'xtlr_Data\StreamingAssets\InstallResource'
  $PS = Join-Path $game 'Persistent_Store\AssetBundles'
  $officialMani = Join-Path $game 'Persistent_Store\ss_win.mani'

  # 读官方清单
  $officialHash = @{}
  $resVer = ''; $gameVer = ''
  if (Test-Path -LiteralPath $officialMani) {
    foreach ($ln in [System.IO.File]::ReadAllLines($officialMani, [System.Text.Encoding]::UTF8)) {
      $s = $ln.Trim()
      if ($s.StartsWith('$RES_VER:'))        { $resVer  = $s.Substring(9).Trim() }
      elseif ($s.StartsWith('$GAME_VER:'))   { $gameVer = $s.Substring(10).Trim() }
      elseif ($s -and -not $s.StartsWith('$')) {
        $p = $s -split '\|'
        if ($p.Count -ge 4) { $officialHash[$p[0]] = $p[1] }
      }
    }
  } else {
    Add-Err '找不到官方清单 ss_win.mani（游戏目录不完整）'
  }

  # -------------------------------------------------------- 4. 版本匹配
  Write-Step '[4/6] 检查游戏版本是否匹配 ...'
  if (Test-Path -LiteralPath $expect) {
    $exp = @{}
    foreach ($ln in [System.IO.File]::ReadAllLines($expect, [System.Text.Encoding]::UTF8)) {
      $s = $ln.Trim()
      if ($s -and $s.Contains('=')) {
        $kv = $s -split '=', 2
        $exp[$kv[0].Trim()] = $kv[1].Trim()
      }
    }
    Write-Host "      本包适配  GAME_VER=$($exp['GAME_VER'])  RES_VER=$($exp['RES_VER'])" -ForegroundColor DarkGray
    Write-Host "      当前游戏  GAME_VER=$gameVer  RES_VER=$resVer" -ForegroundColor DarkGray
    if ($exp['RES_VER'] -and $resVer -and $exp['RES_VER'] -ne $resVer) {
      Add-Err "资源版本不匹配（本包 $($exp['RES_VER']) 不等于当前 $resVer）—— 游戏已更新，请下载新版模组"
    } elseif ($exp['GAME_VER'] -and $gameVer -and $exp['GAME_VER'] -ne $gameVer) {
      Add-Err "游戏版本不匹配（本包 $($exp['GAME_VER']) 不等于当前 $gameVer）—— 请下载新版模组"
    }
  } else {
    Add-Warn '本包未记录适配版本（旧包），跳过版本校验'
  }

  # -------------------------------------------------------- 5. 旧模组残留
  Write-Step '[5/6] 检查是否残留旧模组 ...'
  $dirtyLayers = New-Object System.Collections.ArrayList
  $checked = 0
  foreach ($r in $rows) {
    $layers = if ($r.layer -eq 'BOTH') { @('IR', 'PS') } else { @($r.layer) }
    foreach ($L in $layers) {
      $dir = if ($L -eq 'IR') { $IR } else { $PS }
      $dst = Join-Path $dir $r.pkg
      if (-not (Test-Path -LiteralPath $dst)) { continue }
      $off = $officialHash[$r.pkg]
      if (-not $off) { continue }
      $checked++
      $cur = Get-Md5 $dst
      if ($cur -ne $off) {
        [void]$dirtyLayers.Add([pscustomobject]@{ Layer = $L; Pkg = $r.pkg; Cur = $cur; Off = $off })
      }
    }
  }

  $bakDirs = @(Get-ChildItem -LiteralPath $game -Directory -Filter '_uncensor_backup_*' -ErrorAction SilentlyContinue | Sort-Object Name)

  $bakUsable = $false
  $bakVer = ''
  foreach ($b in $bakDirs) {
    $vf = Join-Path $b.FullName 'game_version.txt'
    if (Test-Path -LiteralPath $vf) {
      foreach ($ln in [System.IO.File]::ReadAllLines($vf, [System.Text.Encoding]::UTF8)) {
        $s = $ln.Trim()
        if ($s.StartsWith('RES_VER=')) { $bakVer = $s.Substring(8).Trim() }
      }
      if ($bakVer -eq $resVer) { $bakUsable = $true }
      break
    }
  }

  Write-Host "      逐个核对了 $checked 个文件" -ForegroundColor DarkGray

  if ($dirtyLayers.Count -eq 0) {
    Write-Ok ' 游戏目录干净，没有旧模组残留'
  } else {
    Write-Warn2 " 发现 $($dirtyLayers.Count) 个文件与官方不一致 —— 之前装过模组或被改过"
    foreach ($d in ($dirtyLayers | Select-Object -First 5)) {
      Write-Host "        [$($d.Layer)] $($d.Pkg)" -ForegroundColor DarkYellow
    }
    if ($dirtyLayers.Count -gt 5) { Write-Host "        … 还有 $($dirtyLayers.Count - 5) 个" -ForegroundColor DarkYellow }

    if ($bakDirs.Count -eq 0) {
      Add-Err '没有备份目录可还原 —— 请用游戏平台「验证文件完整性」或重新安装游戏'
    } elseif (-not $bakUsable) {
      Add-Err "备份目录是旧版游戏留下的（版本 $bakVer，当前 $resVer），不能还原 —— 请用游戏平台验证文件完整性"
    } elseif ($AutoRepair) {
      Write-Step '  正在自动还原 ...'
      $ok = 0
      foreach ($d in $dirtyLayers) {
        $src = $null
        foreach ($b in $bakDirs) {
          $c = Join-Path (Join-Path $b.FullName $d.Layer) $d.Pkg
          if (Test-Path -LiteralPath $c) { $src = $c; break }
        }
        if (-not $src) { continue }
        $dir = if ($d.Layer -eq 'IR') { $IR } else { $PS }
        Copy-Item -LiteralPath $src -Destination (Join-Path $dir $d.Pkg) -Force
        $ok++
      }
      Write-Ok "  已还原 $ok / $($dirtyLayers.Count) 个文件"
      if ($ok -eq $dirtyLayers.Count) {
        Add-Rep "已自动还原 $ok 个旧模组文件，环境已干净"
      } else {
        Add-Err "还有 $($dirtyLayers.Count - $ok) 个文件无法还原（备份缺失）"
      }
    } else {
      Add-Err "残留 $($dirtyLayers.Count) 个旧模组文件 —— 请先运行 uninstall.bat 还原（或加 -AutoRepair 自动还原）"
    }
  }

  # -------------------------------------------------------- 6. 磁盘空间
  Write-Step '[6/6] 检查磁盘空间 ...'
  if ($rows.Count -gt 0) {
    $need = 0
    foreach ($r in $rows) {
      $f = Join-Path $fullDir $r.file
      if (Test-Path -LiteralPath $f) { $need += (Get-Item -LiteralPath $f).Length }
    }
    try {
      $drv = [System.IO.Path]::GetPathRoot($game)
      $di = New-Object System.IO.DriveInfo($drv)
      $freeMB = [math]::Round($di.AvailableFreeSpace / 1MB)
      $needMB = [math]::Round($need / 1MB)
      Write-Host "      替换后占用约 $needMB MB，当前可用 $freeMB MB" -ForegroundColor DarkGray
      if ($freeMB -lt $needMB) {
        Add-Err "磁盘空间不足：需要约 $needMB MB，仅剩 $freeMB MB"
      }
    } catch {
      Add-Warn '无法读取磁盘空间'
    }
  }
}

# ---------------------------------------------------------- 结论
Write-Title '检查结果'
foreach ($r in $repairs) { Write-Ok $r }
foreach ($w in $warns)   { Write-Warn2 $w }

if ($errors.Count -gt 0) {
  Write-Host ''
  Write-Host '  发现以下问题，已中止安装：' -ForegroundColor Red
  foreach ($e in $errors) { Write-Host "    · $e" -ForegroundColor Red }
  Write-Host ''
  Write-Host '  处理完再运行 install.bat。游戏文件没有任何改动。' -ForegroundColor Yellow
  Write-Host ''
  exit 1
}

Write-Host ''
Write-Ok '环境检查通过，可以安装'
Write-Host ''
exit 0
