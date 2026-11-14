# GUI transport. Runtime path guard no longer compiles C# or depends on writable TEMP.
param(
    [Parameter(Mandatory=$true)][ValidateSet('locate','install','uninstall')][string]$Mode,
    [string]$SelectedGameB64='',
    [string]$FixtureGame='',
    [string]$FixtureState=''
)
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=New-Object Text.UTF8Encoding($false)
$OutputEncoding=[Console]::OutputEncoding
function Send-Gui([string]$kind,[string]$text) {
    [Console]::WriteLine('@@XT|'+$kind+'|'+[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($text)))
}
try {
    . (Join-Path $PSScriptRoot 'common.ps1')
    function Write-Step([string]$t) { Send-Gui 'step' $t }
    function Write-Ok([string]$t) { Send-Gui 'ok' $t }
    function Write-Err2([string]$t) { Send-Gui 'error' $t }
    if ($Mode -ceq 'locate') {
        if ($FixtureGame -or $FixtureState -or $SelectedGameB64) { throw '定位操作不接受写入或模拟参数。' }
        Send-Gui 'step' '正在自动寻找国服目录…'
        foreach ($path in @(Find-GameDirs)) { Send-Gui 'path' $path }
        exit 0
    }
    if ([bool]$FixtureGame -xor [bool]$FixtureState) { throw '隔离测试必须同时指定模拟游戏和模拟状态目录。' }
    if ($FixtureGame) {
        # The runtime verifies the sibling-directory fixture authorization.
        # Never fall back to automatic discovery when a fixture is requested.
        if ($SelectedGameB64) { throw '模拟测试不能同时选择真实目录。' }
        Invoke-CleanOperation $Mode $FixtureGame $FixtureState '' 0
    } else {
        if (-not $SelectedGameB64) { throw '请先选择国服目录，未写资源。' }
        $script:GuiGame=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($SelectedGameB64))
        function Get-GameDirInteractive {
            if (-not (Test-GameDir $script:GuiGame)) { throw '选中的国服目录无效；不会自动切换到其他目录。' }
            return (Assert-PlainPath $script:GuiGame).TrimEnd('\','/')
        }
        # Normal production entry: existing process guard, path guard, package binding,
        # official compatibility, lock and all backup/restore logic remain in force.
        Invoke-CleanOperation $Mode '' '' '' 0
    }
    Send-Gui 'done' $Mode
    exit 0
} catch {
    Send-Gui 'error' $_.Exception.Message
    Send-Gui 'detail' ('错误位置：'+$_.InvocationInfo.PositionMessage)
    Send-Gui 'detail' ('调用位置：'+$_.ScriptStackTrace)
    exit 1
}
