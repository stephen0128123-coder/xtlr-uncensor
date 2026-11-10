# 星塔旅人 · 小开关安装；只处理清单中明确列出的层
param([string]$ManifestOverride = '', [string]$GameDirOverride = '')
. (Join-Path $PSScriptRoot 'common.ps1')
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}
function Get-InstallPlan($ctx, $package, $receipt) {
    $plan = @()
    foreach ($row in $package.rows) {
        $dst = Get-Target $ctx $row
        $cur = Get-Hash $dst
        # Back up exact existing bytes, including valid older or third-party replacements.
        $owned = @($receipt.entries | Where-Object { $_.layer -ceq $row.layer -and $_.pkg -ceq $row.pkg })
        if ($owned.Count -gt 0 -and $owned[0].state -ceq 'pending' -and $cur -ceq $row.post) { throw "存在未确认的中断写入：$($row.key)。保留备份，请人工核对，不盲目恢复。" }
        if ($cur -ceq $row.post) { continue }
        $bf = Get-Backup $ctx $row
        if ($owned.Count -gt 0 -and $owned[0].backupMd5 -cne $cur) { throw "当前原件与本包历史安装前原件不同：$($row.key)，拒绝复用旧备份。" }
        if ((Test-Path -LiteralPath $bf) -and ((Get-Hash $bf) -cne $cur -or (Get-Hash $bf 'SHA256') -cne (Get-Hash $dst 'SHA256'))) { throw "本包备份与实际原件不同：$($row.key)。" }
        $plan += [pscustomobject]@{row=$row;dst=$dst;backup=$bf;originalMd5=$cur;originalSha256=(Get-Hash $dst 'SHA256')}
    }
    return $plan
}
$lock = $null
try {
    Write-Title '星塔旅人（国服）· 小开关安装'
    $root = Split-Path -Parent $PSScriptRoot
    $package = Read-Package $root $ManifestOverride
    # 必须在创建备份/收据、写任何目标之前，校验全部源 post。
    foreach ($row in $package.rows) {
        $src = Get-LeafPath $package.full $row.file
        if ((Get-Hash $src) -cne $row.post) { throw "安装包源数据损坏：$($row.file)。请重新完整解压，未写入资源。" }
    }
    $ctx = Get-Context $package $GameDirOverride
    Remember-GameDir $root $ctx.game
    $receipt = Read-Receipt $ctx $package
    $plan = @(Get-InstallPlan $ctx $package $receipt)
    if ($plan.Count -eq 0) { Write-Ok '所有目标已是本包内容，无需写入（不接管无收据的目标）。'; exit 0 }
    $lock = Open-StateLock $ctx
    # 加锁后重新检查，避免本外壳同时运行产生过期计划。
    $receipt = Read-Receipt $ctx $package
    $plan = @(Get-InstallPlan $ctx $package $receipt)
    foreach ($item in $plan) {
        $row = $item.row
        $src = Get-LeafPath $package.full $row.file
        if ((Get-Hash $src) -cne $row.post -or (Get-Hash $item.dst) -cne $item.originalMd5 -or (Get-Hash $item.dst 'SHA256') -cne $item.originalSha256) { throw "写入前文件发生变化：$($row.key)，停止后续写入。" }
        New-Item -ItemType Directory -Path (Split-Path -Parent $item.backup) -Force | Out-Null
        if (-not (Test-Path -LiteralPath $item.backup)) { Copy-Item -LiteralPath $item.dst -Destination $item.backup }
        if ((Get-Hash $item.backup) -cne $item.originalMd5 -or (Get-Hash $item.backup 'SHA256') -cne $item.originalSha256) { throw "备份校验失败：$($row.key)。" }
        $entry = @($receipt.entries | Where-Object { $_.layer -ceq $row.layer -and $_.pkg -ceq $row.pkg })
        if ($entry.Count -eq 0) {
            $e = [pscustomobject]@{layer=$row.layer;pkg=$row.pkg;pre=$row.pre;post=$row.post;backupMd5=$item.originalMd5;backupSha256=$item.originalSha256;state='pending'}
            $receipt.entries = @($receipt.entries) + @($e)
        } else { $e = $entry[0]; $e.state = 'pending' }
        Save-Receipt $ctx $receipt
        Copy-Item -LiteralPath $src -Destination $item.dst -Force
        if ((Get-Hash $item.dst) -cne $row.post) { throw "写入校验失败：$($row.key)。已保留收据和备份，停止后续写入。" }
        $e.state = 'written'
        Save-Receipt $ctx $receipt
        Write-Step "已写入 $($row.key)"
    }
    Write-Ok "安装完成；只写清单内目标，备份位于 $($ctx.state)"
    Write-Host '  更新游戏前，请双击本包 uninstall.bat。若已热更，卸载会拒绝覆盖未知文件。' -ForegroundColor Cyan
    exit 0
} catch {
    Write-Err2 $_.Exception.Message
    Write-Host '  操作未全部完成。不要删除备份；请按具体错误核对目录、版本或重新解压。' -ForegroundColor Yellow
    exit 1
} finally { if ($null -ne $lock) { $lock.Dispose() } }
