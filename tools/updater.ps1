# ===== 星塔旅人 反和谐包 v1.1 · 资源下载器 =====
# 职责：从 GitHub Release 拉取 manifest + 资源包，校验后解压到缓存目录。
# 设计要点：
#   1) 全程只依赖两个已验证国内直连可达的域名：
#        - api.github.com / github.com  (拿 latest release 信息)
#        - release-assets.githubusercontent.com (实际下载，302 跳转后)
#   2) raw.githubusercontent.com 国内被 SNI 阻断，【绝不使用】
#   3) 多通道降级：直连 -> ghproxy.net -> ghfast.top -> gh-proxy.com
#      （全部通道于 2026-10-09 实测 HTTP 200 可用）
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
      $existing = 0
      if ((Test-Path -LiteralPath $OutFile) -and -not $Force) {
        $existing = (Get-Item -LiteralPath $OutFile).Length
      }

      $req = [System.Net.HttpWebRequest]::Create($Url)
      $req.Method = 'GET'
      $req.Timeout = $TimeoutSec * 1000
      $req.ReadWriteTimeout = $TimeoutSec * 1000
      $req.AllowAutoRedirect = $true
      $req.MaximumAutomaticRedirections = 10
      $req.UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) XTLR-Uncensor/1.1'
      $req.Accept = '*/*'
      # 显式开启 TLS 1.2/1.3（部分系统默认只开 TLS 1.0 会导致握手失败）
      try { [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 -bor [System.Net.SecurityProtocolType]::Tls11 } catch {}
      # Range 头不属于受保护头，可安全通过 Headers 设置
      if ($existing -gt 0) { $req.Headers['Range'] = "bytes=$existing-" }

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
        Write-Host '     这条链路不稳，正在自动再试一次 ...' -ForegroundColor DarkYellow
        Start-Sleep -Seconds 2
      } else {
        Write-Host '     这条链路没能连通。' -ForegroundColor DarkYellow
      }
      # 每次尝试都要清理 HTTP 连接，避免连接池耗尽
      try { if ($resp) { $resp.Close() } } catch {}
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

  $n = $Mirrors.Count
  $idx = 0
  foreach ($m in $Mirrors) {
    $idx++
    $url = if ($m -eq '') { $GitHubUrl } else { "$m$GitHubUrl" }
    $label = if ($m -eq '') { '直连' } else { ($m -replace 'https://','' -replace '/','') }
    Write-Step "[$idx/$n] 正在尝试：$label"
    if (Invoke-Download -Url $url -OutFile $OutFile -TimeoutSec $TimeoutSec -Retry $Retry) {
      Write-Ok "连接成功（$label）"
      return $true
    }
    if ($idx -lt $n) { Write-Host '     这个没通，自动换下一个 ...' -ForegroundColor DarkYellow }
  }
  Write-Host ''
  Write-Warn2 '几个下载通道都没能连上。'
  return $false
}

