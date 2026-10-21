# ===== 星塔旅人 模组 · 安装前环境检查 =====
# 目的：把「装不好」的常见原因在动手之前查出来，能自动修就修，修不了就说明白。
#
# 版本策略（2026-10-21 调整）：
#   游戏的小更新不一定会改美术资源，可能只是修 bug。
#   所以 RES_VER 对不上时不再直接拒绝，而是逐包对比：
#     · 本模组涉及的 128 个包如果「当前官方 md5」和「本包记录的原版 md5」完全一致
#       → 说明这次更新没动到我们，照常安装
#     · 有任何包变了 → 才拒绝，并列出是哪几个
#   残留检测同样改用「本包内记录的 pre/post」和自己比，不再依赖当前游戏版本。
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

  # 读当前游戏官方清单
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

  # -------------------------------------------------------- 4. 版本兼容性
  # 关键：不是「版本号相等才允许」，而是「本模组涉及的包有没有被官方改动过」
  Write-Step '[4/6] 检查游戏更新是否影响本模组 ...'
  $exp = @{}
  if (Test-Path -LiteralPath $expect) {
    foreach ($ln in [System.IO.File]::ReadAllLines($expect, [System.Text.Encoding]::UTF8)) {
      $s = $ln.Trim()
      if ($s -and $s.Contains('=')) {
        $kv = $s -split '=', 2
        $exp[$kv[0].Trim()] = $kv[1].Trim()
      }
    }
    Write-Host "      本包适配  GAME_VER=$($exp['GAME_VER'])  RES_VER=$($exp['RES_VER'])" -ForegroundColor DarkGray
    Write-Host "      当前游戏  GAME_VER=$gameVer  RES_VER=$resVer" -ForegroundColor DarkGray
  } else {
    Add-Warn '本包未记录适配版本（旧包），跳过版本说明'
  }

  # 逐包比对：本包记录的「原版 md5」vs 当前游戏的「官方 md5」
  $changed = New-Object System.Collections.ArrayList
  $gonePkg = New-Object System.Collections.ArrayList
  $cmpCount = 0
  foreach ($r in $rows) {
    $off = $officialHash[$r.pkg]
    if (-not $off) { [void]$gonePkg.Add($r.pkg); continue }
    if (-not $r.pre) { continue }
    $cmpCount++
    if ($off -ne $r.pre) { [void]$changed.Add([pscustomobject]@{ Pkg = $r.pkg; Old = $r.pre; New = $off }) }
  }

  $verSame = ($exp['RES_VER'] -ne '' -and $exp['RES_VER'] -eq $resVer)

  if ($verSame) {
    Write-Ok ' 资源版本完全一致'
  } elseif ($changed.Count -eq 0 -and $gonePkg.Count -eq 0) {
    # 版本号变了，但我们涉及的包一个都没变 —— 说明这次更新跟美术资源无关
    Add-Warn "游戏有更新（RES_VER $($exp['RES_VER']) → $resVer），但本模组涉及的 $cmpCount 个包均未变化"
    Add-Rep ' 这次更新没有改动本模组覆盖的资源，可以正常安装'
  } elseif ($changed.Count -gt 0) {
    Add-Err "游戏更新改动了本模组覆盖的 $($changed.Count) 个资源包 —— 需要新版模组才能适配"
    foreach ($c in ($changed | Select-Object -First 8)) {
      Write-Host "        已变化: $($c.Pkg)" -ForegroundColor DarkYellow
    }
    if ($changed.Count -gt 8) { Write-Host "        … 还有 $($changed.Count - 8) 个" -ForegroundColor DarkYellow }
  } else {
    Add-Err "有 $($gonePkg.Count) 个资源包在当前游戏里找不到 —— 游戏结构可能变了，需要新版模组"
  }

  # -------------------------------------------------------- 5. 旧模组残留
  # 判据（不依赖当前版本）：
  #   cur == pre  → 构建时的国服原版，干净
  #   cur == post → 本模组版本（装过，重复安装无妨）
  #   cur == 当前官方 md5 → 游戏更新后的官方版，干净
  #   其它        → 被别的东西改过 = 残留
  Write-Step '[5/6] 检查是否残留旧模组 ...'
  $dirtyLayers = New-Object System.Collections.ArrayList
  $alreadyMod = 0
  $checked = 0
  foreach ($r in $rows) {
    $layers = if ($r.layer -eq 'BOTH') { @('IR', 'PS') } else { @($r.layer) }
    foreach ($L in $layers) {
      $dir = if ($L -eq 'IR') { $IR } else { $PS }
      $dst = Join-Path $dir $r.pkg
      if (-not (Test-Path -LiteralPath $dst)) { continue }
      $checked++
      $cur = Get-Md5 $dst
      $off = $officialHash[$r.pkg]
      $isClean = $false
      if ($r.pre -and $cur -eq $r.pre) { $isClean = $true }
      elseif ($r.post -and $cur -eq $r.post) { $isClean = $true; $alreadyMod++ }
      elseif ($off -and $cur -eq $off) { $isClean = $true }
      if (-not $isClean) {
        [void]$dirtyLayers.Add([pscustomobject]@{ Layer = $L; Pkg = $r.pkg; Cur = $cur })
      }
    }
  }

  $bakDirs = @(Get-ChildItem -LiteralPath $game -Directory -Filter '_uncensor_backup_*' -ErrorAction SilentlyContinue | Sort-Object Name)

  # 备份是否可用：备份里的文件名对应的原始内容还在不在（不比版本号，比内容）
  $bakUsable = $false
  $bakVer = ''
  $bakCovered = 0
  foreach ($b in $bakDirs) {
    $vf = Join-Path $b.FullName 'game_version.txt'
    if (Test-Path -LiteralPath $vf) {
      foreach ($ln in [System.IO.File]::ReadAllLines($vf, [System.Text.Encoding]::UTF8)) {
        $s = $ln.Trim()
        if ($s.StartsWith('RES_VER=')) { $bakVer = $s.Substring(8).Trim() }
      }
    }
    $bmf = Join-Path $b.FullName 'backup_manifest.tsv'
    if (Test-Path -LiteralPath $bmf) {
      foreach ($ln in [System.IO.File]::ReadAllLines($bmf, [System.Text.Encoding]::UTF8)) {
        if ([string]::IsNullOrWhiteSpace($ln)) { continue }
        $f = $ln -split "`t"
        if ($f.Count -lt 2) { continue }
        $src = Join-Path (Join-Path $b.FullName $f[0]) $f[1]
        if (-not (Test-Path -LiteralPath $src)) { continue }
        # 备份的这份内容，必须等于「构建时的原版」或「当前官方」，才算能用的原件
        $m = Get-Md5 $src
        $off = $officialHash[$f[1]]
        $rowRec = $rows | Where-Object { $_.pkg -eq $f[1] } | Select-Object -First 1
        if ($rowRec -and $m -eq $rowRec.pre) { $bakCovered++ }
        elseif ($off -and $m -eq $off) { $bakCovered++ }
      }
    }
    if ($bakCovered -gt 0) { $bakUsable = $true }
    break
  }

  Write-Host "      逐个核对了 $checked 个文件（其中 $alreadyMod 个已是本模组版本）" -ForegroundColor DarkGray

  if ($dirtyLayers.Count -eq 0) {
    Write-Ok ' 游戏目录干净，没有异常改动'
  } else {
    Write-Warn2 " 发现 $($dirtyLayers.Count) 个文件内容异常 —— 之前装过别的模组或被手动改过"
    foreach ($d in ($dirtyLayers | Select-Object -First 5)) {
      Write-Host "        [$($d.Layer)] $($d.Pkg)" -ForegroundColor DarkYellow
    }
    if ($dirtyLayers.Count -gt 5) { Write-Host "        … 还有 $($dirtyLayers.Count - 5) 个" -ForegroundColor DarkYellow }

    if ($bakDirs.Count -eq 0) {
      Add-Err '没有备份目录可还原 —— 请用游戏平台「验证文件完整性」或重新安装游戏'
    } elseif (-not $bakUsable) {
      Add-Err "备份目录里的内容和当前游戏对不上（备份版本 $bakVer），不能还原 —— 请用游戏平台验证文件完整性"
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
        Add-Rep "已自动还原 $ok 个异常文件，环境已干净"
      } else {
        Add-Err "还有 $($dirtyLayers.Count - $ok) 个文件无法还原（备份缺失）"
      }
    } else {
      Add-Err "有 $($dirtyLayers.Count) 个文件内容异常 —— 请先运行 uninstall.bat 还原（或加 -AutoRepair 自动还原）"
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
