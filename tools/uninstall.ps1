# 星塔旅人 · 仅按本包收据恢复本包实际写入的目标
param([string]$ManifestOverride = '', [string]$GameDirOverride = '')
. (Join-Path $PSScriptRoot 'common.ps1')
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}
function Get-RestorePlan($ctx, $receipt) {
    $plan = @()
    foreach ($e in @($receipt.entries)) {
        # restored 不再拥有目标；无收据目标从未由此包接管。
        if ($e.state -ceq 'restored') { continue }
        $dst = Get-Target $ctx $e
        $cur = Get-Hash $dst
        if ($cur -cne $e.backupMd5 -and $cur -cne $e.post) { throw "目标已被热更或其他操作改变：$($e.layer)/$($e.pkg)；未还原任何资源。" }
        if ($e.state -ceq 'pending' -and $cur -ceq $e.post) { throw "中断写入未确认：$($e.layer)/$($e.pkg)，不自动恢复，请保留备份人工核对。" }
        $plan += [pscustomobject]@{entry=$e;dst=$dst;backup=(Get-Backup $ctx $e);needsCopy=($cur -ceq $e.post -and $cur -cne $e.backupMd5)}
    }
    return $plan
}
$lock = $null
try {
    Write-Title '星塔旅人（国服）· 小开关卸载'
    $root = Split-Path -Parent $PSScriptRoot
    $package = Read-Package $root $ManifestOverride
    $ctx = Get-Context $package $GameDirOverride
    $receipt = Read-Receipt $ctx $package
    $plan = @(Get-RestorePlan $ctx $receipt)
    if ($plan.Count -eq 0) { Write-Ok '本包没有需要恢复的安装记录，未写入资源。'; exit 0 }
    $lock = Open-StateLock $ctx
    $receipt = Read-Receipt $ctx $package
    $plan = @(Get-RestorePlan $ctx $receipt)
    # 所有备份、收据和当前目标都已校验通过，才进入写入循环。
    foreach ($item in $plan) {
        $e = $item.entry
        if ((Get-Hash $item.backup) -cne $e.backupMd5 -or (Get-Hash $item.backup 'SHA256') -cne $e.backupSha256) { throw '恢复前备份发生变化，停止后续写入。' }
        $cur = Get-Hash $item.dst
        if ($cur -cne $e.backupMd5 -and $cur -cne $e.post) { throw '恢复前目标发生变化，停止后续写入。' }
        if ($cur -ceq $e.post -and $cur -cne $e.backupMd5) {
            if ($e.state -cne 'written') { throw '此目标没有已确认写入收据，不恢复。' }
            Copy-Item -LiteralPath $item.backup -Destination $item.dst -Force
            if ((Get-Hash $item.dst) -cne $e.backupMd5 -or (Get-Hash $item.dst 'SHA256') -cne $e.backupSha256) { throw '恢复后哈希校验失败，停止后续写入。' }
            Write-Step "已还原 $($e.layer)/$($e.pkg)"
        }
        $e.state = 'restored'
        Save-Receipt $ctx $receipt
    }
    Write-Ok '本包写入内容已还原；备份和收据保留，重复卸载不会改动其他文件。'
    exit 0
} catch {
    Write-Err2 $_.Exception.Message
    Write-Host '  未能全部还原。请保留备份，按错误核对；不要用旧版本备份覆盖新游戏。' -ForegroundColor Yellow
    exit 1
} finally { if ($null -ne $lock) { $lock.Dispose() } }
