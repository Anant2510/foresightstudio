<#
.SYNOPSIS
  Removes Foresight Studio's server setup from this VM (rollback).
.DESCRIPTION
  Stops and removes the app server task, the Caddy service and the firewall rule.
  Files under C:\xperion (including the stored API key) are kept unless you pass -RemoveFiles.
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\deploy\windows\uninstall.ps1
  powershell -ExecutionPolicy Bypass -File .\deploy\windows\uninstall.ps1 -RemoveFiles
#>
[CmdletBinding()]
param([string]$Root = "C:\xperion", [switch]$RemoveFiles)

$ErrorActionPreference = "Stop"
$TaskName = "xPerion Foresight Server"; $SvcName = "xperion-web"; $FwRule = "xPerion Web (HTTP/HTTPS)"
$ServerDir = Join-Path $Root "foresightstudio\server"

$me = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { Write-Host "Run PowerShell as Administrator." -ForegroundColor Red; exit 1 }

if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
  Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
  Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
  Write-Host "  [ok] Removed task '$TaskName'" -ForegroundColor Green
}
Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
  Where-Object { "$($_.CommandLine)" -like "*$ServerDir*" } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

if (Get-Service $SvcName -ErrorAction SilentlyContinue) {
  Stop-Service $SvcName -Force -ErrorAction SilentlyContinue
  & sc.exe delete $SvcName | Out-Null
  Write-Host "  [ok] Removed service '$SvcName'" -ForegroundColor Green
}

if (Get-NetFirewallRule -DisplayName $FwRule -ErrorAction SilentlyContinue) {
  Remove-NetFirewallRule -DisplayName $FwRule
  Write-Host "  [ok] Removed firewall rule '$FwRule'" -ForegroundColor Green
}

if ($RemoveFiles -and (Test-Path $Root)) {
  $a = Read-Host "  Delete $Root, including the stored API key and certificates? Type YES to confirm"
  if ($a -ceq "YES") { Remove-Item $Root -Recurse -Force; Write-Host "  [ok] Deleted $Root" -ForegroundColor Green }
  else { Write-Host "  Kept $Root" }
}
Write-Host "  Done. GitHub Pages is unaffected; the old link still works until cutover."