# ---------- 给小白看的友好失败引导 ----------
function Show-DownloadHelp {
  param(
    [string]$Stage = '资源',
    [string]$Repo  = '',
    [string[]]$TriedUrls = @()
  )

  Write-Host ''
  Write-Host ('=' * 60) -ForegroundColor Yellow
  Write-Host '  下载没有成功，我帮你看看怎么解决' -ForegroundColor Yellow
  Write-Host ('=' * 60) -ForegroundColor Yellow
  Write-Host ''
  Write-Host '  【别慌】' -ForegroundColor Green
  Write-Host '    你的游戏文件完全没有被改动，什么都没坏。' -ForegroundColor Gray
  Write-Host ''

  Write-Host '  【为什么会这样】' -ForegroundColor White
  Write-Host '    这个游戏资源包放在 GitHub 上（1 GB）。' -ForegroundColor Gray
  Write-Host '    GitHub 在国内有时候会连不上，属于正常现象，' -ForegroundColor Gray
  Write-Host '    不是你电脑的问题，也不影响游戏本身。' -ForegroundColor Gray
  Write-Host ''

  Write-Host '  【你现在可以按顺序试这 4 招】' -ForegroundColor White
  Write-Host ''

  Write-Host '    第 1 招（最简单）：再点一次' -ForegroundColor Cyan
  Write-Host '      直接重新双击 install.bat。' -ForegroundColor Gray
  Write-Host '      网络时好时坏，多试一次经常就好了。' -ForegroundColor Gray
  Write-Host ''

  Write-Host '    第 2 招：关掉代理 / 加速器' -ForegroundColor Cyan
  Write-Host '      如果你开着 VPN、加速器、代理软件，请先全部关掉，' -ForegroundColor Gray
  Write-Host '      然后重新双击 install.bat。' -ForegroundColor Gray
  Write-Host '      （反过来说：如果你没开代理，可以试开一个再装）' -ForegroundColor DarkGray
  Write-Host ''

  Write-Host '    第 3 招：换个网络' -ForegroundColor Cyan
  Write-Host '      比如手机开热点，让电脑连热点，再重新双击 install.bat。' -ForegroundColor Gray
  Write-Host '      电信 / 联通 / 移动的网络在各地情况不一样，换个网络常能通。' -ForegroundColor Gray
  Write-Host '      也可以过几分钟再试一次，网络拥堵是一阵一阵的。' -ForegroundColor DarkGray
  Write-Host ''

  Write-Host '    第 4 招：手动下载（前面都不行再用）' -ForegroundColor Cyan
  Write-Host '      我来一步步教你：' -ForegroundColor Gray
  Write-Host ''
  Write-Host '      ① 打开浏览器，访问这个网址：' -ForegroundColor Gray
  if ($Repo) {
    Write-Host "         https://github.com/$Repo/releases/latest" -ForegroundColor White
  } else {
    Write-Host '         （见下面给出的网址）' -ForegroundColor White
  }
  Write-Host '         如果打不开，就在网址前面加上：' -ForegroundColor DarkGray
  Write-Host '         https://ghproxy.net/' -ForegroundColor DarkGray
  Write-Host ''
  Write-Host '      ② 页面上找到 3 个文件，全部点击下载：' -ForegroundColor Gray
  Write-Host '         data.zip        （最大的那个，约 1 GB）' -ForegroundColor White
  Write-Host '         manifest.json' -ForegroundColor White
  Write-Host '         manifest.tsv' -ForegroundColor White
  Write-Host ''
  Write-Host '      ③ 下载完成后，把它们这样放：' -ForegroundColor Gray
  Write-Host '         在本安装器文件夹里，手动新建一个 data 文件夹，' -ForegroundColor Gray
  Write-Host '         再在 data 里新建一个 full 文件夹，' -ForegroundColor Gray
  Write-Host '         然后：' -ForegroundColor Gray
  Write-Host '           · manifest.tsv    →  放进 data 文件夹' -ForegroundColor White
  Write-Host '           · data.zip        →  用压缩软件解压，' -ForegroundColor White
  Write-Host '                                 把里面的所有文件放进 data\full\' -ForegroundColor White
  Write-Host '           · manifest.json   →  不用管' -ForegroundColor DarkGray
  Write-Host ''
  Write-Host '      ④ 回到本文件夹，双击 install.bat 即可' -ForegroundColor Gray
  Write-Host '         （这次它会自动跳过下载，直接用你放好的文件）' -ForegroundColor Gray
  Write-Host ''

  Write-Host '  【还是搞不定？】' -ForegroundColor White
  Write-Host '    把这个黑色窗口拍照 / 截图，发给分享给你这个安装包的人，' -ForegroundColor Gray
  Write-Host '    他会帮你解决。' -ForegroundColor Gray
  Write-Host ''
  Write-Host '  小提示：这个窗口先别关，方便截图哦。' -ForegroundColor DarkGray
  Write-Host ''

  Write-Host ('=' * 60) -ForegroundColor Yellow
  Write-Host ''
}

# ---------- 主流程 ----------
Write-Title '星塔旅人（国服）· 反和谐包 v1.1 —— 资源获取'

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
  Show-DownloadHelp -Stage '清单' -Repo $cfg.repo
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
      Show-DownloadHelp -Stage '资源' -Repo $cfg.repo
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
