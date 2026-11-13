# 星塔旅人国服：官方净还原能力接线候选；仅Windows PowerShell5.1。
param([string]$GameDirOverride='', [string]$StateDirOverride='', [string]$DonorDirOverride='', [int]$TestFailAfter=0)
Write-Host '正在启动小开关，请稍候 ...'
try { . (Join-Path $PSScriptRoot 'common.ps1') } catch { Write-Host $_.Exception.Message -ForegroundColor Red; exit 1 }
try { [Console]::OutputEncoding=[Text.Encoding]::UTF8 } catch {}
try { Write-Title '星塔旅人（国服）· 小开关安装候选'; Invoke-CleanOperation 'install' $GameDirOverride $StateDirOverride $DonorDirOverride $TestFailAfter; exit 0 }
catch { exit 1 }
