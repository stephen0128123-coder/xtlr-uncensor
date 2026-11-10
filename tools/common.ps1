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
function Assert-PlainPath([string]$p) {
    $p = [IO.Path]::GetFullPath($p)
    $check = $p
    while ($check) {
        if (Test-Path -LiteralPath $check) {
            $it = Get-Item -LiteralPath $check -Force
            if (($it.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "拒绝链接/联接路径：$check" }
        }
        $parent = Split-Path -Parent $check
        if ($parent -eq $check) { break }
        $check = $parent
    }
    return $p
}
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
        $hint = Join-Path $packageRoot '_last_game_dir.txt'
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
    try { [IO.File]::WriteAllText((Join-Path $root '_last_game_dir.txt'),$game,(New-Object Text.UTF8Encoding($false))) } catch {}
}
function Assert-GameNotRunning {
    if (Get-Process -Name 'xtlr' -ErrorAction SilentlyContinue) { throw '请先完全退出游戏（xtlr.exe），再操作。' }
}
function Read-Manifest([string]$file) {
    $rows = @(); $seen = @{}
    foreach ($line in [IO.File]::ReadAllLines($file, [Text.Encoding]::UTF8)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $f = $line -split "`t"
        if ($f.Count -ne 6) { throw '清单不完整：每行必须为六列。' }
        if ($f[0] -cne 'full' -or @('IR','PS') -cnotcontains $f[2]) { throw '清单仅支持 full + IR/PS，不支持 BOTH 或 patch。' }
        Assert-Leaf $f[1]; Assert-Leaf $f[5]
        if ($f[3] -cnotmatch '^[0-9a-f]{32}$' -or $f[4] -cnotmatch '^[0-9a-f]{32}$') { throw '清单 pre/post 必须为完整的小写 MD5。' }
        $key = $f[2] + '/' + $f[1]
        if ($seen.ContainsKey($key)) { throw "重复目标：$key" }
        $seen[$key] = $true
        $rows += [pscustomobject]@{type=$f[0];pkg=$f[1];layer=$f[2];pre=$f[3];post=$f[4];file=$f[5];key=$key;allowedPre=@($f[3])}
    }
    if ($rows.Count -eq 0) { throw '清单为空，拒绝安装。' }
    return $rows
}
function Read-Package([string]$root, [string]$manifestOverride) {
    $data = Assert-PlainPath (Join-Path $root 'data')
    $manifest = if ($manifestOverride) { Assert-PlainPath $manifestOverride } else { Join-Path $data 'manifest.tsv' }
    $metaPath = Assert-PlainPath (Join-Path $data 'package.json')
    $meta = [IO.File]::ReadAllText($metaPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
    if ($meta -isnot [pscustomobject]) { throw 'package.json 必须为有效元数据对象。' }
    foreach ($name in @('schema','resVer','baselineId')) { if ($null -eq $meta.PSObject.Properties[$name]) { throw "package.json 缺少 $name。" } }
    if (($meta.schema -isnot [int] -and $meta.schema -isnot [long]) -or $meta.schema -ne 1 -or $meta.resVer -isnot [string] -or $meta.baselineId -isnot [string] -or $meta.resVer -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$' -or $meta.baselineId -cnotmatch '^[0-9a-f]{64}$') { throw 'package.json 的 schema/resVer/baselineId 无效。' }
    $rows = @(Read-Manifest $manifest)
    # 仅接纳构建方明确核验的三个旧官方PS原件；不猜来源、不从真实游戏学习哈希。
    if ($null -ne $meta.PSObject.Properties['acceptedPre']) {
        if ($meta.acceptedPre -isnot [pscustomobject]) { throw 'acceptedPre 必须为目标键到MD5数组的对象。' }
        foreach ($prop in $meta.acceptedPre.PSObject.Properties) {
            if (@('PS/icon-c.unity3d','PS/icon-d.unity3d','PS/icon-f.unity3d') -cnotcontains $prop.Name) { throw "acceptedPre 越权目标：$($prop.Name)。" }
            $match = @($rows | Where-Object { $_.key -ceq $prop.Name })
            if ($match.Count -ne 1) { throw "acceptedPre 没有对应的PS清单目标：$($prop.Name)。" }
            if ($prop.Value -isnot [Array] -or $prop.Value.Count -eq 0) { throw 'acceptedPre 的每个值必须为非空MD5数组。' }
            $row = $match[0]; $seen = @{}
            foreach ($hash in $prop.Value) {
                if ($hash -isnot [string] -or $hash -cnotmatch '^[0-9a-f]{32}$' -or $hash -ceq $row.pre -or $hash -ceq $row.post -or $seen.ContainsKey($hash)) { throw "acceptedPre 哈希非法/重复/等于pre或post：$($prop.Name)。" }
                $seen[$hash] = $true
                $row.allowedPre = @($row.allowedPre) + @($hash)
            }
        }
    }
    # 包ID绑定整个元数据（含acceptedPre）和清单，不接受任意包ID。
    $idText = (Get-Hash $metaPath 'SHA256') + ':' + (Get-Hash $manifest 'SHA256')
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $id = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($idText)))).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
    return [pscustomobject]@{rows=$rows;meta=$meta;id=$id;full=(Assert-PlainPath (Join-Path $data 'full'))}
}
function Get-Context($package, [string]$gameOverride) {
    $game = if ($gameOverride) { $gameOverride } else { Get-GameDirInteractive }
    $game = (Assert-PlainPath $game).TrimEnd('\','/')
    if (-not (Test-GameDir $game)) { throw '指定目录无效；不会回退查找其他游戏目录。' }
    Assert-GameNotRunning
    $mani = Assert-PlainPath (Join-Path $game 'Persistent_Store/ss_win.mani')
    # Compare official advertised target versions, not the player's current modified bytes.
    $official = @{}; $res = @(); $gameVersion = @()
    foreach ($line in [IO.File]::ReadAllLines($mani, [Text.Encoding]::UTF8)) {
        $s=$line.Trim()
        if ($s.StartsWith('$RES_VER:')) { $res += $s.Substring(9).Trim(); continue }
        if ($s.StartsWith('$GAME_VER:')) { $gameVersion += $s.Substring(10).Trim(); continue }
        if ($s -and -not $s.StartsWith('$')) {
            $parts=$s -split '\|'
            if ($parts.Count -ge 2 -and $parts[1] -cmatch '^[0-9a-f]{32}$') { $official[$parts[0]]=$parts[1] }
        }
    }
    if ($res.Count -ne 1) { throw '未读到有效游戏资源版本，请先完成游戏更新；未写入资源。' }
    $versionFile = Join-Path (Split-Path -Parent $PSScriptRoot) 'data/game_version.txt'
    if (-not (Test-Path -LiteralPath $versionFile -PathType Leaf)) { throw '安装包缺少 game_version.txt，请完整解压；未写入资源。' }
    $expected=@([IO.File]::ReadAllLines($versionFile,[Text.Encoding]::UTF8) | ForEach-Object { $_.Trim() } | Where-Object { $_.StartsWith('GAME_VER=') })
    if ($expected.Count -ne 1 -or $expected[0].Substring(9).Trim() -cnotmatch '^[0-9]+(?:\.[0-9]+){1,3}$') { throw '安装包 GAME_VER 缺失、重复或格式无效，请重新完整解压；未写入资源。' }
    if ($gameVersion.Count -ne 1 -or $gameVersion[0] -cne $expected[0].Substring(9).Trim()) { throw '游戏版本与本包适配版本不同，请使用适配的新包；未写入资源。' }
    foreach ($row in $package.rows) {
        if (-not $official.ContainsKey($row.pkg) -or $official[$row.pkg] -cne $row.pre) { throw "游戏官方清单中的资源版本已变化或缺失，本包暂不适配：$($row.key)；未写入资源。" }
    }
    $ir = Assert-PlainPath (Join-Path $game 'xtlr_Data/StreamingAssets/InstallResource')
    $ps = Assert-PlainPath (Join-Path $game 'Persistent_Store/AssetBundles')
    $stateRoot = Assert-PlainPath (Join-Path $game '_xingta_switch')
    # 短目录名避免 Windows PowerShell 5.1 的 MAX_PATH；收据仍核对完整身份，碰撞拒绝复用。
    $resLabel = $package.meta.resVer.Substring(0, [Math]::Min(24, $package.meta.resVer.Length))
    $version = $resLabel + '_' + $package.meta.baselineId.Substring(0,16)
    $state = Assert-PlainPath (Join-Path (Join-Path $stateRoot $version) $package.id.Substring(0,24))
    return [pscustomobject]@{game=$game;IR=$ir;PS=$ps;stateRoot=$stateRoot;state=$state;receipt=(Join-Path $state 'receipt.jsonl')}
}
function Get-Target($ctx, $row) {
    $dir = if ($row.layer -ceq 'IR') { $ctx.IR } else { $ctx.PS }
    return Get-LeafPath $dir $row.pkg
}
function Get-Backup($ctx, $row) { return Get-LeafPath (Join-Path $ctx.state $row.layer) $row.pkg }
function Read-Receipt($ctx, $package) {
    $entries = @()
    if (Test-Path -LiteralPath $ctx.receipt) {
        $path = Assert-PlainPath $ctx.receipt
        $lines = @([IO.File]::ReadAllLines($path, [Text.Encoding]::UTF8))
        if ($lines.Count -eq 0 -or [string]::IsNullOrWhiteSpace($lines[-1])) { throw '安装收据为空/截断，不能自动恢复，请保留备份。' }
        $record = $lines[-1] | ConvertFrom-Json
        if ($record.sha256 -cnotmatch '^[0-9a-f]{64}$' -or (Get-TextHash $record.payload) -cne $record.sha256) { throw '安装收据最后一条损坏/截断，不能自动恢复，请保留备份。' }
        $r = $record.payload | ConvertFrom-Json
        if ($r.schema -ne 1 -or $r.packageId -cne $package.id -or $r.resVer -cne $package.meta.resVer -or $r.baselineId -cne $package.meta.baselineId -or -not [string]::Equals($r.gameDir, $ctx.game, [StringComparison]::OrdinalIgnoreCase)) { throw '安装收据不属于本包/目录/官方基准。' }
        $seen = @{}
        foreach ($e in @($r.entries)) {
            $row = @($package.rows | Where-Object { $_.layer -ceq $e.layer -and $_.pkg -ceq $e.pkg })
            if ($row.Count -ne 1) { throw '收据包含清单外目标。' }
            $key = $e.layer + '/' + $e.pkg
            if ($seen.ContainsKey($key) -or $e.pre -cne $row[0].pre -or $e.post -cne $row[0].post -or $e.backupMd5 -cnotmatch '^[0-9a-f]{32}$' -or $e.backupSha256 -cnotmatch '^[0-9a-f]{64}$' -or @('pending','written','restored') -cnotcontains $e.state) { throw '安装收据损坏/重复/哈希不符。' }
            $seen[$key] = $true
            $bf = Get-Backup $ctx $row[0]
            if ((Get-Hash $bf) -cne $e.backupMd5 -or (Get-Hash $bf 'SHA256') -cne $e.backupSha256) { throw "备份损坏：$key；拒绝覆盖资源。" }
            $entries += $e
        }
    }
    return [pscustomobject]@{schema=1;packageId=$package.id;resVer=$package.meta.resVer;baselineId=$package.meta.baselineId;gameDir=$ctx.game;entries=@($entries)}
}
function Save-Receipt($ctx, $receipt) {
    $path = Assert-PlainPath $ctx.receipt
    if ((Split-Path -Parent $path) -ne $ctx.state) { throw '收据路径越界。' }
    # 追加完整快照+校验，不删除/替换旧收据。最后一条不完整时失败关闭，不回退旧状态。
    $payload = $receipt | ConvertTo-Json -Depth 8 -Compress
    $record = [ordered]@{sha256=(Get-TextHash $payload);payload=$payload} | ConvertTo-Json -Compress
    $stream = [IO.File]::Open($path, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($record + "`r`n")
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    } finally { $stream.Dispose() }
}
function Open-StateLock($ctx) {
    New-Item -ItemType Directory -Path $ctx.state -Force | Out-Null
    $path = Assert-PlainPath (Join-Path $ctx.stateRoot 'operation.lock')
    return [IO.File]::Open($path, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
}
