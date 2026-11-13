# 星塔旅人国服：恢复同层官方cache并复验全集；不清理未知历史目录。
param([string]$GameDirOverride='', [string]$StateDirOverride='', [string]$DonorDirOverride='', [int]$TestFailAfter=0)
Write-Host '正在启动小开关，请稍候 ...'
try { . (Join-Path $PSScriptRoot 'common.ps1') } catch { Write-Host $_.Exception.Message -ForegroundColor Red; exit 1 }
try { [Console]::OutputEncoding=[Text.Encoding]::UTF8 } catch {}
try { Write-Title '星塔旅人（国服）· 官方净还原候选'; Invoke-CleanOperation 'uninstall' $GameDirOverride $StateDirOverride $DonorDirOverride $TestFailAfter; exit 0 }
catch { exit 1 }
