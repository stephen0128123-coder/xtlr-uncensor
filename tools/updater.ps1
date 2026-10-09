# ===== 星塔旅人 反和谐包 v2.0 · 资源下载器 =====
# 职责：从 GitHub Release 拉取 manifest + 资源包，校验后解压到缓存目录。
# 设计要点：
#   1) 全程只依赖两个已验证国内直连可达的域名：
#        - api.github.com / github.com  (拿 latest release 信息)
#        - release-assets.githubusercontent.com (实际下载，302 跳转后)
#   2) raw.githubusercontent.com 国内被 SNI 阻断，【绝不使用】
#   3) 多通道降级：直连 -> ghproxy.net -> gh-proxy.com -> ghfast.top
#   4) 断点续传 + md5 校验 + 重试

param(
  [string]$ConfigOverride = '',
  [string]$WorkDir = '',
  [switch]$Force  # 忽略缓存，强制重新下载
)

. (Join-Path $PSScriptRoot 'common.ps1')

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$root = Split-Path -Parent $PSScriptRoot

# ---------- 读配置 ----------
function Read-Config {
  $p = if ($ConfigOverride) { $ConfigOverride } else { Join-Path $PSScriptRoot 'config.json' }
  if (-not (Test-Path -LiteralPath $p)) { Write-Err2 "缺少配置文件: $p"; exit 1 }
  $raw = [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8)
  return ($raw | ConvertFrom-Json)
}

# ---------- HTTP 下载（支持断点续传 + 多通道）----------
function Invoke-Download {
  param(
    [string]$Url,
    [string]$OutFile,
    [int]$TimeoutSec = 120,
    [int]$Retry = 3
  )

  $dir = Split-Path -Parent $OutFile
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

  for ($attempt = 1; $attempt -le $Retry; $attempt++) {
    try {
      # 支持续传：已有部分文件时带 Range 头
      $headers = @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) XTLR-Uncensor/2.0' }
      $existing = 0
      if ((Test-Path -LiteralPath $OutFile) -and -not $Force) {
        $existing = (Get-Item -LiteralPath $OutFile).Length
        if ($existing -gt 0) { $headers['Range'] = "bytes=$existing-" }
      }

      $req = [System.Net.HttpWebRequest]::Create($Url)
      $req.Method = 'GET'
      $req.Timeout = $TimeoutSec * 1000
      $req.ReadWriteTimeout = $TimeoutSec * 1000
      $req.AllowAutoRedirect = $true
      $req.MaximumAutomaticRedirections = 10
      foreach ($k in $headers.Keys) { $req.Headers[$k] = $headers[$k] }

      $resp = $req.GetResponse()
      $status = [int]$resp.StatusCode
      $total = $resp.ContentLength

      if ($status -eq 206) {
        # 续传
        $mode = 'ab'
      } elseif ($status -eq 200) {
        # 从头下（服务器不支持 Range 或首次下载）
        if ($existing -gt 0) { Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue }
        $mode = 'wb'
      } else {
        $resp.Close()
        throw "HTTP $status"
      }

      $inStream  = $resp.GetResponseStream()
      $buf       = New-Object byte[] 65536
      $totalRead = if ($mode -eq 'ab') { $existing } else { 0 }
      $lastPct   = -1

      while (($read = $inStream.Read($buf, 0, $buf.Length)) -gt 0) {
        $fs = [System.IO.File]::Open($OutFile, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write)
        try { $fs.Write($buf, 0, $read) } finally { $fs.Close() }
        $totalRead += $read

        if ($total -gt 0) {
          $pct = [int](100 * $totalRead / $total)
          if ($pct -ne $lastPct -and ($pct % 5) -eq 0) {
            Write-Host ("`r    下载中 {0}%  ({1:N1} / {2:N1} MB)  " -f $pct, ($totalRead/1MB), ($total/1MB)) -NoNewline -ForegroundColor DarkCyan
            $lastPct = $pct
          }
        }
      }
      $inStream.Close(); $resp.Close()
      Write-Host ''
      return $true
    } catch {
      Write-Host ''
      if ($attempt -lt $Retry) {
        Write-Warn2 "下载失败（第 $attempt/$Retry 次）：$($_.Exception.Message) —— 3 秒后重试"
        Start-Sleep -Seconds 3
      } else {
        Write-Err2 "下载失败（已重试 $Retry 次）：$($_.Exception.Message)"
      }
    }
  }
  return $false
}

