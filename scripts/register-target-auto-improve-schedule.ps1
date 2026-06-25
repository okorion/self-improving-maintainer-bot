#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$TaskName = "ActionLedgerAutoImprove24h",
  [datetime]$StartAt = (Get-Date).AddMinutes(10),
  [int]$IntervalHours = 1,
  [int]$DurationHours = 24,
  [string]$Scope = "docs",
  [ValidateSet("squash", "merge", "rebase")]
  [string]$MergeMethod = "squash",
  [switch]$AutoMerge,
  [switch]$StartNow
)

$ErrorActionPreference = "Stop"
$BotRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path
$OnceScript = Join-Path $BotRoot "scripts\auto-improve-target-once.ps1"
$arguments = @(
  "-NoProfile",
  "-ExecutionPolicy", "Bypass",
  "-File", "`"$OnceScript`"",
  "-Scope", $Scope,
  "-MergeMethod", $MergeMethod
)
if ($AutoMerge) {
  $arguments += "-AutoMerge"
}

$action = New-ScheduledTaskAction `
  -Execute "powershell.exe" `
  -Argument ($arguments -join " ") `
  -WorkingDirectory $BotRoot

$trigger = New-ScheduledTaskTrigger `
  -Once `
  -At $StartAt `
  -RepetitionInterval (New-TimeSpan -Hours $IntervalHours) `
  -RepetitionDuration (New-TimeSpan -Hours $DurationHours)

$settings = New-ScheduledTaskSettingsSet `
  -MultipleInstances IgnoreNew `
  -StartWhenAvailable `
  -AllowStartIfOnBatteries `
  -DontStopIfGoingOnBatteries

Register-ScheduledTask `
  -TaskName $TaskName `
  -Action $action `
  -Trigger $trigger `
  -Settings $settings `
  -Description "Run target self-improvement hourly for 24 hours." `
  -Force | Out-Null

if ($StartNow) {
  Start-ScheduledTask -TaskName $TaskName
}

Get-ScheduledTask -TaskName $TaskName
