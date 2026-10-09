# ===== 星塔旅人 反和谐包 · 公共模块 =====
$ErrorActionPreference = 'Stop'

function Write-Title([string]$t) { Write-Host ''; Write-Host ('=' * 60) -ForegroundColor DarkCyan; Write-Host "  $t" -ForegroundColor Cyan; Write-Host ('=' * 60) -ForegroundColor DarkCyan }
function Write-Ok([string]$t)    { Write-Host "  [OK]   $t" -ForegroundColor Green }
function Write-Warn2([string]$t) { Write-Host "  [警告] $t" -ForegroundColor Yellow }
function Write-Err2([string]$t)  { Write-Host "  [错误] $t" -ForegroundColor Red }
function Write-Step([string]$t)  { Write-Host "  -> $t" -ForegroundColor Gray }

function Get-Md5([string]$p) {
  try { return (Get-FileHash -LiteralPath $p -Algorithm MD5).Hash.ToLower() } catch { return '' }
}

function Test-GameDir([string]$p) {
  if ([string]::IsNullOrWhiteSpace($p)) { return $false }
  try {
    if (-not (Test-Path -LiteralPath $p -PathType Container)) { return $false }
    $need = @('xtlr.exe', 'xtlr_Data\StreamingAssets\InstallResource', 'Persistent_Store\ss_win.mani')
    foreach ($n in $need) { if (-not (Test-Path -LiteralPath (Join-Path $p $n))) { return $false } }
    return $true
  } catch { return $false }
}

function Find-GameDir {
  Write-Step '正在自动定位星塔旅人（国服）安装目录 ...'

  # ① 注册表
  $regRoots = @('HKCU:\Software', 'HKLM:\SOFTWARE', 'HKLM:\SOFTWARE\WOW6432Node')
  $vendors  = @('Yostar', 'YostarGames', 'RoamingStar', 'StellaSora')
  foreach ($rr in $regRoots) {
    foreach ($v in $vendors) {
      $k = Join-Path $rr $v
      if (Test-Path $k) {
        try {
          $item = Get-ItemProperty -Path $k -ErrorAction SilentlyContinue
          foreach ($prop in $item.PSObject.Properties) {
            $val = [string]$prop.Value
            if ($val -match '^[A-Za-z]:\\' ) {
              foreach ($c in @($val, (Join-Path $val 'StellaSora_CN'), (Join-Path $val 'YostarGames\StellaSora_CN'))) {
                if (Test-GameDir $c) { Write-Ok "注册表命中: $c"; return $c }
              }
            }
          }
        } catch {}
      }
    }
  }

  # ② 常见路径
  $drives = @()
  foreach ($d in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) { $drives += $d.Name }
  $rel = @(
    'YostarGames\StellaSora_CN',
    'Program Files\YostarGames\StellaSora_CN',
    'Program Files (x86)\YostarGames\StellaSora_CN',
    'Games\YostarGames\StellaSora_CN',
    'Game\YostarGames\StellaSora_CN',
    'Program Files\StellaSora_CN',
    'StellaSora_CN',
    'StellaSora'
  )
  foreach ($d in $drives) {
    foreach ($r in $rel) {
      $c = "$d`:\$r"
      if (Test-GameDir $c) { Write-Ok "常见路径命中: $c"; return $c }
    }
  }

  # ③ 浅层递归找 xtlr.exe
  Write-Step '常见位置未找到，正在全盘浅层搜索（可能需要 10~60 秒）...'
  foreach ($d in $drives) {
    try {
      $hits = Get-ChildItem -LiteralPath "$d`:\" -Filter 'xtlr.exe' -Recurse -Depth 5 -File -ErrorAction SilentlyContinue
      foreach ($h in $hits) {
        $c = $h.DirectoryName
        if (Test-GameDir $c) { Write-Ok "搜索命中: $c"; return $c }
      }
    } catch {}
  }
  return $null
}

function Get-GameDirInteractive {
  $g = Find-GameDir
  if ($g) { return $g }
  Write-Warn2 '未能自动找到游戏目录。'
  Write-Host '  请把「星塔旅人国服」的安装目录整个拖到本窗口后按回车' -ForegroundColor Yellow
  Write-Host '  例如:  F:\Game\YostarGames\StellaSora_CN' -ForegroundColor DarkGray
  for ($i = 0; $i -lt 5; $i++) {
    $in = Read-Host '  目录'
    if ([string]::IsNullOrWhiteSpace($in)) { continue }
    $in = $in.Trim().Trim('"').Trim("'")
    if (Test-GameDir $in) { Write-Ok "已确认: $in"; return $in }
    Write-Err2 '这不是有效的星塔旅人国服目录（需含 xtlr.exe 与 Persistent_Store\ss_win.mani）'
  }
  return $null
}

function Assert-GameNotRunning {
  $p = Get-Process -Name 'xtlr' -ErrorAction SilentlyContinue
  if ($p) {
    Write-Err2 '检测到游戏正在运行（xtlr.exe），请先完全退出游戏再执行本操作。'
    return $false
  }
  return $true
}

function Read-Manifest([string]$file) {
  $txt = [System.IO.File]::ReadAllText($file, [System.Text.Encoding]::UTF8)
  $rows = @()
  $lines = $txt -split "`r?`n"
  $i = 0
  while ($i -lt $lines.Count) {
    $ln = $lines[$i]
    if ([string]::IsNullOrWhiteSpace($ln)) { $i++; continue }
    if ($ln.StartsWith("`t")) { $i++; continue }
    $f = $ln -split "`t"
    $row = @{ type = $f[0]; pkg = $f[1]; layer = $f[2]; pre = $f[3]; post = $f[4] }
    if ($row.type -eq 'patch') {
      $n = [int]$f[5]
      $segs = @()
      for ($k = 1; $k -le $n; $k++) {
        $g = $lines[$i + $k] -split "`t"
        $segs += @{ off = [long]$g[1]; len = [int]$g[2]; bo = [long]$g[3] }
      }
      $row.segs = $segs
      $i += $n + 1
    } else {
      $row.file = $f[5]
      $i++
    }
    $rows += ,$row
  }
  return $rows
}