# ---------- 多通道尝试下载 ----------
function Invoke-DownloadWithMirrors {
  param(
    [string]$RelPath,       # 相对路径，如 manifest.json 或 data_part01.zip
    [string]$OutFile,
    [string[]]$Mirrors,     # 如 @('', 'https://ghproxy.net/')
    [string]$GitHubUrl,     # 原始 GitHub URL
    [int]$TimeoutSec = 120,
    [int]$Retry = 2
  )

  foreach ($m in $Mirrors) {
    $url = if ($m -eq '') { $GitHubUrl } else { "$m$GitHubUrl" }
    $label = if ($m -eq '') { '直连' } else { ($m -replace 'https://','' -replace '/','') }
    Write-Step "尝试通道：$label"
    Write-Host "    $url" -ForegroundColor DarkGray
    if (Invoke-Download -Url $url -OutFile $OutFile -TimeoutSec $TimeoutSec -Retry $Retry) {
      Write-Ok "通道 $label 下载成功"
      return $true
    }
  }
  Write-Err2 '所有通道均失败。'
  return $false
}

# ---------- 主流程 ----------
Write-Title '星塔旅人（国服）· 反和谐包 v2.0 —— 资源获取'

$cfg = Read-Config
$cache = if ($WorkDir) { $WorkDir } else { [System.Environment]::ExpandEnvironmentVariables($cfg.cache_dir) }
if (-not (Test-Path -LiteralPath $cache)) { New-Item -ItemType Directory -Path $cache -Force | Out-Null }

Write-Step "缓存目录：$cache"
Write-Step "仓库：$($cfg.repo)"

# ① 下载 manifest
$maniUrl = $cfg.manifest_url
$maniName = 'manifest.json'
$maniLocal = Join-Path $cache $maniName

