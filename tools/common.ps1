# 星塔旅人 · 小开关公共模块 (Windows PowerShell 5.1+)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
function Write-Title([string]$t) { Write-Host ''; Write-Host ('=' * 60) -ForegroundColor DarkCyan; Write-Host "  $t" -ForegroundColor Cyan; Write-Host ('=' * 60) -ForegroundColor DarkCyan }
function Write-Ok([string]$t) { Write-Host "  [OK]   $t" -ForegroundColor Green }
function Write-Err2([string]$t) { Write-Host "  [错误] $t" -ForegroundColor Red }
function Write-Step([string]$t) { Write-Host "  -> $t" -ForegroundColor Gray }
function Get-Hash([string]$p, [string]$algorithm = 'MD5') { return (Get-FileHash -LiteralPath $p -Algorithm $algorithm -ErrorAction Stop).Hash.ToLowerInvariant() }
function Get-TextHash([string]$text) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($text)))).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
}
# The same ancestor/reparse checks, using .NET instead of thousands of provider cmdlets.
if (-not ('XingtaPathGuard' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.IO;
public static class XingtaPathGuard {
 public static string Plain(string path) {
  string full=Path.GetFullPath(path), current=full;
  while (!String.IsNullOrEmpty(current)) {
   try {
    if ((File.GetAttributes(current)&FileAttributes.ReparsePoint)!=0)
     throw new IOException("拒绝链接/联接路径："+current);
   } catch (FileNotFoundException) {} catch (DirectoryNotFoundException) {}
   string parent=Path.GetDirectoryName(current);
   if (parent==current) break;
   current=parent;
  }
  return full;
 }
}
'@
}
function Assert-PlainPath([string]$p) { return [XingtaPathGuard]::Plain($p) }
function Assert-Leaf([string]$s) {
    if ($s -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,180}$' -or $s.Contains('..') -or $s.EndsWith('.') -or $s -match '^(CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])(\.|$)') { throw "清单含不安全文件名：$s" }
}
function Get-LeafPath([string]$dir, [string]$leaf) {
    Assert-Leaf $leaf
    return Assert-PlainPath (Join-Path $dir $leaf)
}
function Test-GameDir([string]$p) {
    if ([string]::IsNullOrWhiteSpace($p)) { return $false }
    foreach ($n in @('xtlr.exe', 'Persistent_Store/ss_win.mani')) {
        if (-not (Test-Path -LiteralPath (Join-Path $p $n) -PathType Leaf)) { return $false }
    }
    foreach ($n in @('xtlr_Data/StreamingAssets/InstallResource', 'Persistent_Store/AssetBundles')) {
        if (-not (Test-Path -LiteralPath (Join-Path $p $n) -PathType Container)) { return $false }
    }
    return $true
}
function Get-GameSearchRoots {
    return @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue | Where-Object { $_.Root -match '^[A-Za-z]:\\$' } | ForEach-Object { $_.Root })
}
function Get-RegisteredGameDirs {
    foreach ($base in @('HKCU:\Software','HKLM:\SOFTWARE','HKLM:\SOFTWARE\WOW6432Node')) {
        foreach ($vendor in @('Yostar','YostarGames','RoamingStar','StellaSora')) {
            $key = Join-Path $base $vendor
            if (Test-Path $key) {
                try {
                    foreach ($prop in (Get-ItemProperty $key -ErrorAction Stop).PSObject.Properties) {
                        $value = [string]$prop.Value
                        if ($value -match '^[A-Za-z]:\\') { $value }
                    }
                } catch {}
            }
        }
    }
    foreach ($key in @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall','HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')) {
        foreach ($item in @(Get-ChildItem $key -ErrorAction SilentlyContinue)) {
            try {
                $app = Get-ItemProperty $item.PSPath -ErrorAction Stop
                if ($null -ne $app.PSObject.Properties['DisplayName'] -and [string]$app.DisplayName -match '星塔旅人|Stella.?Sora' -and $null -ne $app.PSObject.Properties['InstallLocation']) { [string]$app.InstallLocation }
            } catch {}
        }
    }
}
function Find-GameDirs([string[]]$SearchRoots = @(), [switch]$NoDeepSearch) {
    $found = New-Object 'Collections.Generic.List[string]'
    $seen = @{}
    function Add-GameCandidate([string]$candidate) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { return }
        try {
            $path = [IO.Path]::GetFullPath($candidate.Trim().Trim('"').Trim("'"))
            if ($path -match '(?i)[\\/](tests?|fixtures?|runs|_xingta_switch|_uncensor_backup_[^\\/]*|_removed[^\\/]*)[\\/]') { return }
            if (-not (Test-GameDir $path)) { return }
            # Empty xtlr.exe placeholders are developer fixtures, not installations.
            if ((Get-Item -LiteralPath (Join-Path $path 'xtlr.exe')).Length -eq 0) { return }
            $path = (Assert-PlainPath $path).TrimEnd('\','/')
            $key = $path.ToLowerInvariant()
            if (-not $seen.ContainsKey($key)) { $seen[$key]=$true; [void]$found.Add($path) }
        } catch {}
    }
    if ($SearchRoots.Count -eq 0) {
        $packageRoot = Split-Path -Parent $PSScriptRoot
        $hint = Join-Path (Get-DefaultStateRoot) 'last-game-dir.txt'
        if (Test-Path -LiteralPath $hint -PathType Leaf) { try { Add-GameCandidate ([IO.File]::ReadAllText($hint).Trim()) } catch {} }
        Add-GameCandidate $packageRoot
        Add-GameCandidate (Split-Path -Parent $packageRoot)
        foreach ($hint in @(Get-RegisteredGameDirs)) {
            foreach ($p in @($hint,(Join-Path $hint 'StellaSora_CN'),(Join-Path $hint 'YostarGames/StellaSora_CN'))) { Add-GameCandidate $p }
        }
        $SearchRoots = @(Get-GameSearchRoots)
    }
    $relative = @('YostarGames/StellaSora_CN','Program Files/YostarGames/StellaSora_CN','Program Files (x86)/YostarGames/StellaSora_CN','Games/YostarGames/StellaSora_CN','Game/YostarGames/StellaSora_CN','Program Files/StellaSora_CN','StellaSora_CN','StellaSora')
    foreach ($drive in $SearchRoots) {
        Add-GameCandidate $drive
        foreach ($rel in $relative) { Add-GameCandidate (Join-Path $drive $rel) }
    }
    if ($found.Count -eq 0 -and -not $NoDeepSearch) {
        Write-Step '常见位置未找到，正在浅层搜索 xtlr.exe ...'
        foreach ($drive in $SearchRoots) {
            foreach ($exe in @(Get-ChildItem -LiteralPath $drive -Filter xtlr.exe -Recurse -Depth 5 -File -ErrorAction SilentlyContinue)) { Add-GameCandidate $exe.DirectoryName }
        }
    }
    return $found.ToArray()
}
function Select-GameFolder {
    Add-Type -AssemblyName System.Windows.Forms
    $dialog = New-Object Windows.Forms.FolderBrowserDialog
    try {
        $dialog.Description = '未能自动找到游戏。请选择包含 xtlr.exe 的国服游戏目录。'
        $dialog.ShowNewFolderButton = $false
        if ($dialog.ShowDialog() -eq [Windows.Forms.DialogResult]::OK -and (Test-GameDir $dialog.SelectedPath)) { return $dialog.SelectedPath }
    } finally { $dialog.Dispose() }
    throw '没有选择有效国服目录，未写入资源。'
}
function Get-GameDirInteractive {
    Write-Step '正在自动定位星塔旅人国服 ...'
    $games = @(Find-GameDirs)
    if ($games.Count -eq 1) { Write-Ok "自动找到：$($games[0])"; return $games[0] }
    if ($games.Count -gt 1) {
        Write-Host '  找到多个国服目录，请选择本次要使用的一个：' -ForegroundColor Yellow
        for ($i=0; $i -lt $games.Count; $i++) { Write-Host ("  {0}. {1}" -f ($i+1),$games[$i]) }
        $choice=0
        if ([int]::TryParse((Read-Host '  编号'),[ref]$choice) -and $choice -ge 1 -and $choice -le $games.Count) { return $games[$choice-1] }
        throw '未选择有效编号，未写入资源。'
    }
    Write-Step '没有自动找到，将打开文件夹选择窗口。'
    return Select-GameFolder
}
function Remember-GameDir([string]$root,[string]$game) {
    try { [IO.File]::WriteAllText((Join-Path $root 'last-game-dir.txt'),$game,(New-Object Text.UTF8Encoding($false))) } catch {}
}