# 如果配置里写的是 latest/download 形式，直接下；否则走 API
if ($maniUrl -match 'releases/latest/download/') {
  $maniGhUrl = $maniUrl
} else {
  # 走 API 拿 asset 真实地址
  $apiUrl = "https://api.github.com/repos/$($cfg.repo)/releases/latest"
  Write-Step "查询最新版本：$apiUrl"
  $apiTmp = Join-Path $cache '_latest.json'
  if (-not (Invoke-DownloadWithMirrors -RelPath '_latest.json' -OutFile $apiTmp `
        -Mirrors @('') -GitHubUrl $apiUrl -TimeoutSec 30 -Retry 2)) {
    Write-Err2 '无法获取版本信息。'
    exit 1
  }
  $rel = [System.IO.File]::ReadAllText($apiTmp, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
  $asset = $rel.assets | Where-Object { $_.name -eq 'manifest.json' } | Select-Object -First 1
  if (-not $asset) { Write-Err2 ' Release 中找不到 manifest.json'; exit 1 }
  $maniGhUrl = $asset.browser_download_url
  Write-Step "最新版本：$($rel.tag_name)"
}

Write-Step '下载 manifest ...'
if (-not (Invoke-DownloadWithMirrors -RelPath $maniName -OutFile $maniLocal `
      -Mirrors $cfg.mirror_prefixes -GitHubUrl $maniGhUrl -TimeoutSec 30 -Retry 2)) {
  Write-Err2 'manifest 下载失败。'
  exit 1
}

$mani = [System.IO.File]::ReadAllText($maniLocal, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
Write-Ok "manifest 就绪：包版本 $($mani.package_version) / 游戏版本 $($mani.game_version)"

# ② 检查本地是否已有完整缓存
$needDownload = $false
foreach ($a in $mani.assets) {
  $local = Join-Path $cache $a.name
  if ($Force -or -not (Test-Path -LiteralPath $local)) { $needDownload = $true; break }
  if ($cfg.verify.check_size -and $a.size -gt 0 -and (Get-Item -LiteralPath $local).Length -ne $a.size) { $needDownload = $true; break }
  if ($cfg.verify.check_md5 -and $a.md5 -and (Get-Md5 $local) -ne $a.md5) { $needDownload = $true; break }
}

if (-not $needDownload) {
  Write-Ok '本地缓存已是最新，跳过下载。'
} else {
  # ③ 逐文件下载
  $i = 0
  foreach ($a in $mani.assets) {
    $i++
    $local = Join-Path $cache $a.name
    Write-Host ''
    Write-Step "[$i/$($mani.assets.Count)] $($a.name)  ($([math]::Round($a.size/1MB,1)) MB)"

    # 找该 asset 的 GitHub 直链
    $ghUrl = ($mani.channels | Where-Object { $_.id -eq 'github' } | Select-Object -First 1).base
    $ghUrl = $ghUrl -replace '\{version\}', $mani.package_version.TrimStart('v')
    $ghUrl = "$ghUrl$($a.name)"

    if (-not (Invoke-DownloadWithMirrors -RelPath $a.name -OutFile $local `
          -Mirrors $cfg.mirror_prefixes -GitHubUrl $ghUrl `
          -TimeoutSec $cfg.download.timeout_sec -Retry $cfg.download.retry)) {
      Write-Err2 "资源 $($a.name) 下载失败，已中止。"
      exit 1
    }

    # ④ 校验
    if ($cfg.verify.check_size -and $a.size -gt 0) {
      $sz = (Get-Item -LiteralPath $local).Length
      if ($sz -ne $a.size) { Write-Err2 "大小不符：期望 $($a.size) 实际 $sz"; exit 1 }
    }
    if ($cfg.verify.check_md5 -and $a.md5) {
      $md5 = Get-Md5 $local
      if ($md5 -ne $a.md5) { Write-Err2 "MD5 不符：期望 $($a.md5) 实际 $md5"; exit 1 }
      Write-Ok "MD5 校验通过：$md5"
    }
  }
}

# ⑤ 解压
$dataDir = Join-Path $root 'data'
$fullDir = Join-Path $dataDir 'full'
Write-Host ''
Write-Step '解压资源 ...'
if (Test-Path -LiteralPath $fullDir) {
  Remove-Item -LiteralPath $fullDir -Recurse -Force -ErrorAction SilentlyContinue
}
New-Item -ItemType Directory -Path $fullDir -Force | Out-Null

foreach ($a in $mani.assets) {
  $local = Join-Path $cache $a.name
  Write-Step "解压 $($a.name)"
  try {
    Expand-Archive -LiteralPath $local -DestinationPath $fullDir -Force
  } catch {
    Write-Err2 "解压失败 $($a.name)：$($_.Exception.Message)"
    exit 1
  }
}

# manifest.tsv 单独放 data 目录
$tsvLocal = Join-Path $cache 'manifest.tsv'
if (Test-Path -LiteralPath $tsvLocal) {
  Copy-Item -LiteralPath $tsvLocal -Destination (Join-Path $dataDir 'manifest.tsv') -Force
  Write-Ok 'manifest.tsv 已就位'
} elseif (Test-Path -LiteralPath (Join-Path $fullDir 'manifest.tsv')) {
  Copy-Item -LiteralPath (Join-Path $fullDir 'manifest.tsv') -Destination (Join-Path $dataDir 'manifest.tsv') -Force
  Write-Ok 'manifest.tsv 已从解压内容中提取'
} else {
  Write-Warn2 '未找到 manifest.tsv —— 请确认它已打包进 Release'
}

Write-Title '资源获取完成'
Write-Ok "资源已就绪：$fullDir"
Write-Host ''
exit 0