# ============================================================================
# 官方净还原运行时（resume-20261113-1717）。定位器保持旧体验，本段只做净还原。
# 本段不按目录名递归删除用户资料，不创建游戏内路径，不修改官方索引/prefs/存档。
# ============================================================================
function Assert-Inside([string]$path,[string]$root) {
    $p=Assert-PlainPath $path; $r=(Assert-PlainPath $root).TrimEnd('\','/')
    if (-not $p.StartsWith($r+'\',[StringComparison]::OrdinalIgnoreCase)) { throw "路径不在允许目录：$p" }
    return $p
}
function Test-Inside([string]$path,[string]$root) {
    $p=(Assert-PlainPath $path).TrimEnd('\','/'); $r=(Assert-PlainPath $root).TrimEnd('\','/')
    return ($p.Equals($r,[StringComparison]::OrdinalIgnoreCase) -or $p.StartsWith($r+'\',[StringComparison]::OrdinalIgnoreCase))
}
function Get-DefaultStateRoot {
    if (-not $env:LOCALAPPDATA) { throw '缺少LOCALAPPDATA，未写资源。' }
    return Assert-PlainPath (Join-Path $env:LOCALAPPDATA 'XingtaSwitch')
}
# ---- 进程保护 --------------------------------------------------------------
# 生产：真实探测游戏进程。任一命中即拒绝，绝不替用户结束进程。
function Assert-ProcessNotRunning([string[]]$names) {
    foreach ($n in $names) {
        if ([string]::IsNullOrWhiteSpace($n)) { continue }
        $hit=@(Get-Process -Name $n -ErrorAction SilentlyContinue)
        if ($hit.Count -gt 0) { throw "检测到正在运行的进程 $n.exe（PID $($hit[0].Id)）：请先完全退出游戏再操作，本工具不会替你结束进程；未写资源。" }
    }
}
function Assert-GameNotRunning { Assert-ProcessNotRunning @('xtlr') }
# 夹具：只认授权文件里声明的模拟进程表，不读用户真实进程；缺声明就拒绝，
# 保证“传了GameDirOverride”不能顺手关掉生产进程保护。
function Assert-FixtureProcessProbe($allow) {
    if ($null -eq $allow.PSObject.Properties['processProbe']) { throw '授权文件缺少进程探测声明：传GameDirOverride不能关掉生产进程保护，未写资源。' }
    $probe=$allow.processProbe
    Assert-Fields $probe @('fixture','running')
    if ($probe.fixture -isnot [bool] -or -not $probe.fixture) { throw '授权文件进程探测声明非法：必须是夹具模式，未写资源。' }
    if ($probe.running -isnot [Array]) { throw '授权文件进程探测声明非法：running必须是数组，未写资源。' }
    foreach ($n in @($probe.running)) {
        if ([string]::IsNullOrWhiteSpace([string]$n)) { continue }
        throw "检测到正在运行的进程 $n.exe（夹具模拟）：请先完全退出游戏再操作，本工具不会替你结束进程；未写资源。"
    }
    Write-Step '受控夹具模式：进程探测使用夹具模拟表（空），不读取您真实运行中的游戏进程。'
}
function Get-LayerRoot([string]$game,[string]$layer) {
    if ($layer -ceq 'IR') { return Assert-Inside (Join-Path $game 'xtlr_Data/StreamingAssets/InstallResource') $game }
    if ($layer -ceq 'PS') { return Assert-Inside (Join-Path $game 'Persistent_Store/AssetBundles') $game }
    throw '目标层非法。'
}
function Get-AuthorityPath([string]$game,[string]$layer) {
    $rel=if ($layer -ceq 'IR') {'xtlr_Data/StreamingAssets/InstallResource/install_resource_manifest.mani'} else {'Persistent_Store/ss_win.mani'}
    return Assert-Inside (Join-Path $game $rel) $game
}
function Assert-Fields($o,[string[]]$names) {
    if ($o -isnot [pscustomobject]) { throw 'JSON对象格式错误。' }
    foreach ($n in $names) { if ($null -eq $o.PSObject.Properties[$n]) { throw "元数据缺少：$n" } }
}
function Assert-Digest($o) {
    Assert-Fields $o @('md5','sha256','size')
    if ($o.md5 -isnot [string] -or $o.md5 -cnotmatch '^[0-9a-f]{32}$' -or $o.sha256 -isnot [string] -or $o.sha256 -cnotmatch '^[0-9a-f]{64}$' -or ($o.size -isnot [long] -and $o.size -isnot [int]) -or $o.size -lt 0) { throw '哈希/size格式非法。' }
}
function Read-Package([string]$root) {
    $root=Assert-PlainPath $root; $data=Assert-Inside (Join-Path $root 'data') $root
    $profilePath=Assert-Inside (Join-Path $data 'restore-profile.json') $root
    $profile=[IO.File]::ReadAllText($profilePath,[Text.Encoding]::UTF8) | ConvertFrom-Json
    Assert-Fields $profile @('schema','product','region','gameVersion','manifestSha256','ledgerSha256','baselineSha256','authorities','targets','legacyChecks')
    if ($profile.schema -ne 1 -or $profile.product -cne 'xingta-switch' -or $profile.region -cne 'cn' -or $profile.gameVersion -cnotmatch '^[0-9]+(?:\.[0-9]+){1,3}$') { throw '不支持的恢复profile。' }
    foreach ($h in @($profile.manifestSha256,$profile.ledgerSha256,$profile.baselineSha256)) { if ($h -cnotmatch '^[0-9a-f]{64}$') { throw '来源指纹非法。' } }
    $versionPath=Assert-Inside (Join-Path $data 'game_version.txt') $root
    if (-not (Test-Path -LiteralPath $versionPath -PathType Leaf)) { throw 'game_version.txt缺失、重复或GAME_VER与profile不一致，未写资源。' }
    $versions=@([IO.File]::ReadAllLines($versionPath,[Text.Encoding]::UTF8) | Where-Object { $_.Trim().StartsWith('GAME_VER=') })
    if ($versions.Count -ne 1 -or $versions[0].Trim().Substring(9) -cne $profile.gameVersion) { throw 'game_version.txt缺失、重复或GAME_VER与profile不一致，未写资源。' }
    $manifest=Assert-Inside (Join-Path $data 'manifest.tsv') $root
    if ((Get-Hash $manifest 'SHA256') -cne $profile.manifestSha256) { throw 'manifest来源指纹不符。' }
    $lines=@([IO.File]::ReadAllLines($manifest,[Text.Encoding]::UTF8) | Where-Object { $_.Trim() })
    $manifestRows=@{}; foreach ($line in $lines) {
        $f=$line -split "`t"; if ($f.Count -ne 6 -or $f[0] -cne 'full' -or @('IR','PS') -cnotcontains $f[2]) { throw 'manifest六列格式非法。' }
        Assert-Leaf $f[1]; Assert-Leaf $f[5]; $key=$f[2]+'/'+$f[1]
        if ($manifestRows.ContainsKey($key)) { throw 'manifest重复目标。' }; $manifestRows[$key]=$f
    }
    if ($profile.targets -isnot [Array] -or $profile.targets.Count -eq 0 -or $profile.targets.Count -ne $manifestRows.Count) { throw 'profile/manifest目标集合不一致。' }
    foreach ($layer in @('IR','PS')) {
        $a=$profile.authorities.$layer; Assert-Fields $a @('relativePath','sourceSha256','sourceVersion')
        $expected=if ($layer -ceq 'IR') {'xtlr_Data/StreamingAssets/InstallResource/install_resource_manifest.mani'} else {'Persistent_Store/ss_win.mani'}
        if ($a.relativePath -cne $expected -or $a.sourceSha256 -cnotmatch '^[0-9a-f]{64}$') { throw 'authority层/相对路径非法。' }
    }
    $seen=@{}; foreach ($e in $profile.targets) {
        Assert-Fields $e @('layer','name','official','post'); Assert-Leaf $e.name
        if (@('IR','PS') -cnotcontains $e.layer) { throw 'profile错层。' }
        Assert-Digest $e.official; Assert-Digest $e.post; Assert-Fields $e.official @('exists'); Assert-Fields $e.post @('file'); Assert-Leaf $e.post.file
        if ($e.official.exists -isnot [bool] -or -not $e.official.exists) { throw '本运行时只支持已有官方present资源；缺目标报未就绪，不创建。' }
        $key=$e.layer+'/'+$e.name
        if ($seen.ContainsKey($key) -or -not $manifestRows.ContainsKey($key)) { throw 'profile重复/未知目标。' }; $seen[$key]=$true; $f=$manifestRows[$key]
        if ($f[3] -cne $e.official.md5 -or $f[4] -cne $e.post.md5 -or $f[5] -cne $e.post.file) { throw 'profile与manifest字节身份不符。' }
    }
    foreach ($e in @($profile.legacyChecks)) {
        Assert-Fields $e @('layer','name','official','reason'); Assert-Leaf $e.name
        if (@('IR','PS') -cnotcontains $e.layer -or $seen.ContainsKey($e.layer+'/'+$e.name)) { throw 'legacy检测与受管目标冲突/错层。' }
        if ($null -ne $e.official) { Assert-Fields $e.official @('md5','size'); if ($e.official.md5 -cnotmatch '^[0-9a-f]{32}$' -or $e.official.size -lt 0) { throw 'legacy官方声明非法。' } }
    }
    return [pscustomobject]@{root=$root;data=$data;profile=$profile;id=(Get-TextHash ((Get-Hash $profilePath 'SHA256')+':'+(Get-Hash $manifest 'SHA256')+':'+(Get-Hash $versionPath 'SHA256')))}
}
function Get-Context($package,[string]$gameOverride,[string]$stateOverride,[string]$donorOverride) {
    if ([bool]$gameOverride -xor [bool]$stateOverride) { throw '测试必须同时显式提供GameDirOverride和StateDirOverride；未扫描/写入。' }
    $testing=[bool]$gameOverride
    if ($testing) {
        $game=(Assert-PlainPath $gameOverride).TrimEnd('\','/'); $base=(Assert-PlainPath $stateOverride).TrimEnd('\','/')
        $run=Split-Path -Parent $game
        if ((Split-Path -Parent $base) -ine $run) { throw '仅允许授权模拟兄弟目录：状态目录必须是模拟游戏的兄弟目录，未写资源。' }
        $authorization=Assert-Inside (Join-Path $run 'fixture-authorization.json') $run
        if (-not (Test-Path -LiteralPath $authorization -PathType Leaf)) { throw '仅允许授权模拟兄弟目录：缺少fixture-authorization.json。传GameDirOverride不能跳过生产进程保护，真实游戏请走正常入口；未写资源。' }
        $allow=[IO.File]::ReadAllText($authorization,[Text.Encoding]::UTF8)|ConvertFrom-Json
        Assert-Fields $allow @('fixtureOnly','game','state')
        if ($allow.fixtureOnly -ne $true -or $allow.game -ine $game -or $allow.state -ine $base) { throw '仅允许授权模拟兄弟目录：授权文件与本次目录不一致，未写资源。' }
        Assert-FixtureProcessProbe $allow
    } else {
        $game=(Assert-PlainPath (Get-GameDirInteractive)).TrimEnd('\','/'); $base=Get-DefaultStateRoot
        Assert-GameNotRunning
    }
    if (Test-Inside $package.root $game) { throw '请先把完整解压安装包移到游戏目录外，再重试；不会自动删除您的文件。' }
    if ((Test-Inside $base $game) -or (Test-Inside $game $base) -or (Test-Inside $base $package.root) -or (Test-Inside $package.root $base)) { throw '状态目录必须在游戏和安装包之外，未写资源。' }
    if (-not (Test-GameDir $game)) { throw '指定游戏目录无效，不回退定位其他目录。' }
    $instance=Assert-Inside (Join-Path $base ('instances/'+(Get-TextHash $game.ToLowerInvariant()).Substring(0,24))) $base
    $state=Assert-Inside (Join-Path $instance $package.id.Substring(0,24)) $instance
    $donor=''; if ($donorOverride) { $donor=Assert-PlainPath $donorOverride; if (Test-Inside $donor $game) { throw '官方donor必须在游戏外，未写资源。' } }
    return [pscustomobject]@{game=$game;base=$base;instance=$instance;state=$state;receipt=(Join-Path $state 'receipt.jsonl');donor=$donor;testing=$testing;package=$package}
}
function Read-OfficialIndex([string]$path) {
    $path=Assert-PlainPath $path; $headers=@{}; $entries=@{}
    # Parse and fingerprint the SAME byte snapshot, never a second path read.
    $raw=[IO.File]::ReadAllBytes($path)
    $memory=[IO.MemoryStream]::new($raw,$false)
    $reader=[IO.StreamReader]::new($memory,[Text.Encoding]::UTF8,$true)
    try { $text=$reader.ReadToEnd() } finally { $reader.Dispose();$memory.Dispose() }
    $hasher=[Security.Cryptography.SHA256]::Create()
    try { $rawSha=([BitConverter]::ToString($hasher.ComputeHash($raw))).Replace('-','').ToLowerInvariant() } finally { $hasher.Dispose() }
    foreach ($line in ($text -split '\r?\n')) {
        $s=$line.Trim(); if (-not $s) { continue }
        if ($s.StartsWith('$')) {
            if ($s -match '^\$(GAME_VER|RES_VER|CLIENT_VER):(.*)$') {
                if ($headers.ContainsKey($matches[1])) { throw '官方索引版本字段重复。' }; $headers[$matches[1]]=$matches[2].Trim()
            }; continue
        }
        $f=$s -split '\|'
        if ($f.Count -lt 3 -or $f[1] -cnotmatch '^[0-9a-f]{32}$' -or $f[2] -cnotmatch '^[0-9]+$') { throw '官方索引资源条目格式错误。' }
        if ($entries.ContainsKey($f[0])) { throw '官方索引资源重复。' }
        $entries[$f[0]]=[pscustomobject]@{md5=$f[1];size=[long]$f[2]}
    }
    foreach ($name in @('GAME_VER','RES_VER','CLIENT_VER')) { if (-not $headers.ContainsKey($name) -or -not $headers[$name]) { throw '官方索引版本字段缺失。' } }
    if ($headers['GAME_VER'] -cnotmatch '^[0-9]+(?:\.[0-9]+){1,3}$' -or $headers['RES_VER'] -cnotmatch '^[0-9]+$' -or $headers['CLIENT_VER'] -cnotmatch '^[0-9]+(\.[0-9]+){1,3}$') { throw '官方索引版本字段异常。' }
    return [pscustomobject]@{entries=$entries;version=$headers;sha256=$rawSha;path=$path}
}
# 同一次操作内，官方索引只在“文件字节没变”时复用解析结果。
# 失效标志是索引原文的 SHA256（重算约几十毫秒，比全量逐行解析快一个数量级）；
# 它仅用于缓存失效，**不是准入白名单**：准入仍旧是 GAME 版本 + 同层 MD5/size + 存在性。
# 文件字节一变，下一次就重新读取+重新解析+重新做全部语义校验。
function New-IndexCache { return @{} }
function Get-CachedIndex($state,$ctx,[string]$layer) {
    $path=Get-AuthorityPath $ctx.game $layer
    $sha=(Get-Hash $path 'SHA256')
    if (-not $state.ContainsKey($layer) -or $state[$layer].sha256 -cne $sha) {
        $state[$layer]=Read-OfficialIndex $path
    }
    return $state[$layer]
}
function Assert-Compatible($ctx,$state,[switch]$SkipTargetPathChecks) {
    if ($null -eq $state) { $state=New-IndexCache }
    $indices=@{}; foreach ($layer in @('IR','PS')) { $indices[$layer]=Get-CachedIndex $state $ctx $layer }
    if ($indices['PS'].version['GAME_VER'] -cne $ctx.package.profile.gameVersion) { throw '当前PS GAME与支持版本不同，拒绝旧恢复/写入。' }
    foreach ($e in $ctx.package.profile.targets) {
        $index=$indices[$e.layer]
        if (-not $index.entries.ContainsKey($e.name)) { throw "受管官方条目缺失：$($e.layer)/$($e.name)" }
        $q=$index.entries[$e.name]
        if ($q.md5 -cne $e.official.md5 -or $q.size -ne $e.official.size) { throw "受管同层官方条目变化：$($e.layer)/$($e.name)；不覆盖新官方。" }
        if (-not $SkipTargetPathChecks) {
            $dst=Get-LeafPath (Get-LayerRoot $ctx.game $e.layer) $e.name
            if (-not (Test-Path -LiteralPath $dst -PathType Leaf)) { throw "资源未就绪/目标缺失：$($e.layer)/$($e.name)，本候选不创建资源。" }
        }
    }
    return $indices
}
function Assert-NoLegacy($ctx,$indices) {
    if ($null -eq $indices) { $indices=Assert-Compatible $ctx }
    foreach ($parent in @($ctx.game,(Get-LayerRoot $ctx.game 'IR'),(Get-LayerRoot $ctx.game 'PS'))) {
        $legacy=Join-Path $parent '_xingta_switch'
        if (Test-Path -LiteralPath $legacy) { throw "发现旧残留，安全迁移未实现，请先安全处理；未完成：$legacy" }
        # Filter in the filesystem, not through every resource on every entry.
        foreach ($item in @(Get-ChildItem -LiteralPath $parent -Force -Filter '_uncensor_backup*' -ErrorAction Stop)) {
            throw "发现旧残留，安全迁移未实现，请先安全处理；未完成：$($item.FullName)"
        }
    }
    foreach ($e in @($ctx.package.profile.legacyChecks)) {
        $p=Get-LeafPath (Get-LayerRoot $ctx.game $e.layer) $e.name
        if (Test-Path -LiteralPath $p) {
            $index=$indices[$e.layer]
            if ($null -eq $e.official -or -not $index.entries.ContainsKey($e.name)) { throw "历史路径来源/归属未明，需安全处理：$($e.layer)/$($e.name)" }
            $q=$index.entries[$e.name]
            if ($q.md5 -cne $e.official.md5 -or $q.size -ne $e.official.size -or (Get-Item -LiteralPath $p).Length -ne $q.size -or (Get-Hash $p) -cne $q.md5) { throw "历史路径不是已验证官方，未恢复/删除：$($e.layer)/$($e.name)" }
        }
    }
}

function Get-LayerListing([string]$game) {
    $out=[ordered]@{}
    foreach ($layer in @('IR','PS')) {
        $root=Get-LayerRoot $game $layer; $list=New-Object 'Collections.Generic.List[string]'
        if (Test-Path -LiteralPath $root -PathType Container) {
            foreach ($it in @(Get-ChildItem -LiteralPath $root -Force -ErrorAction Stop | Sort-Object Name)) {
                $kind=if ($it.PSIsContainer) {'D'} else {'F'}
                [void]$list.Add(($it.Name+'|'+$kind))
            }
        }
        $out[$layer]=$list.ToArray()
    }
    return [pscustomobject]$out
}
# 末端层目录审计。判据是“本工具是否在游戏里创建了路径”，不是“目录里有没有我不认识的文件”：
#   * 本运行时从不创建游戏内路径（createdGamePaths 必须为空），所以缺失受管文件=未完成；
#   * 安装后新出现的文件若能被**当前同层官方清单**认证（名字在册且现场 MD5+size 一致），
#     判定为官方后续更新，保留它、不删除、不叫残留；
#   * 既不在安装前清单、又不能被当前官方清单认证的额外路径，才报“本工具无法认证的额外变化”，
#     保守不删除并明确披露——绝不因“清单没列它”就推断删除合法；
#   * 安装前的受管目标若在末端消失，属于缺失，直接失败。
function Assert-LayerListing([string]$game,$expected) {
    $now=Get-LayerListing $game
    $report=[ordered]@{}
    foreach ($layer in @('IR','PS')) {
        $b=@($expected.$layer); $a=@($now.$layer)
        $before=@{}; foreach ($x in $b) { $before[$x]=$true }
        $after=@{}; foreach ($x in $a) { $after[$x]=$true }
        $removed=@($b|Where-Object { -not $after.ContainsKey($_) })
        $added=@($a|Where-Object { -not $before.ContainsKey($_) })
        if ($removed.Count -ne 0) {
            $show=@(); foreach ($x in $removed) { if ($show.Count -lt 5) { $show+=$x } }
            throw ("受管层目录缺失安装前原有路径（{0}）：{1} 项，例如 {2}；本工具不删除游戏文件，未完成。" -f $layer,$removed.Count,($show -join ' , '))
        }
        $officialNew=@(); $unknown=@()
        if ($added.Count -ne 0) {
            $idx=Read-OfficialIndex (Get-AuthorityPath $game $layer)
            foreach ($x in $added) {
                $name=($x -split '\|')[0]
                $kind=($x -split '\|')[1]
                $ok=$false
                if ($kind -ceq 'F' -and $idx.entries.ContainsKey($name)) {
                    $q=$idx.entries[$name]
                    try {
                        $p=Get-LeafPath (Get-LayerRoot $game $layer) $name
                        $ok=((Get-Item -LiteralPath $p).Length -eq $q.size -and (Get-Hash $p) -ceq $q.md5)
                    } catch { $ok=$false }
                }
                if ($ok) { $officialNew+=$name } else { $unknown+=$x }
            }
        }
        $report[$layer]=[pscustomobject]@{officialNewPaths=@($officialNew);unknownPaths=@($unknown)}
    }
    $allUnknown=@(); foreach ($layer in @('IR','PS')) { $allUnknown+=@($report[$layer].unknownPaths) }
    if ($allUnknown.Count -ne 0) {
        $show=@(); foreach ($x in $allUnknown) { if ($show.Count -lt 5) { $show+=$x } }
        throw ("受管层目录出现本工具无法认证的额外路径：{0} 项，例如 {1}；已保留未删除，未完成。这不等于本工具残留，请在确认来源后手工处理。" -f $allUnknown.Count,($show -join ' , '))
    }
    return [pscustomobject]$report
}
function Get-TreeBytes([string]$p) {
    if (-not (Test-Path -LiteralPath $p)) { return [long]0 }
    $s=[long]0; foreach ($f in @(Get-ChildItem -LiteralPath $p -File -Recurse -Force -ErrorAction SilentlyContinue)) { $s+=[long]$f.Length }
    return $s
}
function Get-Target($ctx,$e) { return Get-LeafPath (Get-LayerRoot $ctx.game $e.layer) $e.name }
function Get-StatePath($ctx,[string]$relative) { return Assert-Inside (Join-Path $ctx.state $relative) $ctx.state }
function Get-Info([string]$path) {
    $p=Assert-PlainPath $path; $f=Get-Item -LiteralPath $p -Force
    if ($f.PSIsContainer) { throw '资源不是普通文件。' }
    if (($f.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw '资源是链接/联接，拒绝处理。' }
    if (($f.Attributes -band ([IO.FileAttributes]::Compressed -bor [IO.FileAttributes]::Encrypted -bor [IO.FileAttributes]::SparseFile)) -ne 0) { throw '不支持特殊资源文件属性。' }
    return [pscustomobject]@{md5=(Get-Hash $p);sha256=(Get-Hash $p 'SHA256');size=[long]$f.Length;mtime=[string]$f.LastWriteTimeUtc.Ticks;ctime=[string]$f.CreationTimeUtc.Ticks;attributes=[int]$f.Attributes}
}
function Test-Bytes([string]$path,$spec) {
    $p=Assert-PlainPath $path
    return ((Test-Path -LiteralPath $p -PathType Leaf) -and (Get-Item -LiteralPath $p).Length -eq $spec.size -and (Get-Hash $p) -ceq $spec.md5 -and (Get-Hash $p 'SHA256') -ceq $spec.sha256)
}
function Open-StateLock($ctx) {
    New-Item -ItemType Directory -Path $ctx.state -Force | Out-Null
    $p=Assert-Inside (Join-Path $ctx.instance 'operation.lock') $ctx.instance
    return [IO.File]::Open($p,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
}
function Save-Receipt($ctx,$r) {
    $r.layerListing=[pscustomobject]@{IR=@();PS=@()}
    $payload=$r|ConvertTo-Json -Depth 16 -Compress
    $row=[ordered]@{sha256=(Get-TextHash $payload);payload=$payload}|ConvertTo-Json -Compress
    $p=Get-StatePath $ctx 'receipt.jsonl'; $s=[IO.File]::Open($p,[IO.FileMode]::Append,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    try { $b=[Text.Encoding]::UTF8.GetBytes($row+"`r`n"); $s.Write($b,0,$b.Length);$s.Flush($true) } finally { $s.Dispose() }
}
function Move-ReceiptAside($ctx) {
    $p=Get-StatePath $ctx 'receipt.jsonl'
    $dir=Assert-Inside (Join-Path $ctx.state 'receipts') $ctx.state
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $stamp=(Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ')
    $target=Assert-Inside (Join-Path $dir ($stamp+'.jsonl')) $dir
    [IO.File]::Move($p,$target)
    Write-Step "上一轮已完成卸载，旧收据归档保留为证据：$target"
}
function Read-Receipt($ctx) {
    $p=Get-StatePath $ctx 'receipt.jsonl'; if (-not (Test-Path -LiteralPath $p)) { return $null }
    Write-Step '正在读取本次安装记录 ...'
    $stream=[IO.File]::Open($p,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try {
        if ($stream.Length -eq 0) { throw '收据为空，未完成。' }
        $null=$stream.Seek(-1,[IO.SeekOrigin]::End)
        if ($stream.ReadByte() -ne 10) { throw '收据截断，保留备份与记录，未完成。' }
        # Locate only the last full snapshot, including the existing large journals.
        $end=$stream.Length-1; $pos=$end; $start=[long]0; $buffer=New-Object byte[] 65536
        :search while ($pos -gt 0) {
            $size=[int][Math]::Min(65536,$pos); $pos-=$size; $null=$stream.Seek($pos,[IO.SeekOrigin]::Begin)
            $read=$stream.Read($buffer,0,$size)
            for ($i=$read-1;$i -ge 0;$i--) { if ($buffer[$i] -eq 10) { $start=$pos+$i+1; break search } }
        }
        $null=$stream.Seek($start,[IO.SeekOrigin]::Begin)
        $reader=[IO.StreamReader]::new($stream,[Text.Encoding]::UTF8,$true)
        try { $line=$reader.ReadLine() } finally { $reader.Dispose() }
    } finally { $stream.Dispose() }
    if ([string]::IsNullOrEmpty($line)) { throw '收据为空，未完成。' }
    $z=$line|ConvertFrom-Json
    if ($z.sha256 -cne (Get-TextHash $z.payload)) { throw '收据校验损坏，保留证据，未完成。' }
    $r=$z.payload|ConvertFrom-Json
    if ($r.schema -ne 1 -or $r.packageId -cne $ctx.package.id -or $r.gameDir -ine $ctx.game -or $r.stateDir -ine $ctx.state -or @('prepared','installed','uninstalling','uninstalled') -cnotcontains $r.phase -or @($r.entries).Count -ne $ctx.package.profile.targets.Count) { throw '收据不属于本包/目录或状态损坏，未完成。' }
    $seen=@{}; foreach ($e in $r.entries) {
        $key=$e.layer+'/'+$e.name; $m=@($ctx.package.profile.targets|Where-Object { $_.layer -ceq $e.layer -and $_.name -ceq $e.name })
        if ($m.Count -ne 1 -or $seen.ContainsKey($key) -or @('planned','pending','written','restore-pending','restored') -cnotcontains $e.stage) { throw '收据目标集/层/阶段损坏，未完成。' };$seen[$key]=$true
        Assert-Digest $e.initial; Assert-Digest $e.cache
        foreach ($n in @('mtime','ctime','attributes')) { if ($null -eq $e.initial.PSObject.Properties[$n]) { throw '收据元数据不全，未完成。' } }
        if ($e.cache.md5 -cne $m[0].official.md5 -or $e.cache.size -ne $m[0].official.size -or $e.cache.sha256 -cne $m[0].official.sha256) { throw '官方cache与profile不符，未完成。' }
    }
    if ($null -eq $r.PSObject.Properties['layerListing']) { throw '收据缺少安装前受管层目录清单，不能证明零新增路径，未完成。' }
    Assert-Fields $r.layerListing @('IR','PS')
    return $r
}
function Assert-Cache($ctx,$r,$state) {
    $null=Assert-Compatible $ctx $state
    foreach ($layer in @('IR','PS')) {
        $p=Get-StatePath $ctx ('source/'+$layer+'.mani'); $s=$r.sources.$layer
        if ((Get-Hash $p 'SHA256') -cne $s.sha256) { throw '来源清单快照缺损，保留证据，未完成。' }
        $idx=Read-OfficialIndex $p
        foreach ($m in @($ctx.package.profile.targets|Where-Object { $_.layer -ceq $layer })) {
            if (-not $idx.entries.ContainsKey($m.name) -or $idx.entries[$m.name].md5 -cne $m.official.md5 -or $idx.entries[$m.name].size -ne $m.official.size) { throw '来源快照不能证明同层官方材料，未完成。' }
        }
    }
    foreach ($e in $r.entries) { if (-not (Test-Bytes (Get-StatePath $ctx ('cache/'+$e.layer+'/'+$e.name)) $e.cache)) { throw "官方cache缺失/损坏：$($e.layer)/$($e.name)，保留证据，未完成。" } }
}
function Assert-Current($ctx,$e,$m) {
    $cur=Get-Info (Get-Target $ctx $e)
    if ($cur.ctime -cne $e.initial.ctime) { throw '目标文件身份/创建时间变化，未完成。' }
    if (($cur.sha256 -cne $e.initial.sha256 -or $cur.size -ne $e.initial.size) -and ($cur.sha256 -cne $m.post.sha256 -or $cur.size -ne $m.post.size) -and ($cur.sha256 -cne $e.cache.sha256 -or $cur.size -ne $e.cache.size)) { throw '未知并发目标变化，未完成。' }
    return $cur
}
function Prepare-Install($ctx,$state) {
    $indices=Assert-Compatible $ctx $state; Assert-NoLegacy $ctx $indices
    $listing=[pscustomobject]@{IR=@();PS=@()} # no inventory of unrelated game files
    # 材料全备齐并校验通过之前，不碰游戏内任何字节。
    Write-Step '准备原文件备份和安装资源；还没有替换游戏文件 ...'
    $prepCount=0
    $plan=@(); foreach ($m in $ctx.package.profile.targets) {
        $prepCount++; Write-Step ("准备 {0}/{1}：{2}" -f $prepCount,$ctx.package.profile.targets.Count,$m.name)
        $dst=Get-Target $ctx $m; $initial=Get-Info $dst
        $post=Get-LeafPath (Join-Path $ctx.package.data 'full') $m.post.file
        if (-not (Test-Bytes $post $m.post)) { throw "本包源缺失/损坏：$($m.name)，未写资源。" }
        $cache=Get-StatePath $ctx ('cache/'+$m.layer+'/'+$m.name)
        $src=''
        if (Test-Bytes $dst $m.official) { $src=$dst }
        elseif (Test-Bytes $cache $m.official) { $src=$cache }
        elseif ($ctx.donor) { $src=Get-LeafPath (Join-Path $ctx.donor $m.layer) $m.name; if (-not (Test-Bytes $src $m.official)) { throw '官方donor校验不符，未写资源。' } }
        else { throw "现有字节未知且官方cache/donor未齐：$($m.layer)/$($m.name)；请提供外置已验证官方donor，未写资源。" }
        $plan += [pscustomobject]@{layer=$m.layer;name=$m.name;initial=$initial;src=$src;cache=$cache}
    }
    $sources=[ordered]@{}
    foreach ($layer in @('IR','PS')) {
        $p=Get-StatePath $ctx ('source/'+$layer+'.mani'); New-Item -ItemType Directory -Path (Split-Path -Parent $p) -Force|Out-Null
        [IO.File]::WriteAllBytes($p,[IO.File]::ReadAllBytes($indices[$layer].path))
        if ((Get-Hash $p 'SHA256') -cne $indices[$layer].sha256) { throw '来源清单准备期间变化，未写资源。' }
        $sources[$layer]=[pscustomobject]@{sha256=$indices[$layer].sha256;version=$indices[$layer].version;profileSourceSha256=$ctx.package.profile.authorities.$layer.sourceSha256}
    }
    Write-Step '正在保存原文件到游戏目录外 ...'
    $entries=@(); foreach ($i in $plan) {
        $m=@($ctx.package.profile.targets|Where-Object {$_.layer -ceq $i.layer -and $_.name -ceq $i.name})[0]
        New-Item -ItemType Directory -Path (Split-Path -Parent $i.cache) -Force|Out-Null
        if ($i.src -ine $i.cache) { [IO.File]::Copy($i.src,$i.cache,$true) }
        if (-not (Test-Bytes $i.cache $m.official)) { throw '官方cache准备失败，未写资源。' }
        $accident=$false
        if ($i.initial.sha256 -cne $m.official.sha256) {
            $a=Get-StatePath $ctx ('accident/'+$i.layer+'/'+$i.name);New-Item -ItemType Directory -Path (Split-Path -Parent $a) -Force|Out-Null
            [IO.File]::Copy((Get-Target $ctx $i),$a,$true); if (-not (Test-Bytes $a $i.initial)) { throw '事故备份校验失败，未写资源。' }; $accident=$true
        }
        if (-not (Test-Bytes (Get-Target $ctx $i) $i.initial)) { throw '准备期间目标变化，未写资源。' }
        $entries += [pscustomobject]@{layer=$i.layer;name=$i.name;initial=$i.initial;cache=$m.official;accident=$accident;stage='planned'}
    }
    $r=[pscustomobject]@{schema=1;packageId=$ctx.package.id;gameDir=$ctx.game;stateDir=$ctx.state;phase='prepared';createdGamePaths=@();layerListing=$listing;sources=[pscustomobject]$sources;entries=@($entries)}
    Assert-Cache $ctx $r; Save-Receipt $ctx $r; return $r
}
function Write-Managed($ctx,$e,$m,[string]$src,$expected) {
    $dst=Get-Target $ctx $e; $cur=Assert-Current $ctx $e $m
    if (-not (Test-Bytes $src $expected)) { throw '写前源材料变化，未完成。' }
    # 原地写同一个文件：不新建游戏内路径、不留临时文件。
    $attrs=[IO.File]::GetAttributes($dst)
    try {
        [IO.File]::SetAttributes($dst,($attrs -band (-bnot [IO.FileAttributes]::ReadOnly)))
        $stream=[IO.File]::Open($dst,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::Read)
        try {
            $sha=[Security.Cryptography.SHA256]::Create()
            try { $actual=([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
            if ($actual -cne $cur.sha256) { throw '目标在打开前发生并发变化，未完成。' }
            $stream.Position=0; $input=[IO.File]::OpenRead($src)
            try { $input.CopyTo($stream);$stream.SetLength($input.Length);$stream.Flush($true) } finally { $input.Dispose() }
        } finally { $stream.Dispose() }
    } finally { [IO.File]::SetAttributes($dst,$attrs) }
    if (-not (Test-Bytes $dst $expected)) { throw '写后全哈希校验失败，保留恢复材料。' }
}
function Restore-Metadata($ctx,$e) {
    $p=Get-Target $ctx $e
    [IO.File]::SetAttributes($p,([IO.File]::GetAttributes($p) -band (-bnot [IO.FileAttributes]::ReadOnly)))
    [IO.File]::SetCreationTimeUtc($p,(New-Object DateTime ([long]$e.initial.ctime),([DateTimeKind]::Utc)))
    [IO.File]::SetLastWriteTimeUtc($p,(New-Object DateTime ([long]$e.initial.mtime),([DateTimeKind]::Utc)))
    [IO.File]::SetAttributes($p,[IO.FileAttributes]$e.initial.attributes)
}
# Restore the installation's original files. No uninstall hash/index scans,
# compatibility gates, unrelated-directory inventory, or final verification pass.
function Invoke-OwnedUninstall($ctx,$r,$byKey,[int]$failAfter=0) {
    if ($null -eq $r) { throw '没有本次安装记录，不能猜测哪些文件应放回；未改动游戏。' }
    if ($r.phase -ceq 'uninstalled') {
        Write-Ok '本次小开关已经卸载，无需重复操作。'
        return
    }
    # This package only overwrites existing files. All backups, locks and
    # receipts live outside the game; there are no tool-created game paths.
    if (@($r.createdGamePaths).Count -ne 0) { throw '安装记录包含本包不会创建的路径，不能据此删除其他文件。' }
    $plan=@()
    foreach ($e in $r.entries) {
        if (@('planned','restored') -ccontains $e.stage) { continue }
        $folder=if ($e.accident) { 'accident/' } else { 'cache/' }
        $src=Get-StatePath $ctx ($folder+$e.layer+'/'+$e.name)
        # File presence/path safety are necessary to perform a copy, not an audit.
        if (-not (Test-Path -LiteralPath $src -PathType Leaf)) { throw "原文件备份缺失：$($e.layer)/$($e.name)，无法放回。" }
        $dst=Get-Target $ctx $e
        if (-not (Test-Path -LiteralPath $dst -PathType Leaf)) { throw "原目标文件不存在：$($e.layer)/$($e.name)，未擅自创建路径。" }
        $plan += [pscustomobject]@{entry=$e;source=$src;destination=$dst}
    }
    $r.phase='uninstalling'; Save-Receipt $ctx $r; $count=0
    foreach ($item in $plan) {
        Write-Step ("放回原文件 {0}/{1}：{2}" -f ($count+1),$plan.Count,$item.entry.name)
        $e=$item.entry; $e.stage='restore-pending'; Save-Receipt $ctx $r
        $attrs=[IO.File]::GetAttributes($item.destination)
        try {
            [IO.File]::SetAttributes($item.destination,($attrs -band (-bnot [IO.FileAttributes]::ReadOnly)))
            $input=[IO.File]::OpenRead($item.source)
            try {
                $output=[IO.File]::Open($item.destination,[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::None)
                try { $input.CopyTo($output);$output.SetLength($input.Length);$output.Flush($true) }
                finally { $output.Dispose() }
            } finally { $input.Dispose() }
        } finally { [IO.File]::SetAttributes($item.destination,$attrs) }
        $count++; if ($failAfter -eq $count) { throw '模拟中断：原文件已写回，保留记录以便继续。' }
        Restore-Metadata $ctx $e
        $e.stage='restored'; Save-Receipt $ctx $r
    }
    foreach ($e in $r.entries) { if ($e.stage -ceq 'planned') { $e.stage='restored' } }
    $r.phase='uninstalled'; Save-Receipt $ctx $r
    Write-Ok '本次替换的原文件已放回；本包不会在游戏根目录留下备份、日志或临时目录。'
    Write-Step '备份与安装记录仍在游戏目录外。请先卸载小开关，再用启动器更新游戏。'
}
function Write-SpaceReport($ctx,$r) {
    $cache=Get-TreeBytes (Join-Path $ctx.state 'cache'); $accident=Get-TreeBytes (Join-Path $ctx.state 'accident'); $source=Get-TreeBytes (Join-Path $ctx.state 'source')
    Write-Step ("外置状态占用：官方cache {0:N0} 字节 / 事故备份 {1:N0} 字节 / 来源快照 {2:N0} 字节，合计约 {3:N1} MB。" -f $cache,$accident,$source,(($cache+$accident+$source)/1MB))
    Write-Step '清理边界：本工具不自动删除任何证据。确认不再需要后，由您自行删除上面这个游戏外状态目录来回收空间。'
    return [pscustomobject]@{cacheBytes=$cache;accidentBytes=$accident;sourceBytes=$source;autoDeleted=$false}
}
function Invoke-CleanOperation([string]$op,[string]$gameOverride,[string]$stateOverride,[string]$donorOverride,[int]$failAfter=0) {
    $lock=$null
    try {
        $package=Read-Package (Split-Path -Parent $PSScriptRoot)
        $ctx=Get-Context $package $gameOverride $stateOverride $donorOverride
        if ($failAfter -ne 0 -and -not $ctx.testing) { throw '中断注入仅允许授权模拟测试，未写资源。' }
        # 一次操作共用一个索引缓存：索引原文 SHA 变了就重新解析并重做语义校验。
        $state=New-IndexCache
        # 目标查找表，避免每条目都扫一遍132项。
        $byKey=@{}; foreach ($m in $package.profile.targets) { $byKey[$m.layer+'/'+$m.name]=$m }
        if ($op -ceq 'uninstall') {
            $lock=Open-StateLock $ctx
            $r=Read-Receipt $ctx
            Invoke-OwnedUninstall $ctx $r $byKey $failAfter
            return
        }
        $indices=Assert-Compatible $ctx $state; Assert-NoLegacy $ctx $indices
        $lock=Open-StateLock $ctx
        $indices=Assert-Compatible $ctx $state; Assert-NoLegacy $ctx $indices
        $r=Read-Receipt $ctx
        if ($null -eq $r) {
            $r=Prepare-Install $ctx $state
        } else {
            if ($op -ceq 'install' -and $r.phase -ceq 'uninstalling') { throw '上一轮卸载未完成：请先重跑卸载到干净，再重新安装；未写资源。' }
            Assert-Cache $ctx $r $state
            foreach ($e in $r.entries) { $null=Assert-Current $ctx $e $byKey[$e.layer+'/'+$e.name] }
            if ($op -ceq 'install' -and $r.phase -ceq 'uninstalled') {
                # 新一轮事务：先把准入、官方材料与全部post验证完，再轮换旧收据证据。
                # 验证失败时旧收据原样保留，不会被一次被拒绝的安装弄丢。
                $indices=Assert-Compatible $ctx $state; Assert-NoLegacy $ctx $indices
                foreach ($m in $package.profile.targets) { if (-not (Test-Bytes (Get-LeafPath (Join-Path $package.data 'full') $m.post.file) $m.post)) { throw '全部post写前校验失败，未写资源。' } }
                Move-ReceiptAside $ctx
                $r=Prepare-Install $ctx $state
                Assert-Cache $ctx $r $state
                foreach ($e in $r.entries) { $null=Assert-Current $ctx $e $byKey[$e.layer+'/'+$e.name] }
            }
        }

        $count=0
        Write-Step '开始替换资源 ...'
        foreach ($e in $r.entries) {
            Write-Step ("安装 {0}/{1}：{2}" -f ($count+1),$r.entries.Count,$e.name)
            # Retain live official semantics for ALL targets on each step.
            # Only skip repeated filesystem walks for OTHER targets: the current
            # target is independently re-resolved/verified immediately below and
            # again in Write-Managed. Full existence checks remain at start/end.
            $indices=Assert-Compatible $ctx $state -SkipTargetPathChecks
            $m=$byKey[$e.layer+'/'+$e.name]
            $e.stage='pending';$src=Get-LeafPath (Join-Path $package.data 'full') $m.post.file;$expected=$m.post
            Save-Receipt $ctx $r
            if (-not (Test-Bytes (Get-Target $ctx $e) $expected)) { Write-Managed $ctx $e $m $src $expected }
            $count++; if ($failAfter -eq $count) { throw '模拟中断：材料和先写意图已保留，未完成。' }
            $e.stage='written';Save-Receipt $ctx $r
        }
        if ($op -ceq 'install') {
            $indices=Assert-Compatible $ctx $state;Assert-NoLegacy $ctx $indices
            foreach ($m in $package.profile.targets) { if (-not (Test-Bytes (Get-Target $ctx $m) $m.post)) { throw '安装末端全集校验失败。' } };$r.phase='installed'
        }
        Save-Receipt $ctx $r
        [IO.File]::WriteAllText((Assert-Inside (Join-Path $ctx.base 'last-game-dir.txt') $ctx.base),$ctx.game,(New-Object Text.UTF8Encoding($false)))
        Write-Ok ($op+'完成；外置官方cache/收据保留。仅受管集已验证，不代表所有历史模组均清除。')
        $null=Write-SpaceReport $ctx $r
    } catch { Write-Err2 $_.Exception.Message;Write-Host '操作未完成。请保留外置官方cache/收据，勿用旧备份覆盖新官方。' -ForegroundColor Yellow;throw }
    finally { if ($null -ne $lock) { $lock.Dispose() } }
}
